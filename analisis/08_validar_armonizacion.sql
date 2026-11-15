-- Paso 3: compara MODIS armonizado (07) con lo que VIIRS observó de verdad a partir de 2018,
-- un periodo que las reglas (06, calibradas con 2012-2017) nunca vieron, y mide el error total.
-- Uso (desde la raíz del repo):  duckdb -no-agent < analisis/08_validar_armonizacion.sql
--
-- Entradas:  datos_armonizados/anio=*/modis_armonizado_India_*.parquet   (salida de 07)
--            datos_crudos/VIIRS/viirs-*_India.csv                         (solo 2018+)
--            analisis/reglas/*.csv                                        (para las variantes de referencia)
-- Salidas:   analisis/validacion/*.csv
--
-- Referencias VIIRS:
--   * NOAA-20 (jpss1), desde 2018-04-01. Es la referencia principal.
--   * S-NPP, desde 2018-01-01 (es el satélite con el que se calibró: sirve para separar el error
--     de la armonización del pequeño desajuste entre los dos VIIRS).
-- Solo se comparan DÍAS COMUNES (MODIS y la referencia con datos), y solo vegetación (type = 0).
--
-- Variantes que se comparan contra VIIRS:
--   armonizado   la regla completa de 06 (peso por celda 2° × mes × día/noche + ajuste 1°)
--   k_mes        una constante por mes del año (el método anterior, como línea base)
--   k_global     una sola constante
--   bruto        MODIS sin armonizar (peso 1)
--   solo_terra   solo los focos de Terra × factor f_terra: simula cómo de bien funciona la regla
--                en 2000-2002, cuando no había Aqua
--
-- Métricas (obs = VIIRS, pred = MODIS armonizado):
--   sesgo_pct  = sum(pred) / sum(obs) - 1                         (error total acumulado)
--   wape_pct   = sum|pred - obs| / sum(obs)                       (error absoluto ponderado)
--   mdape_pct  = mediana de |pred - obs| / obs                    (en celdas, solo con obs >= 50)
--   p05 / p95  = percentiles del error relativo (pred - obs) / obs (intervalo del 90 %)

.print '== Cargando datos 2018+ =='

CREATE OR REPLACE TEMP TABLE viirs AS
SELECT CASE WHEN filename ILIKE '%jpss1%' THEN 'NOAA-20' ELSE 'S-NPP' END AS ref,
       acq_date, daynight AS dn, type, lower(confidence) AS confidence, frp,
       floor(latitude)::INT AS cy, floor(longitude)::INT AS cx
FROM read_csv('datos_crudos/VIIRS/viirs-*_India.csv', union_by_name = true, filename = true,
              types = {'acq_time': 'VARCHAR', 'confidence': 'VARCHAR', 'frp': 'DOUBLE', 'version': 'VARCHAR'})
WHERE acq_date >= DATE '2018-01-01';

CREATE OR REPLACE TEMP TABLE k_simple AS SELECT * FROM read_csv('analisis/reglas/k_simple_linea_base.csv');
CREATE OR REPLACE TEMP TABLE f_terra_m AS SELECT * FROM read_csv('analisis/reglas/f_terra_mes.csv');
CREATE OR REPLACE TEMP TABLE f_terra_c AS SELECT * FROM read_csv('analisis/reglas/f_terra_celda2_mes.csv');

CREATE OR REPLACE TEMP TABLE modis AS
SELECT a.acq_date, a.daynight AS dn, a.type, a.confidence, a.frp, a.peso, a.satellite, a.version,
       floor(a.latitude)::INT AS cy, floor(a.longitude)::INT AS cx,
       ks.k_mes AS peso_k_mes, ks.k_global AS peso_k_global,
       CASE WHEN a.satellite = 'Terra' THEN a.peso * coalesce(fc.f, fm.f, 1) ELSE 0 END AS peso_solo_terra
FROM read_parquet('datos_armonizados/*/*.parquet', hive_partitioning = true) a
JOIN k_simple ks ON ks.mm = month(a.acq_date)
LEFT JOIN f_terra_m fm ON fm.dn = a.daynight AND fm.mm = month(a.acq_date)
LEFT JOIN f_terra_c fc ON fc.dn = a.daynight AND fc.mm = month(a.acq_date)
                      AND fc.gy = floor(a.latitude / 2)::INT AND fc.gx = floor(a.longitude / 2)::INT
