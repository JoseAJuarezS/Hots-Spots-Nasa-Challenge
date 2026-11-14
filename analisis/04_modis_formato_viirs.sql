-- Traduce `confidence` y `frp` de los CSV de MODIS a la escala de VIIRS 375 m.
-- Uso (desde la raíz del repo):  duckdb -no-agent < analisis/04_modis_formato_viirs.sql
--
-- Entradas:  datos_crudos/MODIS/modis_*_India.csv, datos_crudos/VIIRS/viirs-*_India.csv
-- Salidas:   datos_procesados/modis_formato_viirs_India.csv   (todas las filas de MODIS)
--            datos_procesados/calibracion_confidence.csv      (umbrales encontrados)
--            datos_procesados/calibracion_frp.csv             (tabla de cuantiles MODIS -> VIIRS)
--
-- Método: emparejamiento de cuantiles en el periodo en que ambos sensores observan.
--   * Calibración: solo días con datos de MODIS y de VIIRS, solo vegetación (type = 0),
--     y por separado para día y noche (las distribuciones son muy distintas).
--   * confidence: se buscan dos umbrales sobre la confianza numérica de MODIS para que la
--     proporción de focos l / n / h sea la misma que en VIIRS:
--         conf <  umbral_bajo            -> 'l'
--         umbral_bajo <= conf < umbral_alto -> 'n'
--         conf >= umbral_alto            -> 'h'
--     Como referencia se muestran también las clases oficiales de MODIS (<30, 30-79, >=80).
--   * frp: a cada valor de MODIS se le asigna el valor de VIIRS que ocupa el mismo percentil
--     (1001 cuantiles, interpolación lineal entre ellos). Por encima del máximo o por debajo
--     del mínimo calibrado se escala con la razón VIIRS/MODIS del extremo.
--     Ojo: esto convierte cada foco MODIS en un "foco típico de VIIRS"; no conserva la suma
--     total de FRP de un área (VIIRS reparte el mismo fuego en más píxeles más pequeños).
--   Se conservan los valores originales en `confidence_modis` y `frp_modis`.

.print '== Cargando CSV =='

CREATE OR REPLACE TEMP TABLE modis AS
SELECT *
FROM read_csv('datos_crudos/MODIS/modis_*_India.csv', union_by_name = true,
              types = {'acq_time': 'VARCHAR', 'confidence': 'INTEGER', 'frp': 'DOUBLE'});

CREATE OR REPLACE TEMP TABLE viirs AS
SELECT acq_date, daynight, type, confidence, frp
FROM read_csv('datos_crudos/VIIRS/viirs-*_India.csv', union_by_name = true,
              types = {'acq_time': 'VARCHAR', 'confidence': 'VARCHAR', 'frp': 'DOUBLE'});

-- Muestras de calibración: días comunes, solo vegetación
CREATE OR REPLACE TEMP TABLE dias_comunes AS
SELECT DISTINCT acq_date FROM modis
INTERSECT
SELECT DISTINCT acq_date FROM viirs;

CREATE OR REPLACE TEMP TABLE modis_cal AS
SELECT daynight, confidence, frp FROM modis
WHERE type = 0 AND acq_date IN (SELECT acq_date FROM dias_comunes);

CREATE OR REPLACE TEMP TABLE viirs_cal AS
SELECT daynight, confidence, frp FROM viirs
WHERE type = 0 AND acq_date IN (SELECT acq_date FROM dias_comunes);

.print '== Muestras de calibración =='
SELECT (SELECT min(acq_date) FROM dias_comunes) AS desde,
       (SELECT max(acq_date) FROM dias_comunes) AS hasta,
       (SELECT count(*) FROM dias_comunes)      AS dias,
       (SELECT count(*) FROM modis_cal)         AS focos_modis,
       (SELECT count(*) FROM viirs_cal)         AS focos_viirs;

-- ---------------------------------------------------------------------------
-- 1) CONFIDENCE: umbrales por emparejamiento de proporciones
-- ---------------------------------------------------------------------------

CREATE OR REPLACE TEMP TABLE prop_viirs AS
SELECT daynight,
       avg((confidence = 'l')::INT) AS p_l,
       avg((confidence = 'h')::INT) AS p_h
FROM viirs_cal GROUP BY daynight;

-- Distribución acumulada de la confianza de MODIS: f_menor = P(conf < c)
CREATE OR REPLACE TEMP TABLE ecdf_modis AS
SELECT daynight, confidence AS c,
       (sum(count(*)) OVER w - count(*)) / sum(count(*)) OVER (PARTITION BY daynight) AS f_menor
FROM modis_cal
GROUP BY daynight, confidence
WINDOW w AS (PARTITION BY daynight ORDER BY confidence);

-- Umbral bajo: P(conf < t) ≈ p_l ; umbral alto: P(conf >= t) ≈ p_h
CREATE OR REPLACE TEMP TABLE umbrales AS
SELECT e.daynight,
       arg_min(e.c, abs(e.f_menor - p.p_l))       AS umbral_bajo,
       arg_min(e.c, abs((1 - e.f_menor) - p.p_h)) AS umbral_alto
FROM ecdf_modis e JOIN prop_viirs p USING (daynight)
GROUP BY e.daynight;

