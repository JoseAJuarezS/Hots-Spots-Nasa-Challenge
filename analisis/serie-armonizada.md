# Serie armonizada 2000–2025

Siguiente paso de [`correlacion-modis-viirs.md`](correlacion-modis-viirs.md): construir la serie mensual de focos en una **escala común, la de VIIRS S-NPP**, y comprobar que desaparece el salto de 2012.

La constante k depende del **mes del año y de la región**. Por qué la región, en [`propuesta-armonizacion-2012-2018.md`](propuesta-armonizacion-2012-2018.md): la proporción VIIRS/MODIS cambia mucho más entre regiones (de ~2,5 a ~13) que entre meses, porque cada región tiene un tipo de quema distinto.

## Cómo reproducirlo

```bash
mise run datos:cargar       # si aún no existe analisis/focos.duckdb
mise run datos:armonizar    # ejecuta 04_armonizar.sql
```

Los datos se descargan e ingieren con `mise run datos:descargar` y `mise run datos:ingerir` (ver la sección *Datos* del README). Las cifras de este documento son de **India** (`FIRMS_PAISES=India`).

`04_armonizar.sql` crea cuatro tablas en `focos.duckdb`:

| Tabla | Contenido |
|---|---|
| `k_mes` | k nacional por mes del año (todo MODIS y solo Terra), con su rango intercuartil. Es el **respaldo** |
| `k_mes_region` | k por mes del año y región de 5°, solo donde hay ≥ 200 focos MODIS (o Terra) en la calibración |
| `focos_armonizados` | Un registro por foco con su `region`, su `peso` y `nivel_k` (`region`, `nacional` u `observado`). Los focos armonizados de cualquier área son `sum(peso)` |
| `serie_mensual` | Conteos brutos por sensor, la serie armonizada y, para validar, MODIS×k (regional y nacional) y Terra×k |
| `modis_armonizado` | **Todos** los focos MODIS de 2000 a 2025 (1 703 813) en formato VIIRS: `peso`, `confidence` en letras (`l`/`n`/`h`), `frp` en escala VIIRS (los originales, en `confidence_modis` y `frp_modis`), `regla` (`TERRA`/`MODIS`) y `nivel_k`. Se exporta a `analisis/salida/modis_armonizado/anio=YYYY/*.parquet` |
| `umbrales_confidence`, `curva_frp` | Calibración del formato VIIRS (ver más abajo). Se exportan a `analisis/salida/calibracion_confidence.csv` y `calibracion_frp.csv` |
| `error_armonizacion`, `error_formato` | Error de la armonización combinada frente a VIIRS S-NPP en 2012–2025 (nº de focos y FRP total por escala; letras de confidence y distribución de FRP). Se exportan a `analisis/salida/error_armonizacion.csv` y `error_formato.csv` |

Las constantes se calibran con 2012-02 a 2018-12.

## Regla de armonización

Mismos filtros que antes: `type = 0`, MODIS con `confidence >= 30` y VIIRS con `n`/`h`.

| Periodo | Fuente | Peso de cada foco |
|---|---|---|
| 2000-11 a 2002-07 | Solo Terra | k_terra(mes del año, región) |
| 2002-08 a 2012-01 | Todo MODIS (Terra + Aqua) | k_modis(mes del año, región) |
| 2012-02 en adelante | VIIRS S-NPP observado | 1 |

- **Región:** bloque de 5° × 5° de latitud y longitud. Su código es la esquina suroeste; por ejemplo, `30_75` cubre de 30° a 35° N y de 75° a 80° E.
- **Respaldo:** si una región tiene menos de 200 focos en ese mes del año durante la calibración, se usa la k nacional del mes. En la práctica, el **98 % de los focos MODIS de 2002–2012 usa k regional**. El respaldo se usa sobre todo en los meses del monzón, con muy pocos focos.
- **El umbral de 200** se eligió probando 50, 100, 200, 500 y 1000. Por debajo de 200, el error regional apenas mejora (18,6 % frente a 19,9 %), y las constantes se apoyan en menos datos.
- Julio de 2002 se trata como "solo Terra", porque Aqua empieza el 4 de julio y ese mes está incompleto.
- Se armoniza **por foco y no por total**, para que la app pueda sumar cualquier polígono sin recalcular nada.

## Resultado: desaparece el salto de 2012

Media anual de 2012–2014 dividida entre la de 2009–2011:

| Serie | Razón |
|---|---:|
| MODIS bruto (referencia: sin cambio de sensor) | 1,00 |
| Empalme crudo (MODIS hasta 2011, VIIRS después) | **5,36** |
| Serie armonizada con k nacional por mes (versión anterior) | 0,96 |
| **Serie armonizada con k por mes y región** | **0,99** |

