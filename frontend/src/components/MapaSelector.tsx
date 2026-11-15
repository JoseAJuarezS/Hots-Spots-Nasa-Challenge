import { useEffect, useMemo, useRef, useState } from 'react';
import * as maplibregl from 'maplibre-gl';
import 'maplibre-gl/dist/maplibre-gl.css';
import maplibreWorkerUrl from 'maplibre-gl/dist/maplibre-gl-worker.mjs?url';
import { ChevronDown, Crosshair, Globe, Layers, SquareDashedMousePointer } from 'lucide-react';
import type { BBox } from '../types/fire';
import type { FocoIndividual } from '../services/duckdbService';

maplibregl.setWorkerUrl(maplibreWorkerUrl);

type FeatureCollection = Extract<
  maplibregl.GeoJSONSourceSpecification['data'],
  { type: 'FeatureCollection' }
>;

interface Props {
  focosMes: FocoIndividual[];
  anioActivo: number;
  mesActivo: number;
  bbox: BBox | null;
  onCambiarBBox: (nuevo: BBox | null) => void;
}

const PRESETS_INDIA: { label: string; bbox: BBox | null; center: [number, number]; zoom: number }[] = [
  { label: 'Globo / Toda India', bbox: null, center: [79.0, 22.5], zoom: 3.1 },
  {
    label: 'Punjab y Haryana',
    bbox: { minLat: 28.5, maxLat: 32.5, minLon: 73.8, maxLon: 77.6, nombre: 'Punjab y Haryana' },
    center: [75.7, 30.5],
    zoom: 6.2,
  },
  {
    label: 'India Central',
    bbox: { minLat: 21.0, maxLat: 25.5, minLon: 75.5, maxLon: 82.5, nombre: 'India Central' },
    center: [79.0, 23.2],
    zoom: 5.8,
  },
  {
    label: 'Noreste (Assam)',
    bbox: { minLat: 22.0, maxLat: 27.5, minLon: 91.0, maxLon: 96.0, nombre: 'Noreste de India' },
    center: [93.5, 24.8],
    zoom: 6.0,
  },
];

function bboxAGeoJSON(bbox: BBox | null): FeatureCollection {
  if (!bbox) return { type: 'FeatureCollection', features: [] };
  return {
    type: 'FeatureCollection',
    features: [
      {
        type: 'Feature',
        properties: {},
        geometry: {
          type: 'Polygon',
          coordinates: [
            [
              [bbox.minLon, bbox.minLat],
              [bbox.maxLon, bbox.minLat],
              [bbox.maxLon, bbox.maxLat],
              [bbox.minLon, bbox.maxLat],
              [bbox.minLon, bbox.minLat],
            ],
          ],
        },
      },
    ],
  };
}

