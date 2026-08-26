"""Tests for convert_raw_run: deterministic conversion, hashing, atomicity, refusal."""

from __future__ import annotations

import json
import sys
import os

sys.path.insert(0, os.path.dirname(__file__))
import raw_builder as rb  # noqa: E402

from pigeon_observer.data import convert_raw_run  # noqa: E402


def _hashes(dataset_root):
    run = next((dataset_root / "runs").iterdir())
    with open(run / "run_manifest.json") as fh:
        rm = json.load(fh)
    return {k: v for k, v in rm["files"].items()}


def test_convert_creates_parquet_and_manifest(tmp_path):
    raw = rb.build_raw_run(tmp_path / "raw", run_id="runA", seed=1, n_pigeons=6, n_ticks=10)
    out = convert_raw_run(raw, tmp_path / "ds")
    run_dir = tmp_path / "ds" / "runs" / "runA"
    assert run_dir.exists()
    for name in ("ticks", "pigeons", "foods", "interventions"):
        assert (run_dir / f"{name}.parquet").exists()
    assert (run_dir / "run_manifest.json").exists()
    assert (run_dir / "frame_index.csv").exists()
    assert (run_dir / "frames").exists()
    assert out["run_id"] == "runA"
    assert out["seed"] == 1
    assert out["n_frames"] == 10  # cadence 1, 10 ticks


def test_convert_refuses_overwrite(tmp_path):
    raw = rb.build_raw_run(tmp_path / "raw", run_id="runA", seed=1)
    convert_raw_run(raw, tmp_path / "ds")
    try:
        convert_raw_run(raw, tmp_path / "ds")
        assert False, "expected FileExistsError"
    except FileExistsError:
        pass


def test_convert_deterministic_hashes(tmp_path):
    raw = rb.build_raw_run(tmp_path / "raw", run_id="runA", seed=42, n_pigeons=8, n_ticks=12)
    ds1 = tmp_path / "ds1"
    ds2 = tmp_path / "ds2"
    convert_raw_run(raw, ds1)
    convert_raw_run(raw, ds2)
    h1 = _hashes(ds1)
    h2 = _hashes(ds2)
    assert h1 == h2, "conversion must be byte-for-byte deterministic"
    # frame file hashes equal too
    assert h1["frames/frame_000000.png"] == h2["frames/frame_000000.png"]


def test_convert_stamps_arrow_metadata(tmp_path):
    import pyarrow.parquet as pq

    raw = rb.build_raw_run(tmp_path / "raw", run_id="runA", seed=3, n_ticks=8)
    convert_raw_run(raw, tmp_path / "ds")
    tbl = pq.read_table(tmp_path / "ds" / "runs" / "runA" / "ticks.parquet")
    meta = tbl.schema.metadata
    assert meta.get(b"schema_version") == b"pigeon-observer-raw-v1"
    assert meta.get(b"dataset_version") == b"pigeon-observer-v1"
    assert meta.get(b"run_id") == b"runA"


def test_convert_rejects_incomplete_run(tmp_path):
    raw = rb.build_raw_run(tmp_path / "raw", run_id="runA", seed=3)
    # Mark as not completed.
    toml = raw / "raw_run.toml"
    text = toml.read_text().replace('status = "completed"', 'status = "running"')
    toml.write_text(text)
    try:
        convert_raw_run(raw, tmp_path / "ds")
        assert False, "expected ValueError for incomplete run"
    except ValueError as e:
        assert "completed" in str(e)


def test_convert_atomic_no_staging_leftover(tmp_path):
    raw = rb.build_raw_run(tmp_path / "raw", run_id="runA", seed=5, n_ticks=6)
    convert_raw_run(raw, tmp_path / "ds")
    staging = tmp_path / "ds" / ".staging"
    # The published run dir exists; the per-run staging dir is gone.
    assert (tmp_path / "ds" / "runs" / "runA").exists()
    if staging.exists():
        assert list(staging.iterdir()) == [], "staging dir should be empty after publish"
