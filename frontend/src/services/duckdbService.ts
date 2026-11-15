import * as duckdb from '@duckdb/duckdb-wasm';
import duckdb_wasm from '@duckdb/duckdb-wasm/dist/duckdb-mvp.wasm?url';
import mvp_worker from '@duckdb/duckdb-wasm/dist/duckdb-browser-mvp.worker.js?url';
import duckdb_wasm_eh from '@duckdb/duckdb-wasm/dist/duckdb-eh.wasm?url';
import eh_worker from '@duckdb/duckdb-wasm/dist/duckdb-browser-eh.worker.js?url';
import type {
  BBox,
  CeldaCalendario,
  FuenteSensor,
  KMes,
  MetadatosDataset,
  PuntoMapa,
  ResumenAnalitico,
} from '../types/fire';

const MANUAL_BUNDLES: duckdb.DuckDBBundles = {
  mvp: {
    mainModule: duckdb_wasm,
    mainWorker: mvp_worker,
  },
  eh: {
    mainModule: duckdb_wasm_eh,
    mainWorker: eh_worker,
  },
};

let dbInstance: duckdb.AsyncDuckDB | null = null;
let initPromise: Promise<duckdb.AsyncDuckDB> | null = null;

export async function getDuckDB(): Promise<duckdb.AsyncDuckDB> {
  if (dbInstance) return dbInstance;
  if (initPromise) return initPromise;

  initPromise = (async () => {
    const bundle = await duckdb.selectBundle(MANUAL_BUNDLES);
    const worker = new Worker(bundle.mainWorker!);
    const logger = new duckdb.ConsoleLogger(duckdb.LogLevel.WARNING);
    const db = new duckdb.AsyncDuckDB(logger, worker);
    await db.instantiate(bundle.mainModule, bundle.pthreadWorker);

    const response = await fetch('/data/celdas_mes.parquet');
    if (!response.ok) {
      throw new Error('No se pudo cargar /data/celdas_mes.parquet');
    }
    const buffer = await response.arrayBuffer();
    await db.registerFileBuffer('celdas_mes.parquet', new Uint8Array(buffer));

    dbInstance = db;
    return db;
  })();

  return initPromise;
}

export async function cargarAuxiliares(): Promise<{
  kMes: KMes[];
  metadatos: MetadatosDataset;
}> {
  const [resK, resMeta] = await Promise.all([
    fetch('/data/k_mes.json'),
    fetch('/data/metadatos.json'),
  ]);
  const kMes: KMes[] = await resK.json();
  const metadatos: MetadatosDataset = await resMeta.json();
  return { kMes, metadatos };
}

function calcularMediana(valores: number[]): number {
  if (valores.length === 0) return 0;
  const ordenados = [...valores].sort((a, b) => a - b);
  const mitad = Math.floor(ordenados.length / 2);
  return ordenados.length % 2 !== 0
    ? ordenados[mitad]
    : (ordenados[mitad - 1] + ordenados[mitad]) / 2;
}

