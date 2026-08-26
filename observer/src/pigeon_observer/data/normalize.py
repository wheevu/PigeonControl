"""Training-only normalization.

``fit_normalizer`` computes per-feature mean/std **only** from the dataset it is
given. Callers must pass a dataset built from the training split exclusively, so
validation/test statistics never leak into the normalizer. The fitted
:class:`Normalizer` is serializable and applies a deterministic, leakage-free
transform.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Dict, Union

import numpy as np

from .. import schema as S

ArrayLike = Union[np.ndarray, "object"]  # torch.Tensor accepted at runtime


class Normalizer:
    """Per-feature z-score normalizer with serializable stats."""

    def __init__(self, feature_names: list, mean: np.ndarray, std: np.ndarray, eps: float = 1e-6):
        self.feature_names = list(feature_names)
        self.mean = np.asarray(mean, dtype=np.float64)
        self.std = np.asarray(std, dtype=np.float64)
        self.std = np.maximum(self.std, eps)
        self.eps = float(eps)
        if len(self.feature_names) != self.mean.shape[0]:
            raise ValueError("feature_names length mismatch with mean")

    def to_dict(self) -> Dict[str, Any]:
        return {
            "feature_names": self.feature_names,
            "mean": self.mean.tolist(),
            "std": self.std.tolist(),
            "eps": self.eps,
            "dataset_version": S.DATASET_VERSION,
        }

    @classmethod
    def from_dict(cls, d: Dict[str, Any]) -> "Normalizer":
        return cls(d["feature_names"], np.asarray(d["mean"]), np.asarray(d["std"]), eps=float(d.get("eps", 1e-6)))

    def save_json(self, path: Union[str, Path]) -> None:
        with open(path, "w") as fh:
            json.dump(self.to_dict(), fh, indent=2, sort_keys=True)
            fh.write("\n")

    @classmethod
    def load_json(cls, path: Union[str, Path]) -> "Normalizer":
        with open(path) as fh:
            return cls.from_dict(json.load(fh))

    def transform(self, x):
        """Normalize ``x`` (numpy or torch) along the last axis."""
        import torch

        mean = self.mean.reshape((1,) * (x.ndim - 1) + (-1,))
        std = self.std.reshape((1,) * (x.ndim - 1) + (-1,))
        if isinstance(x, torch.Tensor):
            m = torch.as_tensor(mean, dtype=x.dtype, device=x.device)
            s = torch.as_tensor(std, dtype=x.dtype, device=x.device)
            return (x - m) / s
        arr = np.asarray(x, dtype=np.float64)
        return (arr - mean) / std

    def __repr__(self) -> str:  # pragma: no cover - debug aid
        return f"Normalizer(F={len(self.feature_names)})"


def fit_normalizer(dataset) -> Normalizer:
    """Fit a :class:`Normalizer` from a dataset's telemetry windows.

    Only the supplied ``dataset`` is used (typically the training split). This is
    the single sanctioned path to normalization statistics; there is no global
    fit, so validation/test leakage is impossible by construction.
    """
    rows = []
    feature_names = list(dataset.feature_names)
    for tele in dataset.telemetry_stream():
        rows.append(np.asarray(tele, dtype=np.float64))
    if not rows:
        raise ValueError("dataset produced no telemetry windows; cannot fit normalizer")
    mat = np.concatenate(rows, axis=0)  # [M, F]
    mean = mat.mean(axis=0)
    std = mat.std(axis=0)
    return Normalizer(feature_names, mean, std)
