-- Serie armonizada 2000-2025 en escala VIIRS S-NPP.
-- Uso (desde la raíz del repo):  duckdb analisis/focos.duckdb < analisis/04_armonizar.sql
--
-- Regla:
--   * Desde 2012-02: focos VIIRS S-NPP observados (peso 1).
--   * 2002-08 .. 2012-01: focos de todo MODIS (Terra + Aqua) × k(mes del año, región).
--   * 2000-11 .. 2002-07: solo Terra (Aqua aún no está completo) × k_terra(mes del año, región).
-- Región = bloque de 5° x 5° (código = esquina suroeste, p. ej. '30_75').
-- k(mes, región) solo se usa si la región tiene >= 200 focos MODIS (o Terra) en ese mes del año
-- durante la calibración; si no, se usa la k nacional de ese mes (k_mes).
-- Por qué k por región: ver analisis/propuesta-armonizacion-2012-2018.md y serie-armonizada.md.
-- Las k se calibran con 2012-02 .. 2018-12 (el tramo más cercano a los años que rellenamos).
-- Se armoniza a nivel de foco (columna `peso`), así cualquier área dibujada en la app
-- se puede sumar directamente: focos armonizados = sum(peso).
-- Además, cada foco MODIS se pasa al formato VIIRS (método de la rama Develop, sección 1d):
-- confidence en letras l/n/h y frp en escala VIIRS. FRP total de un área = sum(frp * peso).

SET VARIABLE min_focos_region = 200;

-- Filtros comunes (los mismos que en 02 y 03)
CREATE OR REPLACE TEMP VIEW f AS
SELECT *, date_trunc('month', fecha) AS mes,
       printf('%02d_%02d', CAST(floor(latitude / 5) * 5 AS INT), CAST(floor(longitude / 5) * 5 AS INT)) AS region
FROM focos
WHERE type = 0
  AND ((sensor = 'MODIS' AND TRY_CAST(confidence AS INT) >= 30)
       OR (sensor LIKE 'VIIRS%' AND confidence IN ('n', 'h')));

-- 1a) Constantes nacionales por mes del año (respaldo) ---------------------------
CREATE OR REPLACE TABLE k_mes AS
WITH m AS (
  SELECT mes,
         count(*) FILTER (sensor = 'MODIS')      AS modis,
         count(*) FILTER (satellite = 'Terra')   AS terra,
         count(*) FILTER (sensor = 'VIIRS_SNPP') AS snpp
  FROM f WHERE mes BETWEEN DATE '2012-02-01' AND DATE '2018-12-01'
  GROUP BY ALL HAVING modis > 0 AND snpp > 0
)
SELECT month(mes) AS mm,
       sum(snpp) / sum(modis) AS k_modis,
       sum(snpp) / sum(terra) AS k_terra,
       -- dispersión mensual de la razón, para dar una banda de incertidumbre
       quantile_cont(snpp / modis, 0.25) AS k_modis_p25,
       quantile_cont(snpp / modis, 0.75) AS k_modis_p75
FROM m GROUP BY 1 ORDER BY 1;

-- 1b) Constantes por mes del año y región ----------------------------------------
--     NULL cuando la región no llega a min_focos_region (entonces se usa k_mes).
CREATE OR REPLACE TABLE k_mes_region AS
WITH c AS (
  SELECT month(mes) AS mm, region,
         count(*) FILTER (sensor = 'MODIS')      AS n_modis,
         count(*) FILTER (satellite = 'Terra')   AS n_terra,
         count(*) FILTER (sensor = 'VIIRS_SNPP') AS n_snpp
  FROM f WHERE mes BETWEEN DATE '2012-02-01' AND DATE '2018-12-01'
  GROUP BY ALL
)
SELECT mm, region, n_modis, n_terra, n_snpp,
       CASE WHEN n_modis >= getvariable('min_focos_region') THEN n_snpp / n_modis END AS k_modis,
       CASE WHEN n_terra >= getvariable('min_focos_region') THEN n_snpp / n_terra END AS k_terra
FROM c
WHERE n_modis >= getvariable('min_focos_region') OR n_terra >= getvariable('min_focos_region')
ORDER BY mm, region;

