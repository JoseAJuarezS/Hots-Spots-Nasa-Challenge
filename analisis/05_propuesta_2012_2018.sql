-- Propuesta de armonización MODIS -> escala VIIRS S-NPP con los años 2012 y 2018.
-- Uso (desde la raíz del repo):  mise run datos:propuesta
--   (equivale a: duckdb -no-agent analisis/propuesta.duckdb < analisis/05_propuesta_2012_2018.sql)
-- Resultados y discusión: analisis/propuesta-armonizacion-2012-2018.md

------------------------------------------------------------------------------
-- 1. Carga: los cinco CSV en una tabla con esquema común
------------------------------------------------------------------------------
CREATE OR REPLACE TABLE focos_prop AS
SELECT 'MODIS' AS sensor, satellite, CAST(acq_date AS DATE) AS fecha, acq_time,
       latitude, longitude, confidence, version, frp, daynight, type,
       regexp_extract(filename, '[^/\\]+$') AS archivo
FROM read_csv(['datos_crudos/MODIS/modis_2012_India.csv', 'datos_crudos/MODIS/modis_2018_India.csv'],
              union_by_name = true, filename = true,
              types = {'acq_time': 'VARCHAR', 'confidence': 'VARCHAR', 'version': 'VARCHAR'})
UNION ALL
SELECT 'VIIRS_SNPP', satellite, CAST(acq_date AS DATE), acq_time,
       latitude, longitude, confidence, version, frp, daynight, type,
       regexp_extract(filename, '[^/\\]+$')
FROM read_csv(['datos_crudos/VIIRS/viirs-snpp_2012_India.csv', 'datos_crudos/VIIRS/viirs-snpp_2018_India.csv'],
              union_by_name = true, filename = true,
              types = {'acq_time': 'VARCHAR', 'confidence': 'VARCHAR', 'version': 'VARCHAR'})
UNION ALL
SELECT 'VIIRS_NOAA20', satellite, CAST(acq_date AS DATE), acq_time,
       latitude, longitude, confidence, version, frp, daynight, type,
       regexp_extract(filename, '[^/\\]+$')
FROM read_csv('datos_crudos/VIIRS/viirs-jpss1_2018_India.csv', filename = true,
              types = {'acq_time': 'VARCHAR', 'confidence': 'VARCHAR', 'version': 'VARCHAR'});

.print '== 1. Filas cargadas por archivo =='
SELECT archivo, sensor, string_agg(DISTINCT satellite, ',') AS satelites,
       string_agg(DISTINCT version, ',') AS versiones,
       count(*) AS filas, min(fecha) AS desde, max(fecha) AS hasta
FROM focos_prop GROUP BY ALL ORDER BY archivo;

------------------------------------------------------------------------------
-- 2. Filtros comunes y columnas derivadas
--    type = 0 (vegetación); MODIS confidence >= 30; VIIRS confidence n/h;
--    fuera enero de 2012 (S-NPP aún no opera el mes completo).
--    Estaciones de India: invierno dic-feb, premonzón mar-may,
--    monzón jun-sep, posmonzón oct-nov.
--    Región: bloque de 5° x 5°.
------------------------------------------------------------------------------
CREATE OR REPLACE TABLE f AS
SELECT sensor, satellite, fecha, daynight,
       year(fecha) AS anio,
       date_trunc('month', fecha) AS mes,
       month(fecha) AS mm,
       CASE WHEN month(fecha) IN (12, 1, 2) THEN '1_invierno'
            WHEN month(fecha) IN (3, 4, 5)  THEN '2_premonzon'
            WHEN month(fecha) IN (6, 7, 8, 9) THEN '3_monzon'
            ELSE '4_posmonzon' END AS estacion,
       printf('%02d_%02d', CAST(floor(latitude / 5) * 5 AS INT), CAST(floor(longitude / 5) * 5 AS INT)) AS region
FROM focos_prop
WHERE type = 0
  AND fecha >= DATE '2012-02-01'
  AND ((sensor = 'MODIS' AND TRY_CAST(confidence AS INT) >= 30)
       OR (sensor LIKE 'VIIRS%' AND confidence IN ('n', 'h')));

.print '== 2. Filas que pasan los filtros =='
WITH crudas AS (SELECT sensor, year(fecha) AS anio, count(*) AS filas_crudas FROM focos_prop GROUP BY ALL),
     filtradas AS (SELECT sensor, anio, count(*) AS filas_filtradas FROM f GROUP BY ALL)
SELECT sensor, anio, filas_crudas, filas_filtradas,
       round(100.0 * filas_filtradas / filas_crudas, 1) AS pct_conservado
