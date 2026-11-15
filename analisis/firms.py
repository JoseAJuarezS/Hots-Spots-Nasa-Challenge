#!/usr/bin/env python3
"""Descarga e ingesta de los CSV anuales por país de NASA FIRMS.

Los datos viven FUERA del repo, en $FIRMS_DATA_DIR (por defecto ../datos_firms):

    $FIRMS_DATA_DIR/
    ├── crudos/<sensor>/<sensor>_<anio>_<Pais>.csv          (tal cual los da FIRMS)
    └── parquet/sensor=<sensor>/pais=<Pais>/anio=<anio>/*.parquet

<sensor> es el nombre de FIRMS: modis, viirs-snpp o viirs-jpss1 (NOAA-20).
<Pais> es el nombre exacto de FIRMS (India, United_States, Brazil...).

Uso (desde la raíz del repo, o con mise run datos:<comando>):
    python analisis/firms.py estado
    python analisis/firms.py tamano                 # cuánto falta por descargar
    python analisis/firms.py descargar
    python analisis/firms.py ingerir                # CSV -> Parquet (solo lo que cambió)

Los países salen de --paises, de $FIRMS_PAISES (separados por coma) o de
analisis/paises.txt, en ese orden. Agregar un país = añadirlo a paises.txt,
descargar e ingerir; el SQL no cambia.

Solo usa la biblioteca estándar; para ingerir necesita el binario de duckdb
($DUCKDB o duckdb en el PATH).
"""
from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

RAIZ_REPO = Path(__file__).resolve().parent.parent
ARCHIVO_PAISES = RAIZ_REPO / "analisis" / "paises.txt"
URL = "https://firms.modaps.eosdis.nasa.gov/data/country/{sensor}/{anio}/{sensor}_{anio}_{pais}.csv"
USER_AGENT = "firms-descarga/1.0"

# Primer año con datos de cada sensor.
SENSORES = {"modis": 2000, "viirs-snpp": 2012, "viirs-jpss1": 2018}
# Último año completo. Se puede subir con --hasta cuando FIRMS cierre el año.
ULTIMO_ANIO = 2025


# --- Rutas y configuración ---------------------------------------------------

def dir_datos() -> Path:
    d = os.environ.get("FIRMS_DATA_DIR")
    return Path(d).expanduser().resolve() if d else (RAIZ_REPO.parent / "datos_firms").resolve()


def leer_paises(args) -> list[str]:
    if args.paises:
        return [p.strip() for p in args.paises.split(",") if p.strip()]
    env = os.environ.get("FIRMS_PAISES", "")
    if env.strip():
        return [p.strip() for p in env.split(",") if p.strip()]
    lineas = ARCHIVO_PAISES.read_text(encoding="utf-8").splitlines()
    return [l.split("#")[0].strip() for l in lineas if l.split("#")[0].strip()]


def leer_sensores(args) -> list[str]:
    if not args.sensores:
        return list(SENSORES)
    sens = [s.strip() for s in args.sensores.split(",")]
    malos = [s for s in sens if s not in SENSORES]
    if malos:
        sys.exit(f"Sensores desconocidos: {malos}. Válidos: {list(SENSORES)}")
    return sens


def anios(sensor: str, args) -> range:
    return range(max(SENSORES[sensor], args.desde), args.hasta + 1)


def ruta_csv(sensor: str, anio: int, pais: str) -> Path:
    return dir_datos() / "crudos" / sensor / f"{sensor}_{anio}_{pais}.csv"


def ruta_parquet(sensor: str, pais: str) -> Path:
    return dir_datos() / "parquet" / f"sensor={sensor}" / f"pais={pais}"


def combinaciones(args):
    for pais in leer_paises(args):
        for sensor in leer_sensores(args):
            for anio in anios(sensor, args):
                yield pais, sensor, anio


# --- Comandos ------------------------------------------------------------------

def cmd_estado(args):
    print(f"FIRMS_DATA_DIR = {dir_datos()}\n")
    print(f"{'país':<16}{'sensor':<13}{'CSV':>6}{'MB':>9}  parquet")
    for pais in leer_paises(args):
        for sensor in leer_sensores(args):
            csvs = [ruta_csv(sensor, a, pais) for a in anios(sensor, args)]
            hay = [c for c in csvs if c.exists()]
            mb = sum(c.stat().st_size for c in hay) / 1e6
            pq = "al día" if parquet_al_dia(sensor, pais) else ("desactualizado" if ruta_parquet(sensor, pais).exists() else "-")
            print(f"{pais:<16}{sensor:<13}{len(hay):>3}/{len(csvs):<2}{mb:>9.0f}  {pq}")