Totales anuales de la serie armonizada:

| Año | 2001* | 2003 | 2005 | 2007 | 2009 | 2011 | 2012 | 2013 | 2015 | 2017 | 2019 | 2021 | 2023 | 2025 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Focos (miles) | 363 | 278 | 313 | 367 | 462 | 378 | 454 | 359 | 351 | 435 | 378 | 582 | 409 | 460 |

\* A partir de Terra solamente; es menos preciso.

Entre 2003 y 2011, la k regional deja la serie un **~5 % más baja** que la k nacional. La k nacional sobrestimaba esos años porque se quemaba proporcionalmente más en regiones de k baja.

## Validación

**Escala nacional (MODIS×k frente a VIIRS observado, por mes):**

| Tramo | k | Meses | r | Sesgo | Error mediano | RMSE |
|---|---|---:|---:|---:|---:|---:|
| 2012–2018 (calibración) | nacional | 83 | 0,991 | 0,0 % | 8,1 % | 4 983 focos |
| 2012–2018 (calibración) | **mes × región** | 83 | 0,992 | −0,4 % | 7,8 % | 4 841 focos |
| 2019–2025 (prueba) | nacional | 84 | 0,987 | +2,7 % | 10,3 % | 6 655 focos |
| 2019–2025 (prueba) | **mes × región** | 84 | 0,989 | +4,4 % | 10,9 % | 6 477 focos |

**Escala regional (región de 5° × mes, 2019–2025, casos con ≥ 100 focos S-NPP).** Esta escala es la que importa para la app, en la que el usuario elige un área:

| Fuente | k | Casos | r | Error mediano | Error p90 |
|---|---|---:|---:|---:|---:|
| Todo MODIS | nacional | 1 065 | 0,918 | 28,5 % | 64,4 % |
| Todo MODIS | **mes × región** | 1 065 | **0,980** | **19,9 %** | 56,6 % |
| Solo Terra | nacional | 1 065 | 0,819 | 51,3 % | 161,1 % |
| Solo Terra | **mes × región** | 1 065 | **0,939** | **34,6 %** | 97,0 % |

- **A escala regional, la k por región reduce el error un 30 %** con todo MODIS y un 33 % con solo Terra.
- **A escala nacional el resultado es casi el mismo**: r y RMSE mejoran un poco, y el sesgo de prueba pasa de +2,7 % a +4,4 %.

**Tramo con solo Terra (2000–2002).** Se valida de dos formas:

1. **Contra VIIRS observado en 2019–2025**, que no se usó para calibrar. El sesgo nacional de Terra×k_terra es **−1,4 %** con k regional y +7,3 % con k nacional. El error regional es el de la tabla de arriba.
2. **Contra MODIS×k en 2003–2011**, donde no hay VIIRS, así que se comparan dos estimaciones entre sí:

| Comparación (2003–2011, 108 meses) | r | Sesgo | Error mediano |
|---|---:|---:|---:|
| Terra×k_terra frente a MODIS×k, ambas con k nacional | 0,947 | +2,8 % | 11,8 % |
| Terra×k_terra frente a MODIS×k, ambas con k regional | 0,934 | +12,4 % | 12,1 % |

Las dos estimaciones regionales discrepan más en 2003–2011, porque se desvían en sentidos opuestos (Terra +3,7 % y MODIS −5,1 % respecto a sus versiones nacionales). Frente a observaciones reales (punto 1), la k regional es la mejor, por eso es la que se usa.

Esa discrepancia es una medida honesta de la **incertidumbre de 2000–2002: ±10 % en totales anuales**. La app debe marcar esos años como de **menor precisión**.

La proporción de focos que aporta Terra sube un poco con el tiempo: 26,9 % en 2003–2011, 28,0 % en 2012–2018 y 30,1 % en 2019–2025.

## Formato VIIRS de cada foco: confidence y FRP

Se integró el método de la rama `Develop` (`analisis/04_modis_formato_viirs.sql`). Las dos armonizaciones se complementan:

| Qué se armoniza | Método | Origen |
|---|---|---|
| **Cuántos focos** hay | `peso` = k(mes del año, región) | esta rama |
| **Cómo es cada foco**: `confidence` y `frp` | Emparejamiento de proporciones y de cuantiles | rama `Develop` |

En la comparación, el método de `Develop` por sí solo no corrige el número de focos: el salto de 2012 seguía en 6,59 y el sesgo en −85 %. Usar su `confidence` como filtro tampoco mejoró el error (21,6 % frente a 19,9 % por región). Por eso aquí la **letra es solo informativa**: qué focos cuentan lo sigue decidiendo `confidence_modis >= 30`.

