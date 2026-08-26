"""Build the dataset manifest and deterministic train/validation/test splits.

Splits are assigned by **seed**, never by run or frame. The same seed always
lands in exactly one split, even when it spans multiple scenarios or runs. This
guarantees no seed leakage across splits.

Bucket rule (stable, salted SHA-256):

* hash = sha256(f"{split_salt}:{seed}")  ->  take leading uint  ->  mod 10
* 0..7  -> train (80%)
* 8     -> validation (10%)
* 9     -> test (10%)
"""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
from typing import Any, Dict, List, Optional

import pyarrow as pa
import pyarrow.parquet as pq

from .. import schema as S
from ._util import read_parquet


def _seed_bucket(seed: int, split_salt: str) -> str:
    payload = f"{split_salt}:{int(seed)}".encode()
    digest = hashlib.sha256(payload).hexdigest()
    bucket = int(digest[:8], 16) % 10
    if bucket <= S.SPLIT_BUCKET_TRAIN_MAX:
        return S.SPLIT_TRAIN
    if bucket == S.SPLIT_BUCKET_VALIDATION:
        return S.SPLIT_VALIDATION
    return S.SPLIT_TEST


def _discover_runs(dataset_root: Path) -> List[Dict[str, Any]]:
    runs_dir = dataset_root / "runs"
    if not runs_dir.exists():
        return []
    discovered = []
    for run_dir in sorted(runs_dir.iterdir()):
        if not run_dir.is_dir():
            continue
        manifest_path = run_dir / "run_manifest.json"
        if not manifest_path.exists():
            continue
        with open(manifest_path) as fh:
            rm = json.load(fh)
        discovered.append(
            {
                "run_id": str(rm["run_id"]),
                "seed": int(rm["seed"]),
                "scenario": str(rm.get("scenario", "")),
                "config_name": str(rm.get("config_name", "")),
                "n_pigeons": int(rm.get("n_pigeons", 0)),
            }
        )
    return discovered


def build_dataset_manifest(
    dataset_root: Path,
    *,
    split_salt: str = S.DEFAULT_SPLIT_SALT,
    explicit_splits: Optional[Dict[int, str]] = None,
) -> Dict[str, Any]:
    """Discover converted runs and write the dataset manifest + split files.

    ``explicit_splits`` is an optional ``{seed: split}`` override, intended for
    tiny fixtures where an exact assignment is wanted. Production assignment is
    otherwise owned by the stable seed bucketing above.

    Returns the manifest dict.
    """
    dataset_root = Path(dataset_root)
    runs = _discover_runs(dataset_root)
    if not runs:
        raise ValueError(f"no converted runs found under {dataset_root / 'runs'}")

    explicit = {int(k): v for k, v in (explicit_splits or {}).items()}
    for seed, split in explicit.items():
        if split not in S.SPLIT_NAMES:
            raise ValueError(f"explicit split for seed {seed} is invalid: {split!r}")

    seed_to_split: Dict[int, str] = {}
    run_to_seed: Dict[str, int] = {}
    run_records: Dict[str, Dict[str, Any]] = {}

    for run in runs:
        seed = int(run["seed"])
        run_id = run["run_id"]
        run_to_seed[run_id] = seed
        run_records[run_id] = run
        if seed in explicit:
            seed_to_split[seed] = explicit[seed]
        else:
            seed_to_split[seed] = _seed_bucket(seed, split_salt)

    # Group runs by split (keyed by seed -> every run of that seed shares split).
    splits: Dict[str, List[str]] = {s: [] for s in S.SPLIT_NAMES}
    for run_id, seed in run_to_seed.items():
        splits[seed_to_split[seed]].append(run_id)
    for s in splits:
        splits[s].sort()

    n_seeds = len(seed_to_split)

    manifest = {
        "dataset_version": S.DATASET_VERSION,
        "raw_schema_version": S.RAW_SCHEMA_VERSION,
        "split_salt": split_salt,
        "n_runs": len(runs),
        "n_seeds": n_seeds,
        "splits": splits,
        "seed_to_split": {str(k): v for k, v in sorted(seed_to_split.items())},
        "run_to_seed": {k: v for k, v in sorted(run_to_seed.items())},
    }
    if explicit:
        manifest["explicit_splits"] = {str(k): v for k, v in sorted(explicit.items())}

    # Write manifest.json and splits/<split>.json atomically-ish.
    manifest_path = dataset_root / "manifest.json"
    with open(manifest_path, "w") as fh:
        json.dump(manifest, fh, indent=2, sort_keys=True)
        fh.write("\n")

    splits_dir = dataset_root / "splits"
    splits_dir.mkdir(parents=True, exist_ok=True)
    seeds_in_split: Dict[str, List[int]] = {s: [] for s in S.SPLIT_NAMES}
    for seed, split in seed_to_split.items():
        seeds_in_split[split].append(seed)
    for split in S.SPLIT_NAMES:
        split_doc = {
            "split": split,
            "run_ids": splits[split],
            "seeds": sorted(seeds_in_split[split]),
        }
        with open(splits_dir / f"{split}.json", "w") as fh:
            json.dump(split_doc, fh, indent=2, sort_keys=True)
            fh.write("\n")

    return manifest
