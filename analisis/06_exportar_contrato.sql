-- Exporta los 4 artefactos del Contrato de Datos (docs/frontend/plan.tex)
-- Uso: duckdb -no-agent analisis/focos.duckdb < analisis/06_exportar_contrato.sql

-- 1) Rejilla espacial 0.1 grados x mes (alimenta el calendario y mapa en milisegundos)
COPY (
  SELECT
    ROUND(latitude, 1) AS lat,
    ROUND(longitude, 1) AS lon,
    mes,
    ANY_VALUE(fuente) AS fuente,
    COUNT(*)::INT AS focos_brutos,
    ROUND(SUM(peso), 2) AS focos_armonizados,
    ROUND(SUM(frp), 2) AS frp_total
  FROM focos_armonizados
  GROUP BY 1, 2, 3
  ORDER BY mes, lat, lon
) TO 'datos_procesados/celdas_mes.parquet' (FORMAT PARQUET, COMPRESSION ZSTD);

-- 2) Constantes mensuales e incertidumbre (p25 / p75)
COPY (
  SELECT
    mm AS mes,
    ROUND(k_modis, 4) AS k_modis,
    ROUND(k_modis_p25, 4) AS k_modis_p25,
    ROUND(k_modis_p75, 4) AS k_modis_p75,
    ROUND(k_terra, 4) AS k_terra
  FROM k_mes
  ORDER BY mm
) TO 'datos_procesados/k_mes.json' (FORMAT JSON, ARRAY true);

-- 3) Focos individuales particionados por año (para descarga CSV)
COPY (
  SELECT
    YEAR(fecha) AS anio,
    fecha,
    ROUND(latitude, 5) AS latitude,
    ROUND(longitude, 5) AS longitude,
    sensor,
    satellite,
    fuente,
    ROUND(peso, 4) AS peso,
    frp,
    daynight
  FROM focos_armonizados
  ORDER BY fecha
) TO 'datos_procesados/focos' (FORMAT PARQUET, PARTITION_BY (anio), OVERWRITE_OR_IGNORE true, COMPRESSION ZSTD);

-- 4) Metadatos técnicos del dataset
COPY (
  SELECT
    'India' AS region,
    MIN(fecha) AS fecha_inicio,
    MAX(fecha) AS fecha_fin,
    0.1 AS resolucion_rejilla_grados,
    'VIIRS_SNPP' AS escala_referencia,
    'type=0; MODIS confidence>=30; VIIRS confidence IN (n,h)' AS filtros_aplicados,
    COUNT(*)::BIGINT AS total_registros_armonizados
  FROM focos_armonizados
) TO 'datos_procesados/metadatos.json' (FORMAT JSON, ARRAY false);
