# Propuesta de armonización MODIS → VIIRS (años 2012 y 2018)

Propuesta para llevar los focos de MODIS a la escala de VIIRS S-NPP. Se prueba con dos años y se valida cruzando un año contra el otro. Complementa `correlacion-modis-viirs.md` y la serie de `serie-armonizada.md` (`04_armonizar.sql`), que usan **una k por mes del año para todo el país**. Esta propuesta comprueba si conviene añadir la **dimensión espacial**, que es la que necesita la app para consultas por área.

## Datos

| Archivo | Sensor | Versión | Filas | Tras filtros | % conservado |
|---|---|---|---:|---:|---:|
| `MODIS/modis_2012_India.csv` | Terra + Aqua | 6.2 | 93 150 | 85 278 | 91,5 |
| `MODIS/modis_2018_India.csv` | Terra + Aqua | 6.03 | 91 110 | 82 024 | 90,0 |
| `VIIRS/viirs-snpp_2012_India.csv` | S-NPP | 2 | 589 159 | 440 151 | 74,7 |
| `VIIRS/viirs-snpp_2018_India.csv` | S-NPP | 2 | 650 470 | 469 137 | 72,1 |
| `VIIRS/viirs-jpss1_2018_India.csv` | NOAA-20 | 2 | 334 339 | 237 198 | 70,9 |

**Filtros** (los mismos que en `02`/`03`):

- solo vegetación (`type = 0`), lo que también deja fuera `type = 1` (volcán), que aparece en 2018;
- MODIS con `confidence >= 30`;
- VIIRS con `confidence` igual a `n` o `h`;
- **se descarta enero de 2012**, porque S-NPP empieza el 20 de enero.

**Unidades:**

- **Estación** (calendario de India): invierno dic–feb, premonzón mar–may, monzón jun–sep, posmonzón oct–nov.
- **Región**: bloque de 5° × 5° de latitud y longitud. Su código es la esquina suroeste; por ejemplo, `30_75` cubre de 30° a 35° N y de 75° a 80° E.

## Cómo reproducirlo

```bash
mise install               # DuckDB
mise run datos:propuesta   # analisis/05_propuesta_2012_2018.sql -> analisis/propuesta.duckdb
```

Lee los CSV de India directamente de `$FIRMS_DATA_DIR/crudos/` y exporta a `analisis/salida/` (carpeta ignorada por git).

## Punto de partida: k cambia entre años

| Año | MODIS | S-NPP | k = S-NPP / MODIS | % noche MODIS | % noche S-NPP |
|---|---:|---:|---:|---:|---:|
| 2012 | 85 278 | 440 151 | 5,16 | 8,7 | 29,7 |
| 2018 | 82 024 | 469 137 | 5,72 | 8,1 | 28,1 |

Si se usa una sola constante calibrada en un año, el otro año queda desviado un **±10 %**. Las secciones siguientes buscan qué explica esa diferencia.

## Modelos comparados

VIIRS S-NPP ≈ k · MODIS. Lo que cambia entre modelos es de qué depende k:

| Modelo | k depende de | N.º de constantes |
|---|---|---:|
| M1 | nada (global) | 1 |
| M2 | mes del año | 12 |
| M3 | estación | 4 |
| M4 | estación × día/noche | 8 |
| M5 | estación × región 5° (si la región tiene < 200 focos MODIS en la calibración, se usa la k de la estación) | 47 + 4 |

**Validación cruzada:** calibrar con 2012 y predecir 2018, y al revés. Promedio de las dos direcciones:

| Modelo | r nacional | Sesgo anual (abs.) | Error mediano nacional | r regional | **Error mediano regional** |
|---|---:|---:|---:|---:|---:|
| M1 global | 0,995 | 10,3 % | 13,5 % | 0,928 | 29,1 % |
| M2 mes | 0,992 | 10,8 % | 16,4 % | 0,922 | 28,3 % |
| M3 estación | 0,996 | 10,7 % | 14,6 % | 0,927 | 28,7 % |
| M4 estación × día/noche | 0,992 | 12,0 % | 14,6 % | 0,923 | 29,1 % |
| **M5 estación × región** | **0,996** | **3,7 %** | **10,9 %** | **0,991** | **19,4 %** |

- *Nacional*: total de India por mes (11–12 meses de prueba).
- *Regional*: región × mes con al menos 100 focos de S-NPP (134–155 casos de prueba).

Detalle por dirección:

| Modelo | Sesgo 2012→2018 | Sesgo 2018→2012 | Error regional 2012→2018 | Error regional 2018→2012 |
|---|---:|---:|---:|---:|
| M1 | −9,8 % | +10,8 % | 29,8 % | 28,3 % |
| M3 | −9,8 % | +11,6 % | 30,3 % | 27,0 % |
| M5 | −4,1 % | +3,2 % | 20,2 % | 18,7 % |

### Qué se aprende