-- 1c) k efectiva de cada foco MODIS (todas las fechas, también el solape para validar)
CREATE OR REPLACE TEMP TABLE modis_k AS
SELECT f.mes, f.fecha, f.acq_time, f.region, f.satellite, f.latitude, f.longitude, f.frp, f.daynight,
       TRY_CAST(f.confidence AS INT) AS confidence_modis,
       coalesce(kr.k_modis, k.k_modis) AS k_modis,
       coalesce(kr.k_terra, k.k_terra) AS k_terra,
       k.k_modis AS k_modis_nacional,
       k.k_terra AS k_terra_nacional,
       kr.k_modis IS NOT NULL AS k_modis_regional,
       kr.k_terra IS NOT NULL AS k_terra_regional
FROM f
JOIN k_mes k ON month(f.mes) = k.mm
LEFT JOIN k_mes_region kr ON kr.mm = month(f.mes) AND kr.region = f.region
WHERE f.sensor = 'MODIS';

-- 1d) Formato VIIRS de cada foco MODIS: confidence en letras y FRP --------------
--     Método de la rama Develop (analisis/04_modis_formato_viirs.sql), integrado aquí:
--     * confidence: dos umbrales sobre la confianza numérica de MODIS para que la
--       proporción l / n / h sea la de VIIRS S-NPP (por separado de día y de noche).
--       Los umbrales candidatos van de 0 a 101: 101 significa "ningún foco es h", lo que
--       evita que de noche todos los MODIS con confianza 100 queden como h (VIIRS ~0 %).
--     * frp: emparejamiento de cuantiles (1001 percentiles, interpolación lineal; fuera
--       del rango calibrado se escala con la razón VIIRS/MODIS del extremo).
--     Diferencias con Develop, para que sea coherente con las k:
--     * Se calibra con S-NPP (la escala de referencia), no con S-NPP + NOAA-20.
--     * Mismo tramo de calibración que las k (2012-02..2018-12); 2019-2025 queda de prueba.
--     * Solo días con MODIS y S-NPP. confidence se calibra con todos los focos type = 0;
--       frp, con los focos que cuentan en la serie (MODIS conf >= 30, VIIRS n/h).
--     El FRP convertido es el de un "foco típico de VIIRS": la intensidad total de un área
--     en escala VIIRS es sum(frp * peso), no sum(frp).
CREATE OR REPLACE TEMP TABLE dias_cal AS
SELECT fecha FROM focos WHERE sensor = 'MODIS' AND fecha BETWEEN DATE '2012-02-01' AND DATE '2018-12-31'
INTERSECT
SELECT fecha FROM focos WHERE sensor = 'VIIRS_SNPP' AND fecha BETWEEN DATE '2012-02-01' AND DATE '2018-12-31';

CREATE OR REPLACE TABLE umbrales_confidence AS
WITH mc AS (
  SELECT daynight, TRY_CAST(confidence AS INT) AS c, count(*) AS n
  FROM focos JOIN dias_cal USING (fecha)
  WHERE sensor = 'MODIS' AND type = 0 GROUP BY ALL
), vc AS (
  SELECT daynight, avg((confidence = 'l')::INT) AS p_l, avg((confidence = 'h')::INT) AS p_h
  FROM focos JOIN dias_cal USING (fecha)
  WHERE sensor = 'VIIRS_SNPP' AND type = 0 GROUP BY ALL
), cand AS (
  -- P(conf < t) en MODIS para cada umbral candidato t = 0..101
  SELECT mc.daynight, t.t, sum(n) FILTER (c < t.t) / sum(n) AS f_menor
  FROM mc, range(0, 102) t(t) GROUP BY ALL
), elegido AS (
  SELECT cand.daynight,
         arg_min(t, abs(f_menor - p_l))       AS umbral_bajo,
         arg_min(t, abs((1 - f_menor) - p_h)) AS umbral_alto,
         any_value(p_l) AS viirs_p_l, any_value(p_h) AS viirs_p_h
  FROM cand JOIN vc USING (daynight) GROUP BY ALL
)
SELECT daynight, umbral_bajo, greatest(umbral_alto, umbral_bajo) AS umbral_alto, viirs_p_l, viirs_p_h
FROM elegido ORDER BY daynight;

CREATE OR REPLACE TABLE curva_frp AS
WITH qm AS (
  SELECT daynight, quantile_cont(frp, [i / 1000 FOR i IN range(0, 1001)]) AS q
  FROM f JOIN dias_cal USING (fecha) WHERE sensor = 'MODIS' AND frp IS NOT NULL GROUP BY 1
), qv AS (
  SELECT daynight, quantile_cont(frp, [i / 1000 FOR i IN range(0, 1001)]) AS q
  FROM f JOIN dias_cal USING (fecha) WHERE sensor = 'VIIRS_SNPP' AND frp IS NOT NULL GROUP BY 1
), pares AS (
  SELECT qm.daynight, qm.q[i] AS x, qv.q[i] AS y
  FROM qm JOIN qv USING (daynight), range(1, 1002) t(i)
)
SELECT daynight, x0, y0, lead(x0) OVER w AS x1, lead(y0) OVER w AS y1
FROM (SELECT daynight, x AS x0, avg(y) AS y0 FROM pares GROUP BY ALL)
WINDOW w AS (PARTITION BY daynight ORDER BY x0)
ORDER BY daynight, x0;

