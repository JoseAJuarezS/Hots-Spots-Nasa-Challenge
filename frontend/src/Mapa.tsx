import { GeoJSONSource, Map as MapLibre, NavigationControl, Popup, setWorkerUrl } from 'maplibre-gl'
import 'maplibre-gl/dist/maplibre-gl.css'
import urlWorker from 'maplibre-gl/dist/maplibre-gl-worker.mjs?url'
import { useEffect, useRef } from 'react'
import { ESCALA, type CapaGeoJSON } from './datos'

// MapLibre 6 busca su worker junto a su propio archivo; con el pre-empaquetado de Vite
// esa ruta no existe, así que le damos la URL explícita.
setWorkerUrl(urlWorker)

const ESTILO_BASE = 'https://tiles.openfreemap.org/styles/positron'
const INDIA: [number, number, number, number] = [68, 6, 98, 36]

const fmt = new Intl.NumberFormat('es', { maximumFractionDigits: 1 })

type Props = { geojson: CapaGeoJSON | null }

export default function Mapa({ geojson }: Props) {
  const contenedor = useRef<HTMLDivElement>(null)
  const mapa = useRef<MapLibre | null>(null)
  const listo = useRef(false)
  const pendiente = useRef<CapaGeoJSON | null>(null)

  useEffect(() => {
    const m = new MapLibre({
      container: contenedor.current!,
      style: ESTILO_BASE,
      bounds: INDIA,
      fitBoundsOptions: { padding: 20 },
      attributionControl: { compact: true },
    })
    m.addControl(new NavigationControl({ showCompass: false }), 'top-right')
    mapa.current = m

    m.on('load', () => {
      m.addSource('celdas', {
        type: 'geojson',
        data: pendiente.current ?? { type: 'FeatureCollection', features: [] },
      })
      // Debajo de las etiquetas del mapa base, para que los nombres sigan legibles.
      const primeraEtiqueta = m.getStyle().layers.find((l) => l.type === 'symbol')?.id
      m.addLayer(
        {
          id: 'celdas',
          type: 'fill',
          source: 'celdas',
          paint: {
            'fill-color': ['step', ['get', 'f'], ...ESCALA.flatMap(([v, c], k) => (k === 0 ? [c] : [v, c]))] as never,
            'fill-opacity': 0.85,
          },
        },
        primeraEtiqueta,
      )
      listo.current = true
    })

    const popup = new Popup({ closeButton: false, closeOnClick: false, offset: 8 })
    m.on('mousemove', 'celdas', (e) => {
      const p = e.features?.[0]?.properties
      if (!p) return
      m.getCanvas().style.cursor = 'pointer'
      popup
        .setLngLat(e.lngLat)
        .setHTML(
          `<strong>${fmt.format(p.f)}</strong> focos armonizados<br>` +
            `<span style="color:#64748b">${p.b} detecciones · ${p.lat.toFixed(2)}°, ${p.lon.toFixed(2)}°</span>`,
        )
        .addTo(m)
    })
    m.on('mouseleave', 'celdas', () => {
      m.getCanvas().style.cursor = ''
      popup.remove()
    })

    return () => {
      listo.current = false
      m.remove()
    }
  }, [])

  useEffect(() => {
    pendiente.current = geojson
    if (listo.current && geojson) {
      ;(mapa.current?.getSource('celdas') as GeoJSONSource | undefined)?.setData(geojson)
    }
  }, [geojson])

  return <div ref={contenedor} className="h-full w-full" />
}
