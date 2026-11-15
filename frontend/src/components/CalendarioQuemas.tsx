import { useMemo, useState } from 'react';
import type { CeldaCalendario } from '../types/fire';

interface Props {
  celdas: CeldaCalendario[];
  anioSeleccionado: number;
  mesSeleccionado: number;
  onSeleccionarCelda: (anio: number, mes: number) => void;
}

const NOMBRES_MESES = [
  'Ene', 'Feb', 'Mar', 'Abr', 'May', 'Jun',
  'Jul', 'Ago', 'Sep', 'Oct', 'Nov', 'Dic',
];

const ANIOS = Array.from({ length: 26 }, (_, i) => 2000 + i);

function colorAbsoluto(valor: number, maxVal: number): string {
  if (valor <= 0 || maxVal <= 0) return 'bg-slate-900/70 text-slate-500';
  // Escala raíz cuadrada para que meses moderados no queden aplastados por picos extremos
  const ratio = Math.sqrt(valor / maxVal);
  if (ratio < 0.15) return 'bg-amber-950/80 text-amber-200 border-amber-900/50';
  if (ratio < 0.30) return 'bg-amber-800/85 text-amber-100 border-amber-700/50';
  if (ratio < 0.50) return 'bg-orange-600/90 text-white border-orange-500/50';
  if (ratio < 0.75) return 'bg-red-600 text-white border-red-400/60';
  return 'bg-rose-500 text-slate-950 font-bold border-rose-300';
}

function colorAnomalia(pct: number | null): string {
  if (pct === null) return 'bg-slate-900/70 text-slate-500';
  if (pct <= -50) return 'bg-sky-700/90 text-sky-50 border-sky-500/50';
  if (pct <= -20) return 'bg-sky-900/80 text-sky-200 border-sky-700/50';
  if (pct < 20) return 'bg-slate-800/90 text-slate-200 border-slate-700/60';
  if (pct < 50) return 'bg-orange-700/85 text-orange-100 border-orange-500/50';
  if (pct < 100) return 'bg-red-600/90 text-white border-red-400/60';
  return 'bg-rose-500 text-slate-950 font-bold border-rose-300';
}

function formatearCompacto(n: number): string {
  if (n >= 100000) return `${(n / 1000).toFixed(0)}k`;
  if (n >= 10000) return `${(n / 1000).toFixed(1)}k`;
  if (n >= 1000) return `${(n / 1000).toFixed(1)}k`;
  return String(n);
}

