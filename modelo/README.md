# Red neuronal para predecir actividad de incendios

Predice, para cada celda de 0,25° (~28 km) de India, la **actividad de quema del mes siguiente** a partir de los focos de los 24 meses anteriores.

- **Entrenamiento:** solo con MODIS, de 2000 a 2017, armonizado a la escala de VIIRS.
- **Validación:** con VIIRS S-NPP, de 2018 al último mes disponible (hoy 2025-12). Si se añaden los CSV de 2026, se incluyen automáticamente.

## Cómo ejecutarlo

PyTorch todavía no publica paquetes para Python 3.15, así que este subproyecto usa **Python 3.14** (`modelo/.python-version`).

```bash
mise run modelo:datos      # construye la rejilla (~20 s, queda en modelo/cache/)
mise run modelo:entrenar   # entrena, valida con VIIRS y guarda en modelo/salidas/
# o, desde modelo/:  uv run python entrenar.py --epocas 5   (prueba rápida)
```

Requisito: `datos_crudos/MODIS` tiene que estar convertido a `confidence` l/n/h y a FRP en escala VIIRS con `analisis/05_confidence_modis_a_viirs.py`.

| Salida | Contenido |
|---|---|
| `salidas/metricas.json` | Métricas de la validación interna (MODIS) y de la prueba con VIIRS, referencias simples y resultados por año |
| `salidas/validacion_mensual.csv` | Total mensual de India: VIIRS observado frente a la red, la persistencia y la climatología |
| `salidas/predicciones_viirs.csv` | Predicción por celda y mes en 2018–2025, junto con lo observado |
| `salidas/pronostico_<mes>.csv` | Pronóstico del mes siguiente al último dato (hoy 2026-01) |
| `salidas/modelo.pt` | Pesos, normalización, celdas, climatología, k, umbral de decisión |

## Qué predice

Cada muestra es una **celda en un mes objetivo *t***. La red da dos salidas:

1. **¿Habrá actividad de quema?** Es la probabilidad de que la celda tenga ≥ 10 focos en escala VIIRS en el mes *t* (`--umbral`).
2. **¿Cuánta?** Es el valor esperado de `log(1 + focos)` en el mes *t*.

Se usan **celdas y meses**, no focos individuales ni días, por tres razones:

- La armonización entre MODIS y VIIRS solo es fiable para **conteos mensuales**: la constante k se calibró por mes, y a escala diaria el error crece mucho (ver `analisis/correlacion-modis-viirs.md`).
- Es la misma unidad que usa el calendario de la app.
- Un foco aislado no se puede predecir, pero un patrón celda-mes sí: las quemas agrícolas y forestales se repiten cada año.

**¿Por qué un umbral y no "al menos 1 foco"?** Un foco de MODIS equivale a unos 7 de VIIRS. "Al menos 1 foco" significaría cosas distintas para cada sensor: en una celda con 3 focos pequeños, VIIRS diría "hay fuego" y MODIS, que no los ve, "no hay". Exigir 10 focos equivalentes (aprox. 2 focos MODIS) hace que la etiqueta signifique lo mismo en los dos sensores.

## Cómo se resuelve el cambio de sensor (MODIS → VIIRS)

Es el punto clave del diseño: si la red aprende con MODIS y se evalúa con VIIRS, **todo lo que ve tiene que estar en la misma escala**. Si no, en 2018 recibiría entradas unas 7 veces mayores que las que vio en el entrenamiento.

1. **Conteos:** `focos_MODIS × k[mes del año]` (k_terra antes de 2002-08). Las k se calibran **solo con el solape 2012-02 … 2017-12**, así que no se usa ningún dato de VIIRS de 2018 en adelante. En 2018–2025, MODIS armonizado / VIIRS = **1,035**.
2. **Variables por foco:** `confidence` y FRP ya están emparejados por cuantiles con VIIRS (script 05). La red usa **fracciones y medias** (FRP medio, % de confianza alta, % nocturno), que no dependen de cuántos focos detecte cada sensor.
3. **Aumento de datos de escala:** en cada muestra de entrenamiento, los conteos de la entrada y del objetivo se multiplican por un factor aleatorio `exp(N(0; 0,15))`, de ±15 %. Así la red aprende relaciones **relativas** ("este mes viene más fuerte que el anterior") y no depende del nivel absoluto, que es justo lo que puede fallar al cambiar de sensor. El ±15 % es del orden del error de k (10–14 %).
4. **Normal histórica fija:** la climatología de cada celda se calcula con MODIS hasta 2015 y se usa igual en la prueba. Es lo que haría la app: comparar con lo "normal".

## Arquitectura

