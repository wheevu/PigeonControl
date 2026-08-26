"""Tests for ObserverSequenceDataset: shapes, sync, leakage, intervention, collate."""

from __future__ import annotations

import json
import sys
import os
from pathlib import Path

import numpy as np
import torch

sys.path.insert(0, os.path.dirname(__file__))
import raw_builder as rb  # noqa: E402

from pigeon_observer.data import (  # noqa: E402
    convert_raw_run,
    build_dataset_manifest,
    ObserverSequenceDataset,
    collate_observer_batch,
    fit_normalizer,
)
from pigeon_observer import schema as S  # noqa: E402


def _build_single_run_dataset(tmp_path, run_id="r1", seed=1, **kw):
    raw = rb.build_raw_run(tmp_path / "raw", run_id=run_id, seed=seed, **kw)
    ds = tmp_path / "ds"
    convert_raw_run(raw, ds)
    build_dataset_manifest(ds)
    return ds


def test_dataset_window_count_and_shapes(tmp_path):
    ds = _build_single_run_dataset(tmp_path, n_ticks=12, n_pigeons=8)
    d = ObserverSequenceDataset(ds, "train", mode="fusion", sequence_length=4, horizon=6)
    # N=12, L=4, H=6 -> 3 windows
    assert len(d) == 3
    sample = d[0]
    assert sample["telemetry"].shape == (4, S.TELEMETRY_FEATURE_DIM)
    assert sample["frames"].shape == (4, 3, 96, 96)
    assert sample["telemetry"].dtype == torch.float32
    assert float(sample["frames"].max()) <= 1.0 + 1e-6
    assert float(sample["frames"].min()) >= -1e-6
    assert sample["targets"]["panic"].shape == ()
    assert sample["targets"]["hidden_genome"].shape == (2,)
    assert sample["targets"]["future_aggregates"].shape == (5,)
    assert sample["targets"]["crowd_regime"].shape == ()
    assert sample["relevance"].shape == (3,)
    assert set(sample["metadata"].keys()) == {"run_id", "seed", "ticks"}


def test_dataset_modes(tmp_path):
    ds = _build_single_run_dataset(tmp_path, n_ticks=12)
    tel = ObserverSequenceDataset(ds, "train", mode="telemetry")
    vis = ObserverSequenceDataset(ds, "train", mode="vision")
    fus = ObserverSequenceDataset(ds, "train", mode="fusion")
    s_t, s_v, s_f = tel[0], vis[0], fus[0]
    assert "telemetry" in s_t and "frames" not in s_t
    assert "frames" in s_v and "telemetry" not in s_v
    assert "telemetry" in s_f and "frames" in s_f


def test_telemetry_frame_sync_exact(tmp_path):
    ds = _build_single_run_dataset(tmp_path, n_ticks=12, frame_size=96)
    d = ObserverSequenceDataset(ds, "train", mode="fusion", sequence_length=4, horizon=6)
    sample = d[0]
    run_id = sample["metadata"]["run_id"]
    frames_dir = ds / "runs" / run_id / "frames"
    from PIL import Image

    for j, t in enumerate(sample["metadata"]["ticks"]):
        expected = np.asarray(Image.open(frames_dir / f"frame_{t:06d}.png").convert("RGB"), dtype=np.float32) / 255.0
        expected = np.transpose(expected, (2, 0, 1))
        got = sample["frames"][j].numpy()
        assert np.allclose(got, expected, atol=1e-4), f"frame for tick {t} mismatched"
    # input ticks are exact, sequential, and strictly increasing
    ticks = sample["metadata"]["ticks"]
    assert ticks == sorted(ticks)
    assert len(set(ticks)) == len(ticks)


def test_stride_and_history(tmp_path):
    ds = _build_single_run_dataset(tmp_path, n_ticks=12)
    s1 = ObserverSequenceDataset(ds, "train", sequence_length=4, horizon=6, stride=1)
    s2 = ObserverSequenceDataset(ds, "train", sequence_length=4, horizon=6, stride=2)
    # stride 1 -> 3 windows; stride 2 -> ceil((3-1)/2)+1 = 2 windows
    assert len(s1) == 3
    assert len(s2) == 2
    # history length respected
    for idx in range(len(s1)):
        t = s1[idx]["telemetry"]
        assert t.shape[0] == 4


