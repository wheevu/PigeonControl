"""Programmatic builder for tiny synthetic raw runs used by the data tests.

This does NOT use the real Julia simulation. It emits CSV/PNG files that satisfy
the explicit raw schema so conversion, manifest, validation, and dataset code can
be tested without network/GPU/Godot.
"""

from __future__ import annotations

import csv
import math
from pathlib import Path

import numpy as np
from PIL import Image

from pigeon_observer import schema as S


def _deterministic_stream(seed: int):
    rng = np.random.default_rng(seed)
    while True:
        yield rng


def write_csv(path: Path, table: str, rows: list) -> None:
    fields = S.field_specs(table)
    header = [fs.name for fs in fields]
    with open(path, "w", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=header, extrasaction="ignore")
        writer.writeheader()
        for row in rows:
            row = dict(row)
            row.setdefault("schema_version", S.RAW_SCHEMA_VERSION)
            row.setdefault("run_id", path.parent.name)
            aliases = {"local_density": "mean_local_density", "flee_fraction": "frac_fleeing",
                       "eat_fraction": "frac_eating", "fight_fraction": "frac_fighting",
                       "threat_present": "threat_active", "fear": "transient_fear",
                       "variant": "archetype"}
            for old, new in aliases.items():
                if old in row and new in header:
                    row[new] = row[old]
            for field in header:
                row.setdefault(field, 0 if field not in ("schema_version", "run_id", "command", "result", "frame_file") else "")
            writer.writerow(row)


def make_png(path: Path, tick: int, size: int = 96) -> None:
    # Deterministic content that varies by tick so frames are distinguishable.
    arr = np.zeros((size, size, 3), dtype=np.uint8)
    c = (tick * 23) % 256
    arr[:, :, 0] = c
    arr[:, :, 1] = (tick * 7) % 256
    arr[:, :, 2] = 255 - c
    # A simple moving block so decoding + dimension checks are meaningful.
    block = (tick * 5) % (size - 8)
    arr[block : block + 8, block : block + 8, :] = 255
    Image.fromarray(arr).save(path)


def build_raw_run(
    root: Path,
    *,
    run_id: str,
    seed: int,
    scenario: str = "plaza",
    config_name: str = "default",
    n_pigeons: int = 8,
    n_ticks: int = 12,
    cadence: int = 1,
    frame_cadence: int = 1,
    with_interventions: bool = False,
    panic_from_tick: int = 8,
    genome_scalar: float = 1.0,
    frame_size: int = 96,
) -> Path:
    """Create a synthetic completed raw run under ``root/<run_id>``."""
    raw_dir = root / run_id
    raw_dir.mkdir(parents=True, exist_ok=True)
    frames_dir = raw_dir / "frames"
    frames_dir.mkdir(parents=True, exist_ok=True)

    tick_start = 0
    tick_end = (n_ticks - 1) * cadence
    ticks = list(range(tick_start, tick_end + 1, cadence))

    rng = np.random.default_rng(seed)

    # ---- ticks.csv ----
    tick_rows = []
    for t in ticks:
        flee = 0.18 if t >= panic_from_tick else 0.02
        eat = 0.12 if (t % 4 == 0) else 0.03
        fight = 0.06 if (t % 5 == 0) else 0.01
        tick_rows.append(
            {
                "tick": t,
                "n_pigeons": n_pigeons,
                "local_density": 1.0 + 0.1 * t,
                "dispersion": 5.0 + 0.2 * t,
                "fragmentation_proxy": min(0.49, 0.05 + 0.01 * t),
                "flee_fraction": flee,
                "eat_fraction": eat,
                "fight_fraction": fight,
                "threat_present": 0,
                "threat_x": "",
                "threat_y": "",
                "threat_z": "",
            }
        )
    write_csv(raw_dir / "ticks.csv", "ticks", tick_rows)

    # ---- pigeons.csv ----
    pigeon_rows = []
    for t in ticks:
        for pid in range(n_pigeons):
            base = (seed * 1000 + pid * 7 + t * 13) % 1000
            pos_x = float(base) / 50.0 - 10.0
            pos_y = float((base * 3) % 100) / 50.0
            pos_z = float((base * 7) % 1000) / 50.0 - 10.0
            vel_x = 0.1 * ((pid % 3) - 1)
            vel_y = 0.0
            vel_z = 0.1 * ((pid % 2) - 0)
            speed = math.sqrt(vel_x**2 + vel_z**2)
            state = (t + pid) % 8
            hunger = 0.5 + 0.01 * pid
            fear = 0.1 + 0.005 * t
            genome = {
                g: float(round(genome_scalar * (0.8 + 0.4 * ((pid + i) % 5) / 4.0), 4))
                for i, g in enumerate(S.GENOME_FIELDS)
            }
            row = {
                "tick": t,
                "pigeon_id": pid,
                "pos_x": pos_x,
                "pos_y": pos_y,
                "pos_z": pos_z,
                "vel_x": vel_x,
                "vel_y": vel_y,
                "vel_z": vel_z,
                "speed": speed,
                "state": state,
                "archetype": pid % 4,
                "hunger": hunger,
                "fear": fear,
                "energy": 80.0,
                "fight_timer": 0.0,
                "fight_cooldown": 0.0,
                "target_food": -1 if (pid % 3) else 0,
                "age": float(t),
            }
            for g in S.GENOME_FIELDS:
                row[f"genome_{g}"] = genome[g]
            pigeon_rows.append(row)
    write_csv(raw_dir / "pigeons.csv", "pigeons", pigeon_rows)

    # ---- foods.csv ----
    food_rows = []
    n_foods = 4
    for t in ticks:
        for fid in range(n_foods):
            food_rows.append(
                {
                    "tick": t,
                    "food_id": fid,
                    "pos_x": float(fid) - 1.5,
                    "pos_y": 0.2,
                    "pos_z": float(fid) - 1.5,
                    "amount": 50.0 if (t % 3 != 0 or fid % 2 == 0) else 0.0,
                }
            )
    write_csv(raw_dir / "foods.csv", "foods", food_rows)

    # ---- interventions.csv ----
    intervention_rows = []
    if with_interventions:
        intervention_rows.append(
            {"tick": 5, "kind": "DROP_BREAD", "x": 0.0, "y": 0.0, "z": 0.0, "amount": 30.0}
        )
    write_csv(raw_dir / "interventions.csv", "interventions", intervention_rows)

    # ---- frame_index.csv + PNGs ----
    frame_rows = []
    for t in ticks:
        if (t - tick_start) % frame_cadence != 0:
            continue
        fname = f"frame_{t:06d}.png"
        make_png(frames_dir / fname, t, size=frame_size)
        frame_rows.append(
            {"tick": t, "frame_file": fname, "width": frame_size, "height": frame_size}
        )
    write_csv(raw_dir / "frame_index.csv", "frame_index", frame_rows)

    # ---- raw_run.toml ----
    toml_text = f"""run_id = "{run_id}"
seed = {seed}
scenario = "{scenario}"
config_name = "{config_name}"
n_pigeons = {n_pigeons}
tick_start = {tick_start}
tick_end = {tick_end}
sample_cadence = {cadence}
frame_cadence = {frame_cadence}
frame_format = "png"
status = "completed"
schema_version = "{S.RAW_SCHEMA_VERSION}"
"""
    (raw_dir / "raw_run.toml").write_text(toml_text)
    return raw_dir
