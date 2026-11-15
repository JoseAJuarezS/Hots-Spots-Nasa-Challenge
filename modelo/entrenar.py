"""Entrena la red con MODIS armonizado (2000-2017) y la valida con VIIRS S-NPP (2018 en adelante).

Uso (desde modelo/):
    uv run python entrenar.py                 # valores por defecto
    uv run python entrenar.py --epocas 5      # prueba rápida
    uv run python entrenar.py --cpu           # sin GPU

Partición temporal (sin mezclar años):
    ajuste       MODIS armonizado, meses objetivo 2002-11 .. 2015-12
    val. interna MODIS armonizado, 2016-01 .. 2017-12  (parada temprana y umbral de decisión)
    prueba       VIIRS S-NPP,      2018-01 .. último mes disponible (2025-12 hoy; 2026 si se añade)

Salidas en modelo/salidas/: modelo.pt, metricas.json, validacion_mensual.csv,
predicciones_viirs.csv y pronostico_<mes>.csv (el mes siguiente al último dato).
"""

from __future__ import annotations

import argparse
import copy
import csv
import json
import math
import time
from pathlib import Path

import numpy as np
import torch
from torch.nn import functional as F

import datos
import metricas
from datos import mes_a_t, t_a_texto
from red import CONTEXTO, RedIncendios

DIR_SALIDA = Path(__file__).resolve().parent / "salidas"

INICIO_VAL_INTERNA = mes_a_t(2016, 1)
FIN_ENTRENAMIENTO = mes_a_t(2017, 12)
INICIO_PRUEBA = mes_a_t(2018, 1)

N_CONTEO = len(datos.CANALES_CONTEO)
assert datos.CANALES_CONTEO == list(range(N_CONTEO)), "los canales de conteo deben ir primero"


class Fuente:
    """Una serie (MODIS o VIIRS) en el dispositivo, lista para armar lotes."""

    def __init__(self, serie, iy, ix, lat, lon, clim_log, clim_frec, dispositivo):
        self.nombre = serie.nombre
        self.x = torch.from_numpy(datos.secuencias(serie, iy, ix)).to(dispositivo)        # (N, T, C)
        self.focos = torch.from_numpy(np.ascontiguousarray(serie.conteo[:, iy, ix].T)).to(dispositivo)  # (N, T)
        self.lat = torch.as_tensor(lat, dtype=torch.float32, device=dispositivo)
        self.lon = torch.as_tensor(lon, dtype=torch.float32, device=dispositivo)
        self.clim_log = torch.from_numpy(clim_log).to(dispositivo)
        self.clim_frec = torch.from_numpy(clim_frec).to(dispositivo)

    def lote(self, ci, ti, ventana: int, umbral: float, ruido: float = 0.0):
        pasos = torch.arange(-ventana, 0, device=ci.device)
        seq = self.x[ci[:, None], ti[:, None] + pasos]                  # (B, L, C)
        mes = ti % 12
        ang = 2 * math.pi * mes.float() / 12
        ctx = torch.stack([torch.sin(ang), torch.cos(ang), self.lat[ci], self.lon[ci],
                           self.clim_log[ci, mes], self.clim_frec[ci, mes]], dim=1)
        focos = self.focos[ci, ti]
        if ruido > 0:
            # Aumento de datos: un factor de escala por muestra (entrada y objetivo a la vez)
            # simula el error de la constante k y el cambio de sensor.
            s = torch.exp(torch.randn(ci.shape[0], device=ci.device) * ruido)
            seq = seq.clone()
            seq[..., :N_CONTEO] = torch.log1p(torch.expm1(seq[..., :N_CONTEO]) * s[:, None, None])
            focos = focos * s
        return seq, ctx, torch.log1p(focos), (focos >= umbral).float()


def pares(n_celdas: int, meses: np.ndarray, dispositivo):
    """Todas las combinaciones (celda, mes). Orden: celda mayor -> reshape(N, M)."""
    ci, ti = torch.meshgrid(torch.arange(n_celdas), torch.as_tensor(meses), indexing="ij")
    return ci.reshape(-1).to(dispositivo), ti.reshape(-1).to(dispositivo)


def perdida(logit, log_pred, y_log, y_ocu, peso_pos):
    bce = F.binary_cross_entropy_with_logits(logit, y_ocu, pos_weight=peso_pos)
    huber = F.huber_loss(log_pred, y_log, delta=1.0)
    return bce + huber


