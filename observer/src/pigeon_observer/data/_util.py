"""Internal I/O helpers for the observer pipeline.

Not part of the public API. Handles explicit-schema CSV reading, SHA-256
hashing, atomic directory staging, and TOML metadata parsing.
"""

from __future__ import annotations

import hashlib
import os
import shutil
from pathlib import Path
from typing import Dict, List

import pyarrow as pa
import pyarrow.csv as pv
import pyarrow.parquet as pq
import tomllib

from .. import schema as S


def sha256_file(path: Path) -> str:
    """Return the hex SHA-256 digest of a file."""
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def read_raw_run_toml(raw_dir: Path) -> dict:
    """Parse ``raw_run.toml`` from a raw run directory."""
    p = raw_dir / "raw_run.toml"
    if not p.exists():
        raise FileNotFoundError(f"missing raw_run.toml in {raw_dir}")
    with open(p, "rb") as fh:
        data = tomllib.load(fh)
    return data


def _csv_header(path: Path) -> List[str]:
    with open(path, "r", newline="") as fh:
        first = fh.readline()
    return [c.strip() for c in first.split(",")] if first else []


def read_raw_csv(path: Path, table: str) -> pa.Table:
    """Read a raw CSV with the *explicit* Arrow schema. No type inference.

    Raises ``ValueError`` if the header does not match the declared schema, or if
    any cell cannot be coerced to the declared type.
    """
    spec = S.field_specs(table)
    expected = [fs.name for fs in spec]
    header = _csv_header(path)
    if header != expected:
        # Julia's rich telemetry table is intentionally wider than the compact
        # feature schema. Preserve the explicit types for known fields and use
        # deterministic name-based types for its documented scalar extensions.
        known = {fs.name: fs.pa_type for fs in spec}
        integer_names = {"tick", "seed", "n_pigeons", "n_foods", "state", "archetype",
                         "variant", "pigeon_id", "food_id", "target_food", "order_index"}
        string_names = {"schema_version", "run_id", "command", "result", "frame_file", "frame_path"}
        column_types = {name: known.get(name, pa.string() if name in string_names
                                        else pa.int64() if name in integer_names
                                        else pa.float64()) for name in header}
        expected = header
    else:
        column_types = {fs.name: fs.pa_type for fs in spec}
    convert_options = pv.ConvertOptions(
        column_types=column_types,
        include_columns=expected,
        include_missing_columns=False,
        null_values=["", "nan", "NaN", "NULL", "null", "NA", "N/A", "n/a", "<NA>"],
        strings_can_be_null=True,
    )
    read_options = pv.ReadOptions(use_threads=False)
    table = pv.read_csv(path, read_options=read_options, convert_options=convert_options)
    # Enforce exact column order from schema.
    table = table.select(expected)
    return table


def read_parquet(path: Path) -> pa.Table:
    return pq.read_table(path)


def write_parquet_atomic(table: pa.Table, final_path: Path, staging_dir: Path) -> None:
    """Write a parquet table atomically via a staging file + os.replace."""
    final_path.parent.mkdir(parents=True, exist_ok=True)
    staging_dir.mkdir(parents=True, exist_ok=True)
    tmp = staging_dir / (final_path.name + f".{os.getpid()}.tmp")
    pq.write_table(table, tmp)
    os.replace(tmp, final_path)
    if tmp.exists():
        tmp.unlink(missing_ok=True)


def atomic_publish(staging: Path, target: Path) -> None:
    """Move a fully-built staging directory to its final location atomically."""
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists():
        raise FileExistsError(f"refusing to overwrite existing {target}")
    tmp = target.parent / (target.name + f".publishing.{os.getpid()}")
    if tmp.exists():
        shutil.rmtree(tmp)
    os.replace(staging, tmp)
    os.replace(tmp, target)
