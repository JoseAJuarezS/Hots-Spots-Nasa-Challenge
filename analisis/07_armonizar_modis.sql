-- Paso 2: armoniza TODOS los focos de MODIS (2000-2025) a la escala de VIIRS 375 m usando
-- las reglas obtenidas en 06_reglas_armonizacion.sql (calibradas solo con 2012-2017).
-- Uso (desde la raíz del repo):  duckdb -no-agent < analisis/07_armonizar_modis.sql
--
-- Entradas:  datos_crudos/MODIS_original/modis_*_India.csv   (MODIS sin tocar)
--            analisis/reglas/*.csv
-- Salidas:   datos_armonizados/anio=<año>/modis_armonizado_India_0.csv      (uno por año)
--            datos_armonizados/anio=<año>/modis_armonizado_India_0.parquet  (lo mismo, en Parquet)
--
-- Cada fila conserva su foco MODIS, con las columnas en el formato de VIIRS:
--   bright_ti4, bright_ti5, frp  -> valores MODIS llevados por cuantiles a la distribución VIIRS
--   confidence                   -> l / n / h con los umbrales calibrados
--   peso                         -> cuántos focos VIIRS representa este foco MODIS.
--                                   Focos armonizados de cualquier área y periodo = sum(peso).
--                                   Depende de la celda, el mes, día/noche y de la actividad de ese
--                                   mes en su celda de 2° (ver 06), así que hay que recalcular todo
--                                   el mes si se añaden focos nuevos.
--   modo                         -> 'terra_aqua', o 'solo_terra' antes del 2002-07-04 (sin Aqua;
--                                   el peso incluye además el factor f_terra y es menos preciso)
--   *_modis                      -> valores originales, por si hacen falta
-- Las columnas scan/track se dejan como en MODIS (tamaño del píxel de 1 km).

.print '== Cargando MODIS y reglas =='

CREATE OR REPLACE TEMP TABLE modis AS
SELECT *,
       -- actividad: focos MODIS de vegetación en la misma celda 2°, mes concreto y dn
       sum((type = 0)::INT) OVER (PARTITION BY date_trunc('month', acq_date), daynight, gy, gx) AS actividad
FROM (
  SELECT *, month(acq_date) AS mm,
         floor(latitude / 2)::INT AS gy, floor(longitude / 2)::INT AS gx,
         floor(latitude)::INT AS cy, floor(longitude)::INT AS cx,
         CASE WHEN acq_date < DATE '2002-07-04' THEN 'solo_terra' ELSE 'terra_aqua' END AS modo
  FROM read_csv('datos_crudos/MODIS_original/modis_*_India.csv', union_by_name = true,
                types = {'acq_time': 'VARCHAR', 'confidence': 'INTEGER', 'frp': 'DOUBLE',
                         'brightness': 'DOUBLE', 'bright_t31': 'DOUBLE', 'version': 'VARCHAR'})
);

CREATE OR REPLACE TEMP TABLE param   AS SELECT * FROM read_csv('analisis/reglas/parametros.csv');
CREATE OR REPLACE TEMP TABLE act_ref AS SELECT * FROM read_csv('analisis/reglas/actividad_referencia.csv');

CREATE OR REPLACE TEMP TABLE k_dn       AS SELECT * FROM read_csv('analisis/reglas/k_dn.csv');
CREATE OR REPLACE TEMP TABLE s_mes      AS SELECT * FROM read_csv('analisis/reglas/s_mes.csv');
CREATE OR REPLACE TEMP TABLE k_c2       AS SELECT * FROM read_csv('analisis/reglas/k_celda2.csv');
CREATE OR REPLACE TEMP TABLE k_c2m      AS SELECT * FROM read_csv('analisis/reglas/k_celda2_mes.csv');
CREATE OR REPLACE TEMP TABLE r_c1       AS SELECT * FROM read_csv('analisis/reglas/r_celda1.csv');
CREATE OR REPLACE TEMP TABLE k_tipo     AS SELECT * FROM read_csv('analisis/reglas/k_tipo.csv');
CREATE OR REPLACE TEMP TABLE f_terra_m  AS SELECT * FROM read_csv('analisis/reglas/f_terra_mes.csv');
CREATE OR REPLACE TEMP TABLE f_terra_c  AS SELECT * FROM read_csv('analisis/reglas/f_terra_celda2_mes.csv');
CREATE OR REPLACE TEMP TABLE umbrales   AS SELECT * FROM read_csv('analisis/reglas/umbrales_confidence.csv');

-- Curvas de cuantiles con el punto siguiente (para interpolar) y los extremos (para extrapolar)
CREATE OR REPLACE TEMP TABLE curvas AS
SELECT dn, variable, valor_modis AS x0, valor_viirs AS y0,
       lead(valor_modis) OVER w AS x1, lead(valor_viirs) OVER w AS y1
FROM read_csv('analisis/reglas/curvas_cuantiles.csv')
WINDOW w AS (PARTITION BY dn, variable ORDER BY valor_modis);

CREATE OR REPLACE TEMP TABLE extremos AS
SELECT dn, variable,
       min(x0) AS x_min, arg_min(y0, x0) AS y_min, max(x0) AS x_max, arg_max(y0, x0) AS y_max
FROM curvas GROUP BY ALL;

-- Interpolación lineal en la curva; fuera del rango calibrado: FRP se escala con la razón
-- del extremo (multiplicativo) y las temperaturas con el desplazamiento del extremo (aditivo).
CREATE OR REPLACE MACRO transferir(x, var, c_x0, c_y0, c_x1, c_y1, e) AS
  CASE
    WHEN x IS NULL THEN NULL
    WHEN x < e.x_min THEN
      CASE WHEN var = 'frp' THEN (CASE WHEN e.x_min > 0 THEN x * e.y_min / e.x_min ELSE e.y_min END)
           ELSE x + (e.y_min - e.x_min) END
    WHEN c_x1 IS NULL THEN
      CASE WHEN var = 'frp' THEN (CASE WHEN e.x_max > 0 THEN x * e.y_max / e.x_max ELSE e.y_max END)
           ELSE x + (e.y_max - e.x_max) END
    ELSE c_y0 + (x - c_x0) * (c_y1 - c_y0) / (c_x1 - c_x0)
  END;

.print '== Aplicando reglas =='

CREATE OR REPLACE TEMP TABLE armonizado AS
SELECT m.latitude, m.longitude,
       round(transferir(m.brightness, 'bright_ti4', c4.x0, c4.y0, c4.x1, c4.y1, e4), 2) AS bright_ti4,
       m.scan, m.track, m.acq_date, m.acq_time, m.satellite, m.instrument,
       CASE WHEN m.confidence <  u.umbral_bajo THEN 'l'
            WHEN m.confidence >= u.umbral_alto THEN 'h'
            ELSE 'n' END AS confidence,
       m.version,
       round(transferir(m.bright_t31, 'bright_ti5', c5.x0, c5.y0, c5.x1, c5.y1, e5), 2) AS bright_ti5,
       round(transferir(m.frp, 'frp', cf.x0, cf.y0, cf.x1, cf.y1, ef), 2) AS frp,
       m.daynight, m.type,
       round(
         CASE WHEN m.type = 0 THEN
                coalesce(k_c2m.k, coalesce(k_c2.k, k_dn.k) * s_mes.s) * coalesce(r_c1.r, 1)
                -- factor de actividad (en solo Terra, la actividad se pasa a equivalente Terra+Aqua)
                * least(greatest(pow(
                    (m.actividad * CASE WHEN m.modo = 'solo_terra' THEN coalesce(f_terra_m.f, 1) ELSE 1 END + param.n0)
                    / (coalesce(act_ref.nref, 0) + param.n0), param.b), param.factor_min), param.factor_max)
                * CASE WHEN m.modo = 'solo_terra' THEN coalesce(f_terra_c.f, f_terra_m.f, 1) ELSE 1 END
              ELSE coalesce(k_tipo.k, k_dn.k)
                * CASE WHEN m.modo = 'solo_terra' THEN coalesce(f_terra_m.f, 1) ELSE 1 END
         END, 4) AS peso,
       m.modo,
       m.confidence AS confidence_modis, m.frp AS frp_modis,
       m.brightness AS brightness_modis, m.bright_t31 AS bright_t31_modis,
       year(m.acq_date) AS anio
FROM modis m
CROSS JOIN param
LEFT JOIN act_ref ON act_ref.dn = m.daynight AND act_ref.gy = m.gy AND act_ref.gx = m.gx AND act_ref.mm = m.mm
LEFT JOIN umbrales u ON u.dn = m.daynight
LEFT JOIN k_dn ON k_dn.dn = m.daynight
LEFT JOIN s_mes ON s_mes.dn = m.daynight AND s_mes.mm = m.mm
LEFT JOIN k_c2 ON k_c2.dn = m.daynight AND k_c2.gy = m.gy AND k_c2.gx = m.gx
LEFT JOIN k_c2m ON k_c2m.dn = m.daynight AND k_c2m.gy = m.gy AND k_c2m.gx = m.gx AND k_c2m.mm = m.mm
LEFT JOIN r_c1 ON r_c1.dn = m.daynight AND r_c1.cy = m.cy AND r_c1.cx = m.cx
LEFT JOIN k_tipo ON k_tipo.dn = m.daynight AND k_tipo.type = m.type
LEFT JOIN f_terra_m ON f_terra_m.dn = m.daynight AND f_terra_m.mm = m.mm
LEFT JOIN f_terra_c ON f_terra_c.dn = m.daynight AND f_terra_c.gy = m.gy AND f_terra_c.gx = m.gx AND f_terra_c.mm = m.mm
LEFT JOIN extremos e4 ON e4.dn = m.daynight AND e4.variable = 'bright_ti4'
LEFT JOIN extremos e5 ON e5.dn = m.daynight AND e5.variable = 'bright_ti5'
LEFT JOIN extremos ef ON ef.dn = m.daynight AND ef.variable = 'frp'
ASOF LEFT JOIN (SELECT * FROM curvas WHERE variable = 'bright_ti4') c4 ON c4.dn = m.daynight AND m.brightness >= c4.x0
ASOF LEFT JOIN (SELECT * FROM curvas WHERE variable = 'bright_ti5') c5 ON c5.dn = m.daynight AND m.bright_t31 >= c5.x0
ASOF LEFT JOIN (SELECT * FROM curvas WHERE variable = 'frp') cf ON cf.dn = m.daynight AND m.frp >= cf.x0;

.print '== Controles =='
SELECT count(*) AS focos, count(*) FILTER (peso IS NULL) AS sin_peso,
       count(*) FILTER (frp IS NULL AND frp_modis IS NOT NULL) AS frp_sin_convertir,
       count(*) FILTER (bright_ti4 IS NULL) AS ti4_nulo, count(*) FILTER (bright_ti5 IS NULL) AS ti5_nulo,
       round(min(peso), 2) AS peso_min, round(median(peso), 2) AS peso_mediana, round(max(peso), 2) AS peso_max
FROM armonizado;

.print '== Resumen por año (vegetación): focos MODIS y focos armonizados (escala VIIRS) =='
SELECT anio, any_value(modo) FILTER (modo = 'solo_terra') AS modo_parcial,
       count(*) AS focos_modis, round(sum(peso))::BIGINT AS focos_armonizados,
       round(sum(peso) / count(*), 2) AS peso_medio,
       round(100 * sum(peso) FILTER (confidence = 'l') / sum(peso), 1) AS pct_l,
       round(100 * sum(peso) FILTER (confidence = 'h') / sum(peso), 1) AS pct_h,
       round(median(frp_modis), 1) AS frp_mediana_modis, round(median(frp), 1) AS frp_mediana_viirs
FROM armonizado WHERE type = 0 GROUP BY anio ORDER BY anio;

.print '== Escribiendo datos_armonizados/ =='

COPY (SELECT * FROM armonizado ORDER BY acq_date, acq_time, latitude, longitude)
TO 'datos_armonizados' (FORMAT csv, HEADER, PARTITION_BY (anio),
                        FILENAME_PATTERN 'modis_armonizado_India_{i}', OVERWRITE_OR_IGNORE);

COPY (SELECT * FROM armonizado ORDER BY acq_date, acq_time, latitude, longitude)
TO 'datos_armonizados' (FORMAT parquet, PARTITION_BY (anio),
                        FILENAME_PATTERN 'modis_armonizado_India_{i}', OVERWRITE_OR_IGNORE);

.print '== Listo =='
