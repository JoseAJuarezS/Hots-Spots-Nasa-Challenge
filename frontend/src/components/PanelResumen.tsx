import { Download, Flame, TrendingUp } from 'lucide-react';
import type { BBox, PuntoMapa, ResumenAnalitico } from '../types/fire';

interface Props {
  resumen: ResumenAnalitico;
  anioSeleccionado: number;
  mesSeleccionado: number;
  bbox: BBox | null;
  puntosMapa: PuntoMapa[];
}

const MESES_LARGOS = [
  'Enero', 'Febrero', 'Marzo', 'Abril', 'Mayo', 'Junio',
  'Julio', 'Agosto', 'Septiembre', 'Octubre', 'Noviembre', 'Diciembre',
];

function descargarArchivoCSV(nombreArchivo: string, contenidoCSV: string) {
  const blob = new Blob(['\uFEFF' + contenidoCSV], { type: 'text/csv;charset=utf-8;' });
  const url = URL.createObjectURL(blob);
  const enlace = document.createElement('a');
  enlace.href = url;
  enlace.setAttribute('download', nombreArchivo);
  document.body.appendChild(enlace);
  enlace.click();
  document.body.removeChild(enlace);
  URL.revokeObjectURL(url);
}

export function BannerDiagnostico({
  resumen,
  anioSeleccionado,
  mesSeleccionado,
  bbox,
  puntosMapa,
}: Props) {
  const actual = resumen.mesSeleccionado;
  const nombreMes = MESES_LARGOS[mesSeleccionado - 1];

  const exportarCalendarioCSV = () => {
    const encabezados = [
      'anio',
      'mes',
      'fuente_sensor',
      'focos_armonizados_viirs_eq',
      'focos_brutos',
      'mediana_historica_mes',
      'anomalia_pct',
      'incertidumbre_p25',
      'incertidumbre_p75',
      'frp_total_mw',
      'baja_precision_2000_2002',
    ];
    const filas = resumen.celdas.map((c) =>
      [
        c.anio,
        c.mes,
        c.fuente,
        c.armonizado,
        c.bruto,
        c.medianaHistorica,
        c.anomaliaPct ?? '',
        c.incertidumbreMin,
        c.incertidumbreMax,
        c.frp,
        c.bajaPrecision ? 'si' : 'no',
      ].join(',')
    );
    const sufijo = bbox ? 'subregion' : 'india_completa';
    descargarArchivoCSV(
      `calendario_armonizado_${sufijo}_2000_2025.csv`,
      [encabezados.join(','), ...filas].join('\n')
    );
  };

  const exportarCeldasEspacialesCSV = () => {
    const encabezados = ['latitud', 'longitud', 'focos_armonizados_acumulados', 'focos_brutos', 'frp_total_mw'];
    const filas = puntosMapa.map((p) =>
      [p.lat, p.lon, Math.round(p.armonizado), p.bruto, Math.round(p.frp)].join(',')
    );
    const sufijo = bbox ? 'subregion' : 'india_completa';
    descargarArchivoCSV(
      `celdas_espaciales_${sufijo}.csv`,
      [encabezados.join(','), ...filas].join('\n')
    );
  };

  return (
    <section className="rounded-xl border border-slate-800/90 bg-gradient-to-r from-slate-900 via-slate-900 to-orange-950/25 px-4 py-3.5 sm:px-5">
      <div className="flex flex-col gap-3 lg:flex-row lg:items-center lg:justify-between">
        <div className="space-y-1">
          <div className="flex flex-wrap items-center gap-2">
            <span className="text-[11px] font-semibold tracking-wider text-orange-400 uppercase">
              Diagnóstico {bbox?.nombre ? `· ${bbox.nombre}` : '· Toda India'}
            </span>
            {actual && (
              <span className="rounded-full border border-slate-700/80 bg-slate-950/80 px-2 py-0.5 text-[11px] text-slate-300">
                Sensor: <strong className="text-white">{actual.fuente}</strong> ({actual.bruto.toLocaleString('es-MX')} brutos)
              </span>
            )}
          </div>

          {actual ? (
            <p className="text-base font-semibold text-slate-100 sm:text-lg">
              {nombreMes} de {anioSeleccionado}:{' '}
              {actual.anomaliaPct !== null ? (
                <span
                  className={
                    actual.anomaliaPct > 15
                      ? 'text-rose-400'
                      : actual.anomaliaPct < -15
                        ? 'text-sky-400'
                        : 'text-emerald-400'
                  }
                >
                  {actual.anomaliaPct > 0
                    ? `+${actual.anomaliaPct}% por encima de lo normal`
                    : actual.anomaliaPct < 0
                      ? `${Math.abs(actual.anomaliaPct)}% por debajo de lo normal`
                      : 'en el nivel normal histórico'}
                </span>
              ) : (
                <span className="text-slate-300">sin referencia histórica suficiente</span>
              )}
              {resumen.rankingEnSuMes !== null && (
                <span className="font-normal text-slate-300">
                  {' '}
                  — <strong className="text-white">{resumen.rankingEnSuMes}.º</strong> {nombreMes.toLowerCase()} más activo de {resumen.totalAniosEnMes} años.
                </span>
              )}
            </p>
          ) : (
            <p className="text-sm text-slate-300">
              Sin registros para {nombreMes} de {anioSeleccionado} en esta área.
            </p>
          )}
        </div>

        {/* KPIs rápidos + Botones CSV */}
        <div className="flex flex-wrap items-center gap-3">
          {actual && (
            <div className="flex items-center gap-4 rounded-lg border border-slate-800 bg-slate-950/70 px-3 py-1.5 text-xs">
              <div>
                <span className="block text-[10px] text-slate-400">Armonizados</span>
                <strong className="font-mono text-sm text-white">
                  {actual.armonizado.toLocaleString('es-MX')}
                </strong>
              </div>
              <div className="h-6 w-px bg-slate-800" />
              <div>
                <span className="block text-[10px] text-slate-400">Mediana ({nombreMes})</span>
                <strong className="font-mono text-sm text-slate-300">
                  {actual.medianaHistorica.toLocaleString('es-MX')}
                </strong>
              </div>
            </div>
          )}

          <div className="flex items-center gap-2">
            <button
              type="button"
              onClick={exportarCalendarioCSV}
              className="inline-flex items-center gap-1.5 rounded-lg border border-orange-500/40 bg-orange-500/15 px-3 py-2 text-xs font-medium text-orange-200 transition hover:bg-orange-500/25"
            >
              <Download className="h-3.5 w-3.5" />
              CSV Serie
            </button>
            <button
              type="button"
              onClick={exportarCeldasEspacialesCSV}
              className="inline-flex items-center gap-1.5 rounded-lg border border-slate-700 bg-slate-800/80 px-3 py-2 text-xs font-medium text-slate-200 transition hover:bg-slate-800"
            >
              <Download className="h-3.5 w-3.5" />
              CSV Mapa
            </button>
          </div>
        </div>
      </div>
    </section>
  );
}