.print '== Umbrales de confidence (MODIS 0-100 -> VIIRS l/n/h) =='
SELECT u.daynight, u.umbral_bajo, u.umbral_alto,
       round(100 * p.p_l, 1)                                   AS viirs_pct_l,
       round(100 * avg((m.confidence <  u.umbral_bajo)::INT), 1) AS modis_pct_l,
       round(100 * (1 - p.p_l - p.p_h), 1)                     AS viirs_pct_n,
       round(100 * avg((m.confidence >= u.umbral_bajo AND m.confidence < u.umbral_alto)::INT), 1) AS modis_pct_n,
       round(100 * p.p_h, 1)                                   AS viirs_pct_h,
       round(100 * avg((m.confidence >= u.umbral_alto)::INT), 1) AS modis_pct_h,
       -- Referencia: clases oficiales de MODIS (<30 bajo, 30-79 nominal, >=80 alto)
       round(100 * avg((m.confidence < 30)::INT), 1)           AS oficial_pct_l,
       round(100 * avg((m.confidence >= 80)::INT), 1)          AS oficial_pct_h
FROM umbrales u
JOIN prop_viirs p USING (daynight)
JOIN modis_cal m USING (daynight)
GROUP BY ALL ORDER BY u.daynight;

-- ---------------------------------------------------------------------------
-- 2) FRP: emparejamiento de cuantiles
-- ---------------------------------------------------------------------------

CREATE OR REPLACE TEMP TABLE cuantiles_frp AS
WITH qm AS (
  SELECT daynight, quantile_cont(frp, [i / 1000 FOR i IN range(0, 1001)]) AS q
  FROM modis_cal WHERE frp IS NOT NULL GROUP BY daynight
), qv AS (
  SELECT daynight, quantile_cont(frp, [i / 1000 FOR i IN range(0, 1001)]) AS q
  FROM viirs_cal WHERE frp IS NOT NULL GROUP BY daynight
)
SELECT qm.daynight, (i - 1) / 1000 AS percentil, qm.q[i] AS frp_modis, qv.q[i] AS frp_viirs
FROM qm JOIN qv USING (daynight), range(1, 1002) t(i);

-- Puntos de la curva de transferencia (un valor de VIIRS por cada valor distinto de MODIS)
-- con el siguiente punto para interpolar linealmente.
CREATE OR REPLACE TEMP TABLE curva_frp AS
SELECT daynight, x0, y0,
       lead(x0) OVER w AS x1, lead(y0) OVER w AS y1,
       first_value(y0 / nullif(x0, 0)) OVER (PARTITION BY daynight ORDER BY x0 DESC) AS razon_max
FROM (SELECT daynight, frp_modis AS x0, avg(frp_viirs) AS y0
      FROM cuantiles_frp GROUP BY ALL)
WINDOW w AS (PARTITION BY daynight ORDER BY x0);

CREATE OR REPLACE TEMP TABLE razon_min AS
SELECT daynight, arg_min(y0 / nullif(x0, 0), x0) FILTER (x0 > 0) AS razon_min
FROM curva_frp GROUP BY daynight;

.print '== FRP: algunos percentiles (MW) =='
SELECT daynight, percentil, frp_modis, frp_viirs
FROM cuantiles_frp
WHERE percentil IN (0.01, 0.1, 0.25, 0.5, 0.75, 0.9, 0.99)
ORDER BY daynight, percentil;

-- ---------------------------------------------------------------------------
-- 3) Aplicar a todos los focos de MODIS y exportar
-- ---------------------------------------------------------------------------

CREATE OR REPLACE TEMP TABLE modis_viirs AS
SELECT m.*,
       CASE WHEN m.confidence <  u.umbral_bajo THEN 'l'
            WHEN m.confidence >= u.umbral_alto THEN 'h'
            ELSE 'n' END AS conf_viirs,
       CASE WHEN m.frp IS NULL THEN NULL
            WHEN c.x0 IS NULL  THEN m.frp * r.razon_min                       -- bajo el mínimo
            WHEN c.x1 IS NULL  THEN m.frp * c.razon_max                       -- sobre el máximo
            ELSE c.y0 + (m.frp - c.x0) * (c.y1 - c.y0) / (c.x1 - c.x0) END AS frp_viirs
FROM modis m
LEFT JOIN umbrales u USING (daynight)
LEFT JOIN razon_min r USING (daynight)
ASOF LEFT JOIN curva_frp c ON m.daynight = c.daynight AND m.frp >= c.x0;

.print '== Resultado: clases de confidence por año y FRP mediano =='
SELECT year(acq_date) AS anio, count(*) AS focos,
       count(*) FILTER (conf_viirs = 'l') AS l,
       count(*) FILTER (conf_viirs = 'n') AS n,
       count(*) FILTER (conf_viirs = 'h') AS h,
       round(median(frp), 1)       AS frp_modis_mediana,
       round(median(frp_viirs), 1) AS frp_viirs_mediana
FROM modis_viirs GROUP BY ALL ORDER BY anio;

.shell mkdir -p datos_procesados

COPY (
  SELECT latitude, longitude, brightness, scan, track, acq_date, acq_time, satellite, instrument,
         conf_viirs AS confidence, version, bright_t31, round(frp_viirs, 2) AS frp, daynight, type,
         confidence AS confidence_modis, frp AS frp_modis
  FROM modis_viirs ORDER BY acq_date, acq_time, latitude, longitude
) TO 'datos_procesados/modis_formato_viirs_India.csv' (HEADER);

COPY (
  SELECT u.*, round(p.p_l, 4) AS viirs_prop_l, round(p.p_h, 4) AS viirs_prop_h
  FROM umbrales u JOIN prop_viirs p USING (daynight) ORDER BY daynight
) TO 'datos_procesados/calibracion_confidence.csv' (HEADER);

COPY (SELECT * FROM cuantiles_frp ORDER BY daynight, percentil)
TO 'datos_procesados/calibracion_frp.csv' (HEADER);

.print '== Listo: datos_procesados/modis_formato_viirs_India.csv =='
