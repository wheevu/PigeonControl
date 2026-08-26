"""Checkpoint save / load.

A checkpoint stores everything needed to reconstruct the model exactly and to
resume training:

* ``model_config``      plain dict of :class:`ObserverModelConfig`
* ``state_dict``        model weights
* ``optimizer_state``   optimizer state dict
* ``epoch``             last completed epoch
* ``normalization``     externally supplied scalar stats (or None)
* ``schema_hash``       feature schema hash
* ``split_hash``        split manifest hash
* ``config_hash``       full training config hash

``load_checkpoint`` validates the required keys and reconstructs the model,
returning ``(model, metadata)`` where metadata is every non-weight field.
"""
from __future__ import annotations

import hashlib
import json
from typing import Any, Dict, Optional, Tuple

import torch

from ..models.config import ObserverModelConfig
from ..models.factory import build_model

REQUIRED_KEYS = (
    "model_config",
    "state_dict",
    "optimizer_state",
    "epoch",
    "normalization",
    "schema_hash",
    "split_hash",
    "config_hash",
)


def make_hash(obj: Any) -> str:
    payload = json.dumps(obj, sort_keys=True, default=str).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def save_checkpoint(path, model, optimizer, epoch: int,
                    normalization: Optional[Dict] = None,
                    schema_hash: str = "", split_hash: str = "",
                    config_hash: str = "") -> None:
    ckpt: Dict[str, Any] = {
        "model_config": model.get_config().to_dict(),
        "state_dict": model.state_dict(),
        "optimizer_state": optimizer.state_dict() if optimizer is not None else {},
        "epoch": epoch,
        "normalization": normalization,
        "schema_hash": schema_hash,
        "split_hash": split_hash,
        "config_hash": config_hash,
    }
    torch.save(ckpt, path)


def load_checkpoint(path, map_location: str = "cpu") -> Tuple[torch.nn.Module, Dict]:
    ckpt = torch.load(path, map_location=map_location, weights_only=True)
    missing = [k for k in REQUIRED_KEYS if k not in ckpt]
    if missing:
        raise KeyError(f"Checkpoint missing required keys: {missing}")

    cfg = ObserverModelConfig.from_dict(ckpt["model_config"])
    model = build_model(cfg)
    model.load_state_dict(ckpt["state_dict"])
    if ckpt["normalization"]:
        model.set_normalization(
            ckpt["normalization"]["mean"], ckpt["normalization"]["std"]
        )
    model.eval()

    metadata = {k: v for k, v in ckpt.items() if k not in ("state_dict", "optimizer_state")}
    return model, metadata
