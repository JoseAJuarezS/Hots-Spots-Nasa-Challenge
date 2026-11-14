"""Pasa `confidence` y `frp` de los CSV de MODIS a la escala de VIIRS 375 m.

Uso (desde la raíz del repo):
    mise exec -- python analisis/05_confidence_modis_a_viirs.py            # convierte
    mise exec -- python analisis/05_confidence_modis_a_viirs.py --simular  # solo muestra la calibración

Modifica EN SITIO los archivos de datos_crudos/MODIS/. Antes de tocarlos copia los
originales a datos_crudos/MODIS_original/ (solo la primera vez). Las ejecuciones siguientes
siempre leen de esa copia, así que el script se puede repetir sin acumular conversiones.
Para deshacer: copiar de nuevo MODIS_original/*.csv sobre MODIS/.

Calibración: solo días en que hay datos de MODIS y de VIIRS, solo vegetación (type = 0),
y por separado para día (D) y noche (N). Luego se aplica a todas las filas de MODIS.

confidence (emparejamiento de proporciones):
  En VIIRS se mide qué fracción de focos es 'l', 'n' y 'h', y sobre la confianza numérica
  de MODIS se buscan dos umbrales que den la misma proporción:
        conf <  umbral_bajo                 -> 'l'
        umbral_bajo <= conf < umbral_alto   -> 'n'
        conf >= umbral_alto                 -> 'h'

frp (emparejamiento de cuantiles):
  Cada valor de MODIS se sustituye por el valor de VIIRS que ocupa el mismo percentil
  (percentil de rango medio, para los empates). Entre valores calibrados se interpola
  linealmente; por encima del máximo se escala con la razón VIIRS/MODIS del extremo.
  OJO: un píxel MODIS (1 km) equivale a varios píxeles VIIRS (375 m). Tras la conversión
  cada foco MODIS vale como "un foco típico de VIIRS", así que la SUMA de FRP de un área
  solo es comparable con VIIRS si cada foco MODIS se pondera por la constante k de
  focos (ver correlacion-modis-viirs.md / serie-armonizada.md).

Solo cambian las columnas `confidence` y `frp`; el resto del archivo queda igual.
"""

from __future__ import annotations

import argparse
import bisect
import csv
import json
import os
import shutil
from collections import Counter, defaultdict
from pathlib import Path

RAIZ = Path(__file__).resolve().parent.parent
LETRAS = ("l", "n", "h")


# ---------------------------------------------------------------------------
# Lectura: conteos por día, para poder quedarse luego con los días comunes
# ---------------------------------------------------------------------------

def nuevo_conteo():
    # {fecha: {daynight: {"conf": Counter, "frp": Counter}}}
    return defaultdict(lambda: defaultdict(lambda: {"conf": Counter(), "frp": Counter()}))


def contar(archivos: list[Path], conf_numerica: bool):
    conteo = nuevo_conteo()
    for ruta in archivos:
        with ruta.open(newline="", encoding="utf-8") as f:
            for fila in csv.DictReader(f):
                if fila["type"] != "0":
                    continue
                c = fila["confidence"].strip()
                if conf_numerica:
                    try:
                        c = int(c)
                    except ValueError:
                        raise SystemExit(
                            f"{ruta.name}: confidence no numérico ({c!r}). "
                            "¿Se está leyendo un archivo ya convertido?"
                        )
                else:
                    c = c.lower()
                celda = conteo[fila["acq_date"]][fila["daynight"]]
                celda["conf"][c] += 1
                if fila["frp"].strip():
                    celda["frp"][float(fila["frp"])] += 1
    return conteo


def juntar(conteo, dias, dn: str, campo: str) -> Counter:
    total: Counter = Counter()
    for dia in dias:
        if dn in conteo[dia]:
            total.update(conteo[dia][dn][campo])
    return total


# ---------------------------------------------------------------------------
# confidence
# ---------------------------------------------------------------------------

