// Carga de los datos de ejemplo que genera analisis/05_exportar_mapa.sql
// (rejilla de 0,1° × mes en frontend/public/datos/).

export const PASO = 0.1 // tamaño de celda en grados
export const ANIOS = Array.from({ length: 26 }, (_, k) => 2000 + k)

// Rampa secuencial YlOrRd (ColorBrewer, apta para daltonismo) por focos armonizados por celda.
// Escalones casi logarítmicos: la mayoría de celdas tiene pocos focos y unas pocas, cientos.
export const ESCALA: [number, string][] = [
  [0, '#ffffb2'],
  [3, '#fed976'],
  [10, '#feb24c'],
  [30, '#fd8d3c'],
  [100, '#f03b20'],
  [300, '#bd0026'],
]

export type Fuente = 'TERRA' | 'MODIS' | 'VIIRS'

/** Un año de celdas, en columnas paralelas (ver 05_exportar_mapa.sql). */
type CeldasAnio = { i: number[]; j: number[]; m: number[]; f: number[]; b: number[] }

export type MesResumen = { mes: string; fuente: Fuente; focos: number }

const cache = new Map<number, Promise<CeldasAnio>>()

export function cargarAnio(anio: number): Promise<CeldasAnio> {
  let p = cache.get(anio)
  if (!p) {
    p = fetch(`/datos/celdas/anio=${anio}/celdas0.json`).then((r) => {
      if (!r.ok) throw new Error(`No hay datos para ${anio}`)
      return r.json()
    })
    cache.set(anio, p)
  }
  return p
}

export async function cargarResumen(): Promise<MesResumen[]> {
  const r = await fetch('/datos/resumen.json')
  if (!r.ok) throw new Error('No se encontró resumen.json (corre: mise run datos:mapa)')
  return r.json()
}

/**
 * Convierte un año de celdas en polígonos GeoJSON para MapLibre.
 * mes = 0 suma los 12 meses del año.
 */
export function aGeoJSON(d: CeldasAnio, mes: number) {
  const suma = new Map<number, { i: number; j: number; f: number; b: number }>()
  for (let k = 0; k < d.i.length; k++) {
    if (mes !== 0 && d.m[k] !== mes) continue
    const clave = d.i[k] * 100000 + d.j[k]
    const c = suma.get(clave)
    if (c) {
      c.f += d.f[k]
      c.b += d.b[k]
    } else {
      suma.set(clave, { i: d.i[k], j: d.j[k], f: d.f[k], b: d.b[k] })
    }
  }

  let total = 0
  const features = []
  for (const { i, j, f, b } of suma.values()) {
    total += f
    const s = i * PASO
    const o = j * PASO
    const n = s + PASO
    const e = o + PASO
    features.push({
      type: 'Feature' as const,
      properties: { f, b, lat: s + PASO / 2, lon: o + PASO / 2 },
      geometry: {
        type: 'Polygon' as const,
        coordinates: [[[o, s], [e, s], [e, n], [o, n], [o, s]]],
      },
    })
  }
  return { geojson: { type: 'FeatureCollection' as const, features }, total, celdas: suma.size }
}

export type CapaGeoJSON = ReturnType<typeof aGeoJSON>['geojson']
