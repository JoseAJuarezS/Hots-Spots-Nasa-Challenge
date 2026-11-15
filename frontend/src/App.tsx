import { useEffect, useState } from 'react';
import { Calendar, Flame, Info } from 'lucide-react';
import type { BBox, KMes, MetadatosDataset, ResumenAnalitico } from './types/fire';
import {
  cargarAuxiliares,
  consultarArea,
  consultarPuntosMes,
  type FocoIndividual,
} from './services/duckdbService';
import { MapaSelector } from './components/MapaSelector';
import { CalendarioQuemas } from './components/CalendarioQuemas';
import { BannerDiagnostico, TarjetasRankings } from './components/PanelResumen';

const MESES_SELECTOR = [
  'Enero', 'Febrero', 'Marzo', 'Abril', 'Mayo', 'Junio',
  'Julio', 'Agosto', 'Septiembre', 'Octubre', 'Noviembre', 'Diciembre',
];

const ANIOS_SELECTOR = Array.from({ length: 26 }, (_, i) => 2000 + i);

export function App() {
  const [kMes, setKMes] = useState<KMes[]>([]);
  const [metadatos, setMetadatos] = useState<MetadatosDataset | null>(null);
  const [bbox, setBBox] = useState<BBox | null>(null);
  const [anioObjetivo, setAnioObjetivo] = useState<number>(2025);
  const [mesObjetivo, setMesObjetivo] = useState<number>(3);

  const [resumen, setResumen] = useState<ResumenAnalitico | null>(null);
  const [focosMes, setFocosMes] = useState<FocoIndividual[]>([]);
  const [cargando, setCargando] = useState<boolean>(true);
  const [error, setError] = useState<string | null>(null);
  const [mostrarInfo, setMostrarInfo] = useState<boolean>(false);

  useEffect(() => {
    cargarAuxiliares()
      .then(({ kMes: k, metadatos: meta }) => {
        setKMes(k);
        setMetadatos(meta);
      })
      .catch((err) => {
        console.error(err);
        setError('No se pudieron cargar los metadatos en /data/.');
      });
  }, []);

  useEffect(() => {
    if (kMes.length === 0) return;
    let cancelado = false;
    setCargando(true);

    Promise.all([
      consultarArea(bbox, kMes, anioObjetivo, mesObjetivo),
      consultarPuntosMes(anioObjetivo, mesObjetivo, bbox),
    ])
      .then(([datos, puntosIndividuales]) => {
        if (!cancelado) {
          setResumen(datos);
          setFocosMes(puntosIndividuales);
          setError(null);
        }
      })
      .catch((err) => {
        console.error(err);
        if (!cancelado) {
          setError('Error al consultar los archivos Parquet en DuckDB-WASM.');
        }
      })
      .finally(() => {
        if (!cancelado) setCargando(false);
      });

    return () => {
      cancelado = true;
    };
  }, [bbox, kMes, anioObjetivo, mesObjetivo]);

  return (
    <div className="min-h-screen bg-slate-950 text-slate-100">
      <header className="border-b border-slate-800/90 bg-slate-950/90 backdrop-blur">
        <div className="mx-auto flex max-w-[1440px] flex-wrap items-center justify-between gap-3 px-4 py-3">
          <div className="flex items-center gap-2.5">
            <div className="flex h-9 w-9 items-center justify-center rounded-lg border border-orange-500/40 bg-orange-500/15">
              <Flame className="h-5 w-5 text-orange-400" />
            </div>
            <div>
              <h1 className="text-base font-bold tracking-tight text-white sm:text-lg">
                Calendario Armonizado de Actividad de Quemas
              </h1>
              <p className="text-xs text-slate-400">
                MODIS (2000–2012) + VIIRS S-NPP (2012–2025) · {metadatos?.region ?? 'India'}
              </p>
            </div>
          </div>

          <div className="flex items-center gap-2">
            <div className="flex items-center gap-1.5 rounded-lg border border-slate-800 bg-slate-900 px-2.5 py-1.5 text-xs">
              <Calendar className="h-3.5 w-3.5 text-orange-400" />
              <select
                aria-label="Mes a evaluar"
                value={mesObjetivo}
                onChange={(e) => setMesObjetivo(Number(e.target.value))}
                className="bg-transparent text-slate-200 focus:outline-none"
              >
                {MESES_SELECTOR.map((nombre, idx) => (
                  <option key={nombre} value={idx + 1} className="bg-slate-900">
                    {nombre}
                  </option>
                ))}
              </select>
              <select
                aria-label="Año a evaluar"
                value={anioObjetivo}
                onChange={(e) => setAnioObjetivo(Number(e.target.value))}
                className="bg-transparent text-slate-200 focus:outline-none"
              >
                {ANIOS_SELECTOR.map((a) => (
                  <option key={a} value={a} className="bg-slate-900">
                    {a}
                  </option>
                ))}
              </select>
            </div>

            <button
              type="button"
              onClick={() => setMostrarInfo((v) => !v)}
              className="inline-flex items-center gap-1.5 rounded-lg border border-slate-800 bg-slate-900 px-3 py-1.5 text-xs text-slate-300 hover:text-white"
            >
              <Info className="h-3.5 w-3.5 text-sky-400" />
              Metodología
            </button>
          </div>
        </div>

        {mostrarInfo && metadatos && (
          <div className="border-t border-slate-800 bg-slate-900/90 px-4 py-3 text-xs text-slate-300">
            <div className="mx-auto max-w-[1440px] space-y-1">
              <p>
                <strong className="text-white">Armonización MODIS → VIIRS S-NPP:</strong> Los
                registros históricos de MODIS (1 km) se calibran por mes del año usando el periodo
                de traslape 2012–2018 (correlación r = 0.987 en validación 2019–2025) para eliminar
                el salto artificial de resolución entre sensores.
              </p>
              <p className="text-slate-400">
                Filtros aplicados: {metadatos.filtros_aplicados} · Rejilla espacial:{' '}
                {metadatos.resolucion_rejilla_grados}° · Registros base:{' '}
                {metadatos.total_registros_armonizados.toLocaleString('es-MX')}.
              </p>
            </div>
          </div>
        )}
      </header>

      <main className="mx-auto flex max-w-[1440px] flex-col gap-4 px-4 py-4">
        {error && (
          <div className="rounded-xl border border-rose-500/40 bg-rose-950/50 p-4 text-sm text-rose-200">
            {error}
          </div>
        )}

        {cargando && !resumen ? (
          <div className="flex h-72 items-center justify-center rounded-xl border border-slate-800 bg-slate-900/40 text-sm text-slate-400">
            Cargando globo 3D, motor analítico DuckDB-WASM y serie 2000–2025...
          </div>
        ) : (
          resumen && (
            <>
              {/* 1. Franja ejecutiva superior (ancho completo) */}
              <BannerDiagnostico
                resumen={resumen}
                anioSeleccionado={anioObjetivo}
                mesSeleccionado={mesObjetivo}
                bbox={bbox}
                puntosMapa={resumen.puntosMapa}
              />

              {/* 2. Espacio de trabajo simétrico 50% Globo/Rankings | 50% Calendario */}
              <div className="grid grid-cols-1 items-start gap-4 lg:grid-cols-12">
                <div className="flex flex-col gap-4 lg:col-span-6">
                  <MapaSelector
                    focosMes={focosMes}
                    anioActivo={anioObjetivo}
                    mesActivo={mesObjetivo}
                    bbox={bbox}
                    onCambiarBBox={setBBox}
                  />

                  <TarjetasRankings
                    resumen={resumen}
                    onSeleccionarMes={(anio, mes) => {
                      setAnioObjetivo(anio);
                      setMesObjetivo(mes);
                    }}
                  />
                </div>

                <div className="lg:col-span-6">
                  <CalendarioQuemas
                    celdas={resumen.celdas}
                    anioSeleccionado={anioObjetivo}
                    mesSeleccionado={mesObjetivo}
                    onSeleccionarCelda={(anio, mes) => {
                      setAnioObjetivo(anio);
                      setMesObjetivo(mes);
                    }}
                  />
                </div>
              </div>
            </>
          )
        )}
      </main>
    </div>
  );
}

export default App;