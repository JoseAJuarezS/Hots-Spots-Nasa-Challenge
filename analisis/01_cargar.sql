-- Carga los CSV anuales de FIRMS (India) de datos_crudos/ en una tabla común `focos`.
-- Uso (desde la raíz del repo):  duckdb analisis/focos.duckdb < analisis/01_cargar.sql
CREATE OR REPLACE TABLE focos AS
SELECT 'MODIS' AS sensor, satellite, CAST(acq_date AS DATE) AS fecha, acq_time,
       latitude, longitude, CAST(confidence AS VARCHAR) AS confidence, frp, daynight, type
FROM read_csv('datos_crudos/MODIS/modis_*_India.csv', union_by_name = true, types = {'acq_time': 'VARCHAR', 'confidence': 'VARCHAR'})
UNION ALL
SELECT 'VIIRS_SNPP', satellite, CAST(acq_date AS DATE), acq_time,
       latitude, longitude, confidence, frp, daynight, type
FROM read_csv('datos_crudos/VIIRS/viirs-snpp_*_India.csv', union_by_name = true, types = {'acq_time': 'VARCHAR', 'confidence': 'VARCHAR'})
UNION ALL
SELECT 'VIIRS_NOAA20', satellite, CAST(acq_date AS DATE), acq_time,
       latitude, longitude, confidence, frp, daynight, type
FROM read_csv('datos_crudos/VIIRS/viirs-jpss1_*_India.csv', union_by_name = true, types = {'acq_time': 'VARCHAR', 'confidence': 'VARCHAR'});

SELECT sensor, satellite, count(*) AS focos, min(fecha) AS desde, max(fecha) AS hasta
FROM focos GROUP BY ALL ORDER BY ALL;
