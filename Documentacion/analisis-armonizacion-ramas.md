# Revisión de las dos propuestas de armonización MODIS → VIIRS

Fecha: 2026-11-14. Ramas revisadas:

| Rama | Commit | Autor (git) | Archivos nuevos |
|---|---|---|---|
| `Develop` | `03841b4` "Datos harmonizados pepe" | Alberto Juarez | `analisis/04_modis_formato_viirs.sql`, `analisis/05_confidence_modis_a_viirs.py` |
| `daniel` | `d42ca30` "Aplicacion de la armonizacion de los datos" | joserojas-SerSoc | `analisis/04_armonizar.sql` (reescrito), `analisis/05_propuesta_2012_2018.sql`, `analisis/propuesta-armonizacion-2012-2018.md`, `analisis/serie-armonizada.md` (reescrito) |

Las dos ramas parten de `1b3cbc3`, que ya tenía la armonización base: **una k nacional por mes del año**, calibrada con 2012-02 a 2018-12, aplicada como `peso` a cada foco MODIS (ver `analisis/correlacion-modis-viirs.md`).

**Cómo se revisó.** Ejecuté los scripts de las dos ramas con los mismos CSV de FIRMS India (48 archivos; los que subió `daniel` son idénticos byte a byte a los descargados). Todas las cifras de este documento salen de esas ejecuciones. Los números que Daniel pone en sus `.md` **se reproducen exactamente**.

---

## 1. Qué hizo cada uno

### Rama `Develop`: convertir los *atributos* de cada foco MODIS

Responde a la pregunta **«¿cómo se vería este foco MODIS si lo hubiera detectado VIIRS?»**. No toca el número de focos.

- **`confidence`.** MODIS usa un número de 0 a 100 y VIIRS usa letras (`l`/`n`/`h`). Busca dos umbrales sobre el número de MODIS para que la proporción de letras sea la misma que en VIIRS. Lo hace por separado de día y de noche.
- **`frp`.** Emparejamiento de cuantiles: a un foco MODIS en el percentil *p* de FRP le asigna el FRP del percentil *p* de VIIRS. Entre cuantiles interpola; fuera de rango, escala por la razón del extremo.
- **Calibración.** Todos los días en que observan los dos sensores (2012-01-20 a 2025-12-31), con S-NPP y NOAA-20 juntos, `type = 0`.
- **Dos implementaciones:**
  - `04_modis_formato_viirs.sql` (DuckDB): escribe `datos_procesados/modis_formato_viirs_India.csv`.
  - `05_confidence_modis_a_viirs.py` (Python puro): **sobrescribe** los CSV de `datos_crudos/MODIS/`, y antes guarda una copia en `MODIS_original/`.

Umbrales obtenidos (ejecución del SQL):

| | Umbrales | VIIRS l / n / h | MODIS convertido l / n / h |
|---|---|---|---|
| Día | `l` < 54 ≤ `n` < 95 ≤ `h` | 23,7 / 72,3 / 4,0 % | 23,5 / 72,8 / 3,8 % |
| Noche | `l` < 0 ≤ `n` < 100 ≤ `h` | 0,0 / 99,9 / 0,1 % | 0,0 / 93,9 / **6,1 %** |

Curva de FRP (MW): de día, 14,6 → 4,9 (mediana) y 263 → 64 (p99); de noche, 9,0 → 1,3 (mediana).

### Rama `daniel`: corregir el *número* de focos con una k por región, e integrar lo de `Develop`

Responde a **«¿cuántos focos habría visto VIIRS?»**, y añade encima la conversión de atributos de `Develop`.

