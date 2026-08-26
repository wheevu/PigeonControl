"""Deterministic training entry point.

``train_model`` ties the pieces together: seeds everything, builds the model,
computes/loads normalization, runs a minimal epoch/batch loop that supports
short CI runs via ``max_steps``, and writes an immutable run directory containing
``config.json``, ``metrics.json``, ``checkpoint.pt``, ``split_manifest.json``,
``plots/`` and ``failure_examples/``.
"""
from __future__ import annotations

import json
import subprocess
from pathlib import Path
from typing import Any, Dict, Optional

import numpy as np
import torch

from ..models.config import ObserverModelConfig
from ..models.factory import build_model
from . import loss as loss_mod
from .checkpoint import save_checkpoint, make_hash
from .deterministic import seed_everything, make_deterministic_dataloader
from .run_dir import RunDir


def _git_commit() -> Optional[str]:
    try:
        out = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            capture_output=True, text=True, timeout=5,
        )
        if out.returncode == 0:
            return out.stdout.strip()
    except Exception:
        pass
    return None


def _collate(samples):
    keys = set().union(*[set(s.keys()) for s in samples])
    out: Dict[str, Any] = {}
    for k in keys:
        vals = [s[k] for s in samples if k in s]
        if len(vals) != len(samples):
            # key absent in some samples -> omit (mode-specific batches)
            continue
        if isinstance(vals[0], torch.Tensor):
            out[k] = torch.stack(vals, 0)
        elif isinstance(vals[0], dict):
            out[k] = _collate(vals)
        else:
            out[k] = torch.tensor(np.array(vals))
    return out


def _compute_normalization(dataset) -> Optional[Dict[str, list]]:
    arrs = []
    for s in dataset:
        t = s.get("telemetry")
        if t is not None:
            arrs.append(np.asarray(t, dtype=np.float32).reshape(-1, np.asarray(t).shape[-1]))
    if not arrs:
        return None
    all_t = np.concatenate(arrs, axis=0)
    mean = all_t.mean(axis=0).tolist()
    std = all_t.std(axis=0).tolist()
    return {"mean": mean, "std": std}


def _move_to_device(batch, device):
    if isinstance(batch, torch.Tensor):
        return batch.to(device)
    if isinstance(batch, dict):
        return {k: _move_to_device(v, device) for k, v in batch.items()}
    return batch


def _evaluate(model, val_dataset, weights, device):
    model.eval()
    loader = make_deterministic_dataloader(
        val_dataset, batch_size=min(32, max(1, len(val_dataset))),
        shuffle=False, num_workers=0, seed=0, collate_fn=_collate,
    )
    totals: Dict[str, float] = {}
    count = 0
    with torch.no_grad():
        for batch in loader:
            batch = _move_to_device(batch, device)
            out = model(batch)
            ld = loss_mod.compute_loss(out, batch.get("targets", {}), weights)
            for k, v in ld.items():
                totals[k] = totals.get(k, 0.0) + float(v.item())
            count += 1
    if count == 0:
        return {}
    return {k: v / count for k, v in totals.items()}


