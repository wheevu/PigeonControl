"""Convert a raw Julia run directory into an immutable Parquet run.

Contract
--------
Input (raw ingest boundary, ``pigeon-observer-raw-v1``):

* ``raw_run.toml``  - completed run metadata
* ``ticks.csv``     - per-tick aggregate rows (explicit schema)
* ``pigeons.csv``   - per pigeon per tick rows (explicit schema)
* ``foods.csv``     - per food per tick rows (explicit schema)
* ``interventions.csv`` - scheduled interventions
* ``frame_index.csv``  - tick -> frame file mapping
* ``frames/``          - rendered RGB PNGs

Output (immutable, ``pigeon-observer-v1``):

* ``runs/<run_id>/ticks.parquet``
* ``runs/<run_id>/pigeons.parquet``
* ``runs/<run_id>/foods.parquet``
* ``runs/<run_id>/interventions.parquet``
* ``runs/<run_id>/frames/...`` (copied PNGs) + ``frame_index.csv`` (copied)
* ``runs/<run_id>/run_manifest.json``

Overwrite is refused. Staging is atomic via ``os.replace``.
"""

from __future__ import annotations

import json
import os
import shutil
from pathlib import Path
from typing import Any, Dict, List

import pyarrow as pa
import pyarrow.parquet as pq

from .. import schema as S
from ._util import (
    atomic_publish,
    read_raw_csv,
    read_raw_run_toml,
    sha256_file,
    write_parquet_atomic,
)


def _require_completed(raw_dir: Path) -> dict:
    meta = read_raw_run_toml(raw_dir)
    missing = [k for k in S.RAW_RUN_TOML_REQUIRED if k not in meta]
    if missing:
        raise ValueError(f"raw_run.toml missing required keys: {missing}")
    if str(meta.get("status", "")).lower() != "completed":
        raise ValueError(
            f"raw run is not completed (status={meta.get('status')!r}); refusing to convert"
        )
    declared = meta.get("schema_version")
    if declared is not None and declared != S.RAW_SCHEMA_VERSION:
        raise ValueError(
            f"raw schema_version mismatch: {declared!r} != {S.RAW_SCHEMA_VERSION!r}"
        )
    return meta


def _sort_table(table: pa.Table, table_name: str) -> pa.Table:
    keys = {
        "ticks": [("tick", "ascending")],
        "pigeons": [("tick", "ascending"), ("pigeon_id", "ascending")],
        "foods": [("tick", "ascending"), ("food_id", "ascending")],
        "interventions": [("tick", "ascending")],
        "frame_index": [("tick", "ascending")],
    }[table_name]
    return table.sort_by(keys)


def _tag_metadata(table: pa.Table, table_name: str, meta: dict) -> pa.Table:
    existing = table.schema.metadata or {}
    new_meta = {
        **existing,
        b"dataset_version": S.DATASET_VERSION.encode(),
        b"schema_version": S.RAW_SCHEMA_VERSION.encode(),
        b"table": table_name.encode(),
        b"run_id": str(meta["run_id"]).encode(),
        b"seed": str(int(meta["seed"])).encode(),
    }
    return table.replace_schema_metadata(new_meta)