1. **`05_propuesta_2012_2018.sql`: exploración con dos años.** Compara cinco modelos de k con validación cruzada (calibra con 2012 y prueba con 2018, y al revés):

   | Modelo | k depende de | Sesgo anual (abs.) | Error mediano regional |
   |---|---|---:|---:|
   | M1 | nada (global) | 10,3 % | 29,1 % |
   | M2 | mes del año | 10,8 % | 28,3 % |
   | M3 | estación | 10,7 % | 28,7 % |
   | M4 | estación × día/noche | 12,0 % | 29,1 % |
   | **M5** | **estación × región de 5°** | **3,7 %** | **19,4 %** |

   Conclusión: **lo que más hace variar k es el lugar, no el mes.** La k regional va de ~3 (noreste) a ~10 (Jharkhand/Bengala), mientras que la k por estación solo va de 4,8 a 7,3.

2. **`04_armonizar.sql` reescrito: serie de producción.**
   - k(**mes del año × región de 5°**), calibrada con 2012-02 a 2018-12. Si la región tiene menos de 200 focos MODIS en ese mes, usa la k nacional del mes. Con eso, el 98 % de los focos de 2002–2012 usa k regional.
   - Tramo con solo Terra (2000-11 a 2002-07): lo mismo con k_terra.
   - Integra el método de `Develop` con tres cambios:
     - calibra solo con S-NPP (la escala de referencia);
     - usa el mismo tramo 2012–2018 que las k, para que 2019–2025 quede como prueba;
     - admite el umbral 101 («ningún foco es `h`»), lo que corrige el 6,1 % de `h` nocturnas.
   - La letra de `confidence` es **solo informativa**: qué focos cuentan lo sigue decidiendo `confidence_modis >= 30`.
   - Añade un bloque de cálculo de error a 4 escalas (año, mes, región de 5°, celda de 1°) para nº de focos, FRP total y formato. Siempre lo compara con MODIS sin armonizar.
   - Exporta `analisis/salida/modis_armonizado/anio=YYYY/*.parquet` y las tablas de calibración y error.

---

## 2. Comparación de métodos

| Aspecto | `Develop` | `daniel` |
|---|---|---|
| Problema que ataca | Formato de cada foco (`confidence`, `frp`) | Nº de focos (k regional) **+** formato (método de `Develop`) |
| ¿Corrige el salto de 2012? | **No** | **Sí** |
| Referencia VIIRS | S-NPP + NOAA-20 mezclados | Solo S-NPP |
| Calibración / prueba | Todo 2012–2025, sin prueba | 2012–2018 / 2019–2025 |
| Validación | Solo comprueba proporciones en la propia muestra | Error fuera de muestra a 4 escalas, contra MODIS bruto |
| Día / noche | Separado (bien justificado) | Separado para el formato; para k se probó y no ayuda (M4) |
| Dimensión espacial | No | Sí (región de 5°, con respaldo nacional) |
| Efecto sobre los datos crudos | El `.py` sobrescribe `datos_crudos/MODIS/` | Solo lectura; salidas en `analisis/salida/` |
| Documentación de resultados | Comentarios en el código, sin `.md` | Dos `.md` con tablas y lectura |
| Tarea de `mise` | No | `datos:propuesta`; `datos:armonizar` reutilizada |

Las dos propuestas **no compiten, se complementan**. `Develop` da el formato y `daniel` da el número. La rama `daniel` ya contiene las dos cosas.

---

## 3. Resultados

### 3.1 El método de `Develop` por sí solo no resuelve el problema principal

Lo verifiqué con la salida de `Develop`: conté los focos MODIS con letra `n`/`h`, sin k, frente a S-NPP `n`/`h`.

| Métrica | Valor |
|---|---:|
| Salto 2012 (media 2012–14 / 2009–11), empalme MODIS → VIIRS | **6,59** (el empalme crudo da 5,36; lo ideal es ≈ 1) |
| Sesgo en nº de focos frente a S-NPP (2013–2025) | **−85,5 %** |
| Sesgo en FRP total, con el FRP convertido | **−81,5 %** |
| Sesgo en FRP total, con el FRP bruto de MODIS | −31,7 % |

