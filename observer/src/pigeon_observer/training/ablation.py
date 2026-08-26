"""Ablation configuration.

An ablation is a *representation* of which model capabilities are removed. It is
pure data (serializable) and can be turned into a concrete
:class:`ObserverModelConfig` via :func:`ablation_to_model_config`.

Flags:
* ``no_temporal``              collapse sequence to T=1, skip the temporal encoder
* ``no_telemetry_to_vision``   forbid using telemetry (force vision-only source)
* ``no_vision_to_telemetry``   forbid using vision (force telemetry-only source)
* ``no_intervention_metadata`` advisory flag (the data layer enforces it)

Plus sequence-shape controls used for short/long sequence and stride studies:
``sequence_length`` and ``stride``.
"""
from __future__ import annotations

from dataclasses import dataclass, field, asdict
from typing import Dict, Optional

from ..models.config import ObserverModelConfig


@dataclass
class AblationConfig:
    name: str = "baseline"
    no_temporal: bool = False
    no_telemetry_to_vision: bool = False
    no_vision_to_telemetry: bool = False
    no_intervention_metadata: bool = False
    sequence_length: Optional[int] = None
    stride: int = 1

    def to_dict(self) -> Dict:
        return asdict(self)

    @classmethod
    def from_dict(cls, d: Dict) -> "AblationConfig":
        known = {f for f in cls.__dataclass_fields__}  # type: ignore[attr-defined]
        cleaned = {k: v for k, v in dict(d).items() if k in known}
        return cls(**cleaned)


def ablation_to_model_config(base: ObserverModelConfig,
                             ablation: AblationConfig) -> ObserverModelConfig:
    """Derive a concrete model config from a base config and an ablation."""
    d = base.to_dict()

    if ablation.no_telemetry_to_vision and ablation.no_vision_to_telemetry:
        raise ValueError("Cannot disable both telemetry and vision sources")
    if ablation.no_telemetry_to_vision:
        d["mode"] = "vision"
    elif ablation.no_vision_to_telemetry:
        d["mode"] = "telemetry"

    if ablation.no_temporal:
        # T=1 single-step context: transformer with max_seq=1 and a short GRU.
        d["sequence_length"] = 1
        d["temporal"] = "gru"

    if ablation.sequence_length is not None:
        d["sequence_length"] = int(ablation.sequence_length)

    cfg = ObserverModelConfig.from_dict(d)
    return cfg