CREATE OR REPLACE TEMP TABLE razones_frp AS
SELECT daynight,
       arg_min(y0 / x0, x0) FILTER (x0 > 0) AS razon_min,   -- por debajo del mínimo calibrado
       arg_max(y0 / x0, x0) FILTER (x0 > 0) AS razon_max    -- por encima del máximo
FROM curva_frp GROUP BY daynight;

CREATE OR REPLACE TEMP TABLE modis_fmt AS
SELECT m.*,
       CASE WHEN m.confidence_modis <  u.umbral_bajo THEN 'l'
            WHEN m.confidence_modis >= u.umbral_alto THEN 'h'
            ELSE 'n' END AS confidence_viirs,
       CASE WHEN m.frp IS NULL THEN NULL
            WHEN c.x0 IS NULL  THEN m.frp * r.razon_min
            WHEN c.x1 IS NULL  THEN m.frp * r.razon_max
            ELSE c.y0 + (m.frp - c.x0) * (c.y1 - c.y0) / (c.x1 - c.x0) END AS frp_viirs
FROM modis_k m
JOIN umbrales_confidence u USING (daynight)
JOIN razones_frp r USING (daynight)
ASOF LEFT JOIN curva_frp c ON m.daynight = c.daynight AND m.frp >= c.x0;

-- 2a) Todo MODIS 2000-2025 llevado a escala VIIRS S-NPP -------------------------
--     Un registro por foco MODIS con su `peso` (= k que lo convierte a VIIRS),
--     confidence en letras (l/n/h) y frp en escala VIIRS (originales en *_modis).
--     Hasta 2002-07 solo cuenta Terra (k_terra); Aqua de julio de 2002 queda con peso 0
--     porque ese mes está incompleto. Desde 2002-08, Terra + Aqua con k_modis.
--     En 2012-2025 sirve para comparar con VIIRS observado.
--     Nota: qué focos cuentan lo decide confidence_modis >= 30 (ya aplicado en `f`);
--     la letra es informativa (un MODIS con 30-53 de día queda como 'l').
CREATE OR REPLACE TABLE modis_armonizado AS
SELECT fecha, mes, year(fecha) AS anio, acq_time, latitude, longitude, region, satellite, daynight,
       confidence_viirs AS confidence, confidence_modis,
       round(frp_viirs, 2) AS frp, frp AS frp_modis,
       CASE WHEN mes < DATE '2002-08-01' THEN 'TERRA' ELSE 'MODIS' END AS regla,
       CASE WHEN mes >= DATE '2002-08-01' THEN k_modis
            WHEN satellite = 'Terra'      THEN k_terra
            ELSE 0.0 END AS peso,
       CASE WHEN mes >= DATE '2002-08-01' THEN (CASE WHEN k_modis_regional THEN 'region' ELSE 'nacional' END)
            WHEN satellite = 'Terra'      THEN (CASE WHEN k_terra_regional THEN 'region' ELSE 'nacional' END)
            ELSE 'excluido' END AS nivel_k
FROM modis_fmt
ORDER BY fecha, latitude, longitude;

-- 2b) Focos armonizados de la serie (nivel de punto) ----------------------------
--     MODIS armonizado hasta 2012-01 y VIIRS S-NPP observado desde 2012-02.
--     Todas las filas en formato VIIRS: confidence l/n/h y frp en escala VIIRS.
--     Focos de un área = sum(peso); FRP total de un área = sum(frp * peso).
CREATE OR REPLACE TABLE focos_armonizados AS
SELECT fecha, mes, latitude, longitude, region, 'VIIRS_SNPP' AS sensor, satellite,
       confidence, frp, daynight, 'VIIRS' AS fuente, 1.0 AS peso, 'observado' AS nivel_k
FROM f
WHERE mes >= DATE '2012-02-01' AND sensor = 'VIIRS_SNPP'
UNION ALL
SELECT fecha, mes, latitude, longitude, region, 'MODIS', satellite,
       confidence, frp, daynight, regla, peso, nivel_k
FROM modis_armonizado
WHERE mes < DATE '2012-02-01' AND nivel_k <> 'excluido';