**Cambios respecto a `Develop`**, para que sea coherente con las k:

- **Referencia:** se calibra con S-NPP, que es la escala de referencia, no con S-NPP + NOAA-20.
- **Tramo de calibración:** el mismo que el de las k (2012-02 a 2018-12). Así, 2019–2025 sirve de prueba.
- **Umbrales candidatos de 0 a 101.** El valor 101 significa «ningún foco es `h`». En `Develop`, de noche, todos los MODIS con confianza 100 quedaban como `h` (6,1 %), cuando en VIIRS son el 0,1 %. Ahora quedan como `n`.
- **No se usa `05_confidence_modis_a_viirs.py`**, porque sobrescribía los CSV de MODIS y deja `confidence` en letras. Si se ejecuta, este pipeline descarta todos los focos MODIS, porque el filtro `>= 30` no encuentra números.

**confidence** (MODIS 0–100 → `l`/`n`/`h`):

| | Umbrales | MODIS l / n / h (prueba 2019–2025) | VIIRS l / n / h (prueba 2019–2025) |
|---|---|---|---|
| Día | `l` < 54 ≤ `n` < 95 ≤ `h` | 22,9 / 73,5 / 3,7 % | 24,0 / 71,9 / 4,1 % |
| Noche | todo `n` (VIIRS nocturno casi no tiene `l` ni `h`) | 0 / 100 / 0 % | 0 / 99,9 / 0,1 % |

En la serie solo entran los MODIS con `confidence >= 30`. De día, los de 30 a 53 aparecen con la letra `l`.

**FRP por foco** (MW, prueba 2019–2025): MODIS convertido reproduce la distribución de VIIRS.

| | p25 | p50 | p90 | p99 |
|---|---:|---:|---:|---:|
| Día: MODIS bruto | 9,2 | 14,6 | 53,0 | 261 |
| Día: **MODIS convertido** | 3,3 | 5,1 | 15,0 | 61 |
| Día: VIIRS S-NPP | 3,3 | 5,2 | 15,0 | 67 |
| Noche: MODIS bruto | 6,7 | 9,3 | 24,8 | 66 |
| Noche: **MODIS convertido** | 0,85 | 1,3 | 3,0 | 7,1 |
| Noche: VIIRS S-NPP | 0,82 | 1,3 | 2,9 | 7,0 |

**FRP total de un área** = `sum(frp * peso)`. Para la intensidad total en escala VIIRS hacen falta las dos armonizaciones; su error está en la sección siguiente.

## Cálculo de error de la armonización combinada

Se compara MODIS armonizado (`modis_armonizado`, con `peso`, `confidence` en letras y `frp` en escala VIIRS) con VIIRS S-NPP observado en 2012–2025. Lo calcula la sección «Cálculo de error» de `04_armonizar.sql`, que exporta `analisis/salida/error_armonizacion.csv` y `analisis/salida/error_formato.csv`.

**Criterios:**

- **Mismos días:** solo días con datos de S-NPP. Se excluyen sus huecos (por ejemplo, julio de 2024), en los que VIIRS no observó y MODIS sí.
- **Calibración** = 2012–2018, de donde salen las k, los umbrales de `confidence` y la curva de FRP. **Prueba** = 2019–2025, años que el modelo no vio. **El error que cuenta es el de prueba.**
- **Referencia:** cada métrica se calcula también para MODIS *sin armonizar*. Eso es el conteo bruto, `sum(frp_modis)` y las clases oficiales de MODIS (< 30 / 30–79 / ≥ 80).
- **Métricas de área:**
  - *error absoluto ponderado* = Σ|MODIS − VIIRS| / ΣVIIRS, con todos los casos;
  - *error mediano* y *p90*, en casos con ≥ 100 focos VIIRS, para no dividir entre números pequeños.

### 1. Número de focos

Prueba 2019–2025:

| Escala | Casos | r | Sesgo | Error abs. ponderado | Error mediano | Error p90 | Sin armonizar: error mediano |
|---|---:|---:|---:|---:|---:|---:|---:|
| Año, nacional | 7 | 0,986 | +3,9 % | 4,0 % | **2,8 %** | 7,3 % | 82,4 % |
| Mes, nacional | 84 | 0,989 | +3,9 % | 10,5 % | **10,8 %** | 31,6 % | 81,8 % |
| Mes, región 5° | 1 930 | 0,983 | +3,9 % | 17,5 % | **19,9 %** | 56,7 % | 84,2 % |
| Mes, celda 1° | 21 966 | 0,964 | +3,9 % | 34,1 % | **28,6 %** | 79,6 % | 85,1 % |

En calibración (2012–2018), el error mediano es 4,4 % / 7,7 % / 13,5 % / 25,0 % en esas mismas escalas, con un sesgo de −0,7 %.