def umbrales_confidence(cm: Counter, cv: Counter) -> dict:
    total_v = sum(cv[x] for x in LETRAS)
    total_m = sum(cm.values())
    p_l, p_h = cv["l"] / total_v, cv["h"] / total_v

    # Para cada umbral candidato t: P(conf < t) en MODIS
    acumulada, menores = [], 0
    for t in range(0, 102):
        acumulada.append((t, menores / total_m))
        menores += cm.get(t, 0)

    def mejor(objetivo: float) -> int:
        return min(acumulada, key=lambda par: abs(par[1] - objetivo))[0]

    bajo = mejor(p_l)
    alto = max(mejor(1 - p_h), bajo)

    def prop(cond) -> float:
        return sum(n for c, n in cm.items() if cond(c)) / total_m

    return {
        "umbral_bajo": bajo,
        "umbral_alto": alto,
        "viirs_pct": {x: round(100 * cv[x] / total_v, 2) for x in LETRAS},
        "modis_pct": {
            "l": round(100 * prop(lambda c: c < bajo), 2),
            "n": round(100 * prop(lambda c: bajo <= c < alto), 2),
            "h": round(100 * prop(lambda c: c >= alto), 2),
        },
    }


def a_letra(conf: int, u: dict) -> str:
    if conf < u["umbral_bajo"]:
        return "l"
    if conf >= u["umbral_alto"]:
        return "h"
    return "n"


# ---------------------------------------------------------------------------
# frp
# ---------------------------------------------------------------------------

class Cuantiles:
    """Cuantiles (interpolación lineal, como quantile_cont) a partir de un histograma."""

    def __init__(self, hist: Counter):
        self.valores = sorted(hist)
        self.fin = []  # índice (exclusivo) donde termina cada valor en la lista ordenada
        n = 0
        for v in self.valores:
            n += hist[v]
            self.fin.append(n)
        self.n = n

    def valor_en(self, i: int) -> float:
        return self.valores[bisect.bisect_right(self.fin, i)]

    def cuantil(self, p: float) -> float:
        pos = p * (self.n - 1)
        i = int(pos)
        a = self.valor_en(i)
        if i + 1 >= self.n:
            return a
        return a + (pos - i) * (self.valor_en(i + 1) - a)


def curva_frp(hm: Counter, hv: Counter) -> dict:
    """Puntos (frp_modis, frp_viirs) con el mismo percentil, uno por valor distinto de MODIS."""
    qv = Cuantiles(hv)
    total_m = sum(hm.values())
    xs, ys, antes = [], [], 0
    for x in sorted(hm):
        p = (antes + hm[x] / 2) / total_m  # percentil de rango medio
        xs.append(x)
        ys.append(qv.cuantil(p))
        antes += hm[x]
    return {"x": xs, "y": ys}


def a_frp_viirs(x: float, c: dict) -> float:
    xs, ys = c["x"], c["y"]
    if x <= xs[0]:
        return ys[0] if xs[0] <= 0 else x * ys[0] / xs[0]
    if x >= xs[-1]:
        return x * ys[-1] / xs[-1]
    i = bisect.bisect_right(xs, x)
    x0, x1, y0, y1 = xs[i - 1], xs[i], ys[i - 1], ys[i]
    return y0 + (x - x0) * (y1 - y0) / (x1 - x0)


# ---------------------------------------------------------------------------
# Programa
# ---------------------------------------------------------------------------

def calibrar(modis, viirs) -> dict:
    dias = modis.keys() & viirs.keys()
    if not dias:
        raise SystemExit("MODIS y VIIRS no tienen ningún día en común")
    cal = {}
    for dn in ("D", "N"):
        cm, cv = juntar(modis, dias, dn, "conf"), juntar(viirs, dias, dn, "conf")
        hm, hv = juntar(modis, dias, dn, "frp"), juntar(viirs, dias, dn, "frp")
        if not cm or not cv or not hm or not hv:
            continue
        cal[dn] = {
            "dias_comunes": len(dias),
            "focos_modis": sum(cm.values()),
            "focos_viirs": sum(cv.values()),
            "confidence": umbrales_confidence(cm, cv),
            "frp": curva_frp(hm, hv),
        }
    if "D" not in cal:
        raise SystemExit("No se pudo calibrar el día (D)")
    return cal