FROM crudas JOIN filtradas USING (sensor, anio) ORDER BY 1, 2;

------------------------------------------------------------------------------
-- 3. Agregado base: mes x día/noche x región
--    x = focos MODIS (Terra+Aqua), y = focos VIIRS S-NPP, z = focos NOAA-20
------------------------------------------------------------------------------
CREATE OR REPLACE TABLE agg AS
SELECT anio, mes, mm, estacion, daynight, region,
       count(*) FILTER (sensor = 'MODIS')        AS x,
       count(*) FILTER (sensor = 'VIIRS_SNPP')   AS y,
       count(*) FILTER (sensor = 'VIIRS_NOAA20') AS z
FROM f GROUP BY ALL;

.print '== 3. Totales anuales y k anual (S-NPP / MODIS) =='
SELECT anio, sum(x) AS modis, sum(y) AS snpp, round(sum(y) / sum(x), 2) AS k_anual,
       round(100.0 * sum(x) FILTER (daynight = 'N') / sum(x), 1) AS pct_noche_modis,
       round(100.0 * sum(y) FILTER (daynight = 'N') / sum(y), 1) AS pct_noche_snpp
FROM agg GROUP BY anio ORDER BY anio;

------------------------------------------------------------------------------
-- 4. Modelos de k (VIIRS S-NPP ≈ k · MODIS), uno por año de calibración
--    M1 global | M2 mes del año | M3 estación | M4 estación x día/noche
--    M5 estación x región (si la región tiene < 200 focos MODIS se usa M3)
------------------------------------------------------------------------------
CREATE OR REPLACE TABLE k1 AS SELECT anio AS cal, sum(y) / sum(x) AS k FROM agg GROUP BY ALL;
CREATE OR REPLACE TABLE k2 AS SELECT anio AS cal, mm, sum(y) / sum(x) AS k FROM agg GROUP BY ALL HAVING sum(x) > 0;
CREATE OR REPLACE TABLE k3 AS SELECT anio AS cal, estacion, sum(y) / sum(x) AS k FROM agg GROUP BY ALL;
CREATE OR REPLACE TABLE k4 AS SELECT anio AS cal, estacion, daynight, sum(y) / sum(x) AS k FROM agg GROUP BY ALL HAVING sum(x) > 0;
CREATE OR REPLACE TABLE k5 AS SELECT anio AS cal, estacion, region, sum(y) / sum(x) AS k FROM agg GROUP BY ALL HAVING sum(x) >= 200;

.print '== 4a. k por estación y por estación x día/noche =='
SELECT k3.estacion,
       round(any_value(k3.k) FILTER (k3.cal = 2012), 2) AS k_2012,
       round(any_value(k3.k) FILTER (k3.cal = 2018), 2) AS k_2018,
       round(100 * (any_value(k3.k) FILTER (k3.cal = 2018) / any_value(k3.k) FILTER (k3.cal = 2012) - 1), 1) AS cambio_pct,
       round(any_value(k4.k) FILTER (k4.cal = 2012 AND k4.daynight = 'D'), 2) AS k_dia_2012,
       round(any_value(k4.k) FILTER (k4.cal = 2018 AND k4.daynight = 'D'), 2) AS k_dia_2018,
       round(any_value(k4.k) FILTER (k4.cal = 2012 AND k4.daynight = 'N'), 2) AS k_noche_2012,
       round(any_value(k4.k) FILTER (k4.cal = 2018 AND k4.daynight = 'N'), 2) AS k_noche_2018
FROM k3 JOIN k4 USING (cal, estacion) GROUP BY k3.estacion ORDER BY 1;

.print '== 4b. k por mes del año =='
SELECT mm AS mes_del_anio,
       round(any_value(k) FILTER (cal = 2012), 2) AS k_2012,
       round(any_value(k) FILTER (cal = 2018), 2) AS k_2018,
       (SELECT sum(x) FROM agg a WHERE a.mm = k2.mm AND a.anio = 2012) AS modis_2012,
       (SELECT sum(x) FROM agg a WHERE a.mm = k2.mm AND a.anio = 2018) AS modis_2018
FROM k2 GROUP BY mm ORDER BY mm;

------------------------------------------------------------------------------
-- 5. Validación cruzada entre años: calibrar en un año, predecir el otro
------------------------------------------------------------------------------
CREATE OR REPLACE TABLE pares AS SELECT * FROM (VALUES (2012, 2018), (2018, 2012)) t(cal, test);

