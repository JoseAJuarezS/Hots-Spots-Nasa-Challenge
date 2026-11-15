"""Arquitectura de la red: codificador temporal (Conv1d + GRU) + contexto + dos cabezas.

Entrada por muestra (una celda y un mes objetivo t):
  seq  (L, C)  los L meses anteriores a t de la celda (ver datos.CANALES)
  ctx  (K,)    contexto del mes objetivo: estacionalidad, posición y normal histórica
Salida:
  logit de P(focos(t) >= umbral)          -> "¿habrá actividad de quema?"
  log(1 + focos(t)) esperado (>= 0)       -> "¿cuánta?"
"""

from __future__ import annotations

import torch
from torch import nn
from torch.nn import functional as F

CONTEXTO = ["mes_sin", "mes_cos", "lat", "lon", "clim_log", "clim_frec"]


class RedIncendios(nn.Module):
    def __init__(self, n_canales: int, n_contexto: int, oculto: int = 64, dropout: float = 0.2):
        super().__init__()
        # Normalización (se fija con los datos de ajuste y viaja con el modelo)
        self.register_buffer("media_seq", torch.zeros(n_canales))
        self.register_buffer("desv_seq", torch.ones(n_canales))
        self.register_buffer("media_ctx", torch.zeros(n_contexto))
        self.register_buffer("desv_ctx", torch.ones(n_contexto))

        # 1) Patrones locales en el tiempo (subidas, picos de 2-3 meses)
        self.conv = nn.Sequential(
            nn.Conv1d(n_canales, 32, kernel_size=3, padding=1), nn.GELU(),
            nn.Conv1d(32, 32, kernel_size=3, padding=1), nn.GELU(),
        )
        # 2) Memoria de la secuencia completa (estación anterior, mismo mes del año pasado)
        self.gru = nn.GRU(32, oculto, batch_first=True)
        # 3) Contexto del mes que se quiere predecir
        self.ctx = nn.Sequential(nn.Linear(n_contexto, 32), nn.GELU())
        # 4) Fusión
        self.tronco = nn.Sequential(
            nn.Linear(oculto + 32, 128), nn.GELU(), nn.Dropout(dropout),
            nn.Linear(128, 64), nn.GELU(),
        )
        self.cabeza_ocurrencia = nn.Linear(64, 1)
        self.cabeza_conteo = nn.Linear(64, 1)

    def fijar_normalizacion(self, seq: torch.Tensor, ctx: torch.Tensor) -> None:
        """seq (B, L, C) y ctx (B, K) de una muestra representativa del ajuste."""
        self.media_seq.copy_(seq.mean((0, 1)))
        self.desv_seq.copy_(seq.std((0, 1)).clamp_min(1e-3))
        self.media_ctx.copy_(ctx.mean(0))
        self.desv_ctx.copy_(ctx.std(0).clamp_min(1e-3))

    def forward(self, seq: torch.Tensor, ctx: torch.Tensor) -> tuple[torch.Tensor, torch.Tensor]:
        seq = (seq - self.media_seq) / self.desv_seq
        ctx = (ctx - self.media_ctx) / self.desv_ctx
        h = self.conv(seq.transpose(1, 2)).transpose(1, 2)   # (B, L, 32)
        _, h_final = self.gru(h)                              # (1, B, oculto)
        z = self.tronco(torch.cat([h_final[-1], self.ctx(ctx)], dim=1))
        logit = self.cabeza_ocurrencia(z).squeeze(1)
        log_focos = F.softplus(self.cabeza_conteo(z)).squeeze(1)
        return logit, log_focos