1. **Lo que más cambia k es la región, no el mes.** Por región, k va de **3,0** (región `20_90`, Mizoram y Tripura) a **10,3** (`20_85`, Jharkhand, Bengala Occidental y el norte de Odisha, en premonzón). En el noreste (`25_90`, Assam y Meghalaya), k es 3,4. Por estación, solo va de 4,8 a 7,3. Cada región tiene un tipo de quema distinto: los fuegos pequeños, como las quemas agrícolas o en sotobosque, los detecta VIIRS pero no MODIS.
2. **El ±10 % entre años se debe sobre todo al lugar donde se quema.** Si un año se quema más en regiones de k alta, la k nacional sube. M5 recoge ese efecto y reduce el sesgo de ~10 % a ~3,7 %. También baja el error regional de ~29 % a ~19 %.
3. **La k por mes (M2) no mejora a la k por estación**, y con un solo año de calibración es más ruidosa. En el monzón (jul–sep) hay solo 70–180 focos MODIS al mes, y k salta, por ejemplo, de 4,1 a 6,8 en agosto. Agrupar por estación da el mismo resultado con 4 constantes en lugar de 12.
4. **Separar día y noche (M4) no ayuda.** De noche k es mucho mayor (~20 frente a ~4,5 de día), pero la proporción de focos nocturnos es estable entre años (8–9 % en MODIS y 28–30 % en S-NPP), así que una k que mezcla día y noche funciona igual.

## ¿Influye el cambio de versión de MODIS (6.2 → 6.03)?

| Versión | Año | Focos | % Aqua | % confianza ≥ 80 | Mediana FRP (MW) |
|---|---|---:|---:|---:|---:|
| 6.2 | 2012 | 87 848 | 71,5 | 20,7 | 14,7 |
| 6.03 | 2018 | 82 024 | 70,8 | 18,6 | 14,1 |

La composición de MODIS apenas cambia: mismo reparto entre Terra y Aqua, la misma FRP y −2 puntos de confianza alta. Si se usa k por región, el sesgo entre años baja al ~3–4 %, así que **no hay señales de que la versión cause un salto relevante**.

Con dos años no se puede separar del todo el efecto de la versión de la variación natural de un año a otro. Para confirmarlo habría que comparar 2016–2017 con 2018–2019 usando M5.

## NOAA-20 frente a S-NPP

| Métrica (abr–dic de 2018) | Valor |
|---|---:|
| NOAA-20 / S-NPP | **1,033** |
| r mensual | 0,9997 |
| Diferencia mediana mensual | 6,1 % |
| r regional (región × mes) | 0,9991 |
| Diferencia mediana regional | 9,2 % |

NOAA-20 y S-NPP son **prácticamente intercambiables**: basta dividir NOAA-20 por 1,033 para llevarlo a la escala de S-NPP. No deben sumarse, porque se contaría dos veces el mismo fuego. Hay que usar **S-NPP como referencia** y NOAA-20 solo para cubrir huecos.

## Propuesta

**Fórmula:**

```
focos_armonizados(mes, región) = focos_MODIS(mes, región) · k(estación, región)
```

- `k(estación, región)` = Σ S-NPP / Σ MODIS en el periodo de solape. Si la región tiene menos de 200 focos MODIS en esa estación, se usa `k(estación)`.
- Constantes de respaldo por estación (2012 + 2018): **invierno 5,71 · premonzón 5,53 · monzón 7,30 · posmonzón 4,81**.
- **Antes de 2012**: MODIS × k. **Desde 2012**: S-NPP directamente, y NOAA-20 / 1,033 cuando falte S-NPP.

**Salida:** `analisis/salida/armonizado_2012_2018.{parquet,csv}`. Tiene una fila por mes × región, con las columnas:

- `focos_modis`, `focos_modis_armonizados`, `focos_viirs_snpp`, `focos_viirs_noaa20`;
- `k`;
- `modelo` (`M5_estacion_region` o `M5_respaldo_estacion`).

De las 532 combinaciones mes × región, 258 usan la k de su región y 274 usan la k de la estación; estas últimas son regiones con pocos focos. Comprobación con los datos de calibración: el total anual de MODIS armonizado difiere de S-NPP en **+1,0 % (2012)** y **−2,2 % (2018)**.

## Límites y siguientes pasos

- **Integrado en `04_armonizar.sql`** (ver `serie-armonizada.md`). Con la calibración de 7 años (2012–2018), lo mejor es k(**mes del año**, región) y no k(estación, región). Con 7 años hay suficientes focos para tener k por mes, y en la prueba 2019–2025 da un error regional de 19,9 %, frente a 21,2 % con k por estación y 28,5 % con la k nacional por mes.
- **El bloque de 5° es una elección práctica.** Probar con 2,5°, o con estados o ecorregiones, si hay suficientes focos.
- **Las constantes valen solo para India.** Para otra región hay que recalibrar.