def train_model(train_dataset, val_dataset, config: Dict, output_dir) -> Dict:
    seed = int(config.get("seed", 0))
    seed_everything(seed)

    model_cfg = ObserverModelConfig.from_dict(config["model"])
    model = build_model(model_cfg)
    device = config.get("device", "cpu")
    model.to(device)

    # normalization
    norm = config.get("normalization")
    if norm is None:
        norm = _compute_normalization(train_dataset)
    if norm is not None:
        model.set_normalization(norm["mean"], norm["std"])

    optimizer = torch.optim.Adam(model.parameters(), lr=float(config.get("lr", 1e-3)))
    weights = config.get("loss_weights")
    max_epochs = int(config.get("max_epochs", 1))
    max_steps = config.get("max_steps")
    batch_size = int(config.get("batch_size", 8))

    loader = make_deterministic_dataloader(
        train_dataset, batch_size=batch_size, shuffle=True,
        num_workers=0, seed=seed, collate_fn=_collate,
    )

    schema = config.get("feature_schema", {})
    split_manifest = config.get("split_manifest", {})
    schema_hash = make_hash(schema)
    split_hash = make_hash(split_manifest)
    config_hash = make_hash({"model": model_cfg.to_dict(), "training": {k: v for k, v in config.items() if k != "model"}})

    history: list[float] = []
    step = 0
    epoch = 0
    val_metrics: Dict[str, float] = {}

    with RunDir(output_dir) as rd:
        # write config.json up front (in staging)
        rd.write_json("config.json", {
            "seed": seed,
            "git_commit": _git_commit(),
            "model": model_cfg.to_dict(),
            "training": {k: v for k, v in config.items() if k != "model"},
            "schema_hash": schema_hash,
            "split_hash": split_hash,
            "config_hash": config_hash,
            "normalization": norm,
        })
        rd.write_json("split_manifest.json", {
            "manifest": split_manifest,
            "split_hash": split_hash,
            "schema": schema,
            "schema_hash": schema_hash,
        })

        model.train()
        for epoch in range(max_epochs):
            for batch in loader:
                batch = _move_to_device(batch, device)
                outputs = model(batch)
                ld = loss_mod.compute_loss(outputs, batch.get("targets", {}), weights)
                optimizer.zero_grad()
                ld["loss"].backward()
                optimizer.step()
                history.append(float(ld["loss"].item()))
                step += 1
                if max_steps is not None and step >= int(max_steps):
                    break
            if max_steps is not None and step >= int(max_steps):
                break

        # validation
        if val_dataset is not None and len(val_dataset) > 0:
            val_metrics = _evaluate(model, val_dataset, weights, device)

        # checkpoint
        ckpt_path = rd.staging / "checkpoint.pt"
        save_checkpoint(
            ckpt_path, model, optimizer, epoch,
            normalization=norm,
            schema_hash=schema_hash, split_hash=split_hash, config_hash=config_hash,
        )

        rd.write_json("metrics.json", {
            "final_train_loss": history[-1] if history else None,
            "mean_train_loss": float(np.mean(history)) if history else None,
            "steps": step,
            "epochs": epoch + 1,
            "loss_history": history,
            "val": val_metrics,
        })

        # plots/ (only if matplotlib is available, else keep dir present)
        plots_dir = rd.ensure_dir("plots")
        try:
            import matplotlib
            matplotlib.use("Agg")
            import matplotlib.pyplot as plt
            if history:
                plt.figure()
                plt.plot(history)
                plt.title("training loss")
                plt.xlabel("step")
                plt.ylabel("loss")
                plt.savefig(plots_dir / "loss.png")
                plt.close()
        except Exception:
            pass

        # failure_examples/ - highest-loss validation examples if any
        failure_dir = rd.ensure_dir("failure_examples")
        if val_dataset is not None and len(val_dataset) > 0:
            _write_failure_examples(model, val_dataset, failure_dir, device, top_k=min(8, len(val_dataset)))

    return {
        "run_dir": str(output_dir),
        "steps": step,
        "epochs": epoch + 1,
        "final_train_loss": history[-1] if history else None,
        "val": val_metrics,
        "config_hash": config_hash,
        "schema_hash": schema_hash,
        "split_hash": split_hash,
    }


def _write_failure_examples(model, val_dataset, failure_dir, device, top_k=8) -> None:
    model.eval()
    examples = []
    with torch.no_grad():
        for i in range(len(val_dataset)):
            sample = val_dataset[i]
            batch = {
                k: (v.unsqueeze(0) if isinstance(v, torch.Tensor) else v)
                for k, v in sample.items() if k != "targets"
            }
            batch = _move_to_device(batch, device)
            if not batch:
                continue
            out = model(batch)
            panic = out["panic_logits"]
            tg = sample.get("targets", {})
            tgt = tg.get("panic")
            wrong = 0.0
            if tgt is not None:
                pred = (torch.sigmoid(panic) > 0.5).long().reshape(-1)[0].item()
                true = int(np.asarray(tgt).reshape(-1)[0])
                wrong = abs(pred - true)
            examples.append((i, wrong, float(panic.reshape(-1)[0].item())))
    examples.sort(key=lambda x: -x[1])
    top = examples[:top_k]
    with open(failure_dir / "report.json", "w", encoding="utf-8") as f:
        json.dump([{"index": i, "panic_logit": l, "mismatch": w} for i, w, l in top], f, indent=2)