export async function consultarArea(
  bbox: BBox | null,
  kMesList: KMes[],
  anioObjetivo: number,
  mesObjetivo: number
): Promise<ResumenAnalitico> {
  const db = await getDuckDB();
  const conn = await db.connect();

  const whereClause = bbox
    ? `WHERE lat BETWEEN ${Number(bbox.minLat)} AND ${Number(bbox.maxLat)}
         AND lon BETWEEN ${Number(bbox.minLon)} AND ${Number(bbox.maxLon)}`
    : '';

  // 1. Serie agregada por año y mes para construir el calendario
  const resCalendario = await conn.query(`
    SELECT
      YEAR(mes)::INT AS anio,
      MONTH(mes)::INT AS mes_num,
      ANY_VALUE(fuente) AS fuente,
      SUM(focos_armonizados)::DOUBLE AS armonizado,
      SUM(focos_brutos)::INT AS bruto,
      SUM(frp_total)::DOUBLE AS frp
    FROM 'celdas_mes.parquet'
    ${whereClause}
    GROUP BY 1, 2
    ORDER BY 1, 2
  `);

  // 2. Agregación espacial por celda (0.1°) para pintar el mapa de calor
  const resMapa = await conn.query(`
    SELECT
      lat::DOUBLE AS lat,
      lon::DOUBLE AS lon,
      SUM(focos_armonizados)::DOUBLE AS armonizado,
      SUM(focos_brutos)::INT AS bruto,
      SUM(frp_total)::DOUBLE AS frp
    FROM 'celdas_mes.parquet'
    ${whereClause}
    GROUP BY 1, 2
    ORDER BY armonizado DESC
    LIMIT 15000
  `);

  await conn.close();

  const mapaK = new Map<number, KMes>();
  kMesList.forEach((item) => mapaK.set(item.mes, item));

  const filasCrudas = resCalendario.toArray().map((row) => ({
    anio: Number(row.anio),
    mes: Number(row.mes_num),
    fuente: String(row.fuente) as FuenteSensor,
    armonizado: Math.round(Number(row.armonizado)),
    bruto: Number(row.bruto),
    frp: Math.round(Number(row.frp)),
  }));

  // Agrupar valores por mes del año (1..12) para calcular mediana histórica
  const valoresPorMes = new Map<number, number[]>();
  for (let m = 1; m <= 12; m++) valoresPorMes.set(m, []);
  filasCrudas.forEach((f) => valoresPorMes.get(f.mes)?.push(f.armonizado));

  const medianasPorMes = new Map<number, number>();
  valoresPorMes.forEach((vals, m) => {
    medianasPorMes.set(m, calcularMediana(vals));
  });

  const celdas: CeldaCalendario[] = filasCrudas.map((f) => {
    const mediana = medianasPorMes.get(f.mes) ?? 0;
    const anomaliaPct =
      mediana > 0 ? Math.round(((f.armonizado - mediana) / mediana) * 100) : null;

    const kInfo = mapaK.get(f.mes);
    let incMin = f.armonizado;
    let incMax = f.armonizado;
    if (f.fuente === 'MODIS' && kInfo) {
      incMin = Math.round(f.bruto * kInfo.k_modis_p25);
      incMax = Math.round(f.bruto * kInfo.k_modis_p75);
    } else if (f.fuente === 'TERRA') {
      // Margen empírico observado en validación (-6% a +11% / error mediano ~17%)
      incMin = Math.round(f.armonizado * 0.82);
      incMax = Math.round(f.armonizado * 1.18);
    }

    return {
      ...f,
      medianaHistorica: Math.round(mediana),
      anomaliaPct,
      incertidumbreMin: incMin,
      incertidumbreMax: incMax,
      bajaPrecision: f.anio <= 2002,
    };
  });

  // Top 5 meses más activos
  const topMeses = [...celdas]
    .sort((a, b) => b.armonizado - a.armonizado)
    .slice(0, 5);

  // Top 5 años más activos
  const acumuladoAnios = new Map<
    number,
    { armonizado: number; bruto: number; meses: number }
  >();
  celdas.forEach((c) => {
    const prev = acumuladoAnios.get(c.anio) ?? { armonizado: 0, bruto: 0, meses: 0 };
    acumuladoAnios.set(c.anio, {
      armonizado: prev.armonizado + c.armonizado,
      bruto: prev.bruto + c.bruto,
      meses: prev.meses + 1,
    });
  });

  const topAnios = Array.from(acumuladoAnios.entries())
    .filter(([anio]) => anio > 2000) // 2000 solo tiene Nov-Dic
    .map(([anio, datos]) => ({
      anio,
      totalArmonizado: datos.armonizado,
      totalBruto: datos.bruto,
      bajaPrecision: anio <= 2002,
    }))
    .sort((a, b) => b.totalArmonizado - a.totalArmonizado)
    .slice(0, 5);

  // Evaluación del mes y año seleccionados para la "Respuesta en una frase"
  const mesSeleccionado =
    celdas.find((c) => c.anio === anioObjetivo && c.mes === mesObjetivo) ?? null;

  const mismosMesesOrdenados = celdas
    .filter((c) => c.mes === mesObjetivo)
    .sort((a, b) => b.armonizado - a.armonizado);

  const idxRanking = mismosMesesOrdenados.findIndex((c) => c.anio === anioObjetivo);

  const puntosMapa: PuntoMapa[] = resMapa.toArray().map((r) => ({
    lat: Number(r.lat),
    lon: Number(r.lon),
    armonizado: Number(r.armonizado),
    bruto: Number(r.bruto),
    frp: Number(r.frp),
  }));

  return {
    celdas,
    puntosMapa,
    topMeses,
    topAnios,
    mesSeleccionado,
    rankingEnSuMes: idxRanking >= 0 ? idxRanking + 1 : null,
    totalAniosEnMes: mismosMesesOrdenados.length,
  };
}

export interface FocoIndividual {
  fecha: string;
  lat: number;
  lon: number;
  sensor: string;
  fuente: string;
  peso: number;
  frp: number;
  daynight: string;
}

const archivosAnioRegistrados = new Set<number>();

export async function consultarPuntosMes(
  anio: number,
  mes: number,
  bbox: BBox | null
): Promise<FocoIndividual[]> {
  const db = await getDuckDB();
  const nombreVirtual = `focos_${anio}.parquet`;

  if (!archivosAnioRegistrados.has(anio)) {
    const resp = await fetch(`/data/focos/anio=${anio}/data_0.parquet`);
    if (!resp.ok) return [];
    const buf = await resp.arrayBuffer();
    await db.registerFileBuffer(nombreVirtual, new Uint8Array(buf));
    archivosAnioRegistrados.add(anio);
  }

  const conn = await db.connect();
  const filtroEspacial = bbox
    ? `AND latitude BETWEEN ${Number(bbox.minLat)} AND ${Number(bbox.maxLat)}
       AND longitude BETWEEN ${Number(bbox.minLon)} AND ${Number(bbox.maxLon)}`
    : '';

  // Ordenamos por FRP descendente y limitamos a 25,000 puntos para mantener 60 FPS en el globo 3D
  const res = await conn.query(`
    SELECT
      CAST(fecha AS VARCHAR) AS fecha,
      latitude::DOUBLE AS lat,
      longitude::DOUBLE AS lon,
      sensor,
      fuente,
      peso::DOUBLE AS peso,
      COALESCE(frp, 0)::DOUBLE AS frp,
      COALESCE(daynight, 'D') AS daynight
    FROM '${nombreVirtual}'
    WHERE MONTH(fecha) = ${Number(mes)}
      ${filtroEspacial}
    ORDER BY frp DESC
    LIMIT 65000
  `);

  await conn.close();

  return res.toArray().map((r) => ({
    fecha: String(r.fecha),
    lat: Number(r.lat),
    lon: Number(r.lon),
    sensor: String(r.sensor),
    fuente: String(r.fuente),
    peso: Number(r.peso),
    frp: Number(r.frp),
    daynight: String(r.daynight),
  }));
}
