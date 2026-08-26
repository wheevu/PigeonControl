"""Tests for observer models: shapes across modes x temporals, eval determinism,
target/metadata independence, parameter count, and latency utility.
"""
from __future__ import annotations

import math

import torch

from pigeon_observer.models import (
    ObserverModelConfig, build_model, parameter_count, inference_latency, MODES, TEMPORALS,
)


def _make_batch(mode, B=2, T=6, F=4, H=16, W=16, K=5, with_cat=False):
    g = torch.Generator().manual_seed(0)
    batch = {}
    if mode in ("telemetry", "fusion"):
        batch["telemetry"] = torch.randn(B, T, F, generator=g)
        if with_cat:
            batch["categorical"] = torch.randint(0, 3, (B, T, 1))
    if mode in ("vision", "fusion"):
        batch["frames"] = torch.randn(B, T, 3, H, W, generator=g)
    return batch


def _expected_shapes(B=2, E=64, K=5, n_regimes=5):
    return {
        "embedding": (B, E),
        "panic_logits": (B,),
        "hidden_genome": (B, 2),
        "future_aggregates": (B, K),
        "crowd_regime_logits": (B, n_regimes),
    }


def test_shapes_all_modes_x_temporals():
    K, E, n_regimes = 5, 64, 5
    for mode in MODES:
        for temporal in TEMPORALS:
            cfg = ObserverModelConfig(
                mode=mode, temporal=temporal, telemetry_dim=4,
                sequence_length=8, future_dim=K, embedding_dim=E,
                n_regimes=n_regimes, num_heads=4, hidden_dim=32, num_layers=1,
                dropout=0.0,
            )
            model = build_model(cfg).eval()
            batch = _make_batch(mode)
            out = model(batch)
            exp = _expected_shapes(K=K, E=E, n_regimes=n_regimes)
            for key, shape in exp.items():
                assert key in out, f"missing {key} for {mode}/{temporal}"
                assert tuple(out[key].shape) == shape, \
                    f"{mode}/{temporal} {key}: got {tuple(out[key].shape)} want {shape}"


def test_eval_determinism():
    cfg = ObserverModelConfig(mode="fusion", temporal="transformer",
                              telemetry_dim=4, sequence_length=6, future_dim=5,
                              hidden_dim=32, embedding_dim=16, num_heads=4, num_layers=1,
                              dropout=0.0)
    model = build_model(cfg).eval()
    batch = _make_batch("fusion")
    with torch.no_grad():
        o1 = model(batch)
        o2 = model(batch)
    for k in o1:
        assert torch.equal(o1[k], o2[k]), f"non-deterministic output for {k}"


def test_metadata_independence():
    cfg = ObserverModelConfig(mode="fusion", temporal="gru",
                              telemetry_dim=4, sequence_length=6, future_dim=5,
                              hidden_dim=32, embedding_dim=16, num_heads=4, num_layers=1,
                              dropout=0.0)
    model = build_model(cfg).eval()
    batch = _make_batch("fusion")
    with torch.no_grad():
        out_clean = model(batch)
    # add an unknown metadata key that must be ignored
    batch_with_meta = dict(batch)
    batch_with_meta["metadata"] = {"source": "unknown", "extra": torch.randn(2, 3)}
    batch_with_meta["targets"] = {
        "panic": torch.tensor([0.0, 1.0]),
        "hidden_genome": torch.randn(2, 2),
        "future_aggregates": torch.randn(2, 5),
        "crowd_regime": torch.tensor([0, 1]),
    }
    with torch.no_grad():
        out_meta = model(batch_with_meta)
    for k in out_clean:
        assert torch.allclose(out_clean[k], out_meta[k], atol=1e-6), \
            f"metadata changed output for {k}"


def test_parameter_count_sane():
    # default-ish config must stay well under 10M params
    cfg = ObserverModelConfig(telemetry_dim=4, sequence_length=16, future_dim=5)
    n = parameter_count(build_model(cfg))
    assert n < 10_000_000, f"parameter count too large: {n}"
    assert n > 0


def test_latency_finite():
    cfg = ObserverModelConfig(mode="fusion", temporal="transformer",
                              telemetry_dim=4, sequence_length=6, future_dim=5,
                              hidden_dim=32, embedding_dim=16, num_heads=4, num_layers=1,
                              dropout=0.0)
    model = build_model(cfg).eval()
    batch = _make_batch("fusion", B=2, T=6)
    stats = inference_latency(model, batch, n_warmup=1, n_runs=3)
    for v in stats.values():
        assert math.isfinite(v), f"non-finite latency stat: {v}"
    assert stats["mean"] >= 0.0


def test_t1_no_temporal():
    # T=1 must work for both temporal encoders (no temporal context ablation)
    for temporal in TEMPORALS:
        cfg = ObserverModelConfig(mode="telemetry", temporal=temporal,
                                  telemetry_dim=4, sequence_length=1, future_dim=5,
                                  hidden_dim=32, embedding_dim=16, num_heads=4, num_layers=1,
                                  dropout=0.0)
        model = build_model(cfg).eval()
        batch = {"telemetry": torch.randn(2, 1, 4)}
        with torch.no_grad():
            out = model(batch)
        assert tuple(out["embedding"].shape) == (2, 16)


def _run():
    test_shapes_all_modes_x_temporals()
    test_eval_determinism()
    test_metadata_independence()
    test_parameter_count_sane()
    test_latency_finite()
    test_t1_no_temporal()
    print("test_models: ALL PASSED")


if __name__ == "__main__":
    _run()
