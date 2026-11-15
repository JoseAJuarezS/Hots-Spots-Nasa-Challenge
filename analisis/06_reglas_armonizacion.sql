-- Paso 1: compara los datos CRUDOS de MODIS y VIIRS en 2012-2017 y obtiene las reglas
-- de armonización MODIS -> VIIRS 375 m.
-- Uso (desde la raíz del repo):  duckdb -no-agent < analisis/06_reglas_armonizacion.sql
--
-- Entradas:  datos_crudos/MODIS_original/modis_*_India.csv   (MODIS sin tocar: confidence 0-100)
--            datos_crudos/VIIRS/viirs-*_India.csv             (S-NPP y NOAA-20 / jpss1)
-- Salidas:   analisis/reglas/*.csv                            (las reglas; las usa 07_armonizar_modis.sql)
--
-- Referencia VIIRS: todo VIIRS 375 m disponible en 2012-2017. NOAA-20 (jpss1) empieza el
-- 2018-04-01, así que en la práctica la calibración es contra S-NPP. Es el mismo instrumento;
-- 08_validar_armonizacion.sql comprueba después la regla contra NOAA-20 en 2018+.
-- Nada de 2018 en adelante se usa aquí: ese periodo queda reservado para validar.
--
-- Solo se compara en DÍAS COMUNES (días con datos de los dos sensores), para que los huecos
-- de uno u otro no sesguen las razones.
--
-- Reglas que se obtienen
-- ----------------------
-- 1) Conteo -> `peso` de cada foco MODIS = cuántos focos VIIRS representa.
--    Vegetación (type = 0), modelo jerárquico con suavizado (shrinkage):
--        k_dn(dn)                       razón nacional, día / noche
--        k_c2(dn, celda 2°)             suavizada hacia k_dn
--        s_mes(dn, mes)                 estacionalidad que queda tras k_c2
--        k_c2m(dn, celda 2°, mes)       suavizada hacia k_c2 · s_mes
--        r_c1(dn, celda 1°)             ajuste fino dentro de la celda 2°, suavizado hacia 1
--        factor de actividad            ((focos MODIS de la celda 2° ese mes + n0) /
--                                        (focos típicos de ese mes del año + n0)) ^ b, en [0,5; 2]
--    peso = k_c2m · r_c1 · factor   (con caídas a k_c2·s_mes y k_dn·s_mes si la celda no tiene datos)
--    Suavizado: k = (focos_VIIRS + ALFA · k_padre) / (focos_MODIS + ALFA), ALFA = 300 focos MODIS.
--    b (< 0: en meses de mucha actividad MODIS capta una fracción mayor de los fuegos) se elige
--    por validación cruzada dejando un año fuera, dentro de 2012-2017.
--    Otros tipos (2 = fuente estática, 3 = costa afuera): una razón por tipo y dn (si hay >= 100 focos).
-- 2) Solo Terra (antes del 2002-07-04 no hay Aqua): factor f_terra(dn, celda 2°, mes) =
--    focos MODIS (Terra+Aqua) / focos Terra, medido con MODIS 2003-2017 (no involucra a VIIRS).
-- 3) confidence 0-100 -> l/n/h: dos umbrales por dn que igualan las proporciones de VIIRS.
-- 4) frp, brightness -> bright_ti4, bright_t31 -> bright_ti5: emparejamiento de cuantiles por dn.

.print '== Cargando CSV crudos =='

CREATE OR REPLACE TEMP TABLE modis AS
SELECT acq_date, daynight AS dn, satellite, type, confidence, frp, brightness, bright_t31,
       latitude, longitude, year(acq_date) AS anio, month(acq_date) AS mm,
       floor(latitude / 2)::INT AS gy, floor(longitude / 2)::INT AS gx,
       floor(latitude)::INT AS cy, floor(longitude)::INT AS cx
FROM read_csv('datos_crudos/MODIS_original/modis_*_India.csv', union_by_name = true,
              types = {'acq_time': 'VARCHAR', 'confidence': 'INTEGER', 'frp': 'DOUBLE',
                       'brightness': 'DOUBLE', 'bright_t31': 'DOUBLE', 'version': 'VARCHAR'});

CREATE OR REPLACE TEMP TABLE viirs AS
SELECT acq_date, daynight AS dn, satellite, type, lower(confidence) AS confidence, frp,
       bright_ti4, bright_ti5, latitude, longitude, year(acq_date) AS anio, month(acq_date) AS mm,
       floor(latitude / 2)::INT AS gy, floor(longitude / 2)::INT AS gx,
       floor(latitude)::INT AS cy, floor(longitude)::INT AS cx
FROM read_csv('datos_crudos/VIIRS/viirs-*_India.csv', union_by_name = true,
              types = {'acq_time': 'VARCHAR', 'confidence': 'VARCHAR', 'frp': 'DOUBLE',
                       'bright_ti4': 'DOUBLE', 'bright_ti5': 'DOUBLE', 'version': 'VARCHAR'})
WHERE acq_date <= DATE '2017-12-31';

CREATE OR REPLACE TEMP TABLE dias AS
SELECT DISTINCT acq_date FROM modis WHERE anio BETWEEN 2012 AND 2017
INTERSECT
SELECT DISTINCT acq_date FROM viirs;

CREATE OR REPLACE TEMP TABLE m_cal AS SELECT * FROM modis WHERE acq_date IN (SELECT acq_date FROM dias);
CREATE OR REPLACE TEMP TABLE v_cal AS SELECT * FROM viirs WHERE acq_date IN (SELECT acq_date FROM dias);

-- ===========================================================================
-- A) COMPARACIÓN DESCRIPTIVA 2012-2017
-- ===========================================================================

.print '== A1. Días comunes y focos (2012-2017) =='
SELECT (SELECT min(acq_date) FROM dias) AS desde, (SELECT max(acq_date) FROM dias) AS hasta,
       (SELECT count(*) FROM dias) AS dias_comunes,
       (SELECT count(*) FROM m_cal) AS focos_modis, (SELECT count(*) FROM v_cal) AS focos_viirs,
       (SELECT string_agg(DISTINCT satellite, ',') FROM v_cal) AS satelites_viirs;

.print '== A2. Focos por año, tipo y día/noche: VIIRS / MODIS =='
WITH mo AS (SELECT anio, type, dn, count(*) AS modis FROM m_cal GROUP BY ALL),
     vi AS (SELECT anio, type, dn, count(*) AS viirs FROM v_cal GROUP BY ALL)
SELECT anio,
       sum(modis) FILTER (type = 0 AND dn = 'D') AS modis_veg_D,
       round(sum(viirs) FILTER (type = 0 AND dn = 'D') / sum(modis) FILTER (type = 0 AND dn = 'D'), 2) AS k_veg_D,
       sum(modis) FILTER (type = 0 AND dn = 'N') AS modis_veg_N,
       round(sum(viirs) FILTER (type = 0 AND dn = 'N') / sum(modis) FILTER (type = 0 AND dn = 'N'), 2) AS k_veg_N,
       round(sum(viirs) FILTER (type = 2) / sum(modis) FILTER (type = 2), 2) AS k_estaticas
FROM mo FULL JOIN vi USING (anio, type, dn) GROUP BY anio ORDER BY anio;

.print '== A3. Razón VIIRS/MODIS por mes del año (vegetación) =='
SELECT mm,
       round(count(*) FILTER (dn = 'D' AND s = 'V') / count(*) FILTER (dn = 'D' AND s = 'M'), 2) AS k_D,
       round(count(*) FILTER (dn = 'N' AND s = 'V') / count(*) FILTER (dn = 'N' AND s = 'M'), 2) AS k_N,
       count(*) FILTER (s = 'M') AS focos_modis
FROM (SELECT mm, dn, 'M' AS s FROM m_cal WHERE type = 0 UNION ALL SELECT mm, dn, 'V' FROM v_cal WHERE type = 0)
GROUP BY mm ORDER BY mm;

.print '== A4. Razón por región (celdas de 2°, de día, las 15 con más focos) y estabilidad 2012-14 vs 2015-17 =='
WITH t AS (
  SELECT gy, gx, anio, count(*) FILTER (s = 'M') AS mo, count(*) FILTER (s = 'V') AS vi
  FROM (SELECT gy, gx, anio, 'M' AS s FROM m_cal WHERE type = 0 AND dn = 'D'
        UNION ALL SELECT gy, gx, anio, 'V' FROM v_cal WHERE type = 0 AND dn = 'D')
  GROUP BY ALL)
SELECT gy * 2 AS lat_desde, gx * 2 AS lon_desde, sum(mo) AS focos_modis, round(sum(vi) / sum(mo), 2) AS k,
       round(sum(vi) FILTER (anio <= 2014) / sum(mo) FILTER (anio <= 2014), 2) AS k_2012_14,
       round(sum(vi) FILTER (anio >= 2015) / sum(mo) FILTER (anio >= 2015), 2) AS k_2015_17
FROM t GROUP BY ALL ORDER BY focos_modis DESC LIMIT 15;

.print '== A5. Distribución de confidence (vegetación) =='
SELECT 'MODIS' AS sensor, dn, round(100 * avg((confidence < 30)::INT), 1) AS pct_bajo_lt30,
       round(100 * avg((confidence BETWEEN 30 AND 79)::INT), 1) AS pct_nominal,
       round(100 * avg((confidence >= 80)::INT), 1) AS pct_alto_ge80
FROM m_cal WHERE type = 0 GROUP BY dn
UNION ALL
SELECT 'VIIRS', dn, round(100 * avg((confidence = 'l')::INT), 1), round(100 * avg((confidence = 'n')::INT), 1),
       round(100 * avg((confidence = 'h')::INT), 1)
FROM v_cal WHERE type = 0 GROUP BY dn ORDER BY dn, sensor;

.print '== A6. Percentiles de FRP y temperaturas de brillo (vegetación) =='
SELECT 'MODIS' AS sensor, dn,
       quantile_cont(frp, [0.1, 0.5, 0.9, 0.99]) AS frp_p10_50_90_99,
       quantile_cont(brightness, [0.1, 0.5, 0.9]) AS t4_p10_50_90,
       quantile_cont(bright_t31, [0.1, 0.5, 0.9]) AS t11_p10_50_90
FROM m_cal WHERE type = 0 GROUP BY dn
UNION ALL
SELECT 'VIIRS', dn, quantile_cont(frp, [0.1, 0.5, 0.9, 0.99]), quantile_cont(bright_ti4, [0.1, 0.5, 0.9]),
       quantile_cont(bright_ti5, [0.1, 0.5, 0.9])
FROM v_cal WHERE type = 0 GROUP BY dn ORDER BY dn, sensor;

-- ===========================================================================
-- B) REGLA DE CONTEO (peso por foco), con validación cruzada dejando un año fuera
-- ===========================================================================
-- `pliegue` = año que se deja fuera para probar; pliegue 0 = ajuste final con los 6 años.

SET VARIABLE alfa = 300;  -- suavizado de las razones, en focos MODIS
SET VARIABLE n0 = 10;     -- suavizado del cociente de actividad, en focos MODIS

CREATE OR REPLACE TEMP TABLE conteos AS
SELECT anio, mm, date_trunc('month', acq_date) AS mes, dn, gy, gx, cy, cx,
       count(*) FILTER (s = 'M') AS mo, count(*) FILTER (s = 'V') AS vi
FROM (SELECT acq_date, anio, mm, dn, gy, gx, cy, cx, 'M' AS s FROM m_cal WHERE type = 0
      UNION ALL
      SELECT acq_date, anio, mm, dn, gy, gx, cy, cx, 'V' FROM v_cal WHERE type = 0)
GROUP BY ALL;

CREATE OR REPLACE TEMP TABLE pliegues AS SELECT unnest([0, 2012, 2013, 2014, 2015, 2016, 2017]) AS pliegue;
CREATE OR REPLACE TEMP TABLE exponentes AS SELECT unnest([0.0, -0.1, -0.15, -0.2, -0.25, -0.3, -0.35, -0.4, -0.5]) AS b;

-- Corrección por actividad: cuando una celda 2° tiene en un mes más focos MODIS de lo habitual
-- para ese mes del año, MODIS capta una fracción mayor de los fuegos y la razón VIIRS/MODIS baja.
--   actividad   = focos MODIS en (celda 2°, mes concreto, dn)
--   referencia  = media de focos MODIS en (celda 2°, mes del año, dn) en los años de calibración
--   factor      = ((actividad + n0) / (referencia + n0)) ^ b, acotado a [0,5; 2]
-- La jerarquía se ajusta sobre los focos MODIS "efectivos" = focos × factor.
CREATE OR REPLACE TEMP TABLE actividad AS
SELECT mes, mm, anio, dn, gy, gx, sum(mo) AS n FROM conteos GROUP BY ALL;

CREATE OR REPLACE TEMP TABLE referencia AS
SELECT p.pliegue, a.dn, a.gy, a.gx, a.mm, sum(a.n) / any_value(CASE WHEN p.pliegue = 0 THEN 6 ELSE 5 END) AS nref
FROM actividad a, pliegues p WHERE a.anio <> p.pliegue GROUP BY ALL;

CREATE OR REPLACE TEMP TABLE cb AS
SELECT c.*, p.pliegue, e.b,
       c.mo * least(greatest(pow((a.n + getvariable('n0')) / (coalesce(r.nref, 0) + getvariable('n0')), e.b), 0.5), 2) AS me
FROM conteos c
JOIN actividad a USING (mes, dn, gy, gx)
CROSS JOIN pliegues p CROSS JOIN exponentes e
LEFT JOIN referencia r ON r.pliegue = p.pliegue AND r.dn = c.dn AND r.gy = c.gy AND r.gx = c.gx AND r.mm = c.mm;

CREATE OR REPLACE TEMP VIEW ent AS SELECT * FROM cb WHERE anio <> pliegue;

CREATE OR REPLACE TEMP TABLE k_dn AS
SELECT pliegue, b, dn, sum(vi) / sum(me) AS k FROM ent GROUP BY ALL;

CREATE OR REPLACE TEMP TABLE k_c2 AS
SELECT e.pliegue, e.b, e.dn, gy, gx, sum(mo) AS focos_modis,
       (sum(vi) + getvariable('alfa') * any_value(k_dn.k)) / (sum(me) + getvariable('alfa')) AS k
FROM ent e JOIN k_dn USING (pliegue, b, dn) GROUP BY ALL;

CREATE OR REPLACE TEMP TABLE s_mes AS
SELECT e.pliegue, e.b, e.dn, mm, sum(vi) / sum(me * k_c2.k) AS s
FROM ent e JOIN k_c2 USING (pliegue, b, dn, gy, gx) GROUP BY ALL;

CREATE OR REPLACE TEMP TABLE k_c2m AS
SELECT e.pliegue, e.b, e.dn, gy, gx, mm, sum(mo) AS focos_modis,
       (sum(vi) + getvariable('alfa') * any_value(k_c2.k * s_mes.s)) / (sum(me) + getvariable('alfa')) AS k
FROM ent e JOIN k_c2 USING (pliegue, b, dn, gy, gx) JOIN s_mes USING (pliegue, b, dn, mm) GROUP BY ALL;

-- Ajuste fino 1°: VIIRS observado / VIIRS esperado con k_c2m, suavizado hacia 1
CREATE OR REPLACE TEMP TABLE r_c1 AS
SELECT pliegue, b, dn, cy, cx, sum(mo) AS focos_modis,
       (sum(vi) + getvariable('alfa') * sum(me * k) / sum(me))
       / (sum(me * k) + getvariable('alfa') * sum(me * k) / sum(me)) AS r
FROM ent e JOIN k_c2m USING (pliegue, b, dn, gy, gx, mm) GROUP BY ALL HAVING sum(me) > 0;

-- Predicciones en el año dejado fuera (las reglas simples no dependen de b: se calculan con b = 0)
CREATE OR REPLACE TEMP TABLE pred_cv AS
SELECT c.anio, c.mes, c.dn, c.gy, c.gx, c.cy, c.cx, c.vi, c.pliegue, c.b,
       c.mo * kg.k AS p_k_global,
       c.mo * km.k AS p_k_mes,
       c.me * coalesce(k_c2m.k, coalesce(k_c2.k, k_dn.k) * s_mes.s) * coalesce(r_c1.r, 1) AS p_jerarquico
FROM cb c
JOIN (SELECT pliegue, sum(vi) / sum(mo) AS k FROM ent WHERE b = 0 GROUP BY ALL) kg USING (pliegue)
JOIN (SELECT pliegue, mm, sum(vi) / sum(mo) AS k FROM ent WHERE b = 0 GROUP BY ALL) km USING (pliegue, mm)
JOIN k_dn USING (pliegue, b, dn) JOIN s_mes USING (pliegue, b, dn, mm)
LEFT JOIN k_c2 USING (pliegue, b, dn, gy, gx) LEFT JOIN k_c2m USING (pliegue, b, dn, gy, gx, mm)
LEFT JOIN r_c1 USING (pliegue, b, dn, cy, cx)
WHERE c.anio = c.pliegue;

CREATE OR REPLACE TEMP TABLE cv AS
WITH largo AS (
  SELECT * FROM (UNPIVOT pred_cv ON p_k_global, p_k_mes, p_jerarquico INTO NAME regla VALUE p)
  WHERE regla = 'p_jerarquico' OR b = 0
), nac AS (SELECT regla, b, mes, sum(vi) AS vi, sum(p) AS p FROM largo GROUP BY ALL),
c2 AS (SELECT regla, b, mes, gy, gx, sum(vi) AS vi, sum(p) AS p FROM largo GROUP BY ALL),
c1 AS (SELECT regla, b, mes, cy, cx, sum(vi) AS vi, sum(p) AS p FROM largo GROUP BY ALL)
SELECT n.regla, n.b, n.wape_india_mes, n.mdape_india_mes, n.sesgo_pct, x2.wape_celda2_mes, x1.wape_celda1_mes
FROM (SELECT regla, b, round(sum(abs(p - vi)) / sum(vi) * 100, 2) AS wape_india_mes,
             round(median(abs(p - vi) / vi) * 100, 1) AS mdape_india_mes,
             round(sum(p) / sum(vi) * 100 - 100, 1) AS sesgo_pct FROM nac GROUP BY ALL) n
JOIN (SELECT regla, b, round(sum(abs(p - vi)) / sum(vi) * 100, 2) AS wape_celda2_mes FROM c2 GROUP BY ALL) x2 USING (regla, b)
JOIN (SELECT regla, b, round(sum(abs(p - vi)) / sum(vi) * 100, 2) AS wape_celda1_mes FROM c1 GROUP BY ALL) x1 USING (regla, b);

.print '== B1. Validación cruzada (dejando un año fuera, 2012-2017): error de cada regla de conteo =='
.print '   WAPE = suma |predicho - VIIRS| / suma VIIRS. Escalas: India-mes, celda 2°-mes, celda 1°-mes.'
.print '   b = exponente de la corrección por actividad (0 = sin corrección).'
SELECT * FROM cv ORDER BY regla, b DESC;

-- Se elige b con la validación cruzada (nunca con 2018+): mínimo error India-mes + celda 2°-mes
SET VARIABLE b = (SELECT arg_min(b, wape_india_mes + wape_celda2_mes) FROM cv WHERE regla = 'p_jerarquico');

.print '== B2. Regla final (con los 6 años) =='
SELECT getvariable('b') AS b_elegido, getvariable('alfa') AS alfa, getvariable('n0') AS n0;
SELECT dn, round(k, 3) AS k_dn FROM k_dn WHERE pliegue = 0 AND b = getvariable('b') ORDER BY dn;
SELECT mm, round(s, 3) AS s_D FROM s_mes WHERE pliegue = 0 AND b = getvariable('b') AND dn = 'D' ORDER BY mm;

-- Reglas simples, solo como línea base para comparar en la validación
CREATE OR REPLACE TEMP TABLE k_simple AS
SELECT mm, sum(vi) / sum(mo) AS k_mes, (SELECT sum(vi) / sum(mo) FROM conteos) AS k_global
FROM conteos GROUP BY mm;

-- Otros tipos de foco (2 y 3): una razón por tipo y dn. Solo si hay >= 100 focos MODIS;
-- si no, la razón no es fiable (p. ej. costa afuera de noche: VIIRS ve plataformas y barcos
-- que MODIS casi nunca detecta) y 07 usa k_dn como respaldo.
CREATE OR REPLACE TEMP TABLE k_tipo AS
SELECT type, dn, count(*) FILTER (s = 'M') AS focos_modis, count(*) FILTER (s = 'V') AS focos_viirs,
       CASE WHEN count(*) FILTER (s = 'M') >= 100
            THEN count(*) FILTER (s = 'V') / count(*) FILTER (s = 'M') END AS k
FROM (SELECT type, dn, 'M' AS s FROM m_cal WHERE type <> 0 UNION ALL SELECT type, dn, 'V' FROM v_cal WHERE type <> 0)
GROUP BY ALL HAVING count(*) FILTER (s = 'M') > 0;

.print '== B3. Razón para focos que no son de vegetación =='
SELECT type, dn, focos_modis, focos_viirs, round(k, 3) AS k FROM k_tipo ORDER BY ALL;

-- ===========================================================================
-- C) FACTOR "SOLO TERRA" (para 2000-11 .. 2002-07-03, cuando aún no hay Aqua)
-- ===========================================================================
-- Es una relación interna de MODIS: (Terra + Aqua) / Terra, medida en 2003-2017.

CREATE OR REPLACE TEMP TABLE terra_nac AS
SELECT dn, mm, count(*) / count(*) FILTER (satellite = 'Terra') AS f
FROM modis WHERE type = 0 AND anio BETWEEN 2003 AND 2017 GROUP BY ALL;

CREATE OR REPLACE TEMP TABLE f_terra AS
SELECT m.dn, m.gy, m.gx, m.mm, count(*) FILTER (satellite = 'Terra') AS focos_terra,
       (count(*) + getvariable('alfa') * any_value(t.f)) / (count(*) FILTER (satellite = 'Terra') + getvariable('alfa')) AS f
FROM modis m JOIN terra_nac t USING (dn, mm)
WHERE m.type = 0 AND m.anio BETWEEN 2003 AND 2017 GROUP BY ALL;

.print '== C1. Factor solo-Terra nacional por mes (de día) =='
SELECT mm, round(f, 2) AS f_terra_D FROM terra_nac WHERE dn = 'D' ORDER BY mm;

-- ===========================================================================
-- D) CONFIDENCE: umbrales que igualan las proporciones l / n / h de VIIRS
-- ===========================================================================

CREATE OR REPLACE TEMP TABLE prop_viirs AS
SELECT dn, avg((confidence = 'l')::INT) AS p_l, avg((confidence = 'h')::INT) AS p_h
FROM v_cal WHERE type = 0 GROUP BY dn;

CREATE OR REPLACE TEMP TABLE ecdf_conf AS
SELECT dn, t, coalesce(sum(n) FILTER (confidence < t), 0) / sum(n) AS f_menor
FROM (SELECT dn, confidence, count(*) AS n FROM m_cal WHERE type = 0 GROUP BY ALL),
     range(0, 102) r(t)
GROUP BY dn, t;

CREATE OR REPLACE TEMP TABLE umbrales_conf AS
SELECT dn, umbral_bajo, greatest(umbral_alto, umbral_bajo) AS umbral_alto, p_l AS viirs_prop_l, p_h AS viirs_prop_h
FROM (SELECT e.dn, any_value(p.p_l) AS p_l, any_value(p.p_h) AS p_h,
             arg_min(e.t, abs(e.f_menor - p.p_l))       AS umbral_bajo,
             arg_min(e.t, abs((1 - e.f_menor) - p.p_h)) AS umbral_alto
      FROM ecdf_conf e JOIN prop_viirs p USING (dn) GROUP BY e.dn);

.print '== D1. Umbrales de confidence (MODIS 0-100 -> VIIRS l/n/h) =='
SELECT u.dn, u.umbral_bajo, u.umbral_alto,
       round(100 * u.viirs_prop_l, 1) AS viirs_pct_l,
       round(100 * avg((m.confidence < u.umbral_bajo)::INT), 1) AS modis_pct_l,
       round(100 * u.viirs_prop_h, 1) AS viirs_pct_h,
       round(100 * avg((m.confidence >= u.umbral_alto)::INT), 1) AS modis_pct_h
FROM umbrales_conf u JOIN m_cal m USING (dn) WHERE m.type = 0 GROUP BY ALL ORDER BY u.dn;

-- ===========================================================================
-- E) FRP Y BRILLO: emparejamiento de cuantiles por dn (vegetación)
-- ===========================================================================
-- Para cada valor distinto de MODIS se toma su percentil de rango medio y se le asigna el
-- valor de VIIRS en ese percentil (cuantiles de VIIRS en una rejilla de 0,0001).

CREATE OR REPLACE TEMP TABLE m_largo AS
SELECT dn, variable, x FROM (UNPIVOT (SELECT dn, frp, brightness AS bright_ti4, bright_t31 AS bright_ti5 FROM m_cal WHERE type = 0)
                             ON frp, bright_ti4, bright_ti5 INTO NAME variable VALUE x)
WHERE x IS NOT NULL;

CREATE OR REPLACE TEMP TABLE v_largo AS
SELECT dn, variable, y FROM (UNPIVOT (SELECT dn, frp, bright_ti4, bright_ti5 FROM v_cal WHERE type = 0)
                             ON frp, bright_ti4, bright_ti5 INTO NAME variable VALUE y)
WHERE y IS NOT NULL;

CREATE OR REPLACE TEMP TABLE cuantiles_viirs AS
SELECT dn, variable, i, q[i + 1] AS y
FROM (SELECT dn, variable, quantile_cont(y, [j / 10000 FOR j IN range(0, 10001)]) AS q FROM v_largo GROUP BY ALL),
     range(0, 10001) r(i);

CREATE OR REPLACE TEMP TABLE curvas AS
WITH em AS (
  SELECT dn, variable, x, (sum(n) OVER w - n / 2) / sum(n) OVER (PARTITION BY dn, variable) AS p
  FROM (SELECT dn, variable, x, count(*) AS n FROM m_largo GROUP BY ALL)
  WINDOW w AS (PARTITION BY dn, variable ORDER BY x)
), ix AS (
  SELECT *, least(floor(p * 10000)::INT, 9999) AS i0, p * 10000 - least(floor(p * 10000)::INT, 9999) AS fr FROM em
)
SELECT ix.dn, ix.variable, ix.x AS valor_modis, round(ix.p, 6) AS percentil,
       a.y + ix.fr * (b.y - a.y) AS valor_viirs
FROM ix
JOIN cuantiles_viirs a ON a.dn = ix.dn AND a.variable = ix.variable AND a.i = ix.i0
JOIN cuantiles_viirs b ON b.dn = ix.dn AND b.variable = ix.variable AND b.i = ix.i0 + 1;

.print '== E1. Curvas de transferencia: algunos valores MODIS -> VIIRS =='
SELECT dn, variable, valor_modis, round(valor_viirs, 2) AS valor_viirs, percentil
FROM curvas c
WHERE (variable = 'frp' AND valor_modis IN (5, 10, 20, 50, 100, 300))
   OR (variable = 'bright_ti4' AND valor_modis IN (305, 310, 320, 330, 350))
   OR (variable = 'bright_ti5' AND valor_modis IN (280, 290, 300, 310))
ORDER BY dn, variable, valor_modis;

-- ===========================================================================
-- F) EXPORTAR REGLAS (ajuste final = pliegue 0)
-- ===========================================================================

-- La carpeta analisis/reglas/ está versionada en git (DuckDB no crea carpetas al exportar).

COPY (SELECT dn, k FROM k_dn WHERE pliegue = 0 AND b = getvariable('b') ORDER BY dn) TO 'analisis/reglas/k_dn.csv' (HEADER);
COPY (SELECT dn, mm, s FROM s_mes WHERE pliegue = 0 AND b = getvariable('b') ORDER BY ALL) TO 'analisis/reglas/s_mes.csv' (HEADER);
COPY (SELECT dn, gy, gx, focos_modis, k FROM k_c2 WHERE pliegue = 0 AND b = getvariable('b') ORDER BY ALL) TO 'analisis/reglas/k_celda2.csv' (HEADER);
COPY (SELECT dn, gy, gx, mm, focos_modis, k FROM k_c2m WHERE pliegue = 0 AND b = getvariable('b') ORDER BY ALL) TO 'analisis/reglas/k_celda2_mes.csv' (HEADER);
COPY (SELECT dn, cy, cx, focos_modis, r FROM r_c1 WHERE pliegue = 0 AND b = getvariable('b') ORDER BY ALL) TO 'analisis/reglas/r_celda1.csv' (HEADER);
COPY (SELECT dn, gy, gx, mm, nref FROM referencia WHERE pliegue = 0 ORDER BY ALL) TO 'analisis/reglas/actividad_referencia.csv' (HEADER);
COPY (SELECT getvariable('b') AS b, getvariable('alfa') AS alfa, getvariable('n0') AS n0,
             0.5 AS factor_min, 2.0 AS factor_max) TO 'analisis/reglas/parametros.csv' (HEADER);
COPY (SELECT * FROM cv ORDER BY regla, b DESC) TO 'analisis/reglas/validacion_cruzada_2012_2017.csv' (HEADER);
COPY (SELECT type, dn, focos_modis, focos_viirs, k FROM k_tipo ORDER BY ALL) TO 'analisis/reglas/k_tipo.csv' (HEADER);
COPY (SELECT mm, k_mes, k_global FROM k_simple ORDER BY mm) TO 'analisis/reglas/k_simple_linea_base.csv' (HEADER);
COPY (SELECT dn, mm, f FROM terra_nac ORDER BY ALL) TO 'analisis/reglas/f_terra_mes.csv' (HEADER);
COPY (SELECT dn, gy, gx, mm, focos_terra, f FROM f_terra ORDER BY ALL) TO 'analisis/reglas/f_terra_celda2_mes.csv' (HEADER);
COPY (SELECT * FROM umbrales_conf ORDER BY dn) TO 'analisis/reglas/umbrales_confidence.csv' (HEADER);
COPY (SELECT * FROM curvas ORDER BY dn, variable, valor_modis) TO 'analisis/reglas/curvas_cuantiles.csv' (HEADER);

.print '== Listo: reglas en analisis/reglas/ =='