CREATE OR REPLACE TABLE pred AS
SELECT 'M1_global' AS modelo, p.cal, p.test, a.mes, a.region, a.x, a.y, a.x * k1.k AS p
FROM pares p JOIN agg a ON a.anio = p.test JOIN k1 ON k1.cal = p.cal
UNION ALL
SELECT 'M2_mes', p.cal, p.test, a.mes, a.region, a.x, a.y, a.x * coalesce(k2.k, k3.k)  -- enero 2012 no existe: usa la estación
FROM pares p JOIN agg a ON a.anio = p.test
JOIN k3 ON k3.cal = p.cal AND k3.estacion = a.estacion
LEFT JOIN k2 ON k2.cal = p.cal AND k2.mm = a.mm
UNION ALL
SELECT 'M3_estacion', p.cal, p.test, a.mes, a.region, a.x, a.y, a.x * k3.k
FROM pares p JOIN agg a ON a.anio = p.test JOIN k3 ON k3.cal = p.cal AND k3.estacion = a.estacion
UNION ALL
SELECT 'M4_estacion_dianoche', p.cal, p.test, a.mes, a.region, a.x, a.y, a.x * coalesce(k4.k, k3.k)
FROM pares p JOIN agg a ON a.anio = p.test
JOIN k3 ON k3.cal = p.cal AND k3.estacion = a.estacion
LEFT JOIN k4 ON k4.cal = p.cal AND k4.estacion = a.estacion AND k4.daynight = a.daynight
UNION ALL
SELECT 'M5_estacion_region', p.cal, p.test, a.mes, a.region, a.x, a.y, a.x * coalesce(k5.k, k3.k)
FROM pares p JOIN agg a ON a.anio = p.test
JOIN k3 ON k3.cal = p.cal AND k3.estacion = a.estacion
LEFT JOIN k5 ON k5.cal = p.cal AND k5.estacion = a.estacion AND k5.region = a.region;

.print '== 5a. Validación a escala nacional (meses del año de prueba) =='
SELECT modelo, cal || '->' || test AS calibra_prueba, count(*) AS meses,
       round(corr(p, y), 3) AS r,
       round(100 * (sum(p) / sum(y) - 1), 1) AS sesgo_pct,
       round(100 * median(abs(p - y) / y), 1) AS error_mediano_pct
FROM (SELECT modelo, cal, test, mes, sum(p) AS p, sum(y) AS y FROM pred GROUP BY ALL)
GROUP BY ALL ORDER BY calibra_prueba, modelo;

.print '== 5b. Validación a escala regional (región 5° x mes, con >= 100 focos S-NPP) =='
SELECT modelo, cal || '->' || test AS calibra_prueba, count(*) AS celdas_mes,
       round(corr(p, y), 3) AS r,
       round(100 * (sum(p) / sum(y) - 1), 1) AS sesgo_pct,
       round(100 * median(abs(p - y) / y), 1) AS error_mediano_pct
FROM (SELECT modelo, cal, test, mes, region, sum(p) AS p, sum(y) AS y FROM pred GROUP BY ALL HAVING sum(y) >= 100)
GROUP BY ALL ORDER BY calibra_prueba, modelo;

.print '== 5c. Promedio de las dos direcciones =='
WITH nac AS (
  SELECT modelo, cal, corr(p, y) AS r, abs(sum(p) / sum(y) - 1) AS sesgo, median(abs(p - y) / y) AS err
  FROM (SELECT modelo, cal, mes, sum(p) AS p, sum(y) AS y FROM pred GROUP BY ALL) GROUP BY ALL
), reg AS (
  SELECT modelo, cal, corr(p, y) AS r, median(abs(p - y) / y) AS err
  FROM (SELECT modelo, cal, mes, region, sum(p) AS p, sum(y) AS y FROM pred GROUP BY ALL HAVING sum(y) >= 100) GROUP BY ALL
)
SELECT modelo,
       round(avg(nac.r), 3) AS r_nacional, round(100 * avg(nac.sesgo), 1) AS sesgo_abs_pct,
       round(100 * avg(nac.err), 1) AS error_nacional_pct,
       round(avg(reg.r), 3) AS r_regional, round(100 * avg(reg.err), 1) AS error_regional_pct
FROM nac JOIN reg USING (modelo, cal) GROUP BY modelo ORDER BY modelo;

------------------------------------------------------------------------------
-- 6. ¿Cambia MODIS con la versión (6.2 en 2012 -> 6.03 en 2018)?
--    Si la composición del propio MODIS cambia, k no es comparable entre versiones.
------------------------------------------------------------------------------
.print '== 6. Composición de MODIS por versión (focos tras filtros) =='
SELECT p.version, year(p.fecha) AS anio,
       count(*) AS focos,
       round(100.0 * count(*) FILTER (p.satellite = 'Aqua') / count(*), 1) AS pct_aqua,
       round(100.0 * count(*) FILTER (TRY_CAST(p.confidence AS INT) >= 80) / count(*), 1) AS pct_conf_alta,
       round(median(p.frp), 1) AS frp_mediana
