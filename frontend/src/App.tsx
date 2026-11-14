import { useEffect, useMemo, useState } from 'react'
import Mapa from './Mapa'
import { aGeoJSON, ANIOS, ESCALA, cargarAnio, cargarResumen, type Fuente, type MesResumen } from './datos'

const MESES = ['Ene', 'Feb', 'Mar', 'Abr', 'May', 'Jun', 'Jul', 'Ago', 'Sep', 'Oct', 'Nov', 'Dic']
const MESES_LARGOS = [
  'enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio',
  'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre',
]
const NOMBRE_FUENTE: Record<Fuente, string> = {
  TERRA: 'MODIS Terra (solo un satélite, menos preciso)',
  MODIS: 'MODIS Terra + Aqua, convertido a escala VIIRS',
  VIIRS: 'VIIRS S-NPP',
}

const fmt = new Intl.NumberFormat('es', { maximumFractionDigits: 0 })

function App() {
  const [anio, setAnio] = useState(2025)
  const [mes, setMes] = useState(0) // 0 = año completo
  const [datos, setDatos] = useState<Awaited<ReturnType<typeof cargarAnio>> | null>(null)
  const [resumen, setResumen] = useState<MesResumen[]>([])
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    cargarResumen().then(setResumen, (e) => setError(e.message))
  }, [])

  useEffect(() => {
    let vigente = true
    cargarAnio(anio).then(
      (d) => vigente && (setDatos(d), setError(null)),
      (e) => vigente && setError(e.message),
    )
    return () => {
      vigente = false
    }
  }, [anio])

  const capa = useMemo(() => (datos ? aGeoJSON(datos, mes) : null), [datos, mes])

  // Fuente de los datos del periodo elegido (para avisar cuando es menos preciso).
  const fuentes = useMemo(() => {
    const prefijo = mes === 0 ? `${anio}-` : `${anio}-${String(mes).padStart(2, '0')}`
    return [...new Set(resumen.filter((r) => r.mes.startsWith(prefijo)).map((r) => r.fuente))]
  }, [resumen, anio, mes])

  const periodo = mes === 0 ? `${anio}` : `${MESES_LARGOS[mes - 1]} de ${anio}`

  return (
    <div className="flex h-dvh flex-col bg-white text-slate-900">
      <header className="flex flex-wrap items-baseline justify-between gap-x-6 gap-y-1 border-b border-slate-200 px-4 py-3">
        <h1 className="text-lg font-semibold">Focos de calor armonizados · India</h1>
        <p className="text-sm text-slate-500">MODIS + VIIRS en una sola escala, 2000–2025</p>
      </header>

      <section className="flex flex-col gap-3 border-b border-slate-200 px-4 py-3">
        <div className="flex items-center gap-3">
          <label htmlFor="anio" className="w-10 text-sm text-slate-500">
            Año
          </label>
          <input
            id="anio"
            type="range"
            min={ANIOS[0]}
            max={ANIOS.at(-1)}
            value={anio}
            onChange={(e) => setAnio(Number(e.target.value))}
            className="w-full max-w-xl accent-orange-600"
          />
          <span className="w-12 text-right font-semibold tabular-nums">{anio}</span>
        </div>
        <div className="flex items-center gap-3">
          <span className="w-10 text-sm text-slate-500">Mes</span>
          <div className="flex flex-wrap gap-1">
            {['Todo', ...MESES].map((nombre, k) => (
              <button
                key={nombre}
                type="button"
                onClick={() => setMes(k)}
                aria-pressed={mes === k}
                className={`rounded px-2 py-1 text-sm ${
                  mes === k ? 'bg-slate-900 text-white' : 'text-slate-600 hover:bg-slate-100'
                }`}
              >
                {nombre}
              </button>
            ))}
          </div>
        </div>
      </section>

      <main className="relative flex-1">
        <Mapa geojson={capa?.geojson ?? null} />

        <div className="absolute bottom-8 left-3 w-72 max-w-[calc(100%-1.5rem)] rounded-md bg-white/95 p-3 text-sm shadow-sm ring-1 ring-slate-200">
          {error ? (
            <p className="text-red-700">{error}</p>
          ) : (
            <>
              <p className="first-letter:uppercase">
                {periodo}:{' '}
                <strong className="tabular-nums">{capa ? fmt.format(capa.total) : '…'}</strong> focos
                armonizados
              </p>
              {fuentes.length > 0 && (
                <p className={`mt-1 text-xs ${fuentes.includes('TERRA') ? 'text-orange-700' : 'text-slate-500'}`}>
                  Fuente: {fuentes.map((f) => NOMBRE_FUENTE[f]).join('; ')}
                </p>
              )}
              <div className="mt-3">
                <p className="mb-1 text-xs text-slate-500">Focos por celda de 0,1° (~11 km)</p>
                <div className="flex">
                  {ESCALA.map(([v, c], k) => (
                    <div key={v} className="flex-1">
                      <div className="h-2" style={{ background: c }} />
                      <span className="text-[10px] text-slate-500 tabular-nums">
                        {k === 0 ? '<3' : `${v}+`}
                      </span>
                    </div>
                  ))}
                </div>
              </div>
            </>
          )}
        </div>
      </main>
    </div>
  )
}

export default App