-- 3) Serie mensual: armonizada + series brutas para comparar -------------------
CREATE OR REPLACE TABLE serie_mensual AS
WITH bruto AS (
  SELECT mes,
         count(*) FILTER (sensor = 'MODIS')        AS modis,
         count(*) FILTER (satellite = 'Terra')     AS terra,
         count(*) FILTER (sensor = 'VIIRS_SNPP')   AS snpp,
         count(*) FILTER (sensor = 'VIIRS_NOAA20') AS noaa20
  FROM f GROUP BY ALL
), arm AS (
  SELECT mes, any_value(fuente) AS fuente, sum(peso) AS armonizado
  FROM focos_armonizados GROUP BY ALL
), mk AS (
  -- MODIS×k también en el solape, para poder validarlo contra VIIRS
  SELECT mes,
         sum(k_modis)                                       AS modis_x_k,
         sum(k_modis_nacional)                              AS modis_x_k_nacional,
         sum(k_terra) FILTER (satellite = 'Terra')          AS terra_x_k
  FROM modis_k GROUP BY ALL
)
SELECT b.*, a.fuente, round(a.armonizado) AS armonizado,
       round(mk.modis_x_k) AS modis_x_k,
       round(mk.modis_x_k_nacional) AS modis_x_k_nacional,
       round(mk.terra_x_k) AS terra_x_k
FROM bruto b JOIN arm a USING (mes) LEFT JOIN mk USING (mes)
ORDER BY mes;

.print '== Constantes nacionales (respaldo, calibradas 2012-02..2018-12) =='
SELECT mm AS mes, round(k_modis, 2) AS k_modis, round(k_modis_p25, 2) AS p25,
       round(k_modis_p75, 2) AS p75, round(k_terra, 2) AS k_terra
FROM k_mes ORDER BY 1;

.print '== Constantes por región: cobertura y rango por mes del año =='
SELECT mm AS mes,
       count(k_modis) AS regiones_k_modis,
       round(min(k_modis), 2) AS k_modis_min, round(max(k_modis), 2) AS k_modis_max,
       count(k_terra) AS regiones_k_terra
FROM k_mes_region GROUP BY 1 ORDER BY 1;

.print '== Qué parte de los focos MODIS usa k regional (2002-08..2012-01) =='
SELECT round(100.0 * count(*) FILTER (nivel_k = 'region') / count(*), 1) AS pct_focos_k_region,
       round(100.0 * sum(peso) FILTER (nivel_k = 'region') / sum(peso), 1) AS pct_peso_k_region
FROM focos_armonizados WHERE fuente = 'MODIS';

.print '== Totales anuales: bruto vs armonizado =='
SELECT year(mes) AS anio, any_value(fuente) AS fuente_dominante,
       sum(modis) AS modis_bruto, sum(snpp) AS snpp_bruto,
       sum(armonizado)::BIGINT AS armonizado,
       count(*) AS meses
FROM serie_mensual GROUP BY 1 ORDER BY 1;

.print '== ¿Hay salto en 2012? Media anual 2009-2011 vs 2012-2014 =='
-- Si la armonización funciona, la razón "armonizado" debe parecerse a la de MODIS bruto (~1),
-- y no al ×6-7 que aparece al empalmar MODIS crudo con VIIRS crudo.
WITH a AS (
  SELECT year(mes) AS anio, sum(modis) AS modis, sum(armonizado) AS arm,
         sum(CASE WHEN mes < DATE '2012-02-01' THEN modis ELSE snpp END) AS empalme_crudo
  FROM serie_mensual WHERE year(mes) BETWEEN 2009 AND 2014 GROUP BY 1
)
SELECT round(avg(modis)         FILTER (anio >= 2012) / avg(modis)         FILTER (anio <= 2011), 2) AS razon_modis_bruto,
       round(avg(empalme_crudo) FILTER (anio >= 2012) / avg(empalme_crudo) FILTER (anio <= 2011), 2) AS razon_empalme_crudo,
       round(avg(arm)           FILTER (anio >= 2012) / avg(arm)           FILTER (anio <= 2011), 2) AS razon_armonizada
FROM a;

.print '== Validación nacional en el solape: MODIS×k frente a VIIRS observado =='
SELECT CASE WHEN mes < DATE '2019-01-01' THEN '2012-2018 (calibración)' ELSE '2019-2025 (prueba)' END AS tramo,
       metodo, count(*) AS meses,
       round(corr(pred, snpp), 3) AS r,
       round(sum(pred) / sum(snpp) * 100 - 100, 1) AS sesgo_pct,
       round(median(abs(pred - snpp) / snpp) * 100, 1) AS error_mediano_pct,
       round(sqrt(avg((pred - snpp) ^ 2))) AS rmse_focos
