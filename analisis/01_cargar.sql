-- Carga los focos de FIRMS en una tabla común `focos`, desde los Parquet de
-- $FIRMS_DATA_DIR/parquet (los genera `mise run datos:ingerir`; ver analisis/firms.py).
-- Países: $FIRMS_PAISES (separados por coma) o, si no está definida, analisis/paises.txt.
-- Uso (desde la raíz del repo):  mise run datos:cargar
--   (equivale a: duckdb analisis/focos.duckdb < analisis/01_cargar.sql)

CREATE OR REPLACE TABLE paises AS
SELECT trim(pais) AS pais
FROM (SELECT unnest(string_split(getenv('FIRMS_PAISES'), ',')) AS pais)
WHERE coalesce(getenv('FIRMS_PAISES'), '') <> '' AND trim(pais) <> ''
UNION ALL
SELECT trim(split_part(linea, '#', 1))
FROM read_csv('analisis/paises.txt', header = false, columns = {'linea': 'VARCHAR'}, delim = '\0', quote = '', escape = '')
WHERE coalesce(getenv('FIRMS_PAISES'), '') = '' AND trim(split_part(linea, '#', 1)) <> '';

CREATE OR REPLACE TABLE focos AS
SELECT CASE sensor WHEN 'modis'       THEN 'MODIS'
                   WHEN 'viirs-snpp'  THEN 'VIIRS_SNPP'
                   WHEN 'viirs-jpss1' THEN 'VIIRS_NOAA20' END AS sensor,
       satellite, acq_date AS fecha, acq_time,
       latitude, longitude, confidence, frp, daynight, type, pais
FROM read_parquet(getenv('FIRMS_DATA_DIR') || '/parquet/sensor=*/pais=*/anio=*/*.parquet',
                  hive_partitioning = true, union_by_name = true)
WHERE pais IN (SELECT pais FROM paises);

SELECT pais, sensor, satellite, count(*) AS focos, min(fecha) AS desde, max(fecha) AS hasta
FROM focos GROUP BY ALL ORDER BY ALL;

-- Países pedidos que no tienen datos ingeridos (si sale alguno: descargar + ingerir)
SELECT pais AS pais_sin_datos FROM paises
WHERE pais NOT IN (SELECT DISTINCT pais FROM focos);
