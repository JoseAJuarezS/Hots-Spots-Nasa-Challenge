"""Métricas de evaluación (solo numpy)."""

from __future__ import annotations

import numpy as np


def auc_roc(y: np.ndarray, s: np.ndarray) -> float:
    """Área bajo la curva ROC (Mann-Whitney, con empates promediados)."""
    y = y.astype(bool)
    n1 = int(y.sum())
    n0 = y.size - n1
    if n1 == 0 or n0 == 0:
        return float("nan")
    orden = np.argsort(s, kind="mergesort")
    _, inv, cuenta = np.unique(s[orden], return_inverse=True, return_counts=True)
    fin = np.cumsum(cuenta)
    rango_medio = (fin - cuenta + 1 + fin) / 2
    rangos = np.empty(y.size)
    rangos[orden] = rango_medio[inv]
    return float((rangos[y].sum() - n1 * (n1 + 1) / 2) / (n1 * n0))


def precision_promedio(y: np.ndarray, s: np.ndarray) -> float:
    """Average precision (área bajo la curva precisión-exhaustividad)."""
    y = y.astype(bool)
    if y.sum() == 0:
        return float("nan")
    ys = y[np.argsort(-s, kind="mergesort")]
    tp = np.cumsum(ys)
    precision = tp / np.arange(1, ys.size + 1)
    return float(precision[ys].mean())


def f1(y: np.ndarray, pred: np.ndarray) -> dict[str, float]:
    y, pred = y.astype(bool), pred.astype(bool)
    tp = float((y & pred).sum())
    p = tp / max(pred.sum(), 1)
    r = tp / max(y.sum(), 1)
    return {"precision": p, "exhaustividad": r, "f1": 2 * p * r / max(p + r, 1e-12)}


def mejor_umbral_f1(y: np.ndarray, prob: np.ndarray) -> float:
    candidatos = np.linspace(0.05, 0.95, 91)
    return float(max(candidatos, key=lambda u: f1(y, prob >= u)["f1"]))


def ocurrencia(y: np.ndarray, prob: np.ndarray, umbral: float) -> dict[str, float]:
    return {
        "positivos_pct": 100 * float(y.mean()),
        "auc_roc": auc_roc(y, prob),
        "precision_promedio": precision_promedio(y, prob),
        "umbral_prob": umbral,
        **f1(y, prob >= umbral),
    }


def conteo(y_log: np.ndarray, pred_log: np.ndarray) -> dict[str, float]:
    return {
        "mae_log": float(np.abs(y_log - pred_log).mean()),
        "r_log": float(np.corrcoef(y_log, pred_log)[0, 1]),
    }


def totales(obs: np.ndarray, pred: np.ndarray) -> dict[str, float]:
    """Mismas métricas que analisis/serie-armonizada.md, sobre totales mensuales."""
    ok = obs > 0
    obs, pred = obs[ok], pred[ok]
    return {
        "meses": int(ok.sum()),
        "r": float(np.corrcoef(obs, pred)[0, 1]),
        "sesgo_pct": float(pred.sum() / obs.sum() * 100 - 100),
        "error_mediano_pct": float(np.median(np.abs(pred - obs) / obs) * 100),
    }