- Cada foco MODIS sigue contando como **1**, pero VIIRS ve ~5,6 veces más focos. El salto de 2012 sigue ahí; de hecho empeora, porque el filtro por letra descarta ~23 % de los focos MODIS de día.
- Convertir el FRP sin ponderar por k **empeora** el FRP total de un área: pasa de −32 % a −82 %. El mismo autor lo advierte en el docstring del `.py`.
- **Conclusión:** el método de `Develop` solo sirve **combinado con un peso por foco**.

### 3.2 La serie de `daniel`: el salto desaparece

| Serie | Razón 2012–14 / 2009–11 |
|---|---:|
| MODIS bruto (referencia: sin cambio de sensor) | 1,00 |
| Empalme crudo | 5,36 |
| k nacional por mes (versión base) | 0,96 |
| **k por mes × región (`daniel`)** | **0,99** |

Totales anuales armonizados (miles de focos, escala S-NPP):

| 2001* | 2003 | 2005 | 2007 | 2009 | 2011 | 2012 | 2013 | 2015 | 2017 | 2019 | 2021 | 2023 | 2025 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 363 | 278 | 313 | 367 | 462 | 378 | 454 | 359 | 351 | 435 | 378 | 582 | 409 | 460 |

\* Solo Terra.

Entre 2003 y 2011, la k regional deja la serie **~5 % más baja** que la k nacional. Esos años se quemaba proporcionalmente más en regiones de k baja (como el noreste), así que la k nacional los sobrestimaba.

### 3.3 Validación fuera de muestra (prueba 2019–2025)

**Número de focos:**

| Escala | k nacional por mes | **k mes × región** | Sin armonizar |
|---|---:|---:|---:|
| Año, India | — | 2,8 % | 82,4 % |
| Mes, India (error mediano) | 10,3 % | 10,9 % | 81,8 % |
| Mes, región de 5° (error mediano) | 28,5 % | **19,9 %** | 84,2 % |
| Mes, región de 5° (r) | 0,918 | **0,980** | 0,925 |
| Mes, celda de 1° (error mediano) | — | 28,6 % | 85,1 % |
| Sesgo nacional | +2,7 % | +4,4 % | −82 % |

- **A escala nacional las dos k empatan.** La regional tiene un poco más de sesgo (+4,4 % frente a +2,7 %) y un RMSE algo menor.
- **A escala regional, la k regional reduce el error ~30 %.** Esa es la escala que importa para la app, donde el usuario dibuja un área.
- El error crece al achicar el área: ~11 % al mes en toda India, ~20 % por región de 5° y ~29 % por celda de 1°.

**Comprobación adicional (mía): ¿la k regional es estable en el tiempo?** Comparé la k de cada región entre calibración y prueba:

| Región | Focos MODIS (cal.) | k 2012–18 | k 2019–25 | Cambio |
|---|---:|---:|---:|---:|
| 30_75 (Punjab, Himachal) | 82 645 | 5,12 | 4,98 | −2,7 % |
| 25_90 (Assam/Meghalaya) | 60 704 | 3,70 | 3,82 | +3,4 % |
| 25_75 | 48 056 | 5,27 | 5,52 | +4,8 % |
| 20_90 (Mizoram/Tripura) | 45 719 | 3,42 | 3,24 | −5,3 % |
| 20_75 | 45 090 | 5,35 | 5,45 | +1,8 % |
| 15_80 | 42 972 | 7,60 | 8,29 | +9,1 % |
| 20_80 | 39 637 | 8,74 | 7,92 | −9,3 % |
| 20_85 (Jharkhand/Bengala) | 11 367 | 10,13 | 9,47 | −6,6 % |
| 15_75 / 20_70 | 22 480 / 8 747 | 7,51 / 7,35 | 6,08 / 5,93 | −19 % |

- La diferencia **entre regiones** (×3) es mucho mayor que el cambio **en el tiempo** dentro de cada región (casi siempre menos de ±10 %).
- Esto refuerza que la región es una variable física real (tipo de quema y tamaño del fuego), no ruido sobreajustado.
- Las dos regiones que más cambian (−19 %) son del oeste y centro-sur (Gujarat, Maharashtra y norte de Karnataka).