def cmd_tamano(args):
    total, faltan, no_existen = 0, 0, []
    for pais, sensor, anio in combinaciones(args):
        if ruta_csv(sensor, anio, pais).exists():
            continue
        url = URL.format(sensor=sensor, anio=anio, pais=pais)
        req = urllib.request.Request(url, method="HEAD", headers={"User-Agent": USER_AGENT})
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                total += int(r.headers.get("Content-Length", 0))
                faltan += 1
        except urllib.error.HTTPError as e:
            no_existen.append(f"{url} ({e.code})")
    print(f"Faltan {faltan} archivos, {total / 1e9:.2f} GB.")
    for u in no_existen:
        print(f"  no disponible: {u}")


def cmd_descargar(args):
    for pais, sensor, anio in combinaciones(args):
        destino = ruta_csv(sensor, anio, pais)
        if destino.exists():
            continue
        destino.parent.mkdir(parents=True, exist_ok=True)
        url = URL.format(sensor=sensor, anio=anio, pais=pais)
        parcial = destino.with_suffix(".csv.part")
        req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
        try:
            with urllib.request.urlopen(req, timeout=120) as r, open(parcial, "wb") as f:
                shutil.copyfileobj(r, f, length=1 << 20)
        except urllib.error.HTTPError as e:
            parcial.unlink(missing_ok=True)
            print(f"  no disponible ({e.code}): {destino.name}")
            continue
        except Exception:
            parcial.unlink(missing_ok=True)
            raise
        parcial.rename(destino)  # solo aparece completo: un corte no deja un CSV a medias
        print(f"  {destino.name}  {destino.stat().st_size / 1e6:.0f} MB", flush=True)


# --- Ingesta CSV -> Parquet ----------------------------------------------------

MARCA = "_origen.txt"  # lista de CSV (nombre y tamaño) con que se generó el Parquet


def firma_csvs(sensor: str, pais: str) -> str:
    csvs = sorted((dir_datos() / "crudos" / sensor).glob(f"{sensor}_[0-9][0-9][0-9][0-9]_{pais}.csv"))
    return "".join(f"{c.name}\t{c.stat().st_size}\n" for c in csvs)


def parquet_al_dia(sensor: str, pais: str) -> bool:
    marca = ruta_parquet(sensor, pais) / MARCA
    return marca.exists() and marca.read_text() == firma_csvs(sensor, pais)


def duckdb_bin() -> str:
    b = os.environ.get("DUCKDB") or shutil.which("duckdb")
    if not b:
        sys.exit("No encuentro duckdb: instálalo con mise o define $DUCKDB.")
    return b


def sql_literal(s: str) -> str:
    return "'" + s.replace("'", "''") + "'"


def cmd_ingerir(args):
    for pais in leer_paises(args):
        for sensor in leer_sensores(args):
            firma = firma_csvs(sensor, pais)
            if not firma:
                continue
            destino = ruta_parquet(sensor, pais)
            if parquet_al_dia(sensor, pais) and not args.forzar:
                continue
            # Se escribe fuera de sensor=*/pais=* para que nadie lea un Parquet a medias.
            tmp = dir_datos() / "parquet" / ".tmp" / f"{sensor}-{pais}"
            shutil.rmtree(tmp, ignore_errors=True)
            tmp.parent.mkdir(parents=True, exist_ok=True)
            destino.parent.mkdir(parents=True, exist_ok=True)
            patron = str(dir_datos() / "crudos" / sensor / f"{sensor}_[0-9][0-9][0-9][0-9]_{pais}.csv")
            # Mismo tipado que usaba 01_cargar.sql con los CSV: acq_time, confidence y
            # version como texto (conservan ceros a la izquierda y las letras l/n/h).
            sql = f"""
            COPY (
              SELECT *, year(acq_date) AS anio
              FROM read_csv({sql_literal(patron)}, union_by_name = true,
                            types = {{'acq_date': 'DATE', 'acq_time': 'VARCHAR',
                                      'confidence': 'VARCHAR', 'version': 'VARCHAR'}})
            ) TO {sql_literal(str(tmp))} (FORMAT parquet, COMPRESSION zstd, PARTITION_BY (anio));
            """
            print(f"  ingiriendo {sensor} {pais} ...", flush=True)
            subprocess.run([duckdb_bin(), "-no-agent", "-batch"], input=sql, text=True, check=True)
            (tmp / MARCA).write_text(firma)
            shutil.rmtree(destino, ignore_errors=True)
            tmp.rename(destino)


# --- CLI -----------------------------------------------------------------------

def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("comando", choices=["estado", "tamano", "descargar", "ingerir"])
    p.add_argument("--paises", help="lista separada por comas (por defecto, analisis/paises.txt)")
    p.add_argument("--sensores", help=f"lista separada por comas de {list(SENSORES)}")
    p.add_argument("--desde", type=int, default=2000)
    p.add_argument("--hasta", type=int, default=ULTIMO_ANIO)
    p.add_argument("--forzar", action="store_true", help="ingerir: regenera aunque el Parquet esté al día")
    args = p.parse_args()
    {"estado": cmd_estado, "tamano": cmd_tamano, "descargar": cmd_descargar, "ingerir": cmd_ingerir}[args.comando](args)


if __name__ == "__main__":
    main()
