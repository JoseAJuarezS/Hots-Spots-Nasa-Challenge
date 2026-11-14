# Serie armonizada 2000–2025

Siguiente paso de [`correlacion-modis-viirs.md`](correlacion-modis-viirs.md): construir la serie mensual de focos en una **escala común, la de VIIRS S-NPP**, y comprobar que desaparece el salto de 2012.

## Cómo reproducirlo

```bash
mise run datos:cargar       # si aún no existe analisis/focos.duckdb
mise run datos:armonizar    # ejecuta 04_armonizar.sql
```

Los CSV se pueden descargar de `https://firms.modaps.eosdis.nasa.gov/data/country/<sensor>/<año>/<sensor>_<año>_India.csv` (sensor: `modis`, `viirs-snpp`, `viirs-jpss1`) a la carpeta `../data de prueba/`.

`04_armonizar.sql` crea tres tablas en `focos.duckdb`:

| Tabla | Contenido |
|---|---|
| `k_mes` | Constante por mes del año (todo MODIS y solo Terra), calibrada con 2012-02 a 2018-12, y su rango intercuartil |
| `focos_armonizados` | Un registro por foco con su `peso`. Los focos armonizados de cualquier área son `sum(peso)` |
| `serie_mensual` | Conteos brutos por sensor, la serie armonizada y MODIS×k (para validar) |

## Regla de armonización

Mismos filtros que antes: `type = 0`, MODIS con `confidence >= 30` y VIIRS con `n`/`h`.

| Periodo | Fuente | Peso de cada foco |
|---|---|---|
| 2000-11 a 2002-07 | Solo Terra | k_terra del mes del año |
| 2002-08 a 2012-01 | Todo MODIS (Terra + Aqua) | k_modis del mes del año |
| 2012-02 en adelante | VIIRS S-NPP observado | 1 |

- Julio de 2002 se trata como "solo Terra", porque Aqua empieza el 4 de julio y ese mes está incompleto.
- Se armoniza **por foco y no por total**, para que la app pueda sumar cualquier polígono sin recalcular nada.

## Resultado: desaparece el salto de 2012

Media anual de 2012–2014 dividida entre la de 2009–2011:

| Serie | Razón |
|---|---:|
| MODIS bruto (referencia: sin cambio de sensor) | 1,00 |
| Empalme crudo (MODIS hasta 2011, VIIRS después) | **5,36** |
| **Serie armonizada** | **0,96** |

Totales anuales de la serie armonizada:

| Año | 2001* | 2003 | 2005 | 2007 | 2009 | 2011 | 2012 | 2013 | 2015 | 2017 | 2019 | 2021 | 2023 | 2025 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Focos (miles) | 352 | 296 | 334 | 391 | 481 | 375 | 454 | 359 | 351 | 435 | 378 | 582 | 409 | 460 |

\* A partir de Terra solamente; es menos preciso.

## Validación

**MODIS×k frente a VIIRS observado, por mes:**

| Tramo | Meses | r | Sesgo | Error mediano | RMSE |
|---|---:|---:|---:|---:|---:|
| 2012–2018 (calibración) | 83 | 0,991 | 0,0 % | 8,1 % | 4 983 focos |
| 2019–2025 (prueba) | 84 | 0,987 | +2,7 % | 10,3 % | 6 655 focos |

**Tramo con solo Terra (2000–2002).** No se puede validar contra VIIRS. Lo que sí se puede hacer es comprobar que Terra×k_terra reproduce MODIS×k en **2003–2011**, años que no se usaron para calibrar:

| Comparación | Meses | r | Sesgo | Error mediano |
|---|---:|---:|---:|---:|
| Terra×k_terra frente a MODIS×k, 2003–2011 | 108 | 0,947 | +2,8 % | 11,8 % |

- En totales anuales, la diferencia está entre −6 % y +11 %.
- La proporción de focos que aporta Terra es estable (24–30 % entre 2003 y 2025).
- Por tanto, el valor alto de 2001 parece real y no un error del método.
- Aun así, la app debería marcar 2000–2002 como de **menor precisión**.

## Pendiente

1. Gráfico de la serie mensual (bruto frente a armonizado) para el informe.
2. Exportar `focos_armonizados` a Parquet o a rejilla y mes, para servirlo en la app.
3. Mostrar la incertidumbre en el calendario: una banda a partir de `k_modis_p25`/`p75` y una marca para 2000–2002.
4. Repetir con la región objetivo de la app.