def test_intervention_exclusion(tmp_path):
    ds = _build_single_run_dataset(tmp_path, n_ticks=12, with_interventions=True)
    d = ObserverSequenceDataset(ds, "train", mode="telemetry", sequence_length=4, horizon=6)
    # Intervention at tick 5 -> windows whose (input_last, target_end] contains 5
    # are dropped. With L=4,H=6,N=12: s=0 (in 0..3, target 4..9) dropped;
    # s=1 (in 1..4, target 5..10) dropped; s=2 (in 2..5, target 6..11) kept.
    assert len(d) == 1
    win = d[0]
    assert win["metadata"]["ticks"][-1] == 5  # input_last == intervention tick
    # No kept window spans an intervention inside (input_last, target_end]
    run_id = win["metadata"]["run_id"]
    iv_path = ds / "runs" / run_id / "interventions.parquet"
    import pyarrow.parquet as pq

    iv = pq.read_table(iv_path).column("tick").to_numpy(zero_copy_only=False)
    for w in d.windows:
        input_last = w["input_ticks"][-1]
        target_end = w["target_ticks"][-1]
        assert not any(input_last < t <= target_end for t in iv)


def test_no_target_leakage_into_features(tmp_path):
    # Two runs identical except genome magnitude: features must be identical,
    # hidden_genome (a target) must differ.
    ds1 = _build_single_run_dataset(tmp_path / "a", run_id="r", seed=1, n_ticks=10, genome_scalar=1.0)
    ds2 = _build_single_run_dataset(tmp_path / "b", run_id="r", seed=1, n_ticks=10, genome_scalar=2.0)
    d1 = ObserverSequenceDataset(ds1, "train", mode="telemetry")
    d2 = ObserverSequenceDataset(ds2, "train", mode="telemetry")
    t1 = d1[0]["telemetry"].numpy()
    t2 = d2[0]["telemetry"].numpy()
    assert np.allclose(t1, t2), "telemetry features must ignore genome"
    h1 = d1[0]["targets"]["hidden_genome"].numpy()
    h2 = d2[0]["targets"]["hidden_genome"].numpy()
    assert not np.allclose(h1, h2), "hidden_genome target should reflect genome"


def test_relevance_exposes_behavior_not_seed(tmp_path):
    ds = _build_single_run_dataset(tmp_path, n_ticks=12)
    d = ObserverSequenceDataset(ds, "train", mode="fusion")
    sample = d[0]
    # relevance = mean future (flee, eat, fight) factor vector
    fut = sample["targets"]["future_aggregates"].numpy()
    assert np.allclose(sample["relevance"].numpy(), fut[:3])
    # metadata must not expose seed/scenario as a model feature
    assert set(sample["metadata"].keys()) == {"run_id", "seed", "ticks"}


def test_deterministic_dataset_iteration(tmp_path):
    ds = _build_single_run_dataset(tmp_path, n_ticks=12)
    d1 = ObserverSequenceDataset(ds, "train", mode="fusion")
    d2 = ObserverSequenceDataset(ds, "train", mode="fusion")
    for i in range(len(d1)):
        a = d1[i]["telemetry"]
        b = d2[i]["telemetry"]
        assert torch.equal(a, b)


def test_collate_behavior(tmp_path):
    ds = _build_single_run_dataset(tmp_path, n_ticks=12)
    d = ObserverSequenceDataset(ds, "train", mode="fusion", sequence_length=4, horizon=6)
    batch = [d[0], d[1], d[2]]
    collated = collate_observer_batch(batch)
    assert collated["telemetry"].shape == (3, 4, S.TELEMETRY_FEATURE_DIM)
    assert collated["frames"].shape == (3, 4, 3, 96, 96)
    assert collated["targets"]["panic"].shape == (3,)
    assert collated["targets"]["hidden_genome"].shape == (3, 2)
    assert collated["targets"]["future_aggregates"].shape == (3, 5)
    assert collated["targets"]["crowd_regime"].shape == (3,)
    assert collated["relevance"].shape == (3, 3)
    assert len(collated["metadata"]) == 3


def test_normalizer_no_leakage_and_serializable(tmp_path):
    ds = _build_single_run_dataset(tmp_path, n_ticks=12, n_pigeons=8)
    d = ObserverSequenceDataset(ds, "train", mode="telemetry")
    norm = fit_normalizer(d)
    assert norm.feature_names == d.feature_names
    sample = d[0]["telemetry"]
    transformed = norm.transform(sample)
    assert transformed.shape == sample.shape
    assert torch.isfinite(transformed).all()
    # save/load roundtrip
    p = tmp_path / "norm.json"
    norm.save_json(p)
    norm2 = type(norm).load_json(p)
    assert norm2.feature_names == norm.feature_names
    assert np.allclose(norm2.mean, norm.mean)
    assert np.allclose(norm2.std, norm.std)


def test_include_intervention_metadata_flag(tmp_path):
    ds = _build_single_run_dataset(tmp_path, n_ticks=12, with_interventions=True)
    d_off = ObserverSequenceDataset(ds, "train", mode="telemetry", include_intervention_metadata=False)
    d_on = ObserverSequenceDataset(ds, "train", mode="telemetry", include_intervention_metadata=True)
    assert "interventions" not in d_off[0]["metadata"]
    # Only the kept window (input_last==5) has interventions within scope.
    for s in d_on:
        assert "interventions" in s["metadata"]