```
 secuencia: 24 meses × 8 canales                 contexto del mes objetivo (6)
 ┌──────────────────────────────┐                ┌───────────────────────────────┐
 │ log focos celda              │                │ sin/cos del mes               │
 │ log focos vecinas 3×3        │                │ lat, lon                      │
 │ log focos región 9×9 (~2,25°)│                │ normal histórica: log focos   │
 │ log FRP medio, % alta, % noche│               │ y % de años con actividad     │
 │ sin/cos del mes              │                └──────────────┬────────────────┘
 └──────────────┬───────────────┘                               │
       Conv1d(8→32, k=3) + GELU                         Linear(6→32) + GELU
       Conv1d(32→32, k=3) + GELU                                │
       GRU(32→64), último estado ───────────┐                   │
                                            ▼                   ▼
                              concat(64+32) → Linear 128 → GELU → Dropout 0,2 → Linear 64 → GELU
                                            │                                   │
                              cabeza 1: logit P(actividad)        cabeza 2: softplus → log(1+focos)
```

Unos 44 000 parámetros. Pérdida: `BCE(pos_weight = √(neg/pos)) + Huber(log focos)`. Optimizador AdamW, lr 2·10⁻³ con ReduceLROnPlateau y parada temprana.

### Por qué este diseño

| Decisión | Motivo |
|---|---|
| **Ventana de 24 meses** | El fuego en India es muy **estacional**: quema de rastrojo en Punjab en oct–nov y abr–may, y temporada forestal en el centro y el noreste en feb–may. Con 24 meses la red ve **dos veces** el mismo mes del año anterior y puede distinguir un patrón que se repite de un pico aislado. |
| **Conv1d antes del GRU** | Las convoluciones detectan patrones cortos, de 2 a 3 meses: subidas, el pico de la estación o una caída por el monzón. Al GRU le llega una secuencia ya "resumida" y le cuesta menos aprender. |
| **GRU y no LSTM ni Transformer** | Las secuencias son cortas (24 pasos) y hay pocos datos independientes (unas 4 600 celdas × 13 años). Un GRU tiene menos parámetros que un LSTM y rinde igual en secuencias cortas. Un Transformer necesitaría muchos más datos para no sobreajustar y no aporta nada con 24 pasos. |
| **Vecindad como canales (3×3 y 9×9) y no una ConvLSTM sobre el mapa** | El fuego se propaga y las prácticas agrícolas son regionales, así que el contexto espacial importa. Una ConvLSTM sobre toda la rejilla tendría solo unas 200 "imágenes" de entrenamiento, una por mes, y la mayoría de sus píxeles estarían vacíos. Calcular las medias vecinas de antemano da el mismo contexto con una red pequeña, y cada celda y mes cuenta como muestra (unas 700 000). |
| **Rama de contexto separada** | La información sobre el **mes que se predice** (época del año, lugar, normal histórica) no forma parte de la secuencia pasada. Si entra aparte, la red puede aprender cosas como "en esta celda, noviembre siempre es alto". |
| **Dos cabezas** | Responden las dos preguntas del usuario: *¿habrá fuego?* y *¿cuánto?*. Compartir el tronco funciona como regularización: las dos tareas usan la misma representación. |
| **Pérdida en log y Huber** | Los conteos tienen colas enormes: casi todas las celdas tienen 0 focos y unas pocas de Punjab tienen miles. En escala log no dominan unas pocas celdas, y Huber es robusto ante meses atípicos. |
| **`pos_weight = √(neg/pos)`** | Solo hay actividad en el 12–13 % de las muestras. Con la raíz se compensa el desbalance sin disparar los falsos positivos. |
| **Partición estrictamente temporal** | Se ajusta con 2002–2015 y se valida internamente con **MODIS 2016–2017**: esa partición elige la época, el umbral de decisión y el factor para sumar totales. **VIIRS 2018+ solo se usa para medir**: no se toca ni para la parada temprana. |

### Referencias que la red tiene que superar (VIIRS 2018–2025)

Con la red pequeña es fácil sobreajustar, así que se compara contra dos referencias simples:

| Referencia | AUC-ROC | Precisión promedio |
|---|---:|---:|
| Persistencia: mismo mes del año anterior | 0,911 | 0,687 |
| Climatología de MODIS 2000–2015 | 0,873 | 0,634 |

La red solo es útil si las supera. Lo interesante es **el aumento en la precisión promedio** y en los años anómalos, como 2021, en los que la persistencia falla.

## Limitaciones

- **Solo usa la historia de focos.** No ve clima, sequía ni vegetación. Añadir variables de ERA5 (temperatura, humedad, viento), NDVI o el índice de sequía debería mejorar mucho los años anómalos, y la arquitectura lo permite: basta con más canales en la secuencia o en el contexto.
- La armonización es de India en conjunto. Las k no se recalculan por región.
- Las celdas que solo tienen focos de VIIRS (fuegos pequeños que MODIS nunca vio) aparecen en el conjunto de celdas, pero en el entrenamiento casi siempre tienen 0 focos. Ahí la red tenderá a quedarse corta.
- 2000–2002 (solo Terra) tiene más error de armonización (≈18 %).
