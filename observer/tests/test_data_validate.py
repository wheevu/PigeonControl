"""Tests for validate_dataset: integrity, frame correspondence, leakage, warnings."""

from __future__ import annotations

import csv
import json
import sys
import os

sys.path.insert(0, os.path.dirname(__file__))
import raw_builder as rb  # noqa: E402

from pigeon_observer.data import convert_raw_run, build_dataset_manifest  # noqa: E402
from pigeon_observer.data.validate import validate_dataset  # noqa: E402


def _good_dataset(tmp_path, specs):
    raw_root = tmp_path / "raw"
    ds = tmp_path / "ds"
    for spec in specs:
        raw = rb.build_raw_run(raw_root, **spec)
        convert_raw_run(raw, ds)
    build_dataset_manifest(ds)
    return ds


def test_validate_clean_run_ok(tmp_path):
    ds = _good_dataset(tmp_path, [dict(run_id="r1", seed=1, n_ticks=12, n_pigeons=8)])
    report = validate_dataset(ds)
    assert report.ok, report.errors
    assert report.stats["n_runs"] == 1
    assert report.stats["total_ticks"] == 12
    assert report.stats["total_frames"] == 12


def test_validate_detects_hash_tamper(tmp_path):
    ds = _good_dataset(tmp_path, [dict(run_id="r1", seed=1, n_ticks=8)])
    run_dir = ds / "runs" / "r1"
    pq_path = run_dir / "ticks.parquet"
    data = pq_path.read_bytes()
    pq_path.write_bytes(data[:-1] + bytes([data[-1] ^ 0xFF]))
    report = validate_dataset(ds)
    assert not report.ok
    assert any("hash mismatch" in e for e in report.errors)


def test_validate_frame_tick_correspondence(tmp_path):
    ds = _good_dataset(tmp_path, [dict(run_id="r1", seed=1, n_ticks=10, frame_cadence=1)])
    run_dir = ds / "runs" / "r1"
    idx_path = run_dir / "frame_index.csv"
    lines = idx_path.read_text().splitlines()
    header, rows = lines[0], lines[1:]
    drop = rows[0]
    drop_tick = drop.split(",")[0]
    idx_path.write_text(header + "\n" + "\n".join(rows[1:]) + "\n")
    with open(idx_path) as fh:
        remaining = {row["tick"] for row in csv.DictReader(fh)}
    assert drop_tick not in remaining
    report = validate_dataset(ds)
    assert not report.ok
    assert any("frame/tick mismatch" in e or "missing frame file" in e for e in report.errors)


def test_validate_empty_split_warns_not_fails(tmp_path):
    ds = _good_dataset(
        tmp_path,
        [
            dict(run_id="r1", seed=1, n_ticks=8),
            dict(run_id="r2", seed=2, n_ticks=8),
            dict(run_id="r3", seed=3, n_ticks=8),
        ],
    )
    mpath = ds / "manifest.json"
    m = json.loads(mpath.read_text())
    for s in ("validation", "test"):
        m["splits"][s] = []
    mpath.write_text(json.dumps(m, indent=2))
    report = validate_dataset(ds)
    assert report.ok, report.errors
    assert any("empty" in w for w in report.warnings)


def test_validate_key_uniqueness(tmp_path):
    ds = _good_dataset(tmp_path, [dict(run_id="r1", seed=1, n_ticks=8, n_pigeons=6)])
    run_dir = ds / "runs" / "r1"
    import pyarrow as pa
    import pyarrow.parquet as pq

    tbl = pq.read_table(run_dir / "pigeons.parquet")
    combined = pa.concat_tables([tbl, tbl.slice(0, 1)])  # one duplicated (tick, pigeon_id)
    pq.write_table(combined, run_dir / "pigeons.parquet")
    report = validate_dataset(ds)
    assert not report.ok
    assert any("duplicate" in e for e in report.errors)