FROM (SELECT mes, snpp, 'k mes x región' AS metodo, modis_x_k AS pred FROM serie_mensual
      UNION ALL
      SELECT mes, snpp, 'k mes (nacional)', modis_x_k_nacional FROM serie_mensual)
WHERE mes >= DATE '2012-02-01' AND snpp > 0
GROUP BY ALL ORDER BY 1, 2;

.print '== Validación regional 2019-2025 (región 5° x mes con >= 100 focos S-NPP) =='
WITH obs AS (
  SELECT mes, region, count(*) AS snpp
  FROM f WHERE sensor = 'VIIRS_SNPP' AND mes >= DATE '2019-01-01' GROUP BY ALL HAVING count(*) >= 100
), pred AS (
  SELECT mes, region,
         sum(k_modis) AS modis_reg, sum(k_modis_nacional) AS modis_nac,
         coalesce(sum(k_terra) FILTER (satellite = 'Terra'), 0) AS terra_reg,
         coalesce(sum(k_terra_nacional) FILTER (satellite = 'Terra'), 0) AS terra_nac
  FROM modis_k WHERE mes >= DATE '2019-01-01' GROUP BY ALL
), l AS (
  SELECT o.snpp, m.metodo, coalesce(m.pred, 0) AS pred
  FROM obs o LEFT JOIN pred p USING (mes, region),
  LATERAL (VALUES ('MODIS, k mes x región', p.modis_reg), ('MODIS, k mes (nacional)', p.modis_nac),
                  ('Terra, k mes x región', p.terra_reg), ('Terra, k mes (nacional)', p.terra_nac)) m(metodo, pred)
)
SELECT metodo, count(*) AS casos, round(corr(pred, snpp), 3) AS r,
       round(median(abs(pred - snpp) / snpp) * 100, 1) AS error_mediano_pct,
       round(quantile_cont(abs(pred - snpp) / snpp, 0.9) * 100, 1) AS error_p90_pct
FROM l GROUP BY 1 ORDER BY 1;

.print '== Tramo solo Terra: Terra×k_terra frente a MODIS×k en 2003-2011 (no calibrado) =='
SELECT count(*) AS meses, round(corr(terra_x_k, modis_x_k), 3) AS r,
       round(sum(terra_x_k) / sum(modis_x_k) * 100 - 100, 1) AS sesgo_pct,
       round(median(abs(terra_x_k - modis_x_k) / modis_x_k) * 100, 1) AS error_mediano_pct
FROM serie_mensual WHERE year(mes) BETWEEN 2003 AND 2011 AND modis_x_k > 0;

------------------------------------------------------------------------------
-- Cálculo de error de la armonización combinada (MODIS armonizado vs VIIRS S-NPP observado)
--   * Periodo 2012-02..2025-12, solo días con datos de S-NPP (excluye sus huecos, p. ej.
--     jul-2024), para comparar lo mismo que vieron los dos sensores.
--   * Calibración = 2012-2018 (de ahí salen k, umbrales y curva de FRP);
--     prueba = 2019-2025 (años no vistos). El error que vale es el de prueba.
--   * Se compara también con MODIS "sin armonizar" para ver cuánto mejora.
--   * Dos tablas:
--       error_armonizacion: magnitudes de área (nº de focos y FRP total) a 4 escalas
--       error_formato:      formato de cada foco (letras de confidence y distribución de FRP)
------------------------------------------------------------------------------
CREATE OR REPLACE TEMP TABLE dias_snpp AS
SELECT DISTINCT fecha FROM f WHERE sensor = 'VIIRS_SNPP' AND mes >= DATE '2012-02-01';

CREATE OR REPLACE TEMP TABLE comp_celda AS
WITH m AS (
  SELECT mes, floor(latitude) AS lat1, floor(longitude) AS lon1, region,
         sum(peso) AS focos_arm, count(*) AS focos_bruto,
         sum(frp * peso) AS frp_arm, sum(frp_modis) AS frp_bruto
  FROM modis_armonizado JOIN dias_snpp USING (fecha) GROUP BY ALL
), v AS (
  SELECT mes, floor(latitude) AS lat1, floor(longitude) AS lon1, region,
         count(*) AS focos_obs, sum(frp) AS frp_obs
  FROM f JOIN dias_snpp USING (fecha) WHERE sensor = 'VIIRS_SNPP' GROUP BY ALL
)
SELECT mes, lat1, lon1, region,
       coalesce(m.focos_arm, 0) AS focos_arm, coalesce(m.focos_bruto, 0) AS focos_bruto,
       coalesce(m.frp_arm, 0) AS frp_arm, coalesce(m.frp_bruto, 0) AS frp_bruto,
       coalesce(v.focos_obs, 0) AS focos_obs, coalesce(v.frp_obs, 0) AS frp_obs,
       CASE WHEN mes < DATE '2019-01-01' THEN '1_calibracion_2012-2018' ELSE '2_prueba_2019-2025' END AS tramo
