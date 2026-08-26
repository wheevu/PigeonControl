"""PyTorch-ready sequence dataset over the converted Parquet dataset.

Modes (exactly ``telemetry``, ``vision``, ``fusion``):

* ``telemetry`` -> returns ``telemetry`` float tensor [T, F] from externally
  visible + partially observable aggregates only.
* ``vision``    -> returns ``frames`` float tensor [T, 3, H, W] scaled to [0,1].
* ``fusion``    -> returns both.

Every sample also carries ``targets`` (panic scalar, hidden_genome [2],
future_aggregates [5], crowd_regime int), ``metadata`` (run_id/seed/ticks only),
and ``relevance`` (the resulting-behavior factor vector used for retrieval, never
seed/scenario). Features never include target columns or privileged fields.
"""

from __future__ import annotations

import json
import math
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

import numpy as np
import pyarrow as pa
import pyarrow.parquet as pq
import torch
from PIL import Image

from .. import schema as S
from ._util import read_raw_csv


@dataclass
class _RunCache:
    run_id: str
    seed: int
    tick_list: np.ndarray
    feat: np.ndarray            # [N, F] telemetry features
    genome_fear: np.ndarray     # [N]
    genome_greed: np.ndarray    # [N]
    agg: np.ndarray             # [N, 5] flee/eat/fight/dispersion/local_density
    frag: np.ndarray            # [N] fragmentation_proxy
    interventions: set          # set of intervention tick ints
    frame_paths: Dict[int, Path]  # tick -> frame path


def _group_bounds(sorted_ticks: np.ndarray) -> List[Tuple[int, int]]:
    if len(sorted_ticks) == 0:
        return []
    diff = np.flatnonzero(np.diff(sorted_ticks) != 0) + 1
    starts = np.concatenate([[0], diff])
    ends = np.concatenate([diff, [len(sorted_ticks)]])
    return list(zip(starts.tolist(), ends.tolist()))


