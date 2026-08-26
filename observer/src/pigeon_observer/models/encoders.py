"""Encoders for the observer model.

Two independent per-step encoders:

* :class:`VisualEncoder` - a small CNN (no torchvision / foundation dependencies)
  that turns a single frame ``[C,H,W]`` into a ``hidden_dim`` vector.
* :class:`TelemetryEncoder` - normalizes scalar telemetry, optionally embeds
  categorical summary features supplied via config, then projects to
  ``hidden_dim``.
"""
from __future__ import annotations

from typing import Dict, List, Optional

import torch
import torch.nn as nn


class VisualEncoder(nn.Module):
    """Tiny conv encoder. Processes one frame at a time, no external deps."""

    def __init__(self, in_channels: int, hidden_dim: int,
                 stage_channels: tuple = (16, 32, 64, 64)) -> None:
        super().__init__()
        self.stage_channels = tuple(stage_channels)
        layers: List[nn.Module] = []
        c = in_channels
        for out in self.stage_channels:
            layers.append(nn.Conv2d(c, out, kernel_size=3, padding=1, bias=False))
            layers.append(nn.ReLU(inplace=True))
            layers.append(nn.MaxPool2d(kernel_size=2))
            c = out
        self.conv = nn.Sequential(*layers)
        self.proj = nn.Linear(c, hidden_dim)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        # x: [N, C, H, W] -> [N, hidden_dim]
        f = self.conv(x)
        f = torch.nn.functional.adaptive_avg_pool2d(f, (1, 1))
        f = torch.flatten(f, 1)
        return self.proj(f)


class TelemetryEncoder(nn.Module):
    """Structured telemetry encoder.

    Applies externally supplied scalar normalization (handled by the parent
    model before calling this encoder) and optionally embeds categorical summary
    features (behavior / archetype codes) whose presence is declared in config.
    """

    def __init__(self, telemetry_dim: int, hidden_dim: int,
                 categorical_features: Dict[str, int], categorical_embed_dim: int) -> None:
        super().__init__()
        self.telemetry_dim = telemetry_dim
        self.categorical_features = dict(categorical_features)
        self.has_cat = len(self.categorical_features) > 0
        cat_dim = categorical_embed_dim * len(self.categorical_features) if self.has_cat else 0
        self.cat_embeddings = nn.ModuleList(
            [nn.Embedding(num, categorical_embed_dim) for num in self.categorical_features.values()]
        )
        in_dim = telemetry_dim + cat_dim
        self.proj = nn.Sequential(
            nn.Linear(in_dim, hidden_dim),
            nn.ReLU(inplace=True),
            nn.Linear(hidden_dim, hidden_dim),
        )

    def forward(self, x: torch.Tensor,
                categorical: Optional[torch.Tensor] = None) -> torch.Tensor:
        # x: [B, T, F] (already normalized by caller)
        if self.has_cat and categorical is not None:
            if categorical.dim() != 3:
                raise ValueError("categorical must have shape [B, T, C]")
            pieces = [emb(categorical[:, :, i]) for i, emb in enumerate(self.cat_embeddings)]
            cat_vec = torch.cat(pieces, dim=-1)
            x = torch.cat([x, cat_vec], dim=-1)
        return self.proj(x)