export function CalendarioQuemas({
  celdas,
  anioSeleccionado,
  mesSeleccionado,
  onSeleccionarCelda,
}: Props) {
  const [modo, setModo] = useState<'absoluto' | 'anomalia'>('absoluto');
  const [hoverCelda, setHoverCelda] = useState<CeldaCalendario | null>(null);

  const { mapaCeldas, maxArmonizado } = useMemo(() => {
    const mapa = new Map<string, CeldaCalendario>();
    let max = 0;
    for (const c of celdas) {
      mapa.set(`${c.anio}-${c.mes}`, c);
      if (c.armonizado > max) max = c.armonizado;
    }
    return { mapaCeldas: mapa, maxArmonizado: max };
  }, [celdas]);

  return (
    <section className="rounded-xl border border-slate-800 bg-slate-900/60 p-4 sm:p-5">
      {/* Encabezado y selector de modo */}
      <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <div>
          <h2 className="text-lg font-semibold text-slate-100">
            Calendario de actividad de quemas (2000–2025)
          </h2>
          <p className="text-xs text-slate-400">
            Escala equivalente a VIIRS S-NPP · Haz clic en cualquier celda para inspeccionar ese mes
          </p>
        </div>

        <div className="inline-flex rounded-lg border border-slate-700 bg-slate-950 p-1 text-xs">
          <button
            type="button"
            onClick={() => setModo('absoluto')}
            className={`rounded-md px-3 py-1.5 font-medium transition ${
              modo === 'absoluto'
                ? 'bg-orange-500 text-slate-950'
                : 'text-slate-300 hover:text-white'
            }`}
          >
            Focos armonizados
          </button>
          <button
            type="button"
            onClick={() => setModo('anomalia')}
            className={`rounded-md px-3 py-1.5 font-medium transition ${
              modo === 'anomalia'
                ? 'bg-orange-500 text-slate-950'
                : 'text-slate-300 hover:text-white'
            }`}
          >
            Anomalía (% vs. mediana)
          </button>
        </div>
      </div>

      {/* Barra de inspección en vivo al pasar el cursor */}
      <div className="mt-3 flex min-h-[2.75rem] flex-wrap items-center justify-between gap-2 rounded-lg border border-slate-800 bg-slate-950/80 px-3 py-2 text-xs">
        {hoverCelda ? (
          <>
            <div className="flex flex-wrap items-center gap-2">
              <span className="font-semibold text-orange-400">
                {NOMBRES_MESES[hoverCelda.mes - 1]} {hoverCelda.anio}
              </span>
              <span className="rounded bg-slate-800 px-1.5 py-0.5 text-[11px] text-slate-300">
                Sensor: {hoverCelda.fuente}
              </span>
              {hoverCelda.bajaPrecision && (
                <span className="rounded border border-amber-500/40 bg-amber-950/60 px-1.5 py-0.5 text-[11px] text-amber-300">
                  Menor precisión (solo Terra)
                </span>
              )}
            </div>
            <div className="flex flex-wrap items-center gap-4 text-slate-300">
              <span>
                Armonizados:{' '}
                <strong className="text-white">
                  {hoverCelda.armonizado.toLocaleString('es-MX')}
                </strong>
              </span>
              {hoverCelda.fuente !== 'VIIRS' && (
                <span className="text-slate-400">
                  Rango IQR: {hoverCelda.incertidumbreMin.toLocaleString('es-MX')}–
                  {hoverCelda.incertidumbreMax.toLocaleString('es-MX')}
                </span>
              )}
              <span className="text-slate-400">
                Brutos: {hoverCelda.bruto.toLocaleString('es-MX')}
              </span>
              <span>
                Anomalía:{' '}
                <strong
                  className={
                    (hoverCelda.anomaliaPct ?? 0) > 20
                      ? 'text-rose-400'
                      : (hoverCelda.anomaliaPct ?? 0) < -20
                        ? 'text-sky-400'
                        : 'text-slate-200'
                  }
                >
                  {hoverCelda.anomaliaPct !== null
                    ? `${hoverCelda.anomaliaPct > 0 ? '+' : ''}${hoverCelda.anomaliaPct}%`
                    : 'N/D'}
                </strong>
              </span>
            </div>
          </>
        ) : (
          <span className="text-slate-400">
            Pasa el cursor o toca una celda para ver los focos brutos, sensor de origen y banda de incertidumbre.
          </span>
        )}
      </div>

      {/* Cuadrícula 26 años x 12 meses */}
      <div className="mt-4 overflow-x-auto">
        <table className="w-full min-w-[640px] border-collapse text-center text-xs">
          <thead>
            <tr>
              <th className="w-16 pb-2 text-left font-medium text-slate-400">Año</th>
              {NOMBRES_MESES.map((m) => (
                <th key={m} className="pb-2 font-medium text-slate-400">
                  {m}
                </th>
              ))}
            </tr>
          </thead>
          <tbody className="divide-y divide-slate-900/40">
            {ANIOS.map((anio) => {
              const esBajaPrecision = anio <= 2002;
              return (
                <tr key={anio} className="hover:bg-slate-800/30">
                  <td className="py-0.5 pr-2 text-left font-mono text-[11px] text-slate-300">
                    <span className="inline-flex items-center gap-1">
                      {anio}
                      {esBajaPrecision && (
                        <span
                          title="2000–2002: calibrado solo con Terra (menor precisión)"
                          className="text-amber-400"
                        >
                          *
                        </span>
                      )}
                    </span>
                  </td>
                  {Array.from({ length: 12 }, (_, idx) => {
                    const mes = idx + 1;
                    const celda = mapaCeldas.get(`${anio}-${mes}`);
                    const activa = anio === anioSeleccionado && mes === mesSeleccionado;

                    if (!celda) {
                      return (
                        <td key={mes} className="p-[1.5px]">
                          <div className="flex h-[22px] items-center justify-center rounded bg-slate-950/60 text-[10px] text-slate-700">
                            —
                          </div>
                        </td>
                      );
                    }

                    const claseColor =
                      modo === 'absoluto'
                        ? colorAbsoluto(celda.armonizado, maxArmonizado)
                        : colorAnomalia(celda.anomaliaPct);

                    const etiqueta =
                      modo === 'absoluto'
                        ? formatearCompacto(celda.armonizado)
                        : celda.anomaliaPct !== null
                          ? `${celda.anomaliaPct > 0 ? '+' : ''}${celda.anomaliaPct}%`
                          : '0%';

                    return (
                      <td key={mes} className="p-[1.5px]">
                        <button
                          type="button"
                          onMouseEnter={() => setHoverCelda(celda)}
                          onFocus={() => setHoverCelda(celda)}
                          onClick={() => onSeleccionarCelda(anio, mes)}
                          className={`flex h-[22px] w-full items-center justify-center rounded border text-[11px] transition ${claseColor} ${
                            esBajaPrecision ? 'border-dashed' : ''
                          } ${
                            activa
                              ? 'ring-2 ring-white ring-offset-1 ring-offset-slate-950'
                              : 'hover:brightness-110'
                          }`}
                        >
                          {etiqueta}
                        </button>
                      </td>
                    );
                  })}
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>

      {/* Leyenda */}
      <div className="mt-4 flex flex-wrap items-center justify-between gap-3 border-t border-slate-800 pt-3 text-[11px] text-slate-400">
        <div className="flex flex-wrap items-center gap-2">
          <span>Leyenda:</span>
          {modo === 'absoluto' ? (
            <>
              <span className="inline-flex items-center gap-1">
                <span className="h-3 w-3 rounded bg-amber-950 border border-amber-800" /> Bajo
              </span>
              <span className="inline-flex items-center gap-1">
                <span className="h-3 w-3 rounded bg-orange-600" /> Moderado
              </span>
              <span className="inline-flex items-center gap-1">
                <span className="h-3 w-3 rounded bg-red-600" /> Alto
              </span>
              <span className="inline-flex items-center gap-1">
                <span className="h-3 w-3 rounded bg-rose-500" /> Extremo
              </span>
            </>
          ) : (
            <>
              <span className="inline-flex items-center gap-1">
                <span className="h-3 w-3 rounded bg-sky-700" /> Muy bajo (&le;-50%)
              </span>
              <span className="inline-flex items-center gap-1">
                <span className="h-3 w-3 rounded bg-slate-800 border border-slate-600" /> Normal (&plusmn;20%)
              </span>
              <span className="inline-flex items-center gap-1">
                <span className="h-3 w-3 rounded bg-red-600" /> Alto (+50% a +100%)
              </span>
              <span className="inline-flex items-center gap-1">
                <span className="h-3 w-3 rounded bg-rose-500" /> Anomalía extrema (&gt;+100%)
              </span>
            </>
          )}
        </div>
        <span>* 2000–2002 (borde punteado): calibración solo con Terra</span>
      </div>
    </section>
  );
}
