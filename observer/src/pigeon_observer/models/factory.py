"""Model factory and model-level utilities (parameter count, inference latency)."""
from __future__ import annotations

import math
import time
from typing import Dict, Optional

import torch

from .config import ObserverModelConfig
from .model import ObserverModel


def build_model(config: ObserverModelConfig) -> ObserverModel:
    """Construct an :class:`ObserverModel` from a config object or plain dict."""
    if isinstance(config, dict):
        config = ObserverModelConfig.from_dict(config)
    return ObserverModel(config)


def parameter_count(model: torch.nn.Module) -> int:
    return sum(p.numel() for p in model.parameters())


def inference_latency(model: torch.nn.Module, batch: Dict,
                      device: Optional[str] = None,
                      n_warmup: int = 2, n_runs: int = 10) -> Dict[str, float]:
    """Return timing statistics (seconds) for a single ``forward`` call.

    All returned values are finite. Runs under ``torch.no_grad`` and ``eval``.
    """
    if device is None:
        device = next(model.parameters()).device.type
    model.to(device)
    model.eval()

    def _move(x):
        if isinstance(x, torch.Tensor):
            return x.to(device)
        if isinstance(x, dict):
            return {k: _move(v) for k, v in x.items()}
        return x

    batch = _move(batch)
    if device == "cuda":
        torch.cuda.synchronize()

    with torch.no_grad():
        for _ in range(n_warmup):
            model(batch)
        if device == "cuda":
            torch.cuda.synchronize()

        times: list[float] = []
        for _ in range(n_runs):
            if device == "cuda":
                torch.cuda.synchronize()
            t0 = time.perf_counter()
            model(batch)
            if device == "cuda":
                torch.cuda.synchronize()
            times.append(time.perf_counter() - t0)

    import statistics
    stats = {
        "mean": statistics.fmean(times),
        "std": statistics.pstdev(times) if len(times) > 1 else 0.0,
        "min": min(times),
        "max": max(times),
        "n_runs": float(n_runs),
    }
    for v in stats.values():
        if not math.isfinite(v):
            raise ValueError("inference_latency produced a non-finite measurement")
    return stats
