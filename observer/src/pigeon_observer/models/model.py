"""The observer model.

:class:`ObserverModel` is the single entry point for inference. It consumes a
*batch dict* (the contract shared with the sibling data layer) and always returns
the same five keys regardless of ``mode``:

* ``embedding``            ``[B, E]``
* ``panic_logits``         ``[B]``
* ``hidden_genome``        ``[B, 2]``
* ``future_aggregates``    ``[B, K]``
* ``crowd_regime_logits``  ``[B, n_regimes]``

Contract / batch dict keys (all optional except what the mode needs):

* ``telemetry``     ``[B, T, F]``  numeric (normalized externally if provided)
* ``frames``        ``[B, T, C, H, W]``
* ``categorical``   ``[B, T, C]``  long indices into configured embeddings
* ``targets``       dict of supervision tensors (ignored by ``forward``)

Unknown keys (e.g. ``metadata``) are ignored: ``forward`` only reads the keys
above, so it is target- and metadata-independent.
"""
from __future__ import annotations

from typing import Dict, Optional

import torch
import torch.nn as nn

from .config import ObserverModelConfig
from .encoders import TelemetryEncoder, VisualEncoder
from .fusion import ConcatFusion, GatedFusion
from .temporal import GRUTemporal, TransformerTemporal


class ObserverModel(nn.Module):
    def __init__(self, config: ObserverModelConfig) -> None:
        super().__init__()
        self.config = config
        H = config.hidden_dim

        self.telemetry_encoder = TelemetryEncoder(
            config.telemetry_dim, H,
            config.categorical_features, config.categorical_embed_dim,
        )
        self.visual_encoder = VisualEncoder(config.image_channels, H)

        if config.temporal == "gru":
            self.temporal = GRUTemporal(H)
        else:
            self.temporal = TransformerTemporal(
                H, config.num_heads, config.num_layers, config.dropout,
                config.sequence_length,
            )

        self.fusion: Optional[nn.Module] = None
        if config.mode == "fusion":
            self.fusion = ConcatFusion(H) if config.fusion == "concat" else GatedFusion(H)

        # Heads operate on the time-aggregated vector [B, H].
        self.embedding_proj = nn.Linear(H, config.embedding_dim)
        self.panic_head = nn.Linear(H, 1)
        self.genome_head = nn.Linear(H, 2)
        self.future_head = nn.Linear(H, config.future_dim)
        self.regime_head = nn.Linear(H, config.n_regimes)

        # Externally supplied scalar normalization, applied to telemetry only.
        self.register_buffer("norm_mean", torch.zeros(config.telemetry_dim))
        self.register_buffer("norm_std", torch.ones(config.telemetry_dim))
        self._norm_set = False

    # -- normalization ----------------------------------------------------
    def set_normalization(self, mean, std) -> None:
        if mean is not None:
            self.norm_mean.copy_(torch.as_tensor(mean, dtype=torch.float32).reshape(-1))
        if std is not None:
            self.norm_std.copy_(torch.as_tensor(std, dtype=torch.float32).reshape(-1))
        self._norm_set = True

    @property
    def normalization(self) -> Optional[Dict[str, list]]:
        if not self._norm_set:
            return None
        return {
            "mean": self.norm_mean.detach().cpu().tolist(),
            "std": self.norm_std.detach().cpu().tolist(),
        }

    # -- forward ----------------------------------------------------------
    def forward(self, batch: Dict) -> Dict[str, torch.Tensor]:
        telemetry = batch.get("telemetry")
        frames = batch.get("frames")
        categorical = batch.get("categorical")

        encodings: list[torch.Tensor] = []

        if self.config.mode in ("telemetry", "fusion") and telemetry is not None:
            t = telemetry.float()
            if self._norm_set:
                t = (t - self.norm_mean) / (self.norm_std + 1e-8)
            te = self.telemetry_encoder(t, categorical)
            te = self.temporal(te)
            encodings.append(te)

        if self.config.mode in ("vision", "fusion") and frames is not None:
            B, T, C, Hh, Ww = frames.shape
            f = frames.float().reshape(B * T, C, Hh, Ww)
            fe = self.visual_encoder(f)
            fe = fe.reshape(B, T, self.config.hidden_dim)
            fe = self.temporal(fe)
            encodings.append(fe)

        if not encodings:
            raise ValueError(
                "ObserverModel.forward received a batch with no usable modality "
                f"for mode={self.config.mode!r} (need 'telemetry' and/or 'frames')."
            )

        if len(encodings) == 1 or self.fusion is None:
            enc = encodings[0]
        else:
            enc = self.fusion(encodings[0], encodings[1])

        agg = enc.mean(dim=1)  # [B, H]

        return {
            "embedding": self.embedding_proj(agg),
            "panic_logits": self.panic_head(agg).squeeze(-1),
            "hidden_genome": self.genome_head(agg),
            "future_aggregates": self.future_head(agg),
            "crowd_regime_logits": self.regime_head(agg),
        }

    def get_config(self) -> ObserverModelConfig:
        return self.config
