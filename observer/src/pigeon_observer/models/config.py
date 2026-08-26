"""Observer model configuration.

Defines :class:`ObserverModelConfig`, a plain dataclass describing every knob the
observer model needs. It is fully serializable to/from plain dicts so it can be
embedded in checkpoints, training configs, and ablation specs.
"""
from __future__ import annotations

from dataclasses import dataclass, field, asdict
from typing import Dict, List, Optional

MODES = ("telemetry", "vision", "fusion")
TEMPORALS = ("gru", "transformer")
FUSIONS = ("concat", "gated")


@dataclass
class ObserverModelConfig:
    """Configuration contract for :class:`pigeon_observer.models.model.ObserverModel`.

    Everything here is a plain value so the config survives TOML/JSON round-trips
    and checkpoint storage unchanged.
    """

    mode: str = "fusion"                      # telemetry | vision | fusion
    temporal: str = "transformer"             # gru | transformer
    telemetry_dim: int = 1                    # F: numeric telemetry features
    hidden_dim: int = 128
    embedding_dim: int = 64                   # E: task-independent embedding size
    sequence_length: int = 16                 # configured max temporal context
    image_channels: int = 3
    num_heads: int = 4
    num_layers: int = 2
    dropout: float = 0.1
    fusion: str = "concat"                    # concat | gated
    n_regimes: int = 5
    future_dim: int = 5                        # K: future aggregate targets
    categorical_features: Dict[str, int] = field(default_factory=dict)
    categorical_embed_dim: int = 16

    def __post_init__(self) -> None:
        if self.mode not in MODES:
            raise ValueError(f"mode must be one of {MODES}, got {self.mode!r}")
        if self.temporal not in TEMPORALS:
            raise ValueError(f"temporal must be one of {TEMPORALS}, got {self.temporal!r}")
        if self.fusion not in FUSIONS:
            raise ValueError(f"fusion must be one of {FUSIONS}, got {self.fusion!r}")
        if self.telemetry_dim <= 0:
            raise ValueError("telemetry_dim must be positive")
        if self.hidden_dim <= 0:
            raise ValueError("hidden_dim must be positive")
        if self.embedding_dim <= 0:
            raise ValueError("embedding_dim must be positive")
        if self.sequence_length <= 0:
            raise ValueError("sequence_length must be positive")
        if self.num_heads <= 0:
            raise ValueError("num_heads must be positive")
        if self.hidden_dim % self.num_heads != 0:
            raise ValueError("hidden_dim must be divisible by num_heads")
        if self.n_regimes <= 0:
            raise ValueError("n_regimes must be positive")
        if self.future_dim <= 0:
            raise ValueError("future_dim must be positive")

    def to_dict(self) -> Dict:
        return asdict(self)

    @classmethod
    def from_dict(cls, d: Dict) -> "ObserverModelConfig":
        known = {f for f in cls.__dataclass_fields__}  # type: ignore[attr-defined]
        cleaned = {k: v for k, v in dict(d).items() if k in known}
        return cls(**cleaned)