WHERE a.acq_date >= DATE '2018-01-01' AND a.type = 0;

CREATE OR REPLACE TEMP TABLE dias AS
SELECT r.ref, d.acq_date
FROM (SELECT DISTINCT ref, acq_date FROM viirs) r
JOIN (SELECT DISTINCT acq_date FROM modis) d USING (acq_date);

.print '== Días comunes por referencia =='
SELECT ref, min(acq_date) AS desde, max(acq_date) AS hasta, count(*) AS dias FROM dias GROUP BY ref ORDER BY ref;

-- Conteos por referencia × mes × celda 1° × (confidence n/h o no), solo en días comunes
CREATE OR REPLACE TEMP TABLE base AS
WITH o AS (
  SELECT v.ref, date_trunc('month', v.acq_date) AS mes, v.cy, v.cx, v.confidence IN ('n', 'h') AS conf_nh,
         count(*) AS obs, sum(v.frp) AS obs_frp
  FROM viirs v JOIN dias USING (ref, acq_date) WHERE v.type = 0 GROUP BY ALL
), p AS (
  SELECT d.ref, date_trunc('month', m.acq_date) AS mes, m.cy, m.cx, m.confidence IN ('n', 'h') AS conf_nh,
         sum(m.peso) AS armonizado, sum(m.peso_k_mes) AS k_mes, sum(m.peso_k_global) AS k_global,
         count(*)::DOUBLE AS bruto, sum(m.peso_solo_terra) AS solo_terra, sum(m.frp * m.peso) AS pred_frp
  FROM modis m JOIN dias d USING (acq_date) GROUP BY ALL
)
SELECT ref, mes, cy, cx, conf_nh,
       coalesce(o.obs, 0) AS obs, coalesce(o.obs_frp, 0) AS obs_frp,
       coalesce(p.armonizado, 0) AS armonizado, coalesce(p.k_mes, 0) AS k_mes,
       coalesce(p.k_global, 0) AS k_global, coalesce(p.bruto, 0) AS bruto,
       coalesce(p.solo_terra, 0) AS solo_terra, coalesce(p.pred_frp, 0) AS pred_frp
FROM o FULL JOIN p USING (ref, mes, cy, cx, conf_nh);

-- Formato largo: una fila por variante, subconjunto (todas / n_h) y escala
CREATE OR REPLACE TEMP TABLE largo AS
WITH v AS (
  UNPIVOT (SELECT ref, mes, cy, cx, conf_nh, obs, armonizado, k_mes, k_global, bruto, solo_terra FROM base)
  ON armonizado, k_mes, k_global, bruto, solo_terra INTO NAME variante VALUE pred
), s AS (
  SELECT *, 'todas' AS subconjunto FROM v
  UNION ALL
  SELECT *, 'n_h' FROM v WHERE conf_nh
)
SELECT ref, variante, subconjunto, e.escala, mes,
       CASE e.escala WHEN 'india_mes' THEN ''
                     WHEN 'celda2_mes' THEN (floor(cy / 2)::INT * 2) || ',' || (floor(cx / 2)::INT * 2)
                     ELSE cy || ',' || cx END AS celda,
       sum(obs) AS obs, sum(pred) AS pred
FROM s, (VALUES ('india_mes'), ('celda2_mes'), ('celda1_mes')) e(escala)
GROUP BY ALL;

-- Añade la escala anual (India × año)
INSERT INTO largo
SELECT ref, variante, subconjunto, 'india_anio', date_trunc('year', mes), '', sum(obs), sum(pred)
FROM largo WHERE escala = 'india_mes' GROUP BY ALL;

CREATE OR REPLACE TEMP TABLE metricas AS
SELECT ref, variante, subconjunto, escala,
       count(*) AS n,
       round(corr(pred, obs), 4) AS r,
       round(sum(pred) / sum(obs) * 100 - 100, 1) AS sesgo_pct,
       round(sum(abs(pred - obs)) / sum(obs) * 100, 1) AS wape_pct,
       round(median(abs(pred - obs) / obs) FILTER (obs >= 50) * 100, 1) AS mdape_pct,
       round(quantile_cont((pred - obs) / obs, 0.05) FILTER (obs >= 50) * 100, 1) AS p05_pct,
       round(quantile_cont((pred - obs) / obs, 0.95) FILTER (obs >= 50) * 100, 1) AS p95_pct,
       round(sqrt(avg((pred - obs) ^ 2)), 0) AS rmse_focos