FROM m FULL JOIN v USING (mes, lat1, lon1, region);

CREATE OR REPLACE TEMP TABLE comp_largo AS
SELECT c.mes, c.lat1, c.lon1, c.region, c.tramo, c.focos_obs, t.magnitud, t.metodo, t.pred, t.obs
FROM comp_celda c,
LATERAL (VALUES ('1_focos',     'armonizado',    c.focos_arm,            c.focos_obs::DOUBLE),
                ('1_focos',     'sin_armonizar', c.focos_bruto::DOUBLE,  c.focos_obs::DOUBLE),
                ('2_frp_total', 'armonizado',    c.frp_arm,              c.frp_obs),
                ('2_frp_total', 'sin_armonizar', c.frp_bruto,            c.frp_obs)) t(magnitud, metodo, pred, obs);

-- error_mediano y p90: solo casos con >= 100 focos VIIRS (para no dividir entre números
-- pequeños); r, sesgo, error_abs_ponderado (= Σ|e| / Σobs) y RMSE usan todos los casos.
CREATE OR REPLACE TABLE error_armonizacion AS
WITH escalas AS (
  SELECT magnitud, metodo, '1_anio_nacional' AS escala, tramo, sum(pred) AS pred, sum(obs) AS obs, sum(focos_obs) AS n_obs
  FROM comp_largo GROUP BY magnitud, metodo, tramo, year(mes)
  UNION ALL
  SELECT magnitud, metodo, '2_mes_nacional', tramo, sum(pred), sum(obs), sum(focos_obs)
  FROM comp_largo GROUP BY magnitud, metodo, tramo, mes
  UNION ALL
  SELECT magnitud, metodo, '3_mes_region5', tramo, sum(pred), sum(obs), sum(focos_obs)
  FROM comp_largo GROUP BY magnitud, metodo, tramo, mes, region
  UNION ALL
  SELECT magnitud, metodo, '4_mes_celda1', tramo, pred, obs, focos_obs FROM comp_largo
)
SELECT magnitud, metodo, escala, tramo,
       count(*) AS casos,
       count(*) FILTER (n_obs >= 100) AS casos_eval,
       round(corr(pred, obs), 3) AS r,
       round(100 * (sum(pred) / sum(obs) - 1), 1) AS sesgo_pct,
       round(100 * sum(abs(pred - obs)) / sum(obs), 1) AS error_abs_ponderado_pct,
       round(100 * median(abs(pred - obs) / obs) FILTER (n_obs >= 100), 1) AS error_mediano_pct,
       round(100 * quantile_cont(abs(pred - obs) / obs, 0.9) FILTER (n_obs >= 100), 1) AS error_p90_pct,
       round(sqrt(avg((pred - obs) ^ 2)), 1) AS rmse
FROM escalas GROUP BY ALL ORDER BY magnitud, escala, tramo, metodo;

