"""Multitask loss for the observer model.

Combines:
* panic          - BCE with logits (binary)
* hidden_genome  - MSE
* future         - MSE over aggregates
* regime         - cross entropy over crowd regimes

Each term is optional: only targets present in the batch contribute, and each
has a configurable weight.
"""
from __future__ import annotations

from typing import Dict, Optional

import torch
import torch.nn.functional as F


DEFAULT_WEIGHTS: Dict[str, float] = {
    "panic": 1.0,
    "genome": 1.0,
    "future": 1.0,
    "regime": 1.0,
}


def compute_loss(outputs: Dict[str, torch.Tensor],
                 targets: Dict[str, torch.Tensor],
                 weights: Optional[Dict[str, float]] = None) -> Dict[str, torch.Tensor]:
    w = dict(DEFAULT_WEIGHTS)
    if weights:
        w.update(weights)

    panic = targets.get("panic")
    genome = targets.get("hidden_genome")
    future = targets.get("future_aggregates")
    regime = targets.get("crowd_regime")

    parts: Dict[str, torch.Tensor] = {}
    if panic is not None:
        parts["panic"] = w["panic"] * F.binary_cross_entropy_with_logits(
            outputs["panic_logits"], panic.float()
        )
    if genome is not None:
        parts["genome"] = w["genome"] * F.mse_loss(
            outputs["hidden_genome"], genome.float()
        )
    if future is not None:
        parts["future"] = w["future"] * F.mse_loss(
            outputs["future_aggregates"], future.float()
        )
    if regime is not None:
        parts["regime"] = w["regime"] * F.cross_entropy(
            outputs["crowd_regime_logits"], regime.long()
        )

    if not parts:
        raise ValueError("compute_loss received a targets dict with no known keys")

    total = sum(parts.values())
    result: Dict[str, torch.Tensor] = {"loss": total}
    for k, v in parts.items():
        result[k] = v.detach()
    result["loss"] = total  # keep graph on total
    return result
