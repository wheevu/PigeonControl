"""Temporal sequence encoders producing per-step encodings ``[B, T, H]``.

Both implementations are ``batch_first`` and operate on already-frame-encoded
inputs. ``T=1`` (no temporal context) works for either: a transformer with a
single positional slot, or a GRU over one step.
"""
from __future__ import annotations

import torch
import torch.nn as nn


class GRUTemporal(nn.Module):
    def __init__(self, hidden_dim: int) -> None:
        super().__init__()
        self.gru = nn.GRU(hidden_dim, hidden_dim, batch_first=True)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        out, _ = self.gru(x)  # [B, T, H]
        return out


class TransformerTemporal(nn.Module):
    def __init__(self, hidden_dim: int, num_heads: int, num_layers: int,
                 dropout: float, max_seq: int) -> None:
        super().__init__()
        self.max_seq = int(max_seq)
        layer = nn.TransformerEncoderLayer(
            d_model=hidden_dim, nhead=num_heads, dropout=dropout, batch_first=True
        )
        self.encoder = nn.TransformerEncoder(layer, num_layers=num_layers)
        self.pos_embed = nn.Parameter(torch.zeros(1, self.max_seq, hidden_dim))

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        T = x.size(1)
        if T > self.max_seq:
            raise ValueError(f"sequence length {T} exceeds configured max_seq {self.max_seq}")
        x = x + self.pos_embed[:, :T, :]
        return self.encoder(x)  # [B, T, H]