CREATE OR REPLACE TABLE error_formato AS
WITH conf_m AS (
  -- Todos los focos MODIS type = 0, igual que en la calibración de los umbrales.
  -- sin_armonizar = clases oficiales de MODIS (< 30 bajo, 30-79 nominal, >= 80 alto).
  SELECT CASE WHEN year(fecha) < 2019 THEN '1_calibracion_2012-2018' ELSE '2_prueba_2019-2025' END AS tramo,
         daynight, t.metodo, t.letra
  FROM (SELECT fecha, daynight, TRY_CAST(confidence AS INT) AS c FROM focos
        WHERE sensor = 'MODIS' AND type = 0 AND fecha >= DATE '2012-02-01') m
  JOIN umbrales_confidence u USING (daynight),
  LATERAL (VALUES ('armonizado',    CASE WHEN c < u.umbral_bajo THEN 'l' WHEN c >= u.umbral_alto THEN 'h' ELSE 'n' END),
                  ('sin_armonizar', CASE WHEN c < 30 THEN 'l' WHEN c >= 80 THEN 'h' ELSE 'n' END)) t(metodo, letra)
), pm AS (
  SELECT tramo, daynight, metodo,
         avg((letra = 'l')::INT) AS l, avg((letra = 'n')::INT) AS n, avg((letra = 'h')::INT) AS h
  FROM conf_m GROUP BY ALL
), pv AS (
  SELECT CASE WHEN year(fecha) < 2019 THEN '1_calibracion_2012-2018' ELSE '2_prueba_2019-2025' END AS tramo,
         daynight,
         avg((confidence = 'l')::INT) AS l, avg((confidence = 'n')::INT) AS n, avg((confidence = 'h')::INT) AS h
  FROM focos WHERE sensor = 'VIIRS_SNPP' AND type = 0 AND fecha >= DATE '2012-02-01' GROUP BY ALL
), conf AS (
  SELECT '3_confidence' AS magnitud, pm.metodo, pm.tramo, pm.daynight,
         'diferencia total de proporciones l/n/h (puntos %)' AS metrica,
         round(50 * (abs(pm.l - pv.l) + abs(pm.n - pv.n) + abs(pm.h - pv.h)), 1) AS error_medio,
         round(100 * greatest(abs(pm.l - pv.l), abs(pm.n - pv.n), abs(pm.h - pv.h)), 1) AS error_max
  FROM pm JOIN pv USING (tramo, daynight)
), frp_q AS (
  -- Percentiles 5, 10, ..., 95 del FRP de los focos que cuentan en la serie
  SELECT tramo, daynight, metodo, quantile_cont(v, [i / 20 FOR i IN range(1, 20)]) AS q
  FROM (SELECT CASE WHEN anio < 2019 THEN '1_calibracion_2012-2018' ELSE '2_prueba_2019-2025' END AS tramo,
               daynight, 'armonizado' AS metodo, frp AS v
        FROM modis_armonizado WHERE fecha >= DATE '2012-02-01'
        UNION ALL
        SELECT CASE WHEN anio < 2019 THEN '1_calibracion_2012-2018' ELSE '2_prueba_2019-2025' END,
               daynight, 'sin_armonizar', frp_modis
        FROM modis_armonizado WHERE fecha >= DATE '2012-02-01'
        UNION ALL
        SELECT CASE WHEN year(fecha) < 2019 THEN '1_calibracion_2012-2018' ELSE '2_prueba_2019-2025' END,
               daynight, 'viirs', frp
        FROM f WHERE sensor = 'VIIRS_SNPP' AND mes >= DATE '2012-02-01')
  GROUP BY ALL
), frp AS (
  SELECT '4_frp_por_foco' AS magnitud, m.metodo, m.tramo, m.daynight,
         'error relativo de los percentiles 5-95 del FRP (%)' AS metrica,
         round(100 * avg(abs(m.q[i] - v.q[i]) / v.q[i]), 1) AS error_medio,
         round(100 * max(abs(m.q[i] - v.q[i]) / v.q[i]), 1) AS error_max
  FROM frp_q m JOIN frp_q v ON v.metodo = 'viirs' AND v.tramo = m.tramo AND v.daynight = m.daynight,
       range(1, 20) t(i)
  WHERE m.metodo <> 'viirs'
  GROUP BY ALL
)
SELECT * FROM conf UNION ALL SELECT * FROM frp
ORDER BY magnitud, tramo, daynight, metodo;

.print '== ERROR 1/3. Nº de focos y FRP total: MODIS vs VIIRS S-NPP (días con S-NPP) =='
.print '   error_mediano y p90: casos con >= 100 focos VIIRS. Prueba = 2019-2025 (años no usados para calibrar)'
SELECT * FROM error_armonizacion;

.print '== ERROR 2/3. Formato de cada foco: letras de confidence y distribución de FRP =='
SELECT * FROM error_formato;

.print '== ERROR 3/3. Error anual a escala nacional (armonizado vs VIIRS S-NPP) =='
SELECT year(mes) AS anio, any_value(tramo) AS tramo,
       sum(focos_bruto) AS focos_modis_bruto, round(sum(focos_arm)) AS focos_modis_arm, sum(focos_obs) AS focos_viirs,
       round(100 * (sum(focos_arm) / sum(focos_obs) - 1), 1) AS error_focos_pct,
       round(sum(frp_arm)) AS frp_modis_arm, round(sum(frp_obs)) AS frp_viirs,
       round(100 * (sum(frp_arm) / sum(frp_obs) - 1), 1) AS error_frp_pct
