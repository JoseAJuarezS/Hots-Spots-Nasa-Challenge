-- Compara MODIS y VIIRS S-NPP en el periodo de solape (2012-02 .. 2025-12).
-- Uso (desde la raíz del repo):  duckdb analisis/focos.duckdb < analisis/02_correlacion.sql
-- Filtros comunes: solo vegetación (type = 0); MODIS confidence >= 30; VIIRS confidence n/h.

CREATE OR REPLACE TEMP VIEW f AS
SELECT *, date_trunc('month', fecha) AS mes
FROM focos
WHERE type = 0
  AND fecha >= DATE '2012-02-01'
  AND ((sensor = 'MODIS' AND TRY_CAST(confidence AS INT) >= 30)
       OR (sensor LIKE 'VIIRS%' AND confidence IN ('n', 'h')));

-- Conteos mensuales por "variante" de comparación
CREATE OR REPLACE TEMP TABLE mensual AS
WITH base AS (
  -- 1) Detecciones brutas: todo MODIS (Terra+Aqua) vs S-NPP
  SELECT 'A_bruto_MODIS_vs_SNPP' AS variante, mes,
         count(*) FILTER (sensor = 'MODIS') AS x, count(*) FILTER (sensor = 'VIIRS_SNPP') AS y
  FROM f GROUP BY ALL
  UNION ALL
  -- 2) Mismo horario de paso: solo Aqua vs S-NPP (ambos ~13:30 / ~01:30)
  SELECT 'B_bruto_Aqua_vs_SNPP', mes,
         count(*) FILTER (satellite = 'Aqua'), count(*) FILTER (sensor = 'VIIRS_SNPP')
  FROM f GROUP BY ALL
  UNION ALL
  -- 3) Celdas-día con fuego en rejilla de 0,1°, Aqua vs S-NPP
  SELECT 'C_celdas01_Aqua_vs_SNPP', mes,
         count(DISTINCT (fecha, floor(latitude*10), floor(longitude*10))) FILTER (satellite = 'Aqua'),
         count(DISTINCT (fecha, floor(latitude*10), floor(longitude*10))) FILTER (sensor = 'VIIRS_SNPP')
  FROM f GROUP BY ALL
  UNION ALL
  -- 4) Celdas-día 0,1°, todo MODIS vs S-NPP
  SELECT 'D_celdas01_MODIS_vs_SNPP', mes,
         count(DISTINCT (fecha, floor(latitude*10), floor(longitude*10))) FILTER (sensor = 'MODIS'),
         count(DISTINCT (fecha, floor(latitude*10), floor(longitude*10))) FILTER (sensor = 'VIIRS_SNPP')
  FROM f GROUP BY ALL
)
SELECT * FROM base WHERE x > 0 AND y > 0;

.print '== Resumen por variante (mensual, 2012-2025) =='
SELECT variante,
       count(*)                                   AS meses,
       round(corr(x, y), 3)                       AS r_pearson,
       round(corr(ln(x), ln(y)), 3)               AS r_log,
       round(sum(y) / sum(x), 2)                  AS k_global,      -- y ≈ k·x
       round(median(y / x), 2)                    AS k_mediana,
       round(regr_slope(y, x), 2)                 AS pendiente,
       round(regr_intercept(y, x), 0)             AS intercepto,
       round(regr_r2(y, x), 3)                    AS r2,
       round(exp(regr_intercept(ln(y), ln(x))), 2) AS a_loglog,     -- y ≈ a·x^b
       round(regr_slope(ln(y), ln(x)), 3)          AS b_loglog
FROM mensual GROUP BY variante ORDER BY variante;

.print '== Estabilidad de k por año (variante C) =='
SELECT year(mes) AS anio, sum(x) AS aqua, sum(y) AS snpp, round(sum(y)/sum(x), 2) AS k
FROM mensual WHERE variante = 'C_celdas01_Aqua_vs_SNPP' GROUP BY ALL ORDER BY anio;

.print '== Estacionalidad de k por mes del año (variante C) =='
SELECT month(mes) AS mes_del_anio, sum(x) AS aqua, sum(y) AS snpp, round(sum(y)/sum(x), 2) AS k,
       round(quantile_cont(y/x, 0.25), 2) AS k_p25, round(quantile_cont(y/x, 0.75), 2) AS k_p75
FROM mensual WHERE variante = 'C_celdas01_Aqua_vs_SNPP' GROUP BY ALL ORDER BY 1;

.print '== Validación: calibrar k en 2012-2018, probar en 2019-2025 =='
WITH k AS (
  SELECT variante, sum(y)/sum(x) AS k FROM mensual WHERE mes < DATE '2019-01-01' GROUP BY variante
)
SELECT m.variante, round(any_value(k.k), 2) AS k_entrenado,
       round(median(abs(k.k*m.x - m.y) / m.y) * 100, 1) AS error_mediano_pct,
       round(sum(k.k*m.x) / sum(m.y) * 100 - 100, 1)      AS sesgo_total_pct,
       round(corr(k.k*m.x, m.y), 3)                       AS r_prueba
FROM mensual m JOIN k USING (variante)
WHERE m.mes >= DATE '2019-01-01'
GROUP BY m.variante ORDER BY 1;

.print '== Validación de k mensual (por mes del año) en 2019-2025, variante C =='
WITH k AS (
  SELECT month(mes) AS mm, sum(y)/sum(x) AS k FROM mensual
  WHERE variante = 'C_celdas01_Aqua_vs_SNPP' AND mes < DATE '2019-01-01' GROUP BY 1
)
SELECT round(median(abs(k.k*m.x - m.y) / m.y) * 100, 1) AS error_mediano_pct,
       round(sum(k.k*m.x) / sum(m.y) * 100 - 100, 1)      AS sesgo_total_pct,
       round(corr(k.k*m.x, m.y), 3)                       AS r_prueba
FROM mensual m JOIN k ON month(m.mes) = k.mm
WHERE m.variante = 'C_celdas01_Aqua_vs_SNPP' AND m.mes >= DATE '2019-01-01';