interface RankingsProps {
  resumen: ResumenAnalitico;
  onSeleccionarMes: (anio: number, mes: number) => void;
}

export function TarjetasRankings({ resumen, onSeleccionarMes }: RankingsProps) {
  return (
    <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
      <div className="rounded-xl border border-slate-800 bg-slate-900/50 p-3.5">
        <div className="flex items-center justify-between">
          <div className="flex items-center gap-1.5 text-xs font-semibold text-slate-200">
            <Flame className="h-3.5 w-3.5 text-orange-400" />
            <span>Top 5 meses críticos</span>
          </div>
          <span className="text-[10px] text-slate-500">Clic para ver</span>
        </div>
        <ul className="mt-2 divide-y divide-slate-800/70 text-xs">
          {resumen.topMeses.map((m, idx) => (
            <li key={`${m.anio}-${m.mes}`}>
              <button
                type="button"
                onClick={() => onSeleccionarMes(m.anio, m.mes)}
                className="flex w-full items-center justify-between rounded px-1 py-1.5 text-left transition hover:bg-slate-800/60"
              >
                <span className="text-slate-300">
                  <strong className="mr-1.5 font-mono text-slate-500">#{idx + 1}</strong>
                  {MESES_LARGOS[m.mes - 1]} {m.anio}
                  {m.bajaPrecision && <span className="ml-1 text-amber-400">*</span>}
                </span>
                <span className="font-mono font-medium text-orange-300">
                  {m.armonizado.toLocaleString('es-MX')}
                </span>
              </button>
            </li>
          ))}
        </ul>
      </div>

      <div className="rounded-xl border border-slate-800 bg-slate-900/50 p-3.5">
        <div className="flex items-center gap-1.5 text-xs font-semibold text-slate-200">
          <TrendingUp className="h-3.5 w-3.5 text-rose-400" />
          <span>Top 5 años críticos</span>
        </div>
        <ul className="mt-2 divide-y divide-slate-800/70 text-xs">
          {resumen.topAnios.map((a, idx) => (
            <li key={a.anio} className="flex items-center justify-between px-1 py-1.5">
              <span className="text-slate-300">
                <strong className="mr-1.5 font-mono text-slate-500">#{idx + 1}</strong>
                Año {a.anio}
                {a.bajaPrecision && <span className="ml-1 text-amber-400">*</span>}
              </span>
              <span className="font-mono font-medium text-rose-300">
                {a.totalArmonizado.toLocaleString('es-MX')}
              </span>
            </li>
          ))}
        </ul>
      </div>
    </div>
  );
}