### 2. FRP total de un área, `sum(frp * peso)`

Prueba 2019–2025:

| Escala | r | Sesgo | Error abs. ponderado | Error mediano | Error p90 | Sin armonizar: sesgo / error mediano |
|---|---:|---:|---:|---:|---:|---:|
| Año, nacional | 0,974 | +6,2 % | 7,0 % | **3,3 %** | 13,4 % | −25,8 % / 26,8 % |
| Mes, nacional | 0,982 | +6,2 % | 15,4 % | **14,1 %** | 51,0 % | −25,8 % / 38,8 % |
| Mes, región 5° | 0,956 | +6,2 % | 24,6 % | **26,0 %** | 71,5 % | −25,8 % / 48,4 % |
| Mes, celda 1° | 0,949 | +6,2 % | 35,6 % | **32,7 %** | 85,0 % | −25,8 % / 53,3 % |

En calibración, el sesgo también es +6,2 %, así que es sistemático y no un problema de generalización. Probablemente se debe a que las regiones con k alta también tienen fuegos de FRP más alto, y la curva de FRP es nacional. Una curva por región podría corregirlo.

### 3. Formato de cada foco

Calibración / prueba:

| Atributo | Métrica | Día | Noche | Sin armonizar (día / noche, prueba) |
|---|---|---:|---:|---:|
| `confidence` l/n/h | Diferencia total de proporciones con VIIRS (puntos %) | 0,6 / **1,6** | 0,1 / **0,1** | 20,5 / 31,4 |
| `frp` por foco | Error relativo medio de los percentiles 5–95 | 0,2 % / **0,7 %** | 0,2 % / **2,7 %** | 200 % / 716 % |

- **Diferencia total de proporciones** = ½ Σ|p_MODIS − p_VIIRS| sobre las tres letras: el porcentaje de focos que habría que cambiar de letra para igualar a VIIRS. Con tres clases coincide con la mayor diferencia de una letra.
- **Percentiles de FRP:** el error máximo en cualquier percentil entre el 5 y el 95 es de 2,0 % de día y 3,7 % de noche.

### Error anual a escala nacional

| Año | 2012 | 2013 | 2014 | 2015 | 2016 | 2017 | 2018 | 2019 | 2020 | 2021 | 2022 | 2023 | 2024 | 2025 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Nº de focos | +5,4 % | −0,9 % | −6,0 % | −4,4 % | −7,7 % | +4,4 % | +4,0 % | +1,8 % | +2,8 % | +4,7 % | +1,5 % | +4,0 % | −0,4 % | **+11,2 %** |
| FRP total | +13,3 % | +3,3 % | −1,0 % | −0,4 % | +0,8 % | **+14,9 %** | +12,0 % | +11,3 % | −2,3 % | **+16,5 %** | +3,3 % | +8,6 % | −0,9 % | +2,8 % |

### Lectura

- **El número de focos cuadra muy bien en totales y razonablemente por área.**
  - Error típico: 3 % al año, 11 % al mes, 20 % por región de 5° y 29 % por celda de 1°.
  - Sin armonizar, el error es del 82–85 % en cualquier escala.
  - El error crece al reducir el área, porque en áreas pequeñas manda el azar de qué fuegos ve cada sensor. La app debería avisar de que las áreas pequeñas son menos fiables, o mostrarlas agregadas.
- **El formato de cada foco queda prácticamente igual al de VIIRS:**
  - < 2 puntos de diferencia en las letras de `confidence`;
  - < 3 % de error en la distribución de FRP;
  - sin armonizar, los errores son de 20–31 puntos y de 200–700 %.
- **El FRP total es la magnitud menos precisa:**
  - sesgo de +6,2 % y error de 14 % al mes y 26 % por región;
  - algunos años se desvían más del 10 % (2012, 2017, 2018, 2019 y 2021);
  - aun así, reduce a la mitad el error de usar el FRP bruto de MODIS.
- **El sesgo de prueba en número de focos es +3,9 %**, y en 2025 llega a +11 %. Esto podría indicar que la relación entre sensores cambia con el tiempo; por ejemplo, Terra aporta cada vez más focos. Si se recalibra con todo el solape, para producción, este sesgo debería bajar.

## Pendiente

1. Gráfico de la serie mensual (bruto frente a armonizado) para el informe.
2. Exportar `focos_armonizados` a Parquet o a rejilla y mes, para servirlo en la app.
3. Mostrar la incertidumbre en el calendario: una banda a partir de `k_modis_p25`/`p75` y una marca para 2000–2002.
4. Probar regiones más finas (2,5°) o por ecorregión, y repetir con la región objetivo de la app.
