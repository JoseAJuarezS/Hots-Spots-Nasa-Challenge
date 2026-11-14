-- Exporta los focos armonizados a una rejilla de 0,1° × mes para el mapa del frontend.
-- Uso (desde la raíz del repo):  mise run datos:mapa
--   (o: duckdb -readonly analisis/focos.duckdb < analisis/05_exportar_mapa.sql)
-- Requiere haber corrido 04_armonizar.sql.
--
-- Salida en frontend/public/datos/:
--   celdas/anio=AAAA/celdas0.json (nombre fijado por DuckDB)  Un objeto por año con columnas en listas paralelas:
--       i, j  -> índice de la celda: lat_sur = i * 0.1, lon_oeste = j * 0.1
--       m     -> mes del año (1..12)
--       f     -> focos armonizados (= sum(peso)), 2 decimales
--       b     -> focos brutos (número de detecciones)
--   resumen.json  Serie mensual de la región (total armonizado y fuente).
-- Se usa JSON (y no Parquet) para que el prototipo no dependa de DuckDB-WASM.

CREATE OR REPLACE TEMP VIEW celdas AS
SELECT year(mes)                    AS anio,
       month(mes)                   AS m,
       floor(latitude  * 10)::INT   AS i,
       floor(longitude * 10)::INT   AS j,
       round(sum(peso), 2)          AS f,
       count(*)                     AS b
FROM focos_armonizados
GROUP BY ALL;

COPY (
  SELECT anio, list(i ORDER BY m, i, j) AS i, list(j ORDER BY m, i, j) AS j,
         list(m ORDER BY m, i, j) AS m, list(f ORDER BY m, i, j) AS f,
         list(b ORDER BY m, i, j) AS b
  FROM celdas GROUP BY anio
) TO 'frontend/public/datos/celdas'
  (FORMAT 'json', PARTITION_BY ('anio'), FILENAME_PATTERN 'celdas', OVERWRITE_OR_IGNORE);

COPY (
  SELECT strftime(mes, '%Y-%m') AS mes, fuente, round(armonizado, 1) AS focos
  FROM serie_mensual ORDER BY mes
) TO 'frontend/public/datos/resumen.json' (FORMAT 'json', ARRAY true);
