---
name: csv-data-wrangler
description: Procesa, limpia, valida y armoniza CSV grandes con DuckDB, Python (pandas/polars) y herramientas de línea de comandos. Úsala al trabajar con los CSV de FIRMS (MODIS, VIIRS S-NPP, NOAA-20/21), al unir archivos con esquemas distintos, al llevar sensores a una escala común, al resolver problemas de codificación, delimitadores o tipos, o al exportar CSV/Parquet precalculados para la app.
---

# CSV Data Wrangler

Basada en la skill pública `csv-data-wrangler` (claude-supercode-skills) y adaptada a este proyecto: armonizar los focos de calor de MODIS y VIIRS para construir un calendario de quemas consistente de 2000 a hoy.

## Cuándo usarla

- Cargar, unir o filtrar los CSV anuales de FIRMS (`modis_*`, `viirs-snpp_*`, `viirs-jpss1_*`).
- Unificar esquemas distintos en una tabla común (columnas, tipos, códigos).
- Limpiar datos: nulos, tipos mezclados, fechas, duplicados, filas mal formadas.
- Armonizar MODIS → escala VIIRS y validar la serie resultante.
- Exportar agregados (CSV o Parquet) que consume el frontend.

**No usarla para:** hojas Excel con formato (skill `xlsx`), gráficos (skill `dataviz`) ni código de la app web.

## Elegir herramienta

```
Por tamaño del archivo:
├── < 100 MB      → pandas
├── 100 MB - 1 GB → polars o pandas por bloques
├── > 1 GB        → DuckDB (preferido en este repo)
└── Exploración rápida → duckdb -c "DESCRIBE/SUMMARIZE ..." o csvkit/xsv

Por tipo de trabajo:
├── Uniones, filtros, agregados → DuckDB (SQL)
├── Transformaciones complejas  → polars / pandas
└── Streaming fila a fila        → módulo csv de Python
```

En este repo **DuckDB es la herramienta por defecto**: está en `mise.toml`, los scripts viven en `analisis/*.sql` y se ejecutan con tareas de mise (`mise run datos:cargar`, `mise run datos:correlacion`). Los nuevos pasos deben seguir ese patrón: un `.sql` numerado en `analisis/` y una tarea en `mise.toml`.

## Flujos de trabajo

### 1. Perfilar antes de tocar nada

```sql
-- Esquema inferido, sin cargar el archivo
DESCRIBE SELECT * FROM read_csv('ruta/archivo.csv');
-- Estadísticas por columna: nulos, mín/máx, valores distintos
SUMMARIZE SELECT * FROM read_csv('ruta/archivo.csv');
-- Comparar esquemas de varios archivos
SELECT * FROM sniff_csv('ruta/archivo.csv');
```

Revisa: codificación, delimitador, cabecera, columnas que cambian de tipo entre años y número de filas por archivo.

### 2. Cargar y unificar esquemas

- Usa `read_csv('patron_*.csv', union_by_name = true)` para unir años cuyas columnas cambian de orden o de nombre.
- Fija con `types = {...}` las columnas cuyo tipo varía: aquí `acq_time` (se pierde el cero inicial si se lee como número) y `confidence` (numérica en MODIS, letra en VIIRS) se leen como `VARCHAR`.
- Añade una columna `sensor` explícita al unir fuentes; no la deduzcas después del nombre del archivo.
- Guarda el resultado en una tabla DuckDB (`analisis/*.duckdb`, ignorado por git), nunca sobrescribas los CSV originales.

### 3. Limpiar

1. Define reglas por columna y documéntalas como comentarios en el `.sql`.
2. Usa `TRY_CAST` en lugar de `CAST` cuando una columna puede traer basura; cuenta cuántas filas quedan en `NULL`.
3. Elimina duplicados exactos (`SELECT DISTINCT` o `QUALIFY row_number() OVER (...) = 1`).
4. Registra cuántas filas entran y salen de cada filtro.

### 4. Armonizar MODIS y VIIRS

Diferencias de esquema que hay que resolver:

| Campo | MODIS | VIIRS 375 m | Regla común |
|---|---|---|---|
| `confidence` | 0–100 | `l` / `n` / `h` | MODIS `>= 30` ≈ VIIRS `n` o `h` |
| Brillo | `brightness`, `bright_t31` | `bright_ti4`, `bright_ti5` | No mezclar; quedarse con `frp` si hace falta intensidad |
| `satellite` | `Terra`, `Aqua` | `N`, `N20` (y `N21`) | Columna `sensor` propia |
| `type` | 0 / 2 / 3 | 0 / 2 / 3 | Calendario de quemas: `type = 0` |
| `acq_time` | `HHMM` | `HHMM` | Leer como texto |

Método validado en `analisis/correlacion-modis-viirs.md`:

1. Aplicar los mismos filtros a los dos sensores (`type = 0` y umbrales de `confidence`).
2. Contar focos por mes en el periodo de solape (2012-02 en adelante).
3. Calibrar **una constante k por mes del año** (VIIRS ≈ k · MODIS, con todo MODIS: Terra + Aqua) en un tramo de años y **validar en otro tramo no visto**.
4. Reportar correlación (r), sesgo total (%) y error mediano mensual (%).
5. Aplicar k a MODIS antes de 2012 y comprobar que la serie no salta en 2012.

Cuidados:

- Años incompletos: 2000 solo tiene nov–dic y Aqua entra en julio de 2002; no los uses para calibrar.
- NOAA-20 empieza en abril de 2018: no sumes S-NPP y NOAA-20 como si fueran un sensor más; trata cada satélite VIIRS por separado o elige uno de referencia.
- La versión de MODIS cambia (6.2 → 6.03 en 2018): compara k antes y después antes de asumir que es estable.
- Si se cambia de región, recalibra k: no se puede reutilizar la de India.

### 5. Exportar para la app

```sql
COPY (SELECT ...) TO 'salida/focos_mensuales.parquet' (FORMAT parquet, COMPRESSION zstd);
COPY (SELECT ...) TO 'salida/focos_mensuales.csv' (HEADER, DELIMITER ',');
```

Prefiere Parquet para lo que lee la app y CSV para lo que descarga el usuario. Ordena por fecha y celda para que las consultas por área sean rápidas.

## Buenas prácticas

- Perfila antes de elegir herramienta o escribir filtros.
- Indica la codificación de forma explícita si no es UTF-8 (`encoding = 'latin-1'`).
- Conserva los originales y escribe siempre en archivos o tablas nuevas.
- Valida el número de filas antes y después de cada paso.
- Deja cada análisis como un `.sql` reproducible con su tarea de mise, no solo en la consola.
- Documenta las decisiones y resultados en un `.md` junto al análisis.

## Errores comunes

| Error | Problema | Qué hacer |
|---|---|---|
| Cargar todo en pandas | Memoria insuficiente con cientos de MB | DuckDB o lectura por bloques |
| Adivinar la codificación | Caracteres corruptos | Detectarla (`sniff_csv`, `chardet`) |
| Partir líneas a mano con `split(',')` | Rompe con comillas y escapes | Usar un parser de CSV |
| Dejar que `acq_time` sea número | `0130` pasa a `130` | Leerlo como `VARCHAR` |
| Comparar MODIS y VIIRS sin filtros comunes | k sesgada | Mismos `type` y umbral de `confidence` |
| Calibrar y validar con los mismos años | Métricas optimistas | Separar años de calibración y de prueba |
| No validar conteos | Corrupción silenciosa | Comparar filas y totales por paso |