class ObserverSequenceDataset:
    """Windowed sequence dataset for one split of a converted dataset."""

    def __init__(
        self,
        dataset_root: str | Path,
        split: str,
        mode: str = "fusion",
        sequence_length: int = 4,
        stride: int = 1,
        horizon: int = 6,
        image_size: Tuple[int, int] = (96, 96),
        temporal_encoder: str = "transformer",
        include_intervention_metadata: bool = False,
    ) -> None:
        if mode not in ("telemetry", "vision", "fusion"):
            raise ValueError(f"invalid mode {mode!r}; expected telemetry/vision/fusion")
        if split not in S.SPLIT_NAMES:
            raise ValueError(f"invalid split {split!r}")
        self.dataset_root = Path(dataset_root)
        self.split = split
        self.mode = mode
        self.sequence_length = int(sequence_length)
        self.stride = int(stride)
        self.horizon = int(horizon)
        self.image_size = tuple(image_size)
        self.temporal_encoder = temporal_encoder
        self.include_intervention_metadata = bool(include_intervention_metadata)

        manifest_path = self.dataset_root / "manifest.json"
        if not manifest_path.exists():
            raise FileNotFoundError(
                f"dataset manifest not found at {manifest_path}; "
                f"run build_dataset_manifest first"
            )
        with open(manifest_path) as fh:
            self.manifest = json.load(fh)
        self.run_ids = list(self.manifest["splits"][split])
        if not self.run_ids:
            # Still a valid (empty) dataset; no windows.
            pass

        self.feature_names = list(S.TELEMETRY_FEATURE_NAMES)
        self._caches: Dict[str, _RunCache] = {}
        self.windows: List[Dict[str, Any]] = []
        self._build_windows()

    # ------------------------------------------------------------------ #
    # Run loading / precompute
    # ------------------------------------------------------------------ #

    def _load_run(self, run_id: str) -> _RunCache:
        if run_id in self._caches:
            return self._caches[run_id]
        run_dir = self.dataset_root / "runs" / run_id
        with open(run_dir / "run_manifest.json") as fh:
            rm = json.load(fh)
        seed = int(rm["seed"])

        ticks_tbl = pq.read_table(run_dir / "ticks.parquet")
        tick_arr = ticks_tbl.column("tick").to_numpy(zero_copy_only=False)
        order = np.argsort(tick_arr, kind="stable")
        tick_list = tick_arr[order]
        N = len(tick_list)
        density_name = "mean_local_density" if "mean_local_density" in ticks_tbl.column_names else "local_density"
        local_density = ticks_tbl.column(density_name).to_numpy(zero_copy_only=False)[order]
        dispersion = ticks_tbl.column("dispersion").to_numpy(zero_copy_only=False)[order]
        frag = ticks_tbl.column("fragmentation_proxy").to_numpy(zero_copy_only=False)[order]
        flee_name = "frac_fleeing" if "frac_fleeing" in ticks_tbl.column_names else "flee_fraction"
        eat_name = "frac_eating" if "frac_eating" in ticks_tbl.column_names else "eat_fraction"
        fight_name = "frac_fighting" if "frac_fighting" in ticks_tbl.column_names else "fight_fraction"
        flee = ticks_tbl.column(flee_name).to_numpy(zero_copy_only=False)[order]
        eat = ticks_tbl.column(eat_name).to_numpy(zero_copy_only=False)[order]
        fight = ticks_tbl.column(fight_name).to_numpy(zero_copy_only=False)[order]
        agg = np.stack([flee, eat, fight, dispersion, local_density], axis=1)  # [N,5]

        # Pigeons: precompute per-tick aggregates.
        pig_tbl = pq.read_table(run_dir / "pigeons.parquet")
        p_tick = pig_tbl.column("tick").to_numpy(zero_copy_only=False)
        p_order = np.argsort(p_tick, kind="stable")
        st = p_tick[p_order]
        pos_x = pig_tbl.column("pos_x").to_numpy(zero_copy_only=False)[p_order]
        pos_y = pig_tbl.column("pos_y").to_numpy(zero_copy_only=False)[p_order]
        pos_z = pig_tbl.column("pos_z").to_numpy(zero_copy_only=False)[p_order]
        speed = pig_tbl.column("speed").to_numpy(zero_copy_only=False)[p_order]
        hunger = pig_tbl.column("hunger").to_numpy(zero_copy_only=False)[p_order]
        fear_name = "transient_fear" if "transient_fear" in pig_tbl.column_names else "fear"
        fear = pig_tbl.column(fear_name).to_numpy(zero_copy_only=False)[p_order]
        state = pig_tbl.column("state").to_numpy(zero_copy_only=False)[p_order]
        g_fear = pig_tbl.column("genome_fear").to_numpy(zero_copy_only=False)[p_order]
        g_greed = pig_tbl.column("genome_greed").to_numpy(zero_copy_only=False)[p_order]

        F = S.TELEMETRY_FEATURE_DIM
        feat = np.zeros((N, F), dtype=np.float64)
        genome_fear = np.zeros(N, dtype=np.float64)
        genome_greed = np.zeros(N, dtype=np.float64)
        tick_to_gi = {int(t): i for i, t in enumerate(tick_list.tolist())}

        for (s, e) in _group_bounds(st):
            gt = int(st[s])
            gi = tick_to_gi.get(gt)
            if gi is None:
                continue
            n = e - s
            feat[gi, 0] = pos_x[s:e].mean()
            feat[gi, 1] = pos_y[s:e].mean()
            feat[gi, 2] = pos_z[s:e].mean()
            feat[gi, 3] = speed[s:e].mean()
            feat[gi, 4] = hunger[s:e].mean()
            feat[gi, 5] = fear[s:e].mean()
            feat[gi, 6] = local_density[gi]
            feat[gi, 7] = dispersion[gi]
            feat[gi, 8] = frag[gi]
            counts = np.bincount(state[s:e].astype(np.int64), minlength=8)
            for k in range(8):
                feat[gi, 9 + k] = counts[k] / n
            genome_fear[gi] = g_fear[s:e].mean()
            genome_greed[gi] = g_greed[s:e].mean()

        # Foods: visible food count per tick.
        foods_tbl = pq.read_table(run_dir / "foods.parquet")
        f_tick = foods_tbl.column("tick").to_numpy(zero_copy_only=False)
        f_order = np.argsort(f_tick, kind="stable")
        sf = f_tick[f_order]
        amount = foods_tbl.column("amount").to_numpy(zero_copy_only=False)[f_order]
        for (s, e) in _group_bounds(sf):
            gt = int(sf[s])
            gi = tick_to_gi.get(gt)
            if gi is None:
                continue
            feat[gi, 17] = float(np.count_nonzero(amount[s:e] > 0))

        # Interventions.
        interventions: set = set()
        iv_path = run_dir / "interventions.parquet"
        if iv_path.exists():
            iv_tbl = pq.read_table(iv_path)
            if iv_tbl.num_rows > 0:
                interventions = set(int(t) for t in iv_tbl.column("tick").to_numpy(zero_copy_only=False))

        # Frame paths.
        frame_paths: Dict[int, Path] = {}
        idx_tbl = read_raw_csv(run_dir / "frame_index.csv", "frame_index")
        fi_tick = idx_tbl.column("tick").to_numpy(zero_copy_only=False)
        fi_file = idx_tbl.column("frame_file").to_numpy(zero_copy_only=False)
        for i in range(len(fi_tick)):
            frame_paths[int(fi_tick[i])] = run_dir / "frames" / str(fi_file[i])

        cache = _RunCache(
            run_id=run_id,
            seed=seed,
            tick_list=tick_list,
            feat=feat,
            genome_fear=genome_fear,
            genome_greed=genome_greed,
            agg=agg,
            frag=frag,
            interventions=interventions,
            frame_paths=frame_paths,
        )
        self._caches[run_id] = cache
        return cache

    def _build_windows(self) -> None:
        L = self.sequence_length
        H = self.horizon
        for run_id in sorted(self.run_ids):
            cache = self._load_run(run_id)
            N = len(cache.tick_list)
            if N < L + H:
                continue  # not enough ticks for one full window
            for s in range(0, N - (L + H) + 1, self.stride):
                input_last = int(cache.tick_list[s + L - 1])
                target_end = int(cache.tick_list[s + L + H - 1])
                # Skip windows with a scheduled intervention after final input
                # through the target horizon (primary-score exclusion).
                if any(input_last < t <= target_end for t in cache.interventions):
                    continue
                self.windows.append(
                    {
                        "run_id": run_id,
                        "seed": cache.seed,
                        "start": s,
                        "input_ticks": [int(t) for t in cache.tick_list[s : s + L]],
                        "target_ticks": [int(t) for t in cache.tick_list[s + L : s + L + H]],
                    }
                )

    # ------------------------------------------------------------------ #
    # Item access
    # ------------------------------------------------------------------ #

    def __len__(self) -> int:
        return len(self.windows)

    def _load_frame(self, path: Path) -> np.ndarray:
        with Image.open(path) as im:
            im = im.convert("RGB").resize(self.image_size, Image.BILINEAR)
            arr = np.asarray(im, dtype=np.float32) / 255.0
        # [H, W, 3] -> [3, H, W]
        return np.transpose(arr, (2, 0, 1))

    def __getitem__(self, index: int) -> Dict[str, Any]:
        if index < 0 or index >= len(self.windows):
            raise IndexError(index)
        win = self.windows[index]
        cache = self._caches[win["run_id"]]
        s = win["start"]
        L = self.sequence_length
        H = self.horizon

        out: Dict[str, Any] = {}
        if self.mode in ("telemetry", "fusion"):
            telemetry = cache.feat[s : s + L].astype(np.float32)  # [L, F]
            out["telemetry"] = torch.from_numpy(np.ascontiguousarray(telemetry))

        if self.mode in ("vision", "fusion"):
            frames = np.zeros(
                (L, 3, self.image_size[0], self.image_size[1]), dtype=np.float32
            )
            for j, t in enumerate(win["input_ticks"]):
                fpath = cache.frame_paths.get(t)
                if fpath is None or not Path(fpath).exists():
                    # Missing frame in a vision window: zero (validator catches
                    # correspondence; dataset stays lenient to allow partial runs).
                    continue
                frames[j] = self._load_frame(Path(fpath))
            out["frames"] = torch.from_numpy(np.ascontiguousarray(frames))

        # Targets computed from privileged ground-truth aggregates.
        agg_future = cache.agg[s + L : s + L + H]  # [H, 5]
        fm = agg_future.mean(axis=0)
        flee_m, eat_m, fight_m, disp_m, locden_m = fm
        frag_future = float(cache.frag[s + L : s + L + H].mean())
        panic = float(agg_future[:, 0].max() >= S.PANIC_FLEE_FRACTION_THRESHOLD)
        regime = _regime(flee_m, eat_m, fight_m, frag_future)
        hidden_genome = np.array(
            [cache.genome_fear[s + L - 1], cache.genome_greed[s + L - 1]],
            dtype=np.float32,
        )
        future_aggregates = fm.astype(np.float32)

        out["targets"] = {
            "panic": torch.tensor(panic, dtype=torch.float32),
            "hidden_genome": torch.from_numpy(hidden_genome),
            "future_aggregates": torch.from_numpy(future_aggregates),
            "crowd_regime": torch.tensor(regime, dtype=torch.long),
        }
        out["relevance"] = torch.from_numpy(fm[:3].astype(np.float32))
        meta = {
            "run_id": win["run_id"],
            "seed": win["seed"],
            "ticks": list(win["input_ticks"]),
        }
        if self.include_intervention_metadata:
            input_first = int(cache.tick_list[s])
            target_end = int(cache.tick_list[s + L + H - 1])
            meta["interventions"] = sorted(
                int(t) for t in cache.interventions if input_first <= t <= target_end
            )
        out["metadata"] = meta
        return out

    # ------------------------------------------------------------------ #
    # Training-only normalization support (no frame loading)
    # ------------------------------------------------------------------ #

    def telemetry_stream(self):
        """Yield the per-window telemetry numpy array [L, F] (no frames loaded)."""
        L = self.sequence_length
        for win in self.windows:
            cache = self._caches[win["run_id"]]
            s = win["start"]
            yield cache.feat[s : s + L].astype(np.float32)