@torch.no_grad()
def predecir(modelo, fuente: Fuente, ci, ti, a, peso_pos=None, lote=16384):
    modelo.eval()
    probs, logs, total = [], [], 0.0
    for i in range(0, ci.numel(), lote):
        seq, ctx, y_log, y_ocu = fuente.lote(ci[i:i + lote], ti[i:i + lote], a.ventana, a.umbral)
        logit, log_pred = modelo(seq, ctx)
        if peso_pos is not None:
            total += perdida(logit, log_pred, y_log, y_ocu, peso_pos).item() * seq.shape[0]
        probs.append(torch.sigmoid(logit).cpu())
        logs.append(log_pred.cpu())
    return torch.cat(probs).numpy(), torch.cat(logs).numpy(), total / ci.numel()


def entrenar(modelo, modis: Fuente, fit, val, a, dispositivo):
    ci_fit, ti_fit = fit
    p = float((modis.focos[:, ti_fit.unique()] >= a.umbral).float().mean())
    peso_pos = torch.tensor(math.sqrt((1 - p) / p), device=dispositivo)
    print(f"Muestras de ajuste: {ci_fit.numel():,}  positivos: {100 * p:.1f} %  pos_weight: {peso_pos.item():.2f}")

    # Normalización con una muestra aleatoria del ajuste
    idx = torch.randperm(ci_fit.numel(), device=dispositivo)[:200_000]
    seq, ctx, _, _ = modis.lote(ci_fit[idx], ti_fit[idx], a.ventana, a.umbral)
    modelo.fijar_normalizacion(seq, ctx)

    opt = torch.optim.AdamW(modelo.parameters(), lr=a.lr, weight_decay=1e-4)
    plan = torch.optim.lr_scheduler.ReduceLROnPlateau(opt, factor=0.5, patience=2)
    mejor, mejor_estado, sin_mejora = float("inf"), None, 0
    for epoca in range(1, a.epocas + 1):
        t0 = time.time()
        modelo.train()
        perm = torch.randperm(ci_fit.numel(), device=dispositivo)
        suma = 0.0
        for i in range(0, perm.numel(), a.lote):
            j = perm[i:i + a.lote]
            seq, ctx, y_log, y_ocu = modis.lote(ci_fit[j], ti_fit[j], a.ventana, a.umbral, a.ruido)
            logit, log_pred = modelo(seq, ctx)
            loss = perdida(logit, log_pred, y_log, y_ocu, peso_pos)
            opt.zero_grad(set_to_none=True)
            loss.backward()
            torch.nn.utils.clip_grad_norm_(modelo.parameters(), 1.0)
            opt.step()
            suma += loss.item() * j.numel()
        _, _, perdida_val = predecir(modelo, modis, *val, a, peso_pos)
        plan.step(perdida_val)
        marca = ""
        if perdida_val < mejor - 1e-4:
            mejor, mejor_estado, sin_mejora, marca = perdida_val, copy.deepcopy(modelo.state_dict()), 0, " *"
        else:
            sin_mejora += 1
        print(f"época {epoca:3d}  ajuste {suma / perm.numel():.4f}  val {perdida_val:.4f}  "
              f"lr {opt.param_groups[0]['lr']:.1e}  {time.time() - t0:.0f}s{marca}", flush=True)
        if sin_mejora >= a.paciencia:
            print("Parada temprana")
            break
    modelo.load_state_dict(mejor_estado)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--res", type=float, default=0.25, help="tamaño de celda en grados")
    ap.add_argument("--umbral", type=float, default=10.0,
                    help="focos (escala VIIRS) por celda y mes para considerar 'actividad de quema'")
    ap.add_argument("--ventana", type=int, default=24, help="meses de historia que ve la red")
    ap.add_argument("--epocas", type=int, default=40)
    ap.add_argument("--paciencia", type=int, default=6)
    ap.add_argument("--lote", type=int, default=4096)
    ap.add_argument("--lr", type=float, default=2e-3)
    ap.add_argument("--ruido", type=float, default=0.15, help="desv. típica del factor de escala (log)")
    ap.add_argument("--semilla", type=int, default=42)
    ap.add_argument("--cpu", action="store_true")
    ap.add_argument("--rehacer-cache", action="store_true")
    a = ap.parse_args()

    torch.manual_seed(a.semilla)
    np.random.seed(a.semilla)
    dispositivo = torch.device("cuda" if torch.cuda.is_available() and not a.cpu else "cpu")
    print(f"Dispositivo: {dispositivo}")

    # ---- Datos -------------------------------------------------------------
    rej = datos.cargar_rejilla(a.res, a.rehacer_cache)
    iy, ix = datos.celdas_activas(rej)
    lat = datos.LAT_MIN + (iy + 0.5) * a.res
    lon = datos.LON_MIN + (ix + 0.5) * a.res
    # Normal histórica: solo con los años de ajuste de MODIS (nada de 2016 en adelante)
    clim_log, clim_frec = datos.climatologia(rej.modis, iy, ix, INICIO_VAL_INTERNA - 1, a.umbral)
    modis = Fuente(rej.modis, iy, ix, lat, lon, clim_log, clim_frec, dispositivo)
    viirs = Fuente(rej.viirs, iy, ix, lat, lon, clim_log, clim_frec, dispositivo)
    n = iy.size

    meses_fit = np.arange(rej.modis.t_desde + a.ventana, INICIO_VAL_INTERNA)
    meses_val = np.arange(INICIO_VAL_INTERNA, FIN_ENTRENAMIENTO + 1)
    meses_prueba = np.arange(max(INICIO_PRUEBA, rej.viirs.t_desde + a.ventana), rej.viirs.t_hasta + 1)
    print(f"{n} celdas de {a.res}°. Ajuste {t_a_texto(meses_fit[0])}..{t_a_texto(meses_fit[-1])}, "
          f"val. interna {t_a_texto(meses_val[0])}..{t_a_texto(meses_val[-1])}, "
          f"prueba VIIRS {t_a_texto(meses_prueba[0])}..{t_a_texto(meses_prueba[-1])}")
    fit = pares(n, meses_fit, dispositivo)
    val = pares(n, meses_val, dispositivo)
    prueba = pares(n, meses_prueba, dispositivo)

    # ---- Entrenamiento -----------------------------------------------------
    modelo = RedIncendios(len(datos.CANALES), len(CONTEXTO)).to(dispositivo)
    print(f"Parámetros: {sum(p.numel() for p in modelo.parameters()):,}")
    entrenar(modelo, modis, fit, val, a, dispositivo)

    # ---- Calibración con la validación interna (MODIS 2016-2017) ------------
    prob_v, log_v, _ = predecir(modelo, modis, *val, a)
    obs_v = modis.focos[val[0], val[1]].cpu().numpy()
    umbral_prob = metricas.mejor_umbral_f1(obs_v >= a.umbral, prob_v)
    # expm1(E[log]) subestima la media: factor de corrección para sumar focos esperados
    factor = float(obs_v.sum() / np.expm1(log_v).sum())

    def evaluar(prob, log_pred, obs, n_meses):
        esperado = np.expm1(log_pred) * factor
        return {
            "ocurrencia": metricas.ocurrencia(obs >= a.umbral, prob, umbral_prob),
            "conteo_celda": metricas.conteo(np.log1p(obs), log_pred),
            "totales_mensuales": metricas.totales(obs.reshape(n, n_meses).sum(0),
                                                  esperado.reshape(n, n_meses).sum(0)),
        }

    resultado = {
        "configuracion": vars(a),
        "celdas": n,
        "k_modis": rej.k_modis.round(3).tolist(),
        "k_terra": rej.k_terra.round(3).tolist(),
        "umbral_prob": umbral_prob,
        "factor_totales": factor,
        "val_interna_modis_2016_2017": evaluar(prob_v, log_v, obs_v, meses_val.size),
    }

    # ---- Prueba con VIIRS ----------------------------------------------------
    prob_p, log_p, _ = predecir(modelo, viirs, *prueba, a)
    obs_p = viirs.focos[prueba[0], prueba[1]].cpu().numpy()
    m = meses_prueba.size
    resultado["prueba_viirs"] = evaluar(prob_p, log_p, obs_p, m)

    # Referencias sencillas que la red debe superar
    ci_np, ti_np = prueba[0].cpu().numpy(), prueba[1].cpu().numpy()
    hace_un_anio = rej.viirs.conteo[ti_np - 12, iy[ci_np], ix[ci_np]]
    clim_l, clim_f = clim_log[ci_np, ti_np % 12], clim_frec[ci_np, ti_np % 12]
    focos_modis_celda = rej.modis.conteo[:, iy, ix]
    clim_nacional = np.array([focos_modis_celda[[t for t in range(rej.modis.t_desde, INICIO_VAL_INTERNA)
                                                 if t % 12 == mm]].sum(1).mean() for mm in range(12)])
    obs_mes = obs_p.reshape(n, m).sum(0)
    resultado["referencias_viirs"] = {
        "persistencia_mismo_mes_anio_anterior": {
            "ocurrencia": metricas.ocurrencia(obs_p >= a.umbral, np.log1p(hace_un_anio), math.log1p(a.umbral)),
            "conteo_celda": metricas.conteo(np.log1p(obs_p), np.log1p(hace_un_anio)),
            "totales_mensuales": metricas.totales(obs_mes, hace_un_anio.reshape(n, m).sum(0)),
        },
        "climatologia_modis": {
            "ocurrencia": metricas.ocurrencia(obs_p >= a.umbral, clim_f, 0.5),
            "conteo_celda": metricas.conteo(np.log1p(obs_p), clim_l),
            "totales_mensuales": metricas.totales(obs_mes, clim_nacional[meses_prueba % 12]),
        },
    }

    # Por año
    por_anio = {}
    anio = datos.ANIO_BASE + meses_prueba // 12
    for an in np.unique(anio):
        sel_m = anio == an
        sel = np.tile(sel_m, n)
        r = evaluar(prob_p[sel], log_p[sel], obs_p[sel], int(sel_m.sum()))
        por_anio[int(an)] = {"auc_roc": r["ocurrencia"]["auc_roc"],
                             "precision_promedio": r["ocurrencia"]["precision_promedio"],
                             "f1": r["ocurrencia"]["f1"],
                             "sesgo_totales_pct": r["totales_mensuales"]["sesgo_pct"]}
    resultado["prueba_viirs_por_anio"] = por_anio

    # ---- Guardar --------------------------------------------------------------
    DIR_SALIDA.mkdir(exist_ok=True)
    (DIR_SALIDA / "metricas.json").write_text(json.dumps(resultado, indent=2, ensure_ascii=False), encoding="utf-8")
    torch.save({
        "estado": modelo.state_dict(), "canales": datos.CANALES, "contexto": CONTEXTO,
        "configuracion": vars(a),
        "celdas_iy": torch.from_numpy(iy), "celdas_ix": torch.from_numpy(ix),
        "clim_log": torch.from_numpy(clim_log), "clim_frec": torch.from_numpy(clim_frec),
        "k_modis": rej.k_modis.tolist(), "k_terra": rej.k_terra.tolist(),
        "umbral_prob": umbral_prob, "factor_totales": factor,
    }, DIR_SALIDA / "modelo.pt")

    esperado_mes = (np.expm1(log_p) * factor).reshape(n, m).sum(0)
    with open(DIR_SALIDA / "validacion_mensual.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["mes", "viirs_observado", "red", "persistencia", "climatologia_modis"])
        pers_mes = hace_un_anio.reshape(n, m).sum(0)
        for j, t in enumerate(meses_prueba):
            w.writerow([t_a_texto(t), round(obs_mes[j]), round(esperado_mes[j]), round(pers_mes[j]),
                        round(clim_nacional[t % 12])])

    with open(DIR_SALIDA / "predicciones_viirs.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["mes", "lat", "lon", "prob_actividad", "focos_esperados", "focos_observados"])
        esperado = np.expm1(log_p) * factor
        for k in np.flatnonzero((prob_p >= 0.01) | (obs_p > 0)):
            c, t = ci_np[k], ti_np[k]
            w.writerow([t_a_texto(t), round(lat[c], 3), round(lon[c], 3), round(float(prob_p[k]), 4),
                        round(float(esperado[k]), 1), int(obs_p[k])])

    # Pronóstico del mes siguiente al último dato de VIIRS
    t_sig = rej.viirs.t_hasta + 1
    pron = pares(n, np.array([t_sig]), dispositivo)
    prob_f, log_f, _ = predecir(modelo, viirs, *pron, a)
    with open(DIR_SALIDA / f"pronostico_{t_a_texto(t_sig)}.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["lat", "lon", "prob_actividad", "focos_esperados"])
        for c in range(n):
            w.writerow([round(lat[c], 3), round(lon[c], 3), round(float(prob_f[c]), 4),
                        round(float(np.expm1(log_f[c]) * factor), 1)])

    # ---- Resumen ---------------------------------------------------------------
    def fila(nombre, r):
        o, t = r["ocurrencia"], r["totales_mensuales"]
        print(f"{nombre:<34} AUC {o['auc_roc']:.3f}  AP {o['precision_promedio']:.3f}  F1 {o['f1']:.3f}  "
              f"MAE-log {r['conteo_celda']['mae_log']:.3f}  totales r {t['r']:.3f} sesgo {t['sesgo_pct']:+.1f}%")

    print("\n== Resultados ==")
    fila("Red, val. interna MODIS 2016-17", resultado["val_interna_modis_2016_2017"])
    fila("Red, prueba VIIRS", resultado["prueba_viirs"])
    fila("Persistencia, prueba VIIRS", resultado["referencias_viirs"]["persistencia_mismo_mes_anio_anterior"])
    fila("Climatología, prueba VIIRS", resultado["referencias_viirs"]["climatologia_modis"])
    print(f"\nPronóstico de {t_a_texto(t_sig)} y resto de salidas en {DIR_SALIDA}")


if __name__ == "__main__":
    main()