def mostrar(cal: dict) -> None:
    for dn, c in cal.items():
        u, curva = c["confidence"], c["frp"]
        print(f"\n[{dn}] {c['dias_comunes']} días comunes, "
              f"{c['focos_modis']} focos MODIS, {c['focos_viirs']} focos VIIRS")
        print(f"  confidence: l < {u['umbral_bajo']} <= n < {u['umbral_alto']} <= h"
              f"   | VIIRS % {u['viirs_pct']}  MODIS % {u['modis_pct']}")
        print("  frp (MW):  MODIS -> VIIRS")
        for x in (1, 5, 10, 15, 20, 30, 50, 100, 300, 1000):
            print(f"    {x:>6} -> {a_frp_viirs(x, curva):8.2f}")


def convertir_archivo(origen: Path, destino: Path, cal: dict) -> Counter:
    resumen: Counter = Counter()
    temporal = destino.with_suffix(".csv.tmp")
    with origen.open(newline="", encoding="utf-8") as fin, \
         temporal.open("w", newline="", encoding="utf-8") as fout:
        lector = csv.DictReader(fin)
        escritor = csv.DictWriter(fout, fieldnames=lector.fieldnames, lineterminator="\n")
        escritor.writeheader()
        for fila in lector:
            c = cal.get(fila["daynight"]) or cal["D"]
            fila["confidence"] = a_letra(int(fila["confidence"]), c["confidence"])
            resumen[fila["confidence"]] += 1
            if fila["frp"].strip():
                fila["frp"] = f"{a_frp_viirs(float(fila['frp']), c['frp']):.2f}"
            escritor.writerow(fila)
    os.replace(temporal, destino)
    return resumen


def guardar_calibracion(cal: dict, carpeta: Path) -> None:
    resumen = {dn: {k: v for k, v in c.items() if k != "frp"} for dn, c in cal.items()}
    (carpeta / "umbrales_confidence.json").write_text(
        json.dumps(resumen, indent=2, ensure_ascii=False), encoding="utf-8")
    with (carpeta / "curva_frp.csv").open("w", newline="", encoding="utf-8") as f:
        w = csv.writer(f, lineterminator="\n")
        w.writerow(["daynight", "frp_modis", "frp_viirs"])
        for dn, c in cal.items():
            for x, y in zip(c["frp"]["x"], c["frp"]["y"]):
                w.writerow([dn, x, round(y, 4)])


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--datos", type=Path, default=RAIZ / "datos_crudos",
                    help="carpeta con MODIS/ y VIIRS/ (por defecto datos_crudos)")
    ap.add_argument("--simular", action="store_true",
                    help="calcula y muestra la calibración sin modificar archivos")
    args = ap.parse_args()

    dir_modis = args.datos / "MODIS"
    dir_viirs = args.datos / "VIIRS"
    dir_original = args.datos / "MODIS_original"

    # Los originales se leen siempre de la copia de seguridad si ya existe.
    fuente = dir_original if dir_original.is_dir() else dir_modis
    archivos = sorted(fuente.glob("modis_*_India.csv"))
    if not archivos:
        raise SystemExit(f"No hay CSV de MODIS en {fuente}")
    archivos_viirs = sorted(dir_viirs.glob("viirs-*_India.csv"))
    if not archivos_viirs:
        raise SystemExit(f"No hay CSV de VIIRS en {dir_viirs}")
    print(f"Leyendo MODIS de {fuente} ({len(archivos)} archivos)")

    print("Contando VIIRS...")
    viirs = contar(archivos_viirs, conf_numerica=False)
    print("Contando MODIS...")
    modis = contar(archivos, conf_numerica=True)

    cal = calibrar(modis, viirs)
    mostrar(cal)

    if args.simular:
        print("\n--simular: no se modificó ningún archivo")
        return

    if not dir_original.is_dir():
        print(f"\nCopia de seguridad de originales -> {dir_original}")
        shutil.copytree(dir_modis, dir_original)

    print("\nConvirtiendo:")
    for origen in archivos:
        resumen = convertir_archivo(origen, dir_modis / origen.name, cal)
        print(f"  {origen.name}: " + ", ".join(f"{x}={resumen[x]}" for x in LETRAS))

    guardar_calibracion(cal, dir_original)
    print(f"\nListo. Calibración guardada en {dir_original}"
          " (umbrales_confidence.json, curva_frp.csv)")


if __name__ == "__main__":
    main()