FROM focos_prop p
WHERE p.sensor = 'MODIS' AND p.type = 0 AND TRY_CAST(p.confidence AS INT) >= 30
GROUP BY ALL ORDER BY anio;

.print '== 6b. k por satélite MODIS (S-NPP / satélite) =='
SELECT anio,
       round(sum(y) / sum(x_aqua), 2) AS k_aqua,
       round(sum(y) / sum(x_terra), 2) AS k_terra
FROM (SELECT anio, mes,
             count(*) FILTER (satellite = 'Aqua')  AS x_aqua,
             count(*) FILTER (satellite = 'Terra') AS x_terra,
             count(*) FILTER (sensor = 'VIIRS_SNPP') AS y
      FROM f GROUP BY ALL)
GROUP BY anio ORDER BY anio;

------------------------------------------------------------------------------
-- 7. NOAA-20 frente a S-NPP (2018): ¿son intercambiables?
------------------------------------------------------------------------------
.print '== 7. NOAA-20 vs S-NPP por mes (2018) =='
SELECT mes, sum(z) AS noaa20, sum(y) AS snpp, round(sum(z) / sum(y), 3) AS ratio
FROM agg WHERE anio = 2018 AND z > 0 GROUP BY mes ORDER BY mes;

SELECT round(sum(z) / sum(y), 3) AS k_n20_snpp, round(corr(z, y), 4) AS r_mensual,
       round(100 * median(abs(z - y) / y), 1) AS dif_mediana_pct
FROM (SELECT mes, sum(z) AS z, sum(y) AS y FROM agg WHERE anio = 2018 GROUP BY mes HAVING sum(z) > 0);

SELECT round(corr(z, y), 4) AS r_regional, round(100 * median(abs(z - y) / y), 1) AS dif_mediana_regional_pct
FROM (SELECT mes, region, sum(z) AS z, sum(y) AS y FROM agg WHERE anio = 2018 AND mes >= DATE '2018-05-01'
      GROUP BY ALL HAVING sum(y) >= 100);

------------------------------------------------------------------------------
-- 8. Salida armonizada con el modelo recomendado (M5: k por estación x región,
--    con k por estación cuando la región tiene < 200 focos MODIS),
--    calibrado con los dos años juntos.
------------------------------------------------------------------------------
CREATE OR REPLACE TABLE k_estacion AS
SELECT estacion, sum(y) / sum(x) AS k FROM agg GROUP BY estacion;

CREATE OR REPLACE TABLE k_region AS
SELECT estacion, region, sum(x) AS modis_cal, sum(y) / sum(x) AS k
FROM agg GROUP BY ALL HAVING sum(x) >= 200;

.print '== 8. k final por estación (respaldo) y por estación x región (2012 + 2018) =='
SELECT estacion, round(k, 2) AS k_estacion FROM k_estacion ORDER BY estacion;
SELECT region, estacion, modis_cal, round(k, 2) AS k
FROM k_region ORDER BY region, estacion;

CREATE OR REPLACE TABLE mensual_armonizado AS
SELECT a.mes, a.region, a.estacion,
       sum(a.x) AS focos_modis,
       round(sum(a.x) * any_value(coalesce(r.k, e.k)), 1) AS focos_modis_armonizados,
       sum(a.y) AS focos_viirs_snpp,
       sum(a.z) AS focos_viirs_noaa20,
       round(any_value(coalesce(r.k, e.k)), 3) AS k,
       CASE WHEN any_value(r.k) IS NULL THEN 'M5_respaldo_estacion' ELSE 'M5_estacion_region' END AS modelo
FROM agg a
JOIN k_estacion e USING (estacion)
LEFT JOIN k_region r USING (estacion, region)
GROUP BY a.mes, a.region, a.estacion
ORDER BY a.mes, a.region;

.print '== 8b. Comprobación anual de la salida =='
SELECT year(mes) AS anio, sum(focos_modis) AS modis, round(sum(focos_modis_armonizados)) AS modis_armonizado,
       sum(focos_viirs_snpp) AS snpp,
       round(100 * (sum(focos_modis_armonizados) / sum(focos_viirs_snpp) - 1), 1) AS dif_pct
FROM mensual_armonizado GROUP BY ALL ORDER BY 1;

COPY mensual_armonizado TO 'analisis/salida/armonizado_2012_2018.parquet' (FORMAT parquet, COMPRESSION zstd);
COPY mensual_armonizado TO 'analisis/salida/armonizado_2012_2018.csv' (HEADER, DELIMITER ',');