**Formato de cada foco** (método de `Develop` con las correcciones de `daniel`, prueba 2019–2025):

| Atributo | Armonizado (día / noche) | Sin armonizar (día / noche) |
|---|---:|---:|
| `confidence`: diferencia de proporciones l/n/h con VIIRS | 1,6 / 0,1 puntos | 20,5 / 31,4 puntos |
| `frp`: error medio de los percentiles 5–95 | 0,7 % / 2,7 % | 200 % / 716 % |

**FRP total de un área**, `sum(frp × peso)`: sesgo de **+6,2 %**, tanto en calibración como en prueba, así que es sistemático. Error mediano de 14 % al mes y 26 % por región; sin armonizar es 39 % y 48 %. Algunos años se desvían más del 10 % (2012, 2017, 2018, 2019 y 2021).

### 3.4 Tramo con solo Terra (2000–2002)

- Contra VIIRS en 2019–2025, Terra × k_terra regional da sesgo −1,4 % y error regional de 34,6 % (con k nacional, 51,3 %).
- Pero en 2003–2011, Terra × k_terra regional y MODIS × k regional **discrepan +12,4 %** (con las dos k nacionales, +2,8 %).
- Las k_terra nacionales de octubre (37) y noviembre (49) son enormes. Terra pasa por la mañana y la quema de rastrojo del noroeste es por la tarde, así que esos meses son muy inestables.
- Conclusión, compartida con Daniel: **±10 % de incertidumbre en los totales anuales de 2000–2002**, y la app debe marcarlos como menos precisos.

---

## 4. Problemas encontrados

### Rama `Develop`

1. **No armoniza el número de focos** (sección 3.1). Sin un peso, la serie sigue rota en 2012.
2. **Error nocturno en el SQL:** el umbral alto queda en 100, así que el **6,1 %** de los focos MODIS nocturnos salen como `h`, cuando en VIIRS son el 0,1 %. El candidato solo puede tomar valores observados de `confidence`, y no existe uno que deje «ningún foco `h`».
3. **Las dos implementaciones no dan lo mismo:**
   - el `.py` prueba umbrales de 0 a 101 y de noche da `h` = 0 %; el SQL da 6,1 %;
   - el `.py` usa percentil de rango medio y el SQL, 1001 cuantiles fijos, así que las curvas de FRP difieren un poco;
   - el número de días comunes también difiere (4 984 frente a 5 049).
4. **El `.py` sobrescribe los datos crudos.** Después, `01_cargar.sql` + `04_armonizar.sql` hacen `TRY_CAST(confidence AS INT) >= 30` sobre letras, salen `NULL` y se **descartan todos los focos MODIS sin ningún error visible**. También se pierde el FRP original si alguien borra `MODIS_original/`.
5. **Sin separación calibración/prueba**, y mezcla S-NPP con NOAA-20. NOAA-20 ≈ S-NPP × 1,03, así que el efecto es pequeño, pero la escala de referencia del proyecto es S-NPP.
6. Sin `.md` de resultados ni tarea en `mise.toml`.

### Rama `daniel`

1. **Subió 1,15 GB de CSV crudos (48 archivos) a git** en el merge `0c93e32`, aunque `.gitignore` ignora `datos_crudos`: los añadió antes de arreglar el `.gitignore`, que tenía marcas de conflicto `<<<<<<<` sin resolver. **Si se fusiona tal cual, ese peso queda para siempre en el historial del repo.**
2. **Sesgo de prueba +4,4 % que crece con el tiempo** (2025: +11 %). Puede deberse a la deriva orbital de Terra y Aqua en sus últimos años, que cambia su hora de paso. Para rellenar 2000–2011 no afecta, porque la calibración 2012–2018 es la más cercana. Pero no conviene recalibrar con años recientes.
3. **Las regiones de 5° son una rejilla arbitraria.** Un polígono que cruce el borde entre dos regiones mezcla dos k, que pueden diferir ×2–3. El respaldo nacional (< 200 focos) hace lo mismo en los meses del monzón.
4. **El sesgo del FRP total (+6,2 %)** viene de usar una curva de FRP nacional con k regionales. Daniel propone una curva por región.
5. **El emparejamiento de cuantiles no es una equivalencia física foco a foco.** VIIRS ve muchos fuegos pequeños que MODIS no detecta, así que el percentil *p* de cada sensor no corresponde al mismo fuego. Sirve para igualar distribuciones y, con el peso, totales; no sirve para comparar un foco concreto.
6. Detalles: `serie-armonizada.md` dice «cuatro tablas» pero lista más. Añade `.claude/skills/csv-data-wrangler/`, que no tiene que ver con la armonización. Su `04_armonizar.sql` cambia el esquema de `focos_armonizados` (añade `region`, `nivel_k`, `confidence` y `frp` en escala VIIRS).