def _regime(flee_m: float, eat_m: float, fight_m: float, frag_m: float) -> int:
    """Crowd-regime precedence: combat > panic > feeding > fragmented > calm."""
    if fight_m >= S.REGIME_COMBAT_FIGHT_FRACTION:
        return S.REGIME_COMBAT
    if flee_m >= S.REGIME_PANIC_FLEE_FRACTION:
        return S.REGIME_PANIC
    if eat_m >= S.REGIME_FEEDING_EAT_FRACTION:
        return S.REGIME_FEEDING
    if frag_m >= S.REGIME_FRAGMENTED_PROXY:
        return S.REGIME_FRAGMENTED
    return S.REGIME_CALM


def collate_observer_batch(batch: List[Dict[str, Any]]) -> Dict[str, Any]:
    """Deterministic collate: stacks tensors in batch order, keeps metadata as a list."""
    out: Dict[str, Any] = {}
    if "telemetry" in batch[0]:
        out["telemetry"] = torch.stack([b["telemetry"] for b in batch], dim=0)
    if "frames" in batch[0]:
        out["frames"] = torch.stack([b["frames"] for b in batch], dim=0)
    out["targets"] = {
        "panic": torch.stack([b["targets"]["panic"] for b in batch], dim=0),
        "hidden_genome": torch.stack([b["targets"]["hidden_genome"] for b in batch], dim=0),
        "future_aggregates": torch.stack(
            [b["targets"]["future_aggregates"] for b in batch], dim=0
        ),
        "crowd_regime": torch.stack([b["targets"]["crowd_regime"] for b in batch], dim=0),
    }
    out["relevance"] = torch.stack([b["relevance"] for b in batch], dim=0)
    out["metadata"] = [b["metadata"] for b in batch]
    return out
