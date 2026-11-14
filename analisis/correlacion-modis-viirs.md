# Correlación MODIS vs VIIRS y constante de conversión

Análisis del periodo en que los dos sensores funcionan a la vez, para obtener una constante que "traduzca" los focos de MODIS a la escala de VIIRS.

- **Datos:** CSV anuales de FIRMS para **India** (`datos_crudos/MODIS/` y `datos_crudos/VIIRS/`).
- **Periodo de solape:** febrero de 2012 a diciembre de 2025, 167 meses con datos de MODIS y VIIRS S-NPP.
- **Filtros comunes:**
  - solo vegetación (`type = 0`);
  - MODIS con `confidence >= 30`;
  - VIIRS con `confidence` igual a `n` o `h`.
- **Unidad:** focos detectados por mes.

## Cómo reproducirlo

Desde la raíz del repo:

```bash
mise install                 # instala DuckDB, entre otras herramientas
mise run datos:cargar        # CSV -> analisis/focos.duckdb (~147 MB, ignorado por git)
mise run datos:correlacion   # ejecuta 02_correlacion.sql y 03_k_mensual.sql
```

| Archivo | Contenido |
|---|---|
| `01_cargar.sql` | Une todos los CSV en una tabla `focos` |
| `02_correlacion.sql` | Compara cuatro formas de medir, la estabilidad de k por año y por mes, y la validación |
| `03_k_mensual.sql` | k por mes del año, k solo con Terra, y NOAA-20 frente a S-NPP |

## Resultado principal: la relación es casi perfectamente proporcional

Todo MODIS (Terra + Aqua) frente a VIIRS S-NPP, por mes:

| Métrica | Valor |
|---|---:|
| Correlación de Pearson (r) | **0,984** |
| r² | 0,969 |
| Constante global (VIIRS ≈ k · MODIS) | **k = 5,61** |
| Regresión log-log (VIIRS ≈ a · MODIS^b) | a = 5,52, **b = 1,002** |

Que el exponente salga b ≈ 1 indica que la relación es **proporcional pura**: multiplicar por una constante es el modelo adecuado y no hace falta uno más complejo.

## Validación

La constante se calibró con **2012–2018** y se comparó con los datos reales de VIIRS en **2019–2025**, que el modelo no había visto.

| Método | Error mediano por mes | Sesgo total | r |
|---|---:|---:|---:|
| Una sola constante (k = 5,65) | 13,8 % | +1,3 % | 0,983 |
| **Una constante por mes del año** | **10,3 %** | +2,7 % | **0,987** |
| Solo Terra, una sola constante | 39,0 % | +9,2 % | 0,914 |
| Solo Terra, una constante por mes | 17,6 % | +7,3 % | 0,978 |

**Recomendación:** usar **una constante por mes del año**, calculada con todo MODIS.

## Constantes por mes del año (calibradas con 2012–2018)

| Mes | Ene | Feb | Mar | Abr | May | Jun | Jul | Ago | Sep | Oct | Nov | Dic |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| k (todo MODIS → VIIRS) | 5,30 | 5,88 | 5,63 | 6,15 | 5,94 | 8,71 | 6,31 | 3,83 | 5,36 | 4,41 | 5,49 | 5,69 |
| k (solo Terra → VIIRS) | 16,04 | 19,95 | 23,32 | 16,05 | 11,65 | 17,15 | 12,31 | 7,06 | 10,83 | 37,04 | 48,60 | 17,50 |

La proporción cambia con la estación (por ejemplo, 3,8 en agosto y 8,7 en junio). Las causas probables son las nubes del monzón y el tipo de quema en cada época. En los meses del monzón (junio a septiembre) hay muy pocos focos, así que sus constantes son menos fiables.

## Estabilidad de k por año

Medida en celdas-día de 0,1°, Aqua frente a S-NPP:

| Año | 2012 | 2013 | 2014 | 2015 | 2016 | 2017 | 2018 | 2019 | 2020 | 2021 | 2022 | 2023 | 2024 | 2025 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| k | 5,09 | 5,68 | 5,85 | 5,94 | 5,98 | 5,77 | 5,95 | 6,19 | 5,98 | 5,42 | 6,35 | 6,46 | 6,33 | 5,57 |

No hay una tendencia fuerte, aunque sube ligeramente a partir de 2019. Puede deberse a la degradación de Terra y Aqua, que se acercan al final de su vida útil. Hay que vigilarlo.

## Comparación de formas de medir

| Variante | r | k global | Error en validación |
|---|---:|---:|---:|
| A. Focos, todo MODIS vs S-NPP | **0,984** | 5,61 | **13,8 %** |
| B. Focos, solo Aqua vs S-NPP (mismo horario de paso) | 0,945 | 7,91 | 26,4 % |
| C. Celdas-día de 0,1°, Aqua vs S-NPP | 0,942 | 5,87 | 27,2 % |
| D. Celdas-día de 0,1°, todo MODIS vs S-NPP | 0,982 | 4,02 | 15,2 % |

Contar celdas con fuego no mejoró el resultado. Comparar solo con Aqua, aunque tenga el mismo horario de paso que S-NPP, también funciona peor que usar todo MODIS. **Contar focos filtrados de todo MODIS es la opción más simple y la más precisa.**

## Otros hallazgos

- **NOAA-20 y S-NPP son intercambiables:** k = 1,014 y r = 0,999 (de abril de 2018 a 2025). Los dos VIIRS no necesitan armonizarse entre sí.
- **Años 2000–2002:** antes de julio de 2002 solo funcionaba Terra, así que la constante de "todo MODIS" no se aplica a esos años.
  - Hay que usar la **constante de Terra**, que tiene un error mayor (≈18 %).
  - Terra pasa por la mañana, cuando hay menos fuego activo.
  - La app debería indicar que esos años son menos precisos.

## Limitaciones

- Las constantes son **para India en conjunto**. En otra región, como Argentina, hay que recalcularlas, y probablemente sean distintas.
- En áreas pequeñas que dibuje el usuario hay pocos focos y el error será mayor. Allí conviene usar la constante de la región, no calcular una por cada área.
- Las constantes se calcularon con conteos mensuales. Para mostrar datos diarios, el error relativo será mayor.

## Próximos pasos

1. ~~Generar la serie mensual armonizada de 2000 a 2025.~~ Hecho: ver [`serie-armonizada.md`](serie-armonizada.md).
2. Repetir el análisis con la región objetivo de la app.
3. Decidir cómo mostrar la incertidumbre en el calendario, sobre todo en 2000–2002.