FROM largo GROUP BY ALL;

-- ===========================================================================
-- RESULTADOS
-- ===========================================================================

.print ''
.print '== 1. MARGEN DE ERROR TOTAL: MODIS armonizado vs VIIRS 2018+ (vegetación, todas las confidence) =='
SELECT ref, escala, n, r, sesgo_pct, wape_pct, mdape_pct, p05_pct, p95_pct, rmse_focos
FROM metricas WHERE variante = 'armonizado' AND subconjunto = 'todas'
ORDER BY ref, list_position(['india_anio', 'india_mes', 'celda2_mes', 'celda1_mes'], escala);

.print '== 2. Comparación con reglas más simples (referencia NOAA-20) =='
SELECT variante, escala, r, sesgo_pct, wape_pct, mdape_pct
FROM metricas WHERE ref = 'NOAA-20' AND subconjunto = 'todas' AND escala <> 'india_anio'
ORDER BY list_position(['india_mes', 'celda2_mes', 'celda1_mes'], escala),
         list_position(['armonizado', 'k_mes', 'k_global', 'solo_terra', 'bruto'], variante);

.print '== 3. Solo focos con confidence n/h (filtro habitual en el calendario) =='
SELECT ref, escala, r, sesgo_pct, wape_pct, mdape_pct, p05_pct, p95_pct
FROM metricas WHERE variante = 'armonizado' AND subconjunto = 'n_h'
ORDER BY ref, list_position(['india_anio', 'india_mes', 'celda2_mes', 'celda1_mes'], escala);

.print '== 4. Error por año (NOAA-20; S-NPP como control) =='
CREATE OR REPLACE TEMP TABLE por_anio AS
SELECT year(mes) AS anio,
       sum(obs) FILTER (ref = 'NOAA-20') AS viirs_noaa20,
       sum(pred) FILTER (ref = 'NOAA-20') AS modis_armonizado_dias_noaa20,
       round(sum(pred) FILTER (ref = 'NOAA-20') / sum(obs) FILTER (ref = 'NOAA-20') * 100 - 100, 1) AS error_vs_noaa20_pct,
       sum(obs) FILTER (ref = 'S-NPP') AS viirs_snpp,
       round(sum(pred) FILTER (ref = 'S-NPP') / sum(obs) FILTER (ref = 'S-NPP') * 100 - 100, 1) AS error_vs_snpp_pct
FROM largo WHERE variante = 'armonizado' AND subconjunto = 'todas' AND escala = 'india_mes'
GROUP BY anio ORDER BY anio;
SELECT anio, viirs_noaa20, round(modis_armonizado_dias_noaa20)::BIGINT AS modis_armonizado,
       error_vs_noaa20_pct, viirs_snpp, error_vs_snpp_pct FROM por_anio;

.print '== 5. ¿Se degrada con la versión de MODIS? (C6.03 en 2018-2022, C6.1 en 2023-2025; India-mes) =='
SELECT ref, CASE WHEN mes < DATE '2023-01-01' THEN '2018-2022 (v6.03)' ELSE '2023-2025 (v61.03)' END AS tramo,
       count(*) AS meses, round(corr(pred, obs), 4) AS r,
       round(sum(pred) / sum(obs) * 100 - 100, 1) AS sesgo_pct,
       round(sum(abs(pred - obs)) / sum(obs) * 100, 1) AS wape_pct
FROM largo WHERE variante = 'armonizado' AND subconjunto = 'todas' AND escala = 'india_mes'
GROUP BY ALL ORDER BY ALL;

.print '== 6. Sesgo por mes del año (NOAA-20, India) =='
SELECT month(mes) AS mm, sum(obs) AS viirs, round(sum(pred))::BIGINT AS armonizado,
       round(sum(pred) / sum(obs) * 100 - 100, 1) AS sesgo_pct,
       round(sum(abs(pred - obs)) / sum(obs) * 100, 1) AS wape_pct
FROM largo WHERE ref = 'NOAA-20' AND variante = 'armonizado' AND subconjunto = 'todas' AND escala = 'india_mes'
GROUP BY mm ORDER BY mm;

