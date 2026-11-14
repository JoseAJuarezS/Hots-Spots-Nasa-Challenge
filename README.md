# Hots-Spots-Nasa-Challenge

Solución al reto **[Harmonization of MODIS and VIIRS Hot Spots](https://www.spaceappschallenge.org/2026/challenges/modis-and-viirs-hot-spots/)** del NASA Space Apps Challenge 2026. El reto lo propone la CONAE, la agencia espacial argentina.

## Objetivo

Construir un **calendario de actividad de quemas** consistente desde el año 2000 hasta hoy, en el que el número de focos de calor signifique lo mismo **sin importar el satélite que los detectó**, y ofrecerlo en una **aplicación web** para gestores de emergencias, bomberos, científicos y gestores del territorio.

Para ello hay que resolver dos problemas:

1. **Armonizar MODIS y VIIRS.** Llevar los focos de los dos sensores a una escala común, de forma que la serie 2000–2025 no tenga saltos debidos al cambio de sensor y se pueda comparar cualquier mes con su historial.
2. **Construir la app web.** Que permita a un usuario:
   - elegir un área (dibujándola en un mapa o con latitud y longitud) y un periodo o un día específico;
   - ver un **calendario de años por meses** con el número de focos y una rampa de color accesible;
   - comparar el periodo actual con el histórico (mediana o promedio y anomalías), y ver los meses y años con más actividad;
   - **descargar un CSV** con los focos de la búsqueda y las visualizaciones.

## El problema, con nuestros datos

Datos de prueba: CSV anuales de FIRMS para **India** en `datos_crudos/MODIS/` y `datos_crudos/VIIRS/` (no se suben a git). Incluyen MODIS (2000–2025), VIIRS S-NPP (2012–2025) y VIIRS NOAA-20, que aparece como `jpss1` (2018–2025).

Focos detectados por año:

| Año | MODIS | VIIRS S-NPP | VIIRS NOAA-20 | S-NPP / MODIS |
|---|---:|---:|---:|---:|
| 2012 | 93 150 | 589 159 | – | 6,3× |
| 2014 | 76 416 | 544 467 | – | 7,1× |
| 2016 | 88 809 | 681 943 | – | 7,7× |
| 2018 | 91 110 | 650 470 | 334 339* | 7,1× |
| 2020 | 76 021 | 489 632 | 494 734 | 6,4× |
| 2022 | 81 525 | 591 594 | 606 855 | 7,3× |
| 2024 | 74 029 | 552 312 | 578 062 | 7,5× |
| 2025 | 94 917 | 646 376 | 655 554 | 6,8× |

\* NOAA-20 empieza en abril de 2018.

**VIIRS detecta entre 6 y 8 veces más focos que MODIS sobre el mismo territorio y en el mismo año.** Si se usa MODIS para 2000–2011 y VIIRS a partir de 2012, el calendario mostraría un aumento de ×7 en los incendios que **no existe**: se debe solo al cambio de sensor. Además, la proporción **no es constante** (varía entre 6,3 y 7,7 según el año) y probablemente cambia también por región y por mes. Por eso no basta con multiplicar por un número fijo.

### Diferencias que hay que resolver

| | MODIS | VIIRS 375 m |
|---|---|---|
| Píxel | ~1 km | ~375 m |
| Sensibilidad | Fuegos grandes o calientes | También fuegos pequeños |
| Satélites | Terra (desde nov 2000) y Aqua (desde jul 2002) | S-NPP (2012), NOAA-20 (2018), NOAA-21 (2023) |
| `confidence` | Numérica, 0–100 | Categórica: `l` / `n` / `h` |
| Brillo | `brightness`, `bright_t31` | `bright_ti4`, `bright_ti5` |
| `satellite` | `Terra`, `Aqua` | `N` (S-NPP), `N20` (NOAA-20) |

Otros detalles que se ven en los datos:
- **Años incompletos:** 2000 solo tiene noviembre y diciembre (1 407 focos), y 2002 incluye a Aqua solo desde julio.
- **Tipo de foco:** el campo `type` vale 0 para vegetación, 2 para otras fuentes estáticas y 3 para costa afuera. Para el calendario de quemas conviene quedarse con `type = 0`.
- **Versión de MODIS:** pasa de 6.2 a 6.03 en 2018. Hay que revisar si esto afecta a la consistencia de los datos.

## Criterios de éxito

- La serie armonizada no muestra un salto en 2012 (la entrada de VIIRS).
- En el periodo de solape (2012–2025), la serie armonizada a partir de MODIS y la de VIIRS coinciden, con métricas de validación documentadas (correlación, sesgo y error).
- La app responde al instante para cualquier área y periodo de la región elegida, porque usa datos precalculados y no consulta FIRMS en vivo.
- Un usuario no experto puede responder en menos de un minuto preguntas como: *¿este mes es peor que lo normal?* o *¿cuál fue el peor año?*

## Fuera de alcance para el MVP

- Cobertura global: empezamos con una región, India, porque ya tenemos los datos.
- Predicción de incendios.
- Integración en tiempo real (datos NRT). Es deseable, pero secundaria.

## Recursos

- NASA FIRMS: https://www.earthdata.nasa.gov/data/tools/firms
- API de FIRMS: https://firms.modaps.eosdis.nasa.gov/api/
- Descarga de archivo: https://firms.modaps.eosdis.nasa.gov/download/
- Video del reto (CONAE): https://www.youtube.com/watch?v=tEPHsiZtuvk