export function MapaSelector({
  focosMes,
  anioActivo,
  mesActivo,
  bbox,
  onCambiarBBox,
}: Props) {
  const contenedorRef = useRef<HTMLDivElement | null>(null);
  const mapaRef = useRef<maplibregl.Map | null>(null);
  const inicioArrastreRef = useRef<maplibregl.LngLat | null>(null);

  const [modoDibujo, setModoDibujo] = useState(false);
  const [capaSatelital, setCapaSatelital] = useState(true);
  const [mapaListo, setMapaListo] = useState(false);
  const [mostrarCoords, setMostrarCoords] = useState(false);

  const [minLatTxt, setMinLatTxt] = useState('28.5');
  const [maxLatTxt, setMaxLatTxt] = useState('32.5');
  const [minLonTxt, setMinLonTxt] = useState('73.8');
  const [maxLonTxt, setMaxLonTxt] = useState('77.6');

  useEffect(() => {
    if (bbox) {
      setMinLatTxt(bbox.minLat.toFixed(2));
      setMaxLatTxt(bbox.maxLat.toFixed(2));
      setMinLonTxt(bbox.minLon.toFixed(2));
      setMaxLonTxt(bbox.maxLon.toFixed(2));
    }
  }, [bbox]);

  const geojsonFocos = useMemo<FeatureCollection>(() => {
    return {
      type: 'FeatureCollection',
      features: focosMes.map((f) => ({
        type: 'Feature',
        properties: {
          fecha: f.fecha,
          sensor: f.sensor,
          fuente: f.fuente,
          peso: f.peso,
          frp: f.frp,
          daynight: f.daynight,
          lat: f.lat,
          lon: f.lon,
        },
        geometry: {
          type: 'Point',
          coordinates: [f.lon, f.lat],
        },
      })),
    };
  }, [focosMes]);

  const geojsonFocosRef = useRef<FeatureCollection>(geojsonFocos);
  geojsonFocosRef.current = geojsonFocos;

  useEffect(() => {
    if (!contenedorRef.current || mapaRef.current) return;

    const map = new maplibregl.Map({
      container: contenedorRef.current,
      style: {
        version: 8,
        projection: { type: 'globe' },
        sky: {
          'sky-color': '#020617',
          'sky-horizon-blend': 0.5,
          'horizon-color': '#1e293b',
          'horizon-fog-blend': 0.5,
          'fog-color': '#0f172a',
          'fog-ground-blend': 0.5,
          'atmosphere-blend': ['interpolate', ['linear'], ['zoom'], 0, 1, 5, 0.4, 7, 0],
        },
        sources: {
          esriSatellite: {
            type: 'raster',
            tiles: [
              'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
            ],
            tileSize: 256,
            attribution: 'Esri, Maxar, Earthstar Geographics',
          },
          cartoDark: {
            type: 'raster',
            tiles: ['https://a.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}@2x.png'],
            tileSize: 256,
            attribution: '&copy; OpenStreetMap &copy; CARTO',
          },
          boundaries: {
            type: 'raster',
            tiles: [
              'https://server.arcgisonline.com/ArcGIS/rest/services/Reference/World_Boundaries_and_Places/MapServer/tile/{z}/{y}/{x}',
            ],
            tileSize: 256,
          },
        },
        layers: [
          {
            id: 'capa-satelite',
            type: 'raster',
            source: 'esriSatellite',
            layout: { visibility: 'visible' },
          },
          {
            id: 'capa-oscura',
            type: 'raster',
            source: 'cartoDark',
            layout: { visibility: 'none' },
          },
          {
            id: 'capa-fronteras',
            type: 'raster',
            source: 'boundaries',
            paint: { 'raster-opacity': 0.7 },
          },
        ],
      },
      center: [79.0, 22.5],
      zoom: 3.1,
      pitch: 15,
      attributionControl: false,
    });

    map.addControl(new maplibregl.NavigationControl({ visualizePitch: true }), 'top-right');

    map.on('load', () => {
      map.addSource('focos-individuales', {
        type: 'geojson',
        data: geojsonFocosRef.current,
      });

      map.addLayer({
        id: 'focos-heatmap',
        type: 'heatmap',
        source: 'focos-individuales',
        maxzoom: 10,
        paint: {
          'heatmap-weight': [
            'interpolate',
            ['linear'],
            ['get', 'peso'],
            1, 0.4,
            6, 1.0,
          ],
          'heatmap-intensity': [
            'interpolate',
            ['linear'],
            ['zoom'],
            1, 0.8,
            5, 1.8,
            9, 2.6,
          ],
          'heatmap-color': [
            'interpolate',
            ['linear'],
            ['heatmap-density'],
            0, 'rgba(0, 0, 0, 0)',
            0.12, 'rgba(250, 204, 21, 0.55)',
            0.35, 'rgba(249, 115, 22, 0.82)',
            0.65, 'rgba(239, 68, 68, 0.94)',
            1.0, 'rgba(220, 38, 38, 1.0)',
          ],
          'heatmap-radius': [
            'interpolate',
            ['linear'],
            ['zoom'],
            1, 5,
            4, 12,
            8, 22,
          ],
          'heatmap-opacity': [
            'interpolate',
            ['linear'],
            ['zoom'],
            6, 0.9,
            10, 0.35,
          ],
        },
      });

      map.addLayer({
        id: 'focos-nucleo',
        type: 'circle',
        source: 'focos-individuales',
        paint: {
          'circle-pitch-alignment': 'viewport',
          'circle-radius': [
            'interpolate',
            ['linear'],
            ['zoom'],
            2, 2.2,
            5, 3.5,
            8, 5.5,
            11, 8.0,
          ],
          'circle-color': [
            'interpolate',
            ['linear'],
            ['get', 'frp'],
            5, '#ff3b00',
            50, '#ef4444',
            150, '#dc2626',
          ],
          'circle-stroke-width': 0.5,
          'circle-stroke-color': '#450a0a',
          'circle-opacity': 0.95,
        },
      });

      map.on('click', 'focos-nucleo', (e) => {
        const feat = e.features?.[0];
        if (!feat || feat.geometry.type !== 'Point') return;
        const p = feat.properties as Record<string, unknown>;
        const coords = feat.geometry.coordinates.slice() as [number, number];

        new maplibregl.Popup({ closeButton: true, maxWidth: '240px' })
          .setLngLat(coords)
          .setHTML(
            `<div style="color:#0f172a;font-family:sans-serif;font-size:12px;line-height:1.4">
              <strong style="color:#c2410c;font-size:13px">Foco de calor detectado</strong><br/>
              <b>Fecha:</b> ${p.fecha}<br/>
              <b>Coordenadas:</b> ${Number(p.lat).toFixed(4)}°, ${Number(p.lon).toFixed(4)}°<br/>
              <b>Sensor:</b> ${p.sensor} (peso: ${Number(p.peso).toFixed(2)})<br/>
              <b>Potencia (FRP):</b> ${Number(p.frp).toFixed(1)} MW (${p.daynight === 'D' ? 'Día' : 'Noche'})
            </div>`
          )
          .addTo(map);
      });

      map.on('mouseenter', 'focos-nucleo', () => {
        map.getCanvas().style.cursor = 'pointer';
      });
      map.on('mouseleave', 'focos-nucleo', () => {
        map.getCanvas().style.cursor = '';
      });

      map.addSource('seleccion-bbox', {
        type: 'geojson',
        data: bboxAGeoJSON(bbox),
      });

      map.addLayer({
        id: 'seleccion-fill',
        type: 'fill',
        source: 'seleccion-bbox',
        paint: { 'fill-color': '#38bdf8', 'fill-opacity': 0.14 },
      });

      map.addLayer({
        id: 'seleccion-line',
        type: 'line',
        source: 'seleccion-bbox',
        paint: { 'line-color': '#38bdf8', 'line-width': 2, 'line-dasharray': [2, 2] },
      });

      setMapaListo(true);
    });

    mapaRef.current = map;

    return () => {
      map.remove();
      mapaRef.current = null;
    };
  }, []);

  useEffect(() => {
    const map = mapaRef.current;
    if (!map || !mapaListo) return;
    map.setLayoutProperty('capa-satelite', 'visibility', capaSatelital ? 'visible' : 'none');
    map.setLayoutProperty('capa-oscura', 'visibility', capaSatelital ? 'none' : 'visible');
  }, [capaSatelital, mapaListo]);

  useEffect(() => {
    const map = mapaRef.current;
    if (!map || !mapaListo) return;
    const src = map.getSource('focos-individuales') as maplibregl.GeoJSONSource | undefined;
    if (src) {
      src.setData(geojsonFocos);
    }
  }, [geojsonFocos, mapaListo]);

  useEffect(() => {
    const map = mapaRef.current;
    if (!map || !mapaListo) return;
    const src = map.getSource('seleccion-bbox') as maplibregl.GeoJSONSource | undefined;
    src?.setData(bboxAGeoJSON(bbox));
  }, [bbox, mapaListo]);

  useEffect(() => {
    const map = mapaRef.current;
    if (!map || !mapaListo) return;

    if (modoDibujo) {
      map.dragPan.disable();
      map.getCanvas().style.cursor = 'crosshair';
    } else {
      map.dragPan.enable();
      map.getCanvas().style.cursor = '';
    }

    const onMouseDown = (e: maplibregl.MapMouseEvent) => {
      if (!modoDibujo) return;
      inicioArrastreRef.current = e.lngLat;
    };

    const onMouseMove = (e: maplibregl.MapMouseEvent) => {
      if (!modoDibujo || !inicioArrastreRef.current) return;
      const p1 = inicioArrastreRef.current;
      const p2 = e.lngLat;
      const tempBBox: BBox = {
        minLat: Math.min(p1.lat, p2.lat),
        maxLat: Math.max(p1.lat, p2.lat),
        minLon: Math.min(p1.lng, p2.lng),
        maxLon: Math.max(p1.lng, p2.lng),
      };
      const src = map.getSource('seleccion-bbox') as maplibregl.GeoJSONSource | undefined;
      src?.setData(bboxAGeoJSON(tempBBox));
    };

    const onMouseUp = (e: maplibregl.MapMouseEvent) => {
      if (!modoDibujo || !inicioArrastreRef.current) return;
      const p1 = inicioArrastreRef.current;
      const p2 = e.lngLat;
      inicioArrastreRef.current = null;
      setModoDibujo(false);

      const minLat = Number(Math.min(p1.lat, p2.lat).toFixed(2));
      const maxLat = Number(Math.max(p1.lat, p2.lat).toFixed(2));
      const minLon = Number(Math.min(p1.lng, p2.lng).toFixed(2));
      const maxLon = Number(Math.max(p1.lng, p2.lng).toFixed(2));

      if (Math.abs(maxLat - minLat) >= 0.1 && Math.abs(maxLon - minLon) >= 0.1) {
        onCambiarBBox({
          minLat,
          maxLat,
          minLon,
          maxLon,
          nombre: 'Área personalizada',
        });
      }
    };

    map.on('mousedown', onMouseDown);
    map.on('mousemove', onMouseMove);
    map.on('mouseup', onMouseUp);

    return () => {
      map.off('mousedown', onMouseDown);
      map.off('mousemove', onMouseMove);
      map.off('mouseup', onMouseUp);
    };
  }, [modoDibujo, mapaListo, onCambiarBBox]);

  const aplicarCoordenadasManuales = (e: React.FormEvent) => {
    e.preventDefault();
    const minLat = parseFloat(minLatTxt);
    const maxLat = parseFloat(maxLatTxt);
    const minLon = parseFloat(minLonTxt);
    const maxLon = parseFloat(maxLonTxt);
    if ([minLat, maxLat, minLon, maxLon].some((v) => Number.isNaN(v))) return;

    const nuevo: BBox = {
      minLat: Math.min(minLat, maxLat),
      maxLat: Math.max(minLat, maxLat),
      minLon: Math.min(minLon, maxLon),
      maxLon: Math.max(minLon, maxLon),
      nombre: 'Coordenadas manuales',
    };
    onCambiarBBox(nuevo);
    mapaRef.current?.fitBounds(
      [
        [nuevo.minLon, nuevo.minLat],
        [nuevo.maxLon, nuevo.maxLat],
      ],
      { padding: 30, duration: 800 }
    );
  };

  return (
    <aside className="flex flex-col gap-3 rounded-xl border border-slate-800 bg-slate-900/60 p-4">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div>
          <h2 className="text-sm font-semibold text-slate-100">Globo 3D de focos de calor</h2>
          <p className="text-xs text-slate-400">
            {focosMes.length.toLocaleString('es-MX')} puntos en {String(mesActivo).padStart(2, '0')}/{anioActivo}
          </p>
        </div>

        <div className="flex items-center gap-1.5">
          <button
            type="button"
            onClick={() => setCapaSatelital((v) => !v)}
            className="inline-flex items-center gap-1 rounded-lg border border-slate-700 bg-slate-950 px-2.5 py-1.5 text-xs text-slate-200 hover:border-slate-500"
            title="Alternar vista satelital / oscura"
          >
            <Layers className="h-3.5 w-3.5 text-emerald-400" />
            {capaSatelital ? 'Satélite' : 'Oscuro'}
          </button>

          <button
            type="button"
            onClick={() => setModoDibujo((v) => !v)}
            className={`inline-flex items-center gap-1 rounded-lg border px-2.5 py-1.5 text-xs font-medium transition ${
              modoDibujo
                ? 'border-sky-400 bg-sky-500 text-slate-950'
                : 'border-slate-700 bg-slate-950 text-slate-200 hover:border-slate-500'
            }`}
          >
            <SquareDashedMousePointer className="h-3.5 w-3.5" />
            {modoDibujo ? 'Arrastra...' : 'Área'}
          </button>

          {bbox && (
            <button
              type="button"
              onClick={() => {
                onCambiarBBox(null);
                mapaRef.current?.flyTo({ center: [79.0, 22.5], zoom: 3.1, pitch: 15, duration: 800 });
              }}
              className="inline-flex items-center gap-1 rounded-lg border border-slate-700 bg-slate-950 px-2 py-1.5 text-xs text-slate-300 hover:text-white"
              title="Volver a vista global"
            >
              <Globe className="h-3.5 w-3.5" />
            </button>
          )}
        </div>
      </div>

      {/* Globo 3D */}
      <div className="relative h-[430px] w-full overflow-hidden rounded-lg border border-slate-800 bg-slate-950">
        <div ref={contenedorRef} className="h-full w-full" />
        <div className="pointer-events-none absolute bottom-2 left-2 rounded border border-slate-800 bg-slate-950/80 px-2 py-1 text-[10px] text-slate-300">
          Haz clic en cualquier punto brillante para ver fecha, sensor y MW · Rueda para acercar
        </div>
      </div>

      {/* Presets rápidos con vuelo orbital (flyTo) */}
      <div className="flex flex-wrap gap-1.5">
        {PRESETS_INDIA.map((preset) => {
          const activo =
            (!bbox && !preset.bbox) ||
            (bbox && preset.bbox && bbox.nombre === preset.bbox.nombre);
          return (
            <button
              key={preset.label}
              type="button"
              onClick={() => {
                onCambiarBBox(preset.bbox);
                mapaRef.current?.flyTo({
                  center: preset.center,
                  zoom: preset.zoom,
                  pitch: preset.bbox ? 35 : 15,
                  duration: 1100,
                });
              }}
              className={`rounded-md border px-2 py-1 text-[11px] transition ${
                activo
                  ? 'border-orange-500/60 bg-orange-500/20 text-orange-300'
                  : 'border-slate-800 bg-slate-950/80 text-slate-400 hover:text-slate-200'
              }`}
            >
              {preset.label}
            </button>
          );
        })}
      </div>

      {/* Acordeón discreto para coordenadas exactas */}
      <div className="border-t border-slate-800/80 pt-2">
        <button
          type="button"
          onClick={() => setMostrarCoords((v) => !v)}
          className="flex w-full items-center justify-between text-[11px] text-slate-400 hover:text-slate-200"
        >
          <span>Filtro por coordenadas exactas (Lat / Lon)</span>
          <ChevronDown
            className={`h-3.5 w-3.5 transition-transform ${mostrarCoords ? 'rotate-180' : ''}`}
          />
        </button>

        {mostrarCoords && (
          <form
            onSubmit={aplicarCoordenadasManuales}
            className="mt-2.5 grid grid-cols-2 gap-2 text-xs"
          >
            <label className="flex flex-col gap-1 text-slate-400">
              <span>Latitud mín / máx</span>
              <div className="flex gap-1">
                <input
                  type="number"
                  step="0.1"
                  value={minLatTxt}
                  onChange={(e) => setMinLatTxt(e.target.value)}
                  className="w-full rounded border border-slate-700 bg-slate-950 px-2 py-1 text-slate-200"
                />
                <input
                  type="number"
                  step="0.1"
                  value={maxLatTxt}
                  onChange={(e) => setMaxLatTxt(e.target.value)}
                  className="w-full rounded border border-slate-700 bg-slate-950 px-2 py-1 text-slate-200"
                />
              </div>
            </label>

            <label className="flex flex-col gap-1 text-slate-400">
              <span>Longitud mín / máx</span>
              <div className="flex gap-1">
                <input
                  type="number"
                  step="0.1"
                  value={minLonTxt}
                  onChange={(e) => setMinLonTxt(e.target.value)}
                  className="w-full rounded border border-slate-700 bg-slate-950 px-2 py-1 text-slate-200"
                />
                <input
                  type="number"
                  step="0.1"
                  value={maxLonTxt}
                  onChange={(e) => setMaxLonTxt(e.target.value)}
                  className="w-full rounded border border-slate-700 bg-slate-950 px-2 py-1 text-slate-200"
                />
              </div>
            </label>

            <button
              type="submit"
              className="col-span-2 inline-flex items-center justify-center gap-1.5 rounded-lg border border-slate-700 bg-slate-800/80 py-1.5 font-medium text-slate-200 hover:bg-slate-800"
            >
              <Crosshair className="h-3.5 w-3.5 text-orange-400" />
              Volar a coordenadas
            </button>
          </form>
        )}
      </div>
    </aside>
  );
}