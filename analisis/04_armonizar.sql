-- Serie armonizada 2000-2025 en escala VIIRS S-NPP.
-- Uso (desde la raíz del repo):  duckdb analisis/focos.duckdb < analisis/04_armonizar.sql
--
-- Regla:
--   * Desde 2012-02: focos VIIRS S-NPP observados (peso 1).
--   * 2002-08 .. 2012-01: focos de todo MODIS (Terra + Aqua) × k del mes del año.
--   * 2000-11 .. 2002-07: solo Terra (Aqua aún no está completo) × k_terra del mes del año.
-- Las k se calibran con 2012-02 .. 2018-12 (el tramo más cercano a los años que rellenamos).
-- Se armoniza a nivel de foco (columna `peso`), así cualquier área dibujada en la app
-- se puede sumar directamente: focos armonizados = sum(peso).

-- Filtros comunes (los mismos que en 02 y 03)
CREATE OR REPLACE TEMP VIEW f AS
SELECT *, date_trunc('month', fecha) AS mes
FROM focos
WHERE type = 0
  AND ((sensor = 'MODIS' AND TRY_CAST(confidence AS INT) >= 30)
       OR (sensor LIKE 'VIIRS%' AND confidence IN ('n', 'h')));

-- 1) Constantes por mes del año ------------------------------------------------
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

-- 2) Focos armonizados (nivel de punto) ----------------------------------------
CREATE OR REPLACE TABLE focos_armonizados AS
SELECT f.fecha, f.mes, f.latitude, f.longitude, f.sensor, f.satellite, f.frp, f.daynight,
       CASE
         WHEN f.mes >= DATE '2012-02-01' THEN 'VIIRS'
         WHEN f.mes >= DATE '2002-08-01' THEN 'MODIS'
         ELSE 'TERRA'
       END AS fuente,
       CASE
         WHEN f.mes >= DATE '2012-02-01' THEN 1.0
         WHEN f.mes >= DATE '2002-08-01' THEN k.k_modis
         ELSE k.k_terra
       END AS peso
FROM f JOIN k_mes k ON month(f.mes) = k.mm
WHERE (f.mes >= DATE '2012-02-01' AND f.sensor = 'VIIRS_SNPP')
   OR (f.mes BETWEEN DATE '2002-08-01' AND DATE '2012-01-01' AND f.sensor = 'MODIS')
   OR (f.mes <  DATE '2002-08-01' AND f.satellite = 'Terra');

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
)
SELECT b.*, a.fuente, round(a.armonizado) AS armonizado,
       -- MODIS×k también en el solape, para poder validarlo contra VIIRS
       round(b.modis * k.k_modis) AS modis_x_k
FROM bruto b JOIN arm a USING (mes) JOIN k_mes k ON month(b.mes) = k.mm
ORDER BY mes;

.print '== Constantes usadas (calibradas 2012-02..2018-12) =='
SELECT mm AS mes, round(k_modis, 2) AS k_modis, round(k_modis_p25, 2) AS p25,
       round(k_modis_p75, 2) AS p75, round(k_terra, 2) AS k_terra
FROM k_mes ORDER BY 1;

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

.print '== Validación en el solape: MODIS×k frente a VIIRS observado =='
SELECT CASE WHEN mes < DATE '2019-01-01' THEN '2012-2018 (calibración)' ELSE '2019-2025 (prueba)' END AS tramo,
       count(*) AS meses,
       round(corr(modis_x_k, snpp), 3) AS r,
       round(sum(modis_x_k) / sum(snpp) * 100 - 100, 1) AS sesgo_pct,
       round(median(abs(modis_x_k - snpp) / snpp) * 100, 1) AS error_mediano_pct,
       round(sqrt(avg((modis_x_k - snpp) ^ 2))) AS rmse_focos
FROM serie_mensual WHERE mes >= DATE '2012-02-01' AND snpp > 0
GROUP BY 1 ORDER BY 1;
