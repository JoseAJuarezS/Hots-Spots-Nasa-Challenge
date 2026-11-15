export type FuenteSensor = 'TERRA' | 'MODIS' | 'VIIRS';

export interface BBox {
  minLat: number;
  maxLat: number;
  minLon: number;
  maxLon: number;
  nombre?: string;
}

export interface KMes {
  mes: number;
  k_modis: number;
  k_modis_p25: number;
  k_modis_p75: number;
  k_terra: number;
}

export interface MetadatosDataset {
  region: string;
  fecha_inicio: string;
  fecha_fin: string;
  resolucion_rejilla_grados: number;
  escala_referencia: string;
  filtros_aplicados: string;
  total_registros_armonizados: number;
}

export interface CeldaCalendario {
  anio: number;
  mes: number; // 1..12
  fuente: FuenteSensor;
  armonizado: number;
  bruto: number;
  frp: number;
  medianaHistorica: number;
  anomaliaPct: number | null; // % respecto a la mediana de ese mes
  incertidumbreMin: number;
  incertidumbreMax: number;
  bajaPrecision: boolean; // true para 2000-2002 (solo Terra)
}

export interface PuntoMapa {
  lat: number;
  lon: number;
  armonizado: number;
  bruto: number;
  frp: number;
}

export interface ResumenAnalitico {
  celdas: CeldaCalendario[];
  puntosMapa: PuntoMapa[];
  topMeses: CeldaCalendario[];
  topAnios: { anio: number; totalArmonizado: number; totalBruto: number; bajaPrecision: boolean }[];
  mesSeleccionado: CeldaCalendario | null;
  rankingEnSuMes: number | null;
  totalAniosEnMes: number;
}
