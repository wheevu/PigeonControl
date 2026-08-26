"""Validate a converted dataset for integrity, schema, and leakage.

``validate_dataset`` checks: file hashes, Arrow schemas + versions, primary-key
uniqueness, finite numeric values, sample-tick continuity, frame decode and
dimensions, exact frame/tick correspondence, single-split run membership, and
the absence of seed leakage across splits.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, List

import numpy as np
import pyarrow as pa
import pyarrow.parquet as pq
from PIL import Image

from .. import schema as S
from ._util import sha256_file


@dataclass
class ValidationReport:
    """Result of :func:`validate_dataset`."""

    ok: bool = True
    errors: List[str] = field(default_factory=list)
    warnings: List[str] = field(default_factory=list)
    stats: Dict[str, Any] = field(default_factory=dict)

    def error(self, msg: str) -> None:
        self.errors.append(msg)
        self.ok = False

    def warn(self, msg: str) -> None:
        self.warnings.append(msg)

    def to_dict(self) -> Dict[str, Any]:
        return {
            "ok": self.ok,
            "errors": list(self.errors),
            "warnings": list(self.warnings),
            "stats": self.stats,
        }

    def to_json(self, indent: int = 2) -> str:
        return json.dumps(self.to_dict(), indent=indent, sort_keys=True)


def _key_for(table_name: str) -> List[str]:
    return {
        "ticks": ["tick"],
        "pigeons": ["tick", "pigeon_id"],
        "foods": ["tick", "food_id"],
        "interventions": ["tick"],
    }[table_name]


def _check_schema(table: pa.Table, table_name: str, report: ValidationReport, run_id: str) -> None:
    meta = table.schema.metadata or {}
    sv = meta.get(b"schema_version")
    if sv != S.RAW_SCHEMA_VERSION.encode():
        report.error(
            f"[{run_id}] {table_name}.parquet schema_version={sv!r} "
            f"!= {S.RAW_SCHEMA_VERSION!r}"
        )
    expected = S.raw_schema(table_name)
    actual_names = table.schema.names
    required = [name for name in expected.names if name not in ("schema_version", "run_id")]
    # Rich producer tables may carry additional provenance columns.
    if table_name == "pigeons":
        required = [name for name in actual_names if name not in ("schema_version", "run_id")]
    if not all(name in actual_names for name in required):
        report.error(
            f"[{run_id}] {table_name}.parquet column mismatch: "
            f"{actual_names} != {expected.names}"
        )
        return
    for fs in S.field_specs(table_name):
        if fs.name not in actual_names:
            continue
        i = actual_names.index(fs.name)
        actual_type = table.schema.field(i).type
        if actual_type != fs.pa_type:
            report.error(
                f"[{run_id}] {table_name}.{fs.name} type {actual_type} "
                f"!= expected {fs.pa_type}"
            )


def _check_uniqueness(table: pa.Table, keys: List[str], report: ValidationReport, run_id: str, table_name: str) -> None:
    import pandas as pd  # local import; fixture-friendly

    cols = [table.column(k).to_numpy(zero_copy_only=False) for k in keys]
    df = pd.DataFrame({k: c for k, c in zip(keys, cols)})
    dup = int(df.duplicated(subset=keys).sum())
    if dup > 0:
        report.error(f"[{run_id}] {table_name} has {dup} duplicate {keys} rows")


def _check_finite(table: pa.Table, report: ValidationReport, run_id: str, table_name: str) -> None:
    for fs in S.field_specs(table_name):
        if not pa.types.is_floating(fs.pa_type):
            continue
        if fs.nullable:
            continue  # NaN/null allowed (e.g. absent threat)
        if fs.name not in table.column_names:
            continue
        col = table.column(fs.name).to_numpy(zero_copy_only=False)
        if not np.all(np.isfinite(col)):
            report.error(f"[{run_id}] {table_name}.{fs.name} has non-finite values")


def _check_continuity(ticks_table: pa.Table, rm: dict, report: ValidationReport, run_id: str) -> List[int]:
    ticks = ticks_table.column("tick").to_numpy(zero_copy_only=False)
    ticks = np.sort(ticks)
    cadence = int(rm["sample_cadence"])
    start = int(rm["tick_start"])
    end = int(rm["tick_end"])
    expected = np.arange(start, end + 1, cadence, dtype=ticks.dtype)
    if ticks.shape != expected.shape or not np.array_equal(ticks, expected):
        report.error(
            f"[{run_id}] tick continuity broken: got {ticks.shape[0]} ticks, "
            f"expected arithmetic cadence {cadence} from {start}..{end}"
        )
    return [int(t) for t in ticks]


def _check_frames(run_dir: Path, rm: dict, report: ValidationReport, run_id: str) -> List[int]:
    frame_index_csv = run_dir / "frame_index.csv"
    if not frame_index_csv.exists():
        report.error(f"[{run_id}] missing frame_index.csv")
        return []
    import pandas as pd

    idx = pd.read_csv(frame_index_csv)
    present_ticks = sorted(int(t) for t in idx["tick"].tolist())
    for _, row in idx.iterrows():
        fpath = run_dir / "frames" / str(row["frame_file"])
        if not fpath.exists():
            report.error(f"[{run_id}] missing frame file {row['frame_file']}")
            continue
        try:
            with Image.open(fpath) as im:
                im.load()
                w, h = im.size
            if int(w) != int(row["width"]) or int(h) != int(row["height"]):
                report.error(
                    f"[{run_id}] frame {row['frame_file']} size {w}x{h} "
                    f"!= index {int(row['width'])}x{int(row['height'])}"
                )
        except Exception as exc:  # noqa: BLE001
            report.error(f"[{run_id}] failed to decode frame {row['frame_file']}: {exc}")
    cadence = int(rm["frame_cadence"])
    if cadence <= 0:
        # Frame-free runs still carry an empty frame index.
        return []
    start = int(rm["tick_start"])
    end = int(rm["tick_end"])
    expected_frames = list(range(start, end + 1, cadence))
    if present_ticks != expected_frames:
        report.error(
            f"[{run_id}] frame/tick mismatch: {len(present_ticks)} frames "
            f"vs {len(expected_frames)} expected at cadence {cadence}"
        )
    return present_ticks


def validate_dataset(root: Path) -> ValidationReport:
    """Validate a converted dataset rooted at ``root`` and return a report."""
    root = Path(root)
    report = ValidationReport()

    manifest_path = root / "manifest.json"
    if not manifest_path.exists():
        report.error(f"missing dataset manifest at {manifest_path}")
        return report

    with open(manifest_path) as fh:
        manifest = json.load(fh)
    if manifest.get("dataset_version") != S.DATASET_VERSION:
        report.error(
            f"manifest dataset_version={manifest.get('dataset_version')!r} "
            f"!= {S.DATASET_VERSION!r}"
        )

    splits = manifest.get("splits", {})
    run_to_seed = {str(k): int(v) for k, v in manifest.get("run_to_seed", {}).items()}
    seed_to_split = {int(k): v for k, v in manifest.get("seed_to_split", {}).items()}

    all_run_ids = set(run_to_seed.keys())
    assigned = set()
    for split, run_ids in splits.items():
        for rid in run_ids:
            if rid in assigned:
                report.error(f"run {rid} assigned to multiple splits")
            assigned.add(rid)
    missing = all_run_ids - assigned
    if missing:
        report.error(f"runs not present in any split: {sorted(missing)}")
    extra = assigned - all_run_ids
    if extra:
        report.error(f"split-listed runs with no manifest entry: {sorted(extra)}")

    # Actual split each run is in (derived from the split lists, not the desired
    # seed_to_split map) so leakage from a hand-edited manifest is caught.
    run_to_split: Dict[str, str] = {}
    for split, rids in splits.items():
        for rid in rids:
            run_to_split[rid] = split

    seed_split_seen: Dict[int, str] = {}
    for rid, seed in run_to_seed.items():
        split = run_to_split.get(rid)
        if split is None:
            report.error(f"seed {seed} (run {rid}) has no split assignment")
            continue
        if seed in seed_split_seen and seed_split_seen[seed] != split:
            report.error(
                f"seed {seed} leaked across splits: {seed_split_seen[seed]} vs {split}"
            )
        seed_split_seen[seed] = split

    for split, run_ids in splits.items():
        if not run_ids:
            report.warn(f"split '{split}' is empty")

    runs_dir = root / "runs"
    total_ticks = 0
    total_frames = 0

    for rid in sorted(assigned):
        run_dir = runs_dir / rid
        rm_path = run_dir / "run_manifest.json"
        if not rm_path.exists():
            report.error(f"[{rid}] missing run_manifest.json")
            continue
        with open(rm_path) as fh:
            rm = json.load(fh)

        for rel, expected_hash in rm.get("files", {}).items():
            fpath = run_dir / rel
            if not fpath.exists():
                report.error(f"[{rid}] missing hashed file {rel}")
                continue
            actual = sha256_file(fpath)
            if actual != expected_hash:
                report.error(f"[{rid}] hash mismatch for {rel}")

        for table_name in ("ticks", "pigeons", "foods", "interventions"):
            parquet_path = run_dir / f"{table_name}.parquet"
            if not parquet_path.exists():
                report.error(f"[{rid}] missing {table_name}.parquet")
                continue
            try:
                table = pq.read_table(parquet_path)
            except Exception as exc:  # noqa: BLE001
                report.error(f"[{rid}] cannot read {table_name}.parquet: {exc}")
                continue
            _check_schema(table, table_name, report, rid)
            _check_uniqueness(table, _key_for(table_name), report, rid, table_name)
            _check_finite(table, report, rid, table_name)
            if table_name == "ticks":
                tick_list = _check_continuity(table, rm, report, rid)
                total_ticks += len(tick_list)

        frames = _check_frames(run_dir, rm, report, rid)
        total_frames += len(frames)

    report.stats = {
        "n_runs": len(assigned),
        "n_seeds": len(seed_split_seen),
        "splits": {s: len(r) for s, r in splits.items()},
        "total_ticks": total_ticks,
        "total_frames": total_frames,
    }
    return report
