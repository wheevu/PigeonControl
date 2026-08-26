"""Command line interface for the PigeonControl observer package.

Commands (all argparse; no prompts, unknown flags exit non-zero):

    generate   Run the Julia dataset generator, optionally capture frames via
               Godot, then convert + build the manifest.
    validate   Validate a built dataset and print compact JSON.
    train      Build datasets + config and train a model.
    evaluate   Score a checkpoint on a dataset into a NEW eval directory.
    embed      Write sequence embeddings + metadata to parquet / npz.
    retrieve   Nearest sequences/runs by cosine, behavior-based relevance.
    figures    Render evaluation / retrieval figures.

Sibling integration contract (imported lazily so ``--help`` works without
them):

    pigeon_observer.data      convert_raw_run, build_dataset_manifest,
                              validate_dataset, ObserverSequenceDataset
    pigeon_observer.models    ObserverModelConfig, ObserverModel
    pigeon_observer.training train_model, load_checkpoint

Assumed dataset / model API is documented in docs/OBSERVER_EXPERIMENT.md and
in the helper docstrings below.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from typing import Any, Dict, List, Optional, Sequence

# Canonical scenario matrix (all 12). The Julia generator accepts these names.
SCENARIOS: tuple[str, ...] = (
    "baseline_flocking", "bread_competition", "sparse_bread", "bread_abundance",
    "human_panic", "repeated_human_interventions", "mixed_archetype_populations",
    "high_fear_populations", "low_fear_populations", "combat_heavy_populations",
    "dense_populations", "sparse_populations",
)


# ---------------------------------------------------------------------------
# Lazy sibling imports
# ---------------------------------------------------------------------------


def _import_data():
    try:
        from pigeon_observer import data  # type: ignore
    except Exception as exc:  # pragma: no cover - depends on sibling presence
        raise RuntimeError(
            "pigeon_observer.data is required for this command but is not "
            "installed. It is implemented by the sibling data module."
        ) from exc
    return data


def _import_models():
    try:
        from pigeon_observer import models  # type: ignore
    except Exception as exc:  # pragma: no cover
        raise RuntimeError(
            "pigeon_observer.models is required for this command but is not "
            "installed. It is implemented by the sibling models module."
        ) from exc
    return models


def _import_training():
    try:
        from pigeon_observer import training  # type: ignore
    except Exception as exc:  # pragma: no cover
        raise RuntimeError(
            "pigeon_observer.training is required for this command but is not "
            "installed. It is implemented by the sibling training module."
        ) from exc
    return training


# ---------------------------------------------------------------------------
# Subprocess helpers (no shell=True)
# ---------------------------------------------------------------------------


def _resolve_repo_root(args_root: Optional[str]) -> str:
    if args_root:
        return os.path.abspath(args_root)
    # Heuristic: walk up from cwd until we find experiments/ and observer/.
    cur = os.getcwd()
    for _ in range(6):
        if os.path.isdir(os.path.join(cur, "experiments")) and os.path.isdir(
            os.path.join(cur, "observer")
        ):
            return cur
        parent = os.path.dirname(cur)
        if parent == cur:
            break
        cur = parent
    return os.getcwd()


def _run_julia_generator(
    *,
    repo_root: str,
    julia_bin: str,
    scenario: str,
    seed: int,
    n: int,
    steps: int,
    cadence: int,
    raw_output: str,
) -> None:
    """Invoke experiments/generate_observer_dataset.jl without a shell."""
    script = os.path.join(repo_root, "experiments", "generate_observer_dataset.jl")
    if not os.path.isfile(script):
        raise RuntimeError(
            f"Julia generator not found at {script}. It is owned by the "
            "sibling experiments module and must exist before generate runs."
        )
    os.makedirs(raw_output, exist_ok=True)
    cmd = [
        julia_bin,
        "--project=.",
        script,
        "--scenario",
        scenario,
        "--seed",
        str(seed),
        "--n",
        str(n),
        "--steps",
        str(steps),
        "--sample-every",
        str(cadence),
        "--output",
        raw_output,
    ]
    subprocess.run(cmd, cwd=repo_root, check=True)


class _ManagedGodot:
    """Launch Godot as a captured child and terminate ONLY it on cleanup."""

    def __init__(self, cmd: Sequence[str]):
        self.cmd = list(cmd)
        self.proc: Optional[subprocess.Popen] = None

    def __enter__(self):
        # start_new_session gives the child its own process group so we can
        # kill exactly what we spawned and nothing else.
        self.proc = subprocess.Popen(self.cmd, start_new_session=True)
        return self

    def __exit__(self, exc_type, exc, tb):
        if self.proc is None:
            return False
        if self.proc.poll() is None:
            try:
                if hasattr(os, "killpg"):
                    import signal

                    os.killpg(os.getpgid(self.proc.pid), signal.SIGTERM)
                else:  # pragma: no cover - non-unix
                    self.proc.terminate()
            except Exception:
                try:
                    self.proc.kill()
                except Exception:
                    pass
            try:
                self.proc.wait(timeout=10)
            except Exception:
                pass
        return False


def _maybe_capture_frames(
    *,
    repo_root: str,
    godot_bin: str,
    environment: str,
    session: str,
    ports: str,
    timeout: float,
    frames_output: str,
) -> None:
    """Launch Godot capture ONLY when --frames is set; never otherwise."""
    scene = os.path.join(repo_root, "godot", "observer_capture.tscn")
    godot_project = os.path.join(repo_root, "godot")
    if not os.path.isfile(scene):
        raise RuntimeError(
            f"Godot capture scene not found at {scene}. It is owned by the "
            "sibling godot module and must exist before --frames runs."
        )
    os.makedirs(frames_output, exist_ok=True)
    cmd = [
        godot_bin,
        "--headless",
        "--path",
        godot_project,
        scene,
        "--environment",
        environment,
        "--session",
        session,
        "--ports",
        ports,
        "--timeout",
        str(timeout),
        "--frames-out",
        frames_output,
    ]
    with _ManagedGodot(cmd) as g:
        try:
            g.proc.wait(timeout=timeout + 30)
        except subprocess.TimeoutExpired:
            # The child is terminated by __exit__; treat as completed capture.
            pass


# ---------------------------------------------------------------------------
# Assumed model / dataset inference helpers
# ---------------------------------------------------------------------------


def _iter_dataset(dataset) -> List[Dict[str, Any]]:
    """Collect dataset items (each a dict with labels + behavior factors)."""
    items: List[Dict[str, Any]] = []
    for item in dataset:
        items.append(item)
    return items


def _model_infer(model, item: Dict[str, Any]) -> Dict[str, Any]:
    """Assumed model API: model(item) -> prediction dict.

    Expected keys: ``panic_prob`` (per-tick probabilities), ``fear``,
    ``greed`` (regression scalars), ``onset_pred`` (first tick above
    threshold, or -1), ``embedding`` (vector). Sibling model implements this.
    """
    return model(item)


# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------


def cmd_generate(args: argparse.Namespace) -> int:
    data = _import_data()
    repo_root = _resolve_repo_root(args.repo_root)
    scenarios = args.scenario or list(SCENARIOS)
    seeds = args.seed if args.seed else [args.default_seed]

    raw_root = os.path.join(args.output, "raw")
    frames_root = os.path.join(args.output, "frames")

    for scenario in scenarios:
        for seed in seeds:
            raw_out = os.path.join(raw_root, f"{scenario}__seed{seed}")
            _run_julia_generator(
                repo_root=repo_root,
                julia_bin=args.julia_bin,
                scenario=scenario,
                seed=seed,
                n=args.n,
                steps=args.steps,
                cadence=args.sample_every,
                raw_output=raw_out,
            )

    if args.frames:
        _maybe_capture_frames(
            repo_root=repo_root,
            godot_bin=args.godot_bin,
            environment=args.environment,
            session=args.session,
            ports=args.ports,
            timeout=args.timeout,
            frames_output=frames_root,
        )

    # Convert each completed raw run into the dataset, then build the manifest.
    # convert_raw_run is per-run: (raw_run_dir, dataset_root) -> summary dict.
    summaries = []
    for scenario in scenarios:
        for seed in seeds:
            raw_out = os.path.join(raw_root, f"{scenario}__seed{seed}")
            summaries.append(data.convert_raw_run(raw_out, args.output))
    manifest = data.build_dataset_manifest(args.output)
    print(json.dumps({"status": "generated", "runs": len(summaries), "manifest": str(manifest)}, indent=2))
    return 0


def cmd_validate(args: argparse.Namespace) -> int:
    data = _import_data()
    # validate_dataset returns a ValidationReport (not a tuple).
    report = data.validate_dataset(args.dataset)
    if args.full:
        payload = report.to_dict()
    else:
        payload = {"ok": report.ok, "errors": list(report.errors)}
    print(json.dumps(payload, indent=2))
    return 1 if report.errors else 0


def cmd_train(args: argparse.Namespace) -> int:
    data = _import_data()
    models = _import_models()
    training = _import_training()

    train_ds = data.ObserverSequenceDataset(args.dataset, split=args.split, mode=args.mode)
    val_ds = data.ObserverSequenceDataset(args.dataset, split=args.val_split, mode=args.mode)

    model_cfg = models.ObserverModelConfig(
        hidden_dim=args.hidden,
        telemetry_dim=args.telemetry_dim,
        fusion=args.fusion,
        mode=args.mode,
    )
    config = {
        "seed": args.seed,
        "device": "cpu",
        "model": model_cfg.to_dict(),
    }
    # train_model builds the model internally from ``config["model"]``.
    result = training.train_model(train_ds, val_ds, config, args.output)
    print(json.dumps({"status": "trained", "result": str(result)}, indent=2))
    return 0


def cmd_evaluate(args: argparse.Namespace) -> int:
    import numpy as np

    data = _import_data()
    training = _import_training()
    from pigeon_observer.evaluation import (
        build_evaluation_result,
        classification_metrics,
        regression_metrics,
    )

    model, _ = training.load_checkpoint(args.checkpoint)
    dataset = data.ObserverSequenceDataset(args.dataset, split=args.split, mode=args.mode)

    # Write into a NEW, timestamped eval directory; never mutate old results.
    os.makedirs(args.output, exist_ok=True)
    stamp = time.strftime("%Y%m%dT%H%M%S")
    eval_dir = os.path.join(args.output, f"eval_{stamp}")
    os.makedirs(eval_dir, exist_ok=True)

    model.eval()
    seed_results: List[Dict[str, float]] = []
    seed_level: List[Dict[str, Any]] = []
    for item in dataset:
        pred = _model_infer(model, item)
        labels = item.get("labels", {}) or {}
        seq_id = item.get("sequence_id", "?")
        seed = item.get("seed", None)
        res: Dict[str, float] = {}
        if "panic_gt" in labels and "panic_prob" in pred:
            y_true = np.asarray(labels["panic_gt"]).round().astype(int)
            y_pred = (np.asarray(pred["panic_prob"]) >= 0.5).astype(int)
            cls = classification_metrics(y_true, y_pred, np.asarray(pred["panic_prob"]))
            res.update({f"cls_{k}": v for k, v in cls.items()})
        if "fear_gt" in labels and "fear" in pred:
            reg = regression_metrics(np.asarray(labels["fear_gt"]), np.asarray(pred["fear"]))
            res.update({f"fear_{k}": v for k, v in reg.items()})
        if "greed_gt" in labels and "greed" in pred:
            reg = regression_metrics(np.asarray(labels["greed_gt"]), np.asarray(pred["greed"]))
            res.update({f"greed_{k}": v for k, v in reg.items()})
        if res:
            seed_results.append({"seed": seed, "sequence_id": seq_id, **res})
            seed_level.append({"seed": seed, "sequence_id": seq_id, "metrics": res})

    metric_keys = [k for k in seed_results[0].keys() if k not in ("seed", "sequence_id")] if seed_results else []
    result = build_evaluation_result(
        seed_results,
        metric_keys,
        primary_key=args.primary_key,
        negative_findings=[
            "No individual-pigeon understanding is claimed; only population-level behavior factors.",
            "World-model status is deferred until an aggregate head beats persistence on held-out data.",
        ],
    )
    out = result.to_dict()
    out["eval_dir"] = eval_dir
    out["checkpoint"] = args.checkpoint
    out_path = os.path.join(eval_dir, "evaluation.json")
    with open(out_path, "w") as fh:
        json.dump(out, fh, indent=2)
    print(json.dumps({"status": "evaluated", "eval_dir": eval_dir, "out": out_path}, indent=2))
    return 0


def cmd_embed(args: argparse.Namespace) -> int:
    import numpy as np

    data = _import_data()
    training = _import_training()

    model, _ = training.load_checkpoint(args.checkpoint)
    dataset = data.ObserverSequenceDataset(args.dataset, split=args.split, mode=args.mode)
    model.eval()

    embeddings: List[np.ndarray] = []
    records: List[Dict[str, Any]] = []
    for item in dataset:
        pred = _model_infer(model, item)
        if "embedding" not in pred:
            raise RuntimeError("model forward did not return an 'embedding' field")
        emb = np.asarray(pred["embedding"], dtype=np.float32)
        embeddings.append(emb)
        # Seed / scenario are carried ONLY as reporting metadata, never as
        # features of the embedding.
        labels = item.get("labels", {}) or {}
        records.append(
            {
                "sequence_id": item.get("sequence_id"),
                "seed": item.get("seed"),
                "scenario": item.get("scenario"),
                "behavior_factors": labels.get("behavior_factors", {}),
            }
        )

    emb_matrix = np.stack(embeddings) if embeddings else np.empty((0, 0))
    out_parquet = os.path.join(args.output, "embeddings.parquet")
    out_npz = os.path.join(args.output, "embeddings.npz")
    os.makedirs(args.output, exist_ok=True)

    # Parquet with metadata columns only (no feature leakage of seed/scenario).
    import pyarrow as pa
    import pyarrow.parquet as pq

    table = pa.table(
        {
            "sequence_id": [r["sequence_id"] for r in records],
            "seed": [r["seed"] for r in records],
            "scenario": [r["scenario"] for r in records],
            "behavior_factors": [json.dumps(r["behavior_factors"]) for r in records],
        }
    )
    pq.write_table(table, out_parquet)

    np.savez(
        out_npz,
        embeddings=emb_matrix,
        sequence_ids=np.array([str(r["sequence_id"]) for r in records]),
        seeds=np.array([str(r["seed"]) for r in records]),
        scenarios=np.array([str(r["scenario"]) for r in records]),
    )
    print(json.dumps({"status": "embedded", "parquet": out_parquet, "npz": out_npz}, indent=2))
    return 0


def cmd_retrieve(args: argparse.Namespace) -> int:
    import numpy as np

    from pigeon_observer.evaluation import retrieve_neighbors

    index = _load_index(args.index)
    embs = index["embeddings"]
    meta = index["metadata"]

    # Locate query by sequence id (or run/tick when present in metadata).
    q_idx = _find_query(meta, args.query, args.run, args.tick)
    if q_idx is None:
        raise RuntimeError(f"query not found in index: {args.query}")
    q_emb = embs[q_idx]
    q_meta = meta[q_idx]

    factors = args.behavior_factors or ["panic_mean", "fear_mean", "greed_mean"]
    neighbors = retrieve_neighbors(
        q_emb,
        embs,
        meta,
        query_sequence_id=str(q_meta.get("sequence_id", "")),
        behavior_factors=factors,
        top_k=args.top_k,
        exclude_same_sequence=True,
    )
    out = []
    for nb in neighbors:
        out.append(
            {
                "sequence_id": nb.sequence_id,
                "cosine_distance": nb.distance,
                "behavior_factor_distance": nb.behavior_distance,
                "metadata": {k: nb.metadata.get(k) for k in ("seed", "scenario", "run", "tick")},
            }
        )
    print(json.dumps({"query": str(q_meta.get("sequence_id")), "neighbors": out}, indent=2))
    return 0


def _load_index(path: str) -> Dict[str, Any]:
    import numpy as np

    if path.endswith(".npz"):
        data = np.load(path, allow_pickle=False)
        embs = np.asarray(data["embeddings"], dtype=float)
        sids = list(data["sequence_ids"])
        seeds = list(data["seeds"])
        scenarios = list(data["scenarios"])
        meta = [
            {"sequence_id": str(sids[i]), "seed": seeds[i], "scenario": scenarios[i]}
            for i in range(len(sids))
        ]
        return {"embeddings": embs, "metadata": meta}
    if path.endswith(".parquet"):
        import pyarrow.parquet as pq

        t = pq.read_table(path)
        d = t.to_pydict()
        sids = d.get("sequence_id", [])
        seeds = d.get("seed", [None] * len(sids))
        scenarios = d.get("scenario", [None] * len(sids))
        bf_raw = d.get("behavior_factors", [None] * len(sids))
        meta = []
        for i, s in enumerate(sids):
            bf = bf_raw[i]
            if isinstance(bf, str):
                try:
                    bf = json.loads(bf)
                except Exception:
                    bf = {}
            meta.append(
                {
                    "sequence_id": str(s),
                    "seed": seeds[i],
                    "scenario": scenarios[i],
                    "behavior_factors": bf if isinstance(bf, dict) else {},
                }
            )
        return {"embeddings": np.empty((len(sids), 0)), "metadata": meta}
    raise RuntimeError(f"unsupported index format: {path}")


def _find_query(meta, query, run, tick) -> Optional[int]:
    for i, m in enumerate(meta):
        if query is not None and str(m.get("sequence_id")) == str(query):
            return i
        if run is not None and str(m.get("run")) == str(run) and tick is not None and str(m.get("tick")) == str(tick):
            return i
    return None


def cmd_figures(args: argparse.Namespace) -> int:
    from pigeon_observer.evaluation import (
        plot_embedding_projection,
        plot_fear_greed_scatter,
        plot_multimodal_examples,
        plot_neighbor_strips,
        plot_timeline,
    )
    import json as _json

    kind = args.kind
    out = args.output

    if kind == "timeline":
        if not args.result:
            raise RuntimeError("timeline requires --result JSON with ticks/ground_truth/predicted")
        res = _json.load(open(args.result))
        for k in ("ticks", "ground_truth", "predicted"):
            if k not in res:
                raise RuntimeError(f"timeline result missing required key: {k}")
        path = plot_timeline(res["ticks"], res["ground_truth"], res["predicted"], out)
        print(json.dumps({"figure": path}, indent=2))
        return 0

    if kind == "embedding":
        idx = _load_index(args.index)
        emb = idx["embeddings"]
        labels = [m.get("scenario") for m in idx["metadata"]]
        path = plot_embedding_projection(emb, labels, out)
        print(json.dumps({"figure": path}, indent=2))
        return 0

    if kind == "fear_greed":
        if not args.index or not args.index.endswith(".parquet"):
            raise RuntimeError("fear_greed requires a parquet index carrying behavior_factors")
        idx = _load_index(args.index)
        fg = [m.get("behavior_factors", {}) for m in idx["metadata"]]
        fear = [float(f.get("fear_mean", 0.0)) for f in fg]
        greed = [float(f.get("greed_mean", 0.0)) for f in fg]
        path = plot_fear_greed_scatter(fear, greed, out_path=out)
        print(json.dumps({"figure": path}, indent=2))
        return 0

    if kind == "neighbors":
        raise RuntimeError("neighbor strips require captured frames; supply --frames index")

    if kind == "multimodal":
        if not args.result or not args.result_b:
            raise RuntimeError("multimodal requires both --result and --result-b")
        a = _json.load(open(args.result))
        b = _json.load(open(args.result_b))
        path = plot_multimodal_examples(a, b, out)
        print(json.dumps({"figure": path}, indent=2))
        return 0

    raise RuntimeError(f"unknown figure kind: {kind}")


# ---------------------------------------------------------------------------
# Parser
# ---------------------------------------------------------------------------


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="pigeon-observer",
        description="Offline observer / evaluation CLI for PigeonControl datasets.",
    )
    sub = p.add_subparsers(dest="command", required=True)

    # generate
    g = sub.add_parser("generate", help="Generate a dataset via Julia + optional Godot capture.")
    g.add_argument("--scenario", action="append", help="Scenario name (repeatable). Default: all 12.")
    g.add_argument("--seed", action="append", type=int, help="Seed (repeatable).")
    g.add_argument("--default-seed", type=int, default=69420, help="Fallback seed when --seed omitted.")
    g.add_argument("--n", type=int, default=200, help="Pigeon population.")
    g.add_argument("--steps", type=int, default=600, help="Simulation ticks per run.")
    g.add_argument("--sample-every", type=int, default=10, help="Sample every N simulation ticks.")
    g.add_argument("--output", required=True, help="Output dataset directory.")
    g.add_argument("--frames", action="store_true", help="Also capture frames via Godot (owns only its child).")
    g.add_argument("--environment", default="plaza", help="Godot environment preset.")
    g.add_argument("--session", default="observer", help="Godot capture session name.")
    g.add_argument("--ports", default="5000,5001", help="Comma list of ports for capture.")
    g.add_argument("--timeout", type=float, default=120.0, help="Max capture seconds.")
    g.add_argument("--julia-bin", default="julia", help="Julia executable.")
    g.add_argument("--godot-bin", default="godot", help="Godot executable.")
    g.add_argument("--repo-root", default=None, help="Repo root (auto-detected from cwd).")
    g.set_defaults(func=cmd_generate)

    # validate
    v = sub.add_parser("validate", help="Validate a built dataset; print compact JSON.")
    v.add_argument("--dataset", required=True, help="Dataset directory or manifest.")
    v.add_argument("--full", action="store_true", help="Include full detail report.")
    v.set_defaults(func=cmd_validate)

    # train
    t = sub.add_parser("train", help="Train a model on a dataset.")
    t.add_argument("--dataset", required=True, help="Dataset directory.")
    t.add_argument("--output", required=True, help="Checkpoint output directory.")
    t.add_argument("--split", default="train", help="Split used for training.")
    t.add_argument("--val-split", default="validation", help="Split used for validation.")
    t.add_argument("--mode", default="fusion", choices=["telemetry", "vision", "fusion"], help="Model modality.")
    t.add_argument("--hidden", type=int, default=128, help="Hidden width.")
    t.add_argument("--telemetry-dim", type=int, default=32, help="Telemetry feature dim.")
    t.add_argument("--fusion", default="concat", help="Fusion strategy.")
    t.add_argument("--seed", type=int, default=0, help="Training seed.")
    t.set_defaults(func=cmd_train)

    # evaluate
    e = sub.add_parser("evaluate", help="Evaluate a checkpoint into a NEW eval directory.")
    e.add_argument("--checkpoint", required=True, help="Model checkpoint path.")
    e.add_argument("--dataset", required=True, help="Dataset directory.")
    e.add_argument("--output", required=True, help="Base eval directory (a run subdir is created).")
    e.add_argument("--split", default="test", help="Split used for evaluation.")
    e.add_argument("--mode", default="fusion", choices=["telemetry", "vision", "fusion"], help="Model modality.")
    e.add_argument("--primary-key", default="cls_auroc", help="Primary metric for ranking.")
    e.set_defaults(func=cmd_evaluate)

    # embed
    em = sub.add_parser("embed", help="Write embeddings + metadata to parquet/npz.")
    em.add_argument("--checkpoint", required=True, help="Model checkpoint path.")
    em.add_argument("--dataset", required=True, help="Dataset directory.")
    em.add_argument("--output", required=True, help="Output directory.")
    em.add_argument("--split", default="test", help="Split used for embedding.")
    em.add_argument("--mode", default="fusion", choices=["telemetry", "vision", "fusion"], help="Model modality.")
    em.set_defaults(func=cmd_embed)

    # retrieve
    r = sub.add_parser("retrieve", help="Nearest sequences/runs by cosine (behavior-based).")
    r.add_argument("--index", required=True, help="Embedding index (.npz/.parquet).")
    r.add_argument("--query", default=None, help="Query sequence id.")
    r.add_argument("--run", default=None, help="Query run id (alternative to --query).")
    r.add_argument("--tick", default=None, help="Query tick (with --run).")
    r.add_argument("--top-k", type=int, default=5, help="Number of neighbors.")
    r.add_argument("--behavior-factors", nargs="*", default=None, help="Factors for behavior distance.")
    r.set_defaults(func=cmd_retrieve)

    # figures
    f = sub.add_parser("figures", help="Render evaluation/retrieval figures.")
    f.add_argument("--kind", required=True, choices=["timeline", "embedding", "neighbors", "fear_greed", "multimodal"])
    f.add_argument("--result", default=None, help="Result JSON (timeline/multimodal A).")
    f.add_argument("--result-b", default=None, help="Result JSON B (multimodal).")
    f.add_argument("--index", default=None, help="Embedding index for embedding/fear_greed.")
    f.add_argument("--output", required=True, help="Output figure path.")
    f.set_defaults(func=cmd_figures)

    return p


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
