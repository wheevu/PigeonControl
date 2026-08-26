"""Deterministic generator for the observer v1 CI fixture.

This script is owned by the observer package. It produces a tiny, clearly
synthetic smoke dataset under tests/fixtures/v1 so CI and local smoke tests do
not depend on the full Julia/Godot generation pipeline.

Output (all deterministic given the fixed seed):

    v1/manifest.json              dataset manifest (seeds, scenarios, factors)
    v1/sequences/seq_{seed}_{i}.parquet   per-sequence telemetry + frame refs
    v1/frames/{seed}_{i}_{t}.png          tiny 8x8 synthetic frames

The data is synthetic and smoke-only. It is NOT a research training result.
"""

from __future__ import annotations

import json
import os
import struct
from typing import Dict, List

import numpy as np
import pyarrow as pa
import pyarrow.parquet as pq
from PIL import Image

SEED = 1234
N_SEEDS = 3
N_SEQS_PER_SEED = 4
N_TICKS = 20
N_FRAMES_PER_SEQ = 2
FEATURE_DIM = 6

SCENARIOS = [
    "baseline_idle",
    "bread_drop_single",
    "human_walkthrough",
    "combat_brawl",
]
BEHAVIOR_FACTORS = ["panic_mean", "fear_mean", "greed_mean", "combat"]


def _make_png(path: str, rng: np.random.Generator) -> None:
    arr = rng.integers(0, 256, size=(8, 8, 3), dtype=np.uint8)
    Image.fromarray(arr).save(path)


def main(root: str) -> Dict[str, object]:
    rng = np.random.default_rng(SEED)
    seq_dir = os.path.join(root, "sequences")
    frame_dir = os.path.join(root, "frames")
    os.makedirs(seq_dir, exist_ok=True)
    os.makedirs(frame_dir, exist_ok=True)

    manifest: Dict[str, object] = {
        "version": "v1",
        "synthetic": True,
        "note": "Synthetic smoke-only fixture. Not a research training result.",
        "seeds": [],
        "scenarios": SCENARIOS,
        "behavior_factors": BEHAVIOR_FACTORS,
        "sequences": [],
    }

    for s in range(N_SEEDS):
        seed = 1000 + s * 7
        manifest["seeds"].append(seed)
        for i in range(N_SEQS_PER_SEED):
            scenario = SCENARIOS[(s + i) % len(SCENARIOS)]
            seq_id = f"seq_{seed}_{i}"
            # Deterministic but seed-distinct behavior factors.
            panic = float(np.clip(rng.normal(0.3 + 0.1 * s, 0.1), 0, 1))
            fear = float(np.clip(rng.normal(0.4 + 0.05 * i, 0.1), 0, 1))
            greed = float(np.clip(rng.normal(0.5 - 0.05 * s, 0.1), 0, 1))
            combat = int(rng.integers(0, 2))

            ticks = np.arange(N_TICKS)
            telemetry = rng.normal(size=(N_TICKS, FEATURE_DIM)).astype(np.float32)

            frame_paths: List[str] = []
            for t in range(N_FRAMES_PER_SEQ):
                fname = f"{seed}_{i}_{t}.png"
                _make_png(os.path.join(frame_dir, fname), rng)
                frame_paths.append(os.path.join("frames", fname))

            table = pa.table(
                {
                    "tick": ticks.astype(np.int32),
                    "feature": list(telemetry),
                    "frame_path": frame_paths + [""] * (N_TICKS - len(frame_paths)),
                }
            )
            pq.write_table(table, os.path.join(seq_dir, f"{seq_id}.parquet"))

            manifest["sequences"].append(
                {
                    "sequence_id": seq_id,
                    "seed": seed,
                    "scenario": scenario,
                    "n_ticks": N_TICKS,
                    "parquet": os.path.join("sequences", f"{seq_id}.parquet"),
                    "behavior_factors": {
                        "panic_mean": panic,
                        "fear_mean": fear,
                        "greed_mean": greed,
                        "combat": combat,
                    },
                }
            )

    with open(os.path.join(root, "manifest.json"), "w") as fh:
        json.dump(manifest, fh, indent=2)
    return manifest


if __name__ == "__main__":
    here = os.path.dirname(os.path.abspath(__file__))
    out_root = os.path.join(here, "v1")
    os.makedirs(out_root, exist_ok=True)
    main(out_root)
    print("wrote fixtures to", out_root)