.print '== 7. Error de base entre los dos VIIRS (NOAA-20 frente a S-NPP, mismos días, India-mes) =='
.print '   Es el mínimo razonable: ni dos satélites VIIRS coinciden exactamente.'
WITH dc AS (SELECT acq_date FROM dias WHERE ref = 'NOAA-20' INTERSECT SELECT acq_date FROM dias WHERE ref = 'S-NPP'),
m AS (SELECT date_trunc('month', acq_date) AS mes,
             count(*) FILTER (ref = 'NOAA-20') AS n20, count(*) FILTER (ref = 'S-NPP') AS snpp
      FROM viirs WHERE type = 0 AND acq_date IN (SELECT acq_date FROM dc) GROUP BY ALL)
SELECT count(*) AS meses, round(corr(snpp, n20), 4) AS r,
       round(sum(snpp) / sum(n20) * 100 - 100, 1) AS sesgo_snpp_vs_n20_pct,
       round(sum(abs(snpp - n20)) / sum(n20) * 100, 1) AS wape_pct
FROM m;

.print '== 8. FRP: total mensual de India, sum(frp × peso) frente a sum(frp) de VIIRS =='
SELECT ref, count(*) AS meses, round(corr(pred, obs), 4) AS r,
       round(sum(pred) / sum(obs) * 100 - 100, 1) AS sesgo_pct,
       round(sum(abs(pred - obs)) / sum(obs) * 100, 1) AS wape_pct
FROM (SELECT ref, mes, sum(obs_frp) AS obs, sum(pred_frp) AS pred FROM base GROUP BY ALL)
GROUP BY ref ORDER BY ref;

.print '== 9. Distribución de FRP y de confidence por foco (2018+, vegetación) =='
SELECT 'MODIS armonizado' AS fuente, dn, quantile_cont(frp, [0.1, 0.5, 0.9, 0.99]) AS frp_p10_50_90_99,
       round(100 * sum(peso) FILTER (confidence = 'l') / sum(peso), 1) AS pct_l,
       round(100 * sum(peso) FILTER (confidence = 'n') / sum(peso), 1) AS pct_n,
       round(100 * sum(peso) FILTER (confidence = 'h') / sum(peso), 1) AS pct_h
FROM modis GROUP BY dn
UNION ALL
SELECT 'VIIRS ' || ref, dn, quantile_cont(frp, [0.1, 0.5, 0.9, 0.99]),
       round(100 * avg((confidence = 'l')::INT), 1), round(100 * avg((confidence = 'n')::INT), 1),
       round(100 * avg((confidence = 'h')::INT), 1)
FROM viirs WHERE type = 0 GROUP BY ALL ORDER BY dn, fuente;

-- ===========================================================================
-- EXPORTAR
-- ===========================================================================
-- La carpeta analisis/validacion/ está versionada en git (DuckDB no crea carpetas al exportar).

COPY (SELECT * FROM metricas ORDER BY ref, variante, subconjunto, escala)
TO 'analisis/validacion/metricas.csv' (HEADER);

COPY (SELECT ref, mes::DATE AS mes, obs AS viirs, round(pred) AS modis_armonizado,
             round((pred - obs) / obs * 100, 1) AS error_pct
      FROM largo WHERE variante = 'armonizado' AND subconjunto = 'todas' AND escala = 'india_mes'
      ORDER BY ref, mes)
TO 'analisis/validacion/serie_mensual.csv' (HEADER);

COPY (SELECT * FROM por_anio) TO 'analisis/validacion/por_anio.csv' (HEADER);

COPY (SELECT celda, sum(obs) AS viirs, round(sum(pred)) AS modis_armonizado,
             round(sum(pred) / sum(obs) * 100 - 100, 1) AS sesgo_pct,
             round(sum(abs(pred - obs)) / sum(obs) * 100, 1) AS wape_pct
      FROM largo WHERE ref = 'NOAA-20' AND variante = 'armonizado' AND subconjunto = 'todas' AND escala = 'celda2_mes'
      GROUP BY celda HAVING sum(obs) > 0 ORDER BY viirs DESC)
TO 'analisis/validacion/error_por_celda2.csv' (HEADER);

.print '== Listo: analisis/validacion/ =='
