-- k por mes del año (todo MODIS vs S-NPP, detecciones filtradas) + validación, y k para Terra sola.
-- Uso (desde la raíz del repo):  duckdb analisis/focos.duckdb < analisis/03_k_mensual.sql
CREATE OR REPLACE TEMP TABLE m AS
SELECT date_trunc('month', fecha) AS mes,
       count(*) FILTER (sensor = 'MODIS')        AS modis,
       count(*) FILTER (satellite = 'Terra')     AS terra,
       count(*) FILTER (sensor = 'VIIRS_SNPP')   AS snpp
FROM focos
WHERE type = 0 AND fecha >= DATE '2012-02-01'
  AND ((sensor = 'MODIS' AND TRY_CAST(confidence AS INT) >= 30)
       OR (sensor LIKE 'VIIRS%' AND confidence IN ('n', 'h')))
GROUP BY ALL HAVING modis > 0 AND snpp > 0;

.print '== k por mes del año: todo MODIS -> S-NPP (calibrado 2012-2018) =='
CREATE OR REPLACE TEMP TABLE kmes AS
SELECT month(mes) AS mm, sum(snpp)/sum(modis) AS k, sum(snpp)/sum(terra) AS k_terra
FROM m WHERE mes < DATE '2019-01-01' GROUP BY 1;
SELECT mm AS mes_del_anio, round(k, 2) AS k_modis, round(k_terra, 2) AS k_terra FROM kmes ORDER BY 1;

.print '== Validación 2019-2025: k global vs k por mes =='
WITH kg AS (SELECT sum(snpp)/sum(modis) AS k, sum(snpp)/sum(terra) AS kt FROM m WHERE mes < DATE '2019-01-01')
SELECT 'MODIS, k global' AS metodo, round(median(abs(kg.k*modis-snpp)/snpp)*100,1) AS error_mediano_pct,
       round(sum(kg.k*modis)/sum(snpp)*100-100,1) AS sesgo_pct, round(corr(kg.k*modis,snpp),3) AS r
FROM m, kg WHERE mes >= DATE '2019-01-01'
UNION ALL
SELECT 'MODIS, k por mes', round(median(abs(k*modis-snpp)/snpp)*100,1),
       round(sum(k*modis)/sum(snpp)*100-100,1), round(corr(k*modis,snpp),3)
FROM m JOIN kmes ON month(mes) = mm WHERE mes >= DATE '2019-01-01'
UNION ALL
SELECT 'Solo Terra, k global', round(median(abs(kg.kt*terra-snpp)/snpp)*100,1),
       round(sum(kg.kt*terra)/sum(snpp)*100-100,1), round(corr(kg.kt*terra,snpp),3)
FROM m, kg WHERE mes >= DATE '2019-01-01' AND terra > 0
UNION ALL
SELECT 'Solo Terra, k por mes', round(median(abs(k_terra*terra-snpp)/snpp)*100,1),
       round(sum(k_terra*terra)/sum(snpp)*100-100,1), round(corr(k_terra*terra,snpp),3)
FROM m JOIN kmes ON month(mes) = mm WHERE mes >= DATE '2019-01-01' AND terra > 0;

.print '== NOAA-20 vs S-NPP (2018-04..2025): ¿son intercambiables? =='
SELECT round(sum(n20)/sum(snpp),3) AS k_n20_snpp, round(corr(n20,snpp),4) AS r FROM (
  SELECT date_trunc('month', fecha) mes, count(*) FILTER (sensor='VIIRS_NOAA20') n20, count(*) FILTER (sensor='VIIRS_SNPP') snpp
  FROM focos WHERE type=0 AND confidence IN ('n','h') AND fecha >= DATE '2018-05-01' GROUP BY 1);
