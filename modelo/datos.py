"""Prepara los focos de calor para la red neuronal.

Convierte los CSV de FIRMS en una rejilla regular (celdas de `res` grados) por mes y
lleva MODIS a la escala de VIIRS S-NPP, igual que en analisis/04_armonizar.sql:

    focos_armonizados(celda, mes) = focos_MODIS(celda, mes) * k[mes del año]

Las constantes k se calibran SOLO con el solape 2012-02 .. 2017-12, para no tocar los
datos de VIIRS de 2018 en adelante, que son la validación.

Requisito: los CSV de datos_crudos/MODIS deben estar ya convertidos a confidence l/n/h
y FRP en escala VIIRS (analisis/05_confidence_modis_a_viirs.py).
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

import duckdb
import numpy as np

RAIZ = Path(__file__).resolve().parent.parent
DIR_DATOS = RAIZ / "datos_crudos"
DIR_CACHE = Path(__file__).resolve().parent / "cache"

# Caja que contiene a India
LAT_MIN, LAT_MAX = 6.0, 38.0
LON_MIN, LON_MAX = 68.0, 98.0

ANIO_BASE = 2000  # t = 0 es enero de 2000


def mes_a_t(anio: int, mes: int) -> int:
    return (anio - ANIO_BASE) * 12 + (mes - 1)


def t_a_texto(t: int) -> str:
    return f"{ANIO_BASE + t // 12}-{t % 12 + 1:02d}"


INICIO_TERRA_AQUA = mes_a_t(2002, 8)  # antes de esto solo hay Terra completo
CALIB_DESDE = mes_a_t(2012, 2)        # primer mes completo de VIIRS S-NPP
CALIB_HASTA = mes_a_t(2017, 12)       # VIIRS >= 2018 queda reservado para validar

# Canales de la secuencia de entrada (uno por mes de la ventana)
CANALES = [
    "log_focos",         # log(1 + focos armonizados en la celda)
    "log_vecinos_3x3",   # log(1 + media de focos en la celda y sus 8 vecinas)
    "log_region_9x9",    # log(1 + media de focos en un entorno de ~2,25°)
    "log_frp_medio",     # log(1 + FRP medio por foco, MW)
    "frac_alta",         # fracción de focos con confidence 'h'
    "frac_noche",        # fracción de focos nocturnos
    "mes_sin",           # estacionalidad del mes de ese paso
    "mes_cos",
]
CANALES_CONTEO = [0, 1, 2]  # los que dependen de la escala del sensor


@dataclass
class Serie:
    """Una fuente (MODIS armonizado o VIIRS) en rejilla, arrays (T, NY, NX)."""

    nombre: str
    conteo: np.ndarray       # focos en escala VIIRS S-NPP
    frp_medio: np.ndarray
    frac_alta: np.ndarray
    frac_noche: np.ndarray
    t_desde: int             # primer y último mes con datos (inclusive)
    t_hasta: int


@dataclass
class Rejilla:
    res: float
    ny: int
    nx: int
    t_total: int             # incluye un mes extra vacío para el pronóstico
    modis: Serie
    viirs: Serie
    k_modis: np.ndarray      # (12,)
    k_terra: np.ndarray      # (12,)


# ---------------------------------------------------------------------------
# Lectura con DuckDB
# ---------------------------------------------------------------------------

def _consulta(patron: Path, res: float) -> str:
    return f"""
    SELECT (year(acq_date) - {ANIO_BASE}) * 12 + month(acq_date) - 1 AS t,
           CAST(floor((latitude  - {LAT_MIN}) / {res}) AS INTEGER) AS iy,
           CAST(floor((longitude - {LON_MIN}) / {res}) AS INTEGER) AS ix,
           count(*)                                             AS n,
           count(*) FILTER (WHERE satellite = 'Terra')          AS n_terra,
           count(*) FILTER (WHERE lower(confidence) = 'h')      AS n_h,
           count(*) FILTER (WHERE daynight = 'N')               AS n_noche,
           coalesce(sum(frp), 0)                                AS frp
    FROM read_csv('{patron.as_posix()}', union_by_name = true, header = true,
                  types = {{'confidence': 'VARCHAR', 'acq_time': 'VARCHAR',
                           'frp': 'DOUBLE', 'type': 'INTEGER', 'acq_date': 'DATE',
                           'satellite': 'VARCHAR'}})
    WHERE type = 0
      AND lower(confidence) IN ('n', 'h')
      AND latitude  >= {LAT_MIN} AND latitude  < {LAT_MAX}
      AND longitude >= {LON_MIN} AND longitude < {LON_MAX}
    GROUP BY ALL
    """


def _comprobar_modis_convertido(con: duckdb.DuckDBPyConnection, patron: Path) -> None:
    malos = con.execute(f"""
        SELECT count(*) FROM read_csv('{patron.as_posix()}', union_by_name = true,
                                      types = {{'confidence': 'VARCHAR'}})
        WHERE lower(confidence) NOT IN ('l', 'n', 'h')
    """).fetchone()[0]
    if malos:
        raise SystemExit(
            f"Hay {malos} focos MODIS con confidence numérica. Ejecuta antes "
            "analisis/05_confidence_modis_a_viirs.py para pasarlos a la escala VIIRS."
        )


def _leer_crudo(res: float) -> dict[str, np.ndarray]:
    patron_modis = DIR_DATOS / "MODIS" / "modis_*_India.csv"
    patron_viirs = DIR_DATOS / "VIIRS" / "viirs-snpp_*_India.csv"
    con = duckdb.connect()
    _comprobar_modis_convertido(con, patron_modis)
    print("Leyendo MODIS ...", flush=True)
    m = con.execute(_consulta(patron_modis, res)).fetchnumpy()
    print("Leyendo VIIRS S-NPP ...", flush=True)
    v = con.execute(_consulta(patron_viirs, res)).fetchnumpy()

    ny = int(round((LAT_MAX - LAT_MIN) / res))
    nx = int(round((LON_MAX - LON_MIN) / res))
    t_total = int(max(m["t"].max(), v["t"].max())) + 2  # +1 mes para pronosticar

    salida: dict[str, np.ndarray] = {"meta": np.array([res, ny, nx, t_total])}
    for prefijo, d in (("modis", m), ("viirs", v)):
        t, iy, ix = (np.asarray(d[c], dtype=np.int64) for c in ("t", "iy", "ix"))
        for col in ("n", "n_terra", "n_h", "n_noche", "frp"):
            a = np.zeros((t_total, ny, nx), dtype=np.float32)
            a[t, iy, ix] = np.asarray(d[col], dtype=np.float32)
            salida[f"{prefijo}_{col}"] = a
    return salida


# ---------------------------------------------------------------------------
# Armonización
# ---------------------------------------------------------------------------

def _constantes_k(c: dict[str, np.ndarray]) -> tuple[np.ndarray, np.ndarray]:
    """k por mes del año: focos VIIRS / focos MODIS (y / Terra) en todo India."""
    modis = c["modis_n"].sum((1, 2))
    terra = c["modis_n_terra"].sum((1, 2))
    viirs = c["viirs_n"].sum((1, 2))
    meses = np.arange(CALIB_DESDE, CALIB_HASTA + 1)
    meses = meses[(modis[meses] > 0) & (viirs[meses] > 0)]
    k_modis = np.zeros(12)
    k_terra = np.zeros(12)
    for mm in range(12):
        sel = meses[meses % 12 == mm]
        k_modis[mm] = viirs[sel].sum() / modis[sel].sum()
        k_terra[mm] = viirs[sel].sum() / terra[sel].sum()
    return k_modis, k_terra


def _rango_valido(n: np.ndarray) -> tuple[int, int]:
    meses = np.flatnonzero(n.sum((1, 2)) > 0)
    return int(meses[0]), int(meses[-1])


def _serie(nombre: str, conteo, n, n_h, n_noche, frp, t_desde, t_hasta) -> Serie:
    con_focos = np.maximum(n, 1)
    return Serie(
        nombre=nombre,
        conteo=conteo.astype(np.float32),
        frp_medio=np.where(n > 0, frp / con_focos, 0).astype(np.float32),
        frac_alta=np.where(n > 0, n_h / con_focos, 0).astype(np.float32),
        frac_noche=np.where(n > 0, n_noche / con_focos, 0).astype(np.float32),
        t_desde=t_desde,
        t_hasta=t_hasta,
    )


def cargar_rejilla(res: float = 0.25, rehacer: bool = False) -> Rejilla:
    DIR_CACHE.mkdir(exist_ok=True)
    cache = DIR_CACHE / f"rejilla_{res:g}.npz"
    if cache.exists() and not rehacer:
        c = dict(np.load(cache))
    else:
        c = _leer_crudo(res)
        np.savez_compressed(cache, **c)
    _, ny, nx, t_total = c["meta"]
    ny, nx, t_total = int(ny), int(nx), int(t_total)

    k_modis, k_terra = _constantes_k(c)
    # MODIS -> escala VIIRS: antes de 2002-08 solo Terra × k_terra; después todo × k_modis
    t = np.arange(t_total)
    solo_terra = (t < INICIO_TERRA_AQUA)[:, None, None]
    k_t = np.where(solo_terra, k_terra[t % 12][:, None, None], k_modis[t % 12][:, None, None])
    n_base = np.where(solo_terra, c["modis_n_terra"], c["modis_n"])
    modis = _serie("MODIS armonizado", n_base * k_t, c["modis_n"], c["modis_n_h"],
                   c["modis_n_noche"], c["modis_frp"], *_rango_valido(c["modis_n"]))

    v_desde, v_hasta = _rango_valido(c["viirs_n"])
    v_desde = max(v_desde, CALIB_DESDE)  # enero de 2012 está incompleto
    viirs = _serie("VIIRS S-NPP", c["viirs_n"], c["viirs_n"], c["viirs_n_h"],
                   c["viirs_n_noche"], c["viirs_frp"], v_desde, v_hasta)
    return Rejilla(res, ny, nx, t_total, modis, viirs, k_modis, k_terra)


# ---------------------------------------------------------------------------
# Variables de entrada
# ---------------------------------------------------------------------------

def media_caja(a: np.ndarray, r: int) -> np.ndarray:
    """Media espacial en una ventana (2r+1)×(2r+1) para cada mes; fuera del mapa cuenta 0."""
    k = 2 * r + 1
    p = np.pad(a.astype(np.float64), ((0, 0), (r + 1, r), (r + 1, r)))
    c = p.cumsum(1).cumsum(2)
    s = c[:, k:, k:] - c[:, :-k, k:] - c[:, k:, :-k] + c[:, :-k, :-k]
    return (s / (k * k)).astype(np.float32)


def celdas_activas(rej: Rejilla) -> tuple[np.ndarray, np.ndarray]:
    """Celdas con al menos un foco de vegetación en algún momento (máscara espacial)."""
    alguna = (rej.modis.conteo.sum(0) > 0) | (rej.viirs.conteo.sum(0) > 0)
    return np.nonzero(alguna)


def secuencias(serie: Serie, iy: np.ndarray, ix: np.ndarray) -> np.ndarray:
    """Variables por celda y mes: array (N_celdas, T, C) en el orden de CANALES."""
    t = np.arange(serie.conteo.shape[0])
    mes = np.broadcast_to((t % 12)[:, None], (t.size, iy.size))
    canales = [
        np.log1p(serie.conteo[:, iy, ix]),
        np.log1p(media_caja(serie.conteo, 1)[:, iy, ix]),
        np.log1p(media_caja(serie.conteo, 4)[:, iy, ix]),
        np.log1p(serie.frp_medio[:, iy, ix]),
        serie.frac_alta[:, iy, ix],
        serie.frac_noche[:, iy, ix],
        np.sin(2 * np.pi * mes / 12),
        np.cos(2 * np.pi * mes / 12),
    ]
    return np.stack(canales, axis=-1).transpose(1, 0, 2).astype(np.float32)


def climatologia(serie: Serie, iy, ix, t_hasta: int, umbral: float):
    """Normal histórica por celda y mes del año, usando solo meses <= t_hasta.

    Devuelve (clim_log, clim_frec), cada uno (N_celdas, 12):
      clim_log  = media de log(1 + focos) de ese mes en los años de ajuste
      clim_frec = fracción de esos años en que la celda superó el umbral
    """
    clim_log = np.zeros((iy.size, 12), dtype=np.float32)
    clim_frec = np.zeros((iy.size, 12), dtype=np.float32)
    for mm in range(12):
        meses = np.arange(serie.t_desde, t_hasta + 1)
        meses = meses[meses % 12 == mm]
        x = serie.conteo[meses][:, iy, ix]
        clim_log[:, mm] = np.log1p(x).mean(0)
        clim_frec[:, mm] = (x >= umbral).mean(0)
    return clim_log, clim_frec


if __name__ == "__main__":
    import argparse

    ap = argparse.ArgumentParser(description="Construye la rejilla y muestra un resumen")
    ap.add_argument("--res", type=float, default=0.25)
    ap.add_argument("--rehacer", action="store_true")
    a = ap.parse_args()
    rej = cargar_rejilla(a.res, a.rehacer)
    iy, ix = celdas_activas(rej)
    print(f"Rejilla {rej.ny}×{rej.nx} de {rej.res}°, {rej.t_total} meses, {iy.size} celdas activas")
    print("k_modis:", np.round(rej.k_modis, 2))
    print("k_terra:", np.round(rej.k_terra, 2))
    for s in (rej.modis, rej.viirs):
        print(f"{s.nombre}: {t_a_texto(s.t_desde)} .. {t_a_texto(s.t_hasta)}")
    # Comprobación del salto de 2012 (debe ser ~1)
    m, v = rej.modis.conteo.sum((1, 2)), rej.viirs.conteo.sum((1, 2))
    sel = np.arange(mes_a_t(2018, 1), mes_a_t(2025, 12) + 1)
    print(f"2018-2025, MODIS armonizado / VIIRS: {m[sel].sum() / v[sel].sum():.3f}")
