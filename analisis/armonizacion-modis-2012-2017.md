# Armonización MODIS → VIIRS: reglas de 2012–2017 y validación con 2018+

Tres pasos, cada uno en un script:

1. **Comparar** los datos crudos de MODIS y VIIRS en 2012–2017 y obtener **reglas de armonización**.
2. **Aplicar** las reglas a todos los focos de MODIS (2000–2025).
3. **Validar**: comparar MODIS armonizado con lo que VIIRS observó de verdad desde 2018, un periodo que las reglas no vieron, y medir el error total.

## Cómo reproducirlo

```bash
mise run armonizacion:todo        # o, por partes:
mise run armonizacion:reglas      # 06_reglas_armonizacion.sql   (~2,5 min)  -> analisis/reglas/
mise run armonizacion:aplicar     # 07_armonizar_modis.sql       (~5 s)      -> datos_armonizados/
mise run armonizacion:validar     # 08_validar_armonizacion.sql  (~3 s)      -> analisis/validacion/
```

- Entradas: `datos_crudos/MODIS_original/` (MODIS **sin modificar**, con `confidence` de 0 a 100) y `datos_crudos/VIIRS/`.
- Salida: `datos_armonizados/anio=<año>/modis_armonizado_India_0.{csv,parquet}` (ignorada por git).

## Qué referencia VIIRS se usa

- **NOAA-20 (jpss1) no tiene datos antes del 2018-04-01.** En 2012–2017 la única referencia VIIRS es **S-NPP**, así que las reglas se calibran con S-NPP. Es el mismo instrumento VIIRS de 375 m.
- La validación se hace contra **NOAA-20** (referencia principal) y también contra S-NPP.
- Entre los dos VIIRS hay un desajuste de base del **2,7 %** mensual (sesgo −1 %). Ninguna armonización puede bajar de ese error.
- Solo se comparan **días comunes**, con datos de los dos sensores, y focos de vegetación (`type = 0`).

## Paso 1: lo que muestra la comparación 2012–2017

| Hallazgo | Dato |
|---|---|
| VIIRS ve muchos más focos que MODIS, y la proporción depende de día o noche | día ×5,7; noche ×17 |
| **La razón depende mucho de la región** y es estable en el tiempo | ×2,8 en el noreste, ×5 en Punjab, ×9–10 en el centro-sur; r = 0,95 entre 2012–14 y 2015–17 (celdas de 2°) |
| Parte de la variación "por mes" del análisis anterior es solo el cambio de qué regiones arden en cada estación | — |
| **Cuando una celda tiene más actividad de lo normal, la razón baja**: MODIS capta una fracción mayor de los fuegos | r = −0,45 entre el residuo y la anomalía de actividad, tanto en 2012–17 como en 2018+ |
| La `confidence` de MODIS no se corresponde con las clases de VIIRS | MODIS <30 = 4 % de los focos de día; VIIRS `l` = 23 % |
| El FRP por foco de MODIS es ~3 veces el de VIIRS (píxel de 1 km frente a 375 m) | mediana de día 14,8 frente a 5,0 MW |

## Reglas (en `analisis/reglas/`)

**1. Conteo: `peso` de cada foco MODIS**, es decir, cuántos focos VIIRS representa. Los focos armonizados de cualquier área y periodo son `sum(peso)`.

```
peso = k(celda 2°, mes del año, día/noche) · r(celda 1°, día/noche) · factor_actividad
factor_actividad = ((focos MODIS en la celda 2° ese mes + 10) / (focos típicos de ese mes + 10)) ^ b
```

- Las constantes se **suavizan hacia el nivel superior** (celda 1° → celda 2° × mes → celda 2° → India), con un peso de 300 focos MODIS. Así las celdas con pocos datos no dan valores extremos.
- **b = −0,30**. Se eligió con validación cruzada dejando un año fuera **dentro de 2012–2017**, nunca mirando 2018+. El factor se limita a [0,5; 2].
- Focos que no son de vegetación (`type` 2 y 3): una razón por tipo y día/noche, solo si hay al menos 100 focos MODIS. Si no, se usa la razón nacional.
- **Antes del 2002-07-04 solo hay Terra.** El peso se multiplica por f_terra = (Terra + Aqua) / Terra por celda y mes, medido con MODIS 2003–2017. En la salida, estos focos llevan `modo = solo_terra`.

**2. `confidence` 0–100 → `l`/`n`/`h`.** Se eligen umbrales que igualan las proporciones de VIIRS.
- De día: `l` < 53 ≤ `n` < 95 ≤ `h`.
- De noche: todo es `n`, igual que en VIIRS.

**3. `frp`, `brightness` → `bright_ti4` y `bright_t31` → `bright_ti5`.** Emparejamiento de cuantiles por día/noche. Cada foco MODIS pasa a tener los valores de un "foco VIIRS típico".

Los valores originales de MODIS se conservan en las columnas `*_modis`.

Validación cruzada dentro de 2012–2017 (`reglas/validacion_cruzada_2012_2017.csv`). WAPE = Σ|predicho − VIIRS| / Σ VIIRS:

