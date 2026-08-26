"""Tests for build_dataset_manifest: stable assignment, seed leakage, determinism."""

from __future__ import annotations

import json
import sys
import os

sys.path.insert(0, os.path.dirname(__file__))
import raw_builder as rb  # noqa: E402

from pigeon_observer.data import convert_raw_run, build_dataset_manifest  # noqa: E402
from pigeon_observer.data.validate import validate_dataset  # noqa: E402
from pigeon_observer import schema as S  # noqa: E402


def _convert_runs(tmp_path, specs):
    raw_root = tmp_path / "raw"
    ds = tmp_path / "ds"
    for spec in specs:
        raw = rb.build_raw_run(raw_root, **spec)
        convert_raw_run(raw, ds)
    return ds


def test_manifest_writes_splits_and_discovers(tmp_path):
    ds = _convert_runs(
        tmp_path,
        [
            dict(run_id="r1", seed=1, n_ticks=8),
            dict(run_id="r2", seed=2, n_ticks=8),
        ],
    )
    manifest = build_dataset_manifest(ds)
    assert (ds / "manifest.json").exists()
    for split in S.SPLIT_NAMES:
        assert (ds / "splits" / f"{split}.json").exists()
    all_runs = [r for v in manifest["splits"].values() for r in v]
    assert set(all_runs) == {"r1", "r2"}
    assert manifest["n_runs"] == 2
    assert manifest["n_seeds"] == 2


def test_same_seed_same_split_across_scenarios(tmp_path):
    ds = _convert_runs(
        tmp_path,
        [
            dict(run_id="rA", seed=123, scenario="plaza"),
            dict(run_id="rB", seed=123, scenario="storm"),  # same seed, diff scenario
            dict(run_id="rC", seed=999, scenario="plaza"),
        ],
    )
    manifest = build_dataset_manifest(ds)
    # rA and rB share seed 123 -> identical split.
    sA = next(s for s, rs in manifest["splits"].items() if "rA" in rs)
    sB = next(s for s, rs in manifest["splits"].items() if "rB" in rs)
    assert sA == sB
    # seed 123 appears in exactly one split.
    seed_splits = {v for k, v in manifest["seed_to_split"].items() if int(k) == 123}
    assert seed_splits == {sA}


def test_no_seed_leakage_in_manifest(tmp_path):
    specs = [dict(run_id=f"r{i}", seed=100 + i, n_ticks=8) for i in range(20)]
    ds = _convert_runs(tmp_path, specs)
    manifest = build_dataset_manifest(ds, split_salt="pigeon-observer-v1")
    report = validate_dataset(ds)
    assert report.ok, report.errors
    # No seed should be present in more than one split.
    seed_split_map = {}
    for run_id, seed in manifest["run_to_seed"].items():
        split = next(s for s, rs in manifest["splits"].items() if run_id in rs)
        if seed in seed_split_map:
            assert seed_split_map[seed] == split
        else:
            seed_split_map[seed] = split
    # 80/10/10 is approximately respected for 20 seeds (mod 10 bucketing).
    counts = {s: len(rs) for s, rs in manifest["splits"].items()}
    assert counts["train"] >= counts["validation"]
    assert counts["train"] >= counts["test"]


def test_explicit_splits_for_tiny_fixture(tmp_path):
    ds = _convert_runs(
        tmp_path,
        [
            dict(run_id="r1", seed=1, n_ticks=8),
            dict(run_id="r2", seed=2, n_ticks=8),
            dict(run_id="r3", seed=3, n_ticks=8),
        ],
    )
    manifest = build_dataset_manifest(ds, explicit_splits={1: "train", 2: "validation", 3: "test"})
    assert set(manifest["splits"]["train"]) == {"r1"}
    assert set(manifest["splits"]["validation"]) == {"r2"}
    assert set(manifest["splits"]["test"]) == {"r3"}
    assert manifest["explicit_splits"] == {"1": "train", "2": "validation", "3": "test"}


def test_seed_leakage_rejected_by_validator(tmp_path):
    ds = _convert_runs(
        tmp_path,
        [
            dict(run_id="r1", seed=7, n_ticks=8),
            dict(run_id="r2", seed=7, n_ticks=8, scenario="storm"),
        ],
    )
    build_dataset_manifest(ds)  # both r1,r2 -> same split initially
    # Craft a leaking manifest: move r2 to a different split than r1.
    manifest_path = ds / "manifest.json"
    m = json.loads(manifest_path.read_text())
    # find r1's split, put r2 in a different one
    r1_split = next(s for s, rs in m["splits"].items() if "r1" in rs)
    other = [s for s in S.SPLIT_NAMES if s != r1_split][0]
    m["splits"][r1_split].remove("r2")
    m["splits"][other].append("r2")
    m["splits"][other].sort()
    manifest_path.write_text(json.dumps(m, indent=2))
    report = validate_dataset(ds)
    assert not report.ok
    assert any("leaked across splits" in e for e in report.errors)


def test_deterministic_split_assignment(tmp_path):
    specs = [dict(run_id=f"r{i}", seed=50 + i, n_ticks=8) for i in range(10)]
    ds1 = _convert_runs(tmp_path / "a", specs)
    ds2 = _convert_runs(tmp_path / "b", specs)
    m1 = build_dataset_manifest(ds1, split_salt="salt")
    m2 = build_dataset_manifest(ds2, split_salt="salt")
    assert m1["seed_to_split"] == m2["seed_to_split"]