### Nota sobre la rama `jonny`

Está encima de `Develop`. Su `06_exportar_contrato.sql` lee `focos_armonizados` y calcula `SUM(frp)` **sin ponderar por `peso`**. Con el esquema de `daniel`, el FRP total de un área debe ser `SUM(frp * peso)`.

---

## 5. Recomendación

1. **Adoptar el `04_armonizar.sql` de `daniel` como armonización oficial.**
   - Es el único que corrige el salto de 2012.
   - Tiene validación fuera de muestra.
   - Ya integra el método de `Develop` con sus errores corregidos.
2. **No fusionar la rama `daniel` tal cual.** Hay que traer sus cambios sin `datos_crudos/`: un commit nuevo desde `Develop` con `git checkout origin/daniel -- analisis/ mise.toml README.md .gitignore`, o un squash. Antes, revisar que el resultado no incluya los CSV.
3. **Retirar `05_confidence_modis_a_viirs.py`**, o como mínimo hacer que escriba en otra carpeta y nunca en `datos_crudos/`. `04_modis_formato_viirs.sql` de `Develop` puede quedarse como referencia histórica, pero ya está superado.
4. **Renumerar los scripts.** Las dos ramas usan `04_` y `05_` para cosas distintas.
5. **Ajustar `06_exportar_contrato.sql` (jonny)** a `SUM(frp * peso)` y a las columnas nuevas.
6. **Para la app:**
   - marcar 2000–2002 como de menor precisión (±10 %);
   - avisar de que en áreas pequeñas (≤ 1°) el error típico es ~30 %;
   - mostrar la banda `k_modis_p25`/`p75`.
7. **Siguientes análisis posibles:**
   - curva de FRP por región, para quitar el +6,2 %;
   - regiones más finas (2,5°) o por ecorregión, en vez de bloques de 5°;
   - validación por emparejamiento espacio-temporal de focos (Aqua frente a S-NPP, mismo paso, < 1 km) para comprobar si las letras de `confidence` coinciden foco a foco, no solo en proporción.

---

## Apéndice: cómo reproducir esta revisión

Con los CSV en `~/Documents/data de prueba/`, se extrae `analisis/` de cada rama (`git archive origin/<rama> analisis`) a una carpeta temporal. Ahí se crea `datos_crudos/MODIS` y `datos_crudos/VIIRS` con enlaces simbólicos a los CSV, y se ejecuta:

```bash
# Develop
duckdb -no-agent < analisis/04_modis_formato_viirs.sql
python -I analisis/05_confidence_modis_a_viirs.py --datos ./datos_crudos --simular   # sin modificar archivos

# daniel
duckdb -no-agent analisis/focos.duckdb < analisis/01_cargar.sql
duckdb -no-agent analisis/focos.duckdb < analisis/04_armonizar.sql
duckdb -no-agent analisis/propuesta.duckdb < analisis/05_propuesta_2012_2018.sql
```

Las comprobaciones adicionales (el método de `Develop` sin k y la estabilidad de k por región) son dos consultas sobre `focos.duckdb` y `datos_procesados/modis_formato_viirs_India.csv`. Su lógica está descrita en las secciones 3.1 y 3.3.
