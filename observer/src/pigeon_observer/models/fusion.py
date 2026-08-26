"""Fusion of per-step modality encodings ``[B, T, H]`` -> ``[B, T, H]``.

Cross-attention is intentionally out of scope. Two strategies are provided:
concatenation followed by a projection, and a learned sigmoid gate.
"""
from __future__ import annotations

import torch
import torch.nn as nn
import torch.nn.functional as F


class ConcatFusion(nn.Module):
    def __init__(self, hidden_dim: int) -> None:
        super().__init__()
        self.proj = nn.Linear(hidden_dim * 2, hidden_dim)

    def forward(self, a: torch.Tensor, b: torch.Tensor) -> torch.Tensor:
        return self.proj(torch.cat([a, b], dim=-1))


class GatedFusion(nn.Module):
    def __init__(self, hidden_dim: int) -> None:
        super().__init__()
        self.gate = nn.Linear(hidden_dim * 2, hidden_dim)
        self.proj = nn.Linear(hidden_dim, hidden_dim)

    def forward(self, a: torch.Tensor, b: torch.Tensor) -> torch.Tensor:
        gate = torch.sigmoid(self.gate(torch.cat([a, b], dim=-1)))
        fused = gate * a + (1.0 - gate) * b
        return self.proj(fused)