FROM comp_celda GROUP BY 1 ORDER BY 1;

------------------------------------------------------------------------------
-- Prueba del formato VIIRS (confidence y FRP), 2019-2025 = años no usados para calibrar
------------------------------------------------------------------------------
.print '== Umbrales de confidence (MODIS 0-100 -> l/n/h), calibrados 2012-02..2018-12 =='
SELECT daynight, umbral_bajo, umbral_alto,
       round(100 * viirs_p_l, 1) AS viirs_pct_l, round(100 * viirs_p_h, 1) AS viirs_pct_h
FROM umbrales_confidence ORDER BY daynight;

.print '== Proporción de letras: MODIS convertido vs VIIRS S-NPP (todos los focos type = 0) =='
-- Se aplican los umbrales a todos los focos MODIS (no solo conf >= 30) para comparar
-- con la distribución completa de VIIRS, que es contra la que se calibró.
WITH m AS (
  SELECT CASE WHEN year(fecha) < 2019 THEN '1_calibracion_2012-2018' ELSE '2_prueba_2019-2025' END AS tramo,
         daynight,
         CASE WHEN TRY_CAST(confidence AS INT) <  u.umbral_bajo THEN 'l'
              WHEN TRY_CAST(confidence AS INT) >= u.umbral_alto THEN 'h' ELSE 'n' END AS letra
  FROM focos JOIN umbrales_confidence u USING (daynight)
  WHERE sensor = 'MODIS' AND type = 0 AND fecha >= DATE '2012-02-01'
), v AS (
  SELECT CASE WHEN year(fecha) < 2019 THEN '1_calibracion_2012-2018' ELSE '2_prueba_2019-2025' END AS tramo,
         daynight, confidence AS letra
  FROM focos WHERE sensor = 'VIIRS_SNPP' AND type = 0 AND fecha >= DATE '2012-02-01'
)
SELECT tramo, daynight,
       round(100 * avg((m.letra = 'l')::INT), 1) AS modis_l,
       round(100 * avg((m.letra = 'n')::INT), 1) AS modis_n,
       round(100 * avg((m.letra = 'h')::INT), 1) AS modis_h,
       any_value(v.l) AS viirs_l, any_value(v.n) AS viirs_n, any_value(v.h) AS viirs_h
FROM m JOIN (SELECT tramo, daynight,
                    round(100 * avg((letra = 'l')::INT), 1) AS l,
                    round(100 * avg((letra = 'n')::INT), 1) AS n,
                    round(100 * avg((letra = 'h')::INT), 1) AS h
             FROM v GROUP BY ALL) v USING (tramo, daynight)
GROUP BY ALL ORDER BY 1, 2;

.print '== FRP por foco (MW): MODIS bruto, MODIS convertido y VIIRS S-NPP, 2019-2025 =='
SELECT serie, daynight, round(quantile_cont(frp, 0.25), 2) AS p25, round(quantile_cont(frp, 0.5), 2) AS p50,
       round(quantile_cont(frp, 0.9), 2) AS p90, round(quantile_cont(frp, 0.99), 1) AS p99
FROM (SELECT '1_MODIS bruto' AS serie, daynight, frp_modis AS frp FROM modis_armonizado WHERE anio >= 2019
      UNION ALL SELECT '2_MODIS convertido', daynight, frp FROM modis_armonizado WHERE anio >= 2019
      UNION ALL SELECT '3_VIIRS S-NPP', daynight, frp FROM f WHERE sensor = 'VIIRS_SNPP' AND year(fecha) >= 2019)
GROUP BY ALL ORDER BY daynight, serie;

-- Exportación: todo MODIS armonizado (Parquet por año), la prueba de error y las calibraciones
COPY (SELECT * EXCLUDE (mes) FROM modis_armonizado)
  TO 'analisis/salida/modis_armonizado' (FORMAT parquet, COMPRESSION zstd, PARTITION_BY (anio), OVERWRITE_OR_IGNORE);
COPY error_armonizacion TO 'analisis/salida/error_armonizacion.csv' (HEADER, DELIMITER ',');
COPY error_formato TO 'analisis/salida/error_formato.csv' (HEADER, DELIMITER ',');
COPY umbrales_confidence TO 'analisis/salida/calibracion_confidence.csv' (HEADER, DELIMITER ',');
COPY (SELECT daynight, x0 AS frp_modis, round(y0, 4) AS frp_viirs FROM curva_frp ORDER BY daynight, x0)
  TO 'analisis/salida/calibracion_frp.csv' (HEADER, DELIMITER ',');