def convert_raw_run(raw_dir: Path, dataset_root: Path) -> Dict[str, Any]:
    """Convert a completed raw run into an immutable Parquet run.

    Returns a summary dict describing the converted run (run_id, seed, counts,
    file hashes, output directory).
    """
    raw_dir = Path(raw_dir)
    dataset_root = Path(dataset_root)

    meta = _require_completed(raw_dir)
    run_id = str(meta["run_id"])

    runs_dir = dataset_root / "runs"
    final_run_dir = runs_dir / run_id
    if final_run_dir.exists():
        raise FileExistsError(
            f"refusing to overwrite existing converted run: {final_run_dir}"
        )

    # Atomic staging location.
    staging_root = dataset_root / ".staging"
    staging_root.mkdir(parents=True, exist_ok=True)
    staging_run = staging_root / f"{run_id}.{os.getpid()}"
    if staging_run.exists():
        shutil.rmtree(staging_run)
    staging_run.mkdir(parents=True)

    files: Dict[str, str] = {}
    tables_written: List[str] = []

    # Convert each raw CSV -> parquet (explicit schema, no inference).
    for csv_name, table_name in S.RAW_CSV_FILES.items():
        src = raw_dir / csv_name
        if not src.exists():
            raise FileNotFoundError(f"missing required raw file: {src}")
        table = read_raw_csv(src, table_name)
        table = _sort_table(table, table_name)
        table = _tag_metadata(table, table_name, meta)
        out_name = f"{table_name}.parquet"
        out_path = staging_run / out_name
        write_parquet_atomic(table, out_path, staging_root / ".parquet_stage")
        files[out_name] = sha256_file(out_path)
        tables_written.append(out_name)

    # Copy frame files referenced by frame_index.csv.
    frame_index_path = staging_run / "frame_index.csv"
    # The frame_index parquet already exists; copy the raw index csv as well for
    # provenance, then copy the PNGs it references.
    raw_index = raw_dir / "frame_index.csv"
    if raw_index.exists():
        shutil.copy2(raw_index, frame_index_path)
        files["frame_index.csv"] = sha256_file(frame_index_path)

    frames_dir = staging_run / "frames"
    frames_dir.mkdir(parents=True, exist_ok=True)
    with open(raw_dir / "frame_index.csv", "r", newline="") as fh:
        header = fh.readline().rstrip("\r\n").split(",")
        tick_i = header.index("tick")
        file_i = header.index("frame_file")
        width_i = header.index("width")
        height_i = header.index("height")
        n_frames = 0
        for line in fh:
            line = line.rstrip("\r\n")
            if not line.strip():
                continue
            parts = line.split(",")
            _tick = parts[tick_i]
            frame_file = parts[file_i]
            width = int(parts[width_i])
            height = int(parts[height_i])
            src_frame = raw_dir / "frames" / frame_file
            if not src_frame.exists():
                raise FileNotFoundError(f"missing frame file: {src_frame}")
            dst_frame = frames_dir / frame_file
            dst_frame.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src_frame, dst_frame)
            files[f"frames/{frame_file}"] = sha256_file(dst_frame)
            n_frames += 1

    # Run manifest.
    run_manifest = {
        "run_id": run_id,
        "seed": int(meta["seed"]),
        "scenario": str(meta["scenario"]),
        "config_name": str(meta["config_name"]),
        "n_pigeons": int(meta["n_pigeons"]),
        "tick_start": int(meta["tick_start"]),
        "tick_end": int(meta["tick_end"]),
        "sample_cadence": int(meta["sample_cadence"]),
        "frame_cadence": int(meta["frame_cadence"]),
        "frame_format": str(meta["frame_format"]),
        "schema_version": S.RAW_SCHEMA_VERSION,
        "dataset_version": S.DATASET_VERSION,
        "tables": tables_written,
        "frame_count": n_frames,
        "files": files,
    }
    manifest_path = staging_run / "run_manifest.json"
    with open(manifest_path, "w") as fh:
        json.dump(run_manifest, fh, indent=2, sort_keys=True)
        fh.write("\n")

    # Atomic publish.
    atomic_publish(staging_run, final_run_dir)

    # Remove the parquet temp staging dir left under .staging.
    parquet_stage = staging_root / ".parquet_stage"
    if parquet_stage.exists():
        shutil.rmtree(parquet_stage, ignore_errors=True)
    # If .staging is now empty, remove it so conversion leaves no stray dirs.
    if staging_root.exists() and not any(staging_root.iterdir()):
        staging_root.rmdir()

    return {
        "run_id": run_id,
        "seed": int(meta["seed"]),
        "scenario": str(meta["scenario"]),
        "config_name": str(meta["config_name"]),
        "n_pigeons": int(meta["n_pigeons"]),
        "n_ticks": int(meta["tick_end"]) - int(meta["tick_start"]) + 1,
        "n_frames": n_frames,
        "output_dir": str(final_run_dir),
        "files": files,
    }