| Regla | India-mes | Celda 2°-mes | Celda 1°-mes |
|---|---:|---:|---:|
| k global | 18,8 % | 43,2 % | 46,8 % |
| k por mes (método anterior) | 10,8 % | 39,6 % | 43,8 % |
| Jerárquica, sin factor de actividad | 11,3 % | 22,2 % | 28,6 % |
| **Jerárquica + actividad (b = −0,30)** | **8,7 %** | **19,3 %** | **26,2 %** |

## Paso 3: margen de error frente a VIIRS real (2018+)

Referencia NOAA-20, desde 2018-04 hasta 2025-12 (93 meses, 2 764 días). Vegetación, todas las `confidence`.

| Escala | r | Sesgo total | WAPE | Intervalo del 90 % del error* |
|---|---:|---:|---:|---|
| **India × año** | 0,993 | **−0,6 %** | **2,2 %** | −3,7 % a +3,7 % |
| **India × mes** | 0,991 | −0,6 % | **9,7 %** | −34 % a +25 % |
| Celda 2° (~220 km) × mes | 0,974 | −0,6 % | 23,7 % | −68 % a +87 % |
| Celda 1° (~110 km) × mes | 0,965 | −0,6 % | 31,3 % | −77 % a +100 % |

\* Percentiles 5 y 95 de (armonizado − VIIRS) / VIIRS, en unidades con al menos 50 focos VIIRS. Los extremos negativos a escala India-mes vienen de los meses del monzón, que tienen muy pocos focos.

Contra S-NPP los resultados son casi iguales: sesgo 0,0 %, WAPE India-mes 9,0 % y celda 2° 22,4 %.

**Comparación con reglas más simples** (WAPE frente a NOAA-20):

| | India-mes | Celda 2°-mes | Celda 1°-mes |
|---|---:|---:|---:|
| MODIS sin armonizar | 85,0 % | 85,1 % | 85,2 % |
| k global | 17,3 % | 42,8 % | 47,6 % |
| k por mes (método anterior) | 11,0 % | 40,4 % | 45,6 % |
| **Reglas nuevas** | **9,7 %** | **23,7 %** | **31,3 %** |
| Solo Terra (simula 2000–2002) | 16,1 % | 41,3 % | 52,8 % |

**Error por año** (`validacion/por_anio.csv`):

| Año | 2018* | 2019 | 2020 | 2021 | 2022 | 2023 | 2024 | 2025 |
|---|---|---|---|---|---|---|---|---|
| Error vs. NOAA-20 | −0,6 % | +4,7 % | −2,4 % | −0,2 % | −3,3 % | −1,1 % | −3,9 % | +2,0 % |

\* NOAA-20 empieza en abril de 2018.

**Otros resultados:**
- **Versión de MODIS.** Con C6.03 (2018–2022) el WAPE mensual es del 8,2 %; con C6.1 (2023–2025) sube al 12,0 %. El sesgo sigue cerca de 0. La regla resiste el cambio de versión, aunque es algo menos precisa con C6.1.
- **Estacionalidad.** El sesgo mensual queda dentro de ±10 % en los meses con más fuego (marzo, abril, octubre y noviembre).
  - Se desvía más en febrero (+14 %), diciembre (−21 %) y en el monzón (agosto −30 %, septiembre −22 %). Esos meses del monzón tienen muy pocos focos.
- **Filtro `confidence` n/h.** Sesgo +1,5 %, WAPE India-mes 14,1 % y celda 2° 27,8 %. Funciona, aunque algo peor que sin filtrar.
- **Distribución de FRP y de `confidence` por foco.** Coincide con VIIRS. Por ejemplo, la mediana de FRP de día es 4,86 frente a 4,85 MW.
- **FRP total de un área** (`sum(frp × peso)`). Se **queda corto un 13 %** frente a VIIRS (WAPE mensual 15 %). Para mapas de energía radiativa hace falta una corrección propia (ver pendientes).

## Limitaciones

- Calibrado **solo para India**. En otra región hay que volver a correr `06`.
- **El peso depende de la actividad del mes en la celda.** Si se añaden focos nuevos de un mes, hay que recalcular el peso de todo ese mes en esa celda.
- **2000–2002 (solo Terra) es menos preciso.** Error del 16 % por mes a nivel nacional y del 41 % por celda de 2°. La app debería marcarlo.
- En áreas pequeñas (por debajo de ~1°) el error por mes supera el 30 %. Conviene mostrar la incertidumbre.

## Pendientes

1. Corregir el FRP total por área. Por ejemplo, ajustar con 2012–2017 una constante de FRP aparte de la de conteo.
2. Que la app y `modelo/datos.py` lean `datos_armonizados/` en lugar de `datos_crudos/MODIS`.
   - `datos_crudos/MODIS` está convertido con `05_confidence_modis_a_viirs.py`, que se calibró con **todos** los años, incluidos los de 2018+. Eso contamina la validación del modelo.
