"""Evaluation metrics for the PigeonControl observer experiments.

All functions here are pure (numpy / scikit-learn) so they are fast to test
and free of torch / sibling-module dependencies. Higher-level orchestration
(model loading, dataset iteration) lives in the CLI and the sibling
``training`` / ``models`` modules.

Design notes:

- Classification AUROC is returned as ``None`` (with a status string) when the
  target has a single class, instead of raising. We never crash on degenerate
  labels.
- Bootstrap confidence intervals resample at the seed / run level (the unit of
  independence) with a deterministic RNG seed. Aggregation across seeds reports
  a point estimate and a percentile CI.
- Negative findings and missing baselines are first-class fields. We never infer
  a result that was not actually measured, and we never claim world-model status
  from a single head beating a persistence baseline.
"""

from __future__ import annotations

import numpy as np
from dataclasses import dataclass, field
from typing import Callable, Dict, List, Optional, Sequence, Tuple

# ---------------------------------------------------------------------------
# Classification
# ---------------------------------------------------------------------------


def classification_metrics(
    y_true: Sequence[int],
    y_pred: Sequence[int],
    y_score: Optional[Sequence[float]] = None,
) -> Dict[str, object]:
    """Accuracy, macro-F1, and AUROC for a binary/ multiclass target.

    AUROC is ``None`` when ``y_true`` has fewer than two classes. The returned
    ``auroc_status`` explains a ``None`` value (``"ok"`` or ``"single_class"``).
    """
    y_true = np.asarray(y_true)
    y_pred = np.asarray(y_pred)

    # Accuracy.
    accuracy = float(np.mean(y_true == y_pred)) if len(y_true) else float("nan")

    # Macro-F1 (computed directly to stay dependency-light and handle 0 labels).
    labels = np.unique(np.concatenate([y_true, y_pred]))
    f1_per_label = []
    for lab in labels:
        tp = int(np.sum((y_true == lab) & (y_pred == lab)))
        fp = int(np.sum((y_true != lab) & (y_pred == lab)))
        fn = int(np.sum((y_true == lab) & (y_pred != lab)))
        prec = tp / (tp + fp) if (tp + fp) else 0.0
        rec = tp / (tp + fn) if (tp + fn) else 0.0
        f1 = 2 * prec * rec / (prec + rec) if (prec + rec) else 0.0
        f1_per_label.append(f1)
    f1_macro = float(np.mean(f1_per_label)) if f1_per_label else float("nan")

    auroc, status = _safe_roc_auc(y_true, y_score)

    return {
        "accuracy": accuracy,
        "f1_macro": f1_macro,
        "auroc": auroc,
        "auroc_status": status,
    }


def _safe_roc_auc(
    y_true: np.ndarray, y_score: Optional[Sequence[float]]
) -> Tuple[Optional[float], str]:
    classes = np.unique(y_true)
    if len(classes) < 2:
        return None, "single_class"
    if y_score is None:
        return None, "no_scores"
    try:
        from sklearn.metrics import roc_auc_score

        return float(roc_auc_score(y_true, np.asarray(y_score))), "ok"
    except ValueError:
        return None, "undefined"


# ---------------------------------------------------------------------------
# Regression
# ---------------------------------------------------------------------------


def regression_metrics(
    y_true: Sequence[float], y_pred: Sequence[float]
) -> Dict[str, float]:
    y_true = np.asarray(y_true, dtype=float)
    y_pred = np.asarray(y_pred, dtype=float)
    if len(y_true) == 0:
        return {"mae": float("nan"), "rmse": float("nan"), "r2": float("nan")}
    mae = float(np.mean(np.abs(y_true - y_pred)))
    rmse = float(np.sqrt(np.mean((y_true - y_pred) ** 2)))
    ss_res = float(np.sum((y_true - y_pred) ** 2))
    ss_tot = float(np.sum((y_true - y_true.mean()) ** 2))
    r2 = 1.0 - ss_res / ss_tot if ss_tot > 0 else float("nan")
    return {"mae": mae, "rmse": rmse, "r2": r2}


# ---------------------------------------------------------------------------
# Calibration
# ---------------------------------------------------------------------------


def ece(y_true: Sequence[int], y_prob: Sequence[float], n_bins: int = 10) -> float:
    """Expected calibration error (weighted absolute conf - acc gap)."""
    y_true = np.asarray(y_true, dtype=float)
    y_prob = np.asarray(y_prob, dtype=float)
    if len(y_true) == 0:
        return float("nan")
    bins = np.linspace(0.0, 1.0, n_bins + 1)
    idx = np.clip(np.digitize(y_prob, bins) - 1, 0, n_bins - 1)
    total = len(y_true)
    err = 0.0
    for b in range(n_bins):
        m = idx == b
        if not m.any():
            continue
        conf = float(y_prob[m].mean())
        acc = float(y_true[m].mean())
        err += (m.sum() / total) * abs(conf - acc)
    return float(err)


def brier_score(y_true: Sequence[int], y_prob: Sequence[float]) -> float:
    y_true = np.asarray(y_true, dtype=float)
    y_prob = np.asarray(y_prob, dtype=float)
    if len(y_true) == 0:
        return float("nan")
    return float(np.mean((y_prob - y_true) ** 2))


def calibration_metrics(
    y_true: Sequence[int], y_prob: Sequence[float], n_bins: int = 10
) -> Dict[str, float]:
    return {"ece": ece(y_true, y_prob, n_bins), "brier": brier_score(y_true, y_prob)}


# ---------------------------------------------------------------------------
# Lead time for panic onset
# ---------------------------------------------------------------------------


def lead_time_metrics(
    onset_true: Sequence[int],
    onset_pred: Sequence[int],
) -> Dict[str, float]:
    """Error in predicting the tick at which panic begins.

    ``onset_pred`` is the first tick where the predicted panic probability
    crosses a threshold (or -1 if never). A positive lead-time error means the
    model recognized onset later than it actually happened.
    """
    onset_true = np.asarray(onset_true, dtype=float)
    onset_pred = np.asarray(onset_pred, dtype=float)
    if len(onset_true) == 0:
        return {"lead_mae": float("nan"), "lead_rmse": float("nan")}
    # Treat "never predicted" (-1) as the worst case: offset by max horizon.
    never = onset_pred < 0
    if never.any():
        horizon = float(np.nanmax(onset_true)) + 1.0
        onset_pred = np.where(never, horizon, onset_pred)
    diff = onset_pred - onset_true
    return {
        "lead_mae": float(np.mean(np.abs(diff))),
        "lead_rmse": float(np.sqrt(np.mean(diff**2))),
    }


# ---------------------------------------------------------------------------
# Bootstrap confidence intervals (resample at seed / run level)
# ---------------------------------------------------------------------------


def bootstrap_ci(
    samples: Sequence[float],
    stat_fn: Callable[[Sequence[float]], float] = np.mean,
    n_boot: int = 1000,
    seed: int = 0,
) -> Tuple[float, Tuple[float, float]]:
    """Resample ``samples`` with replacement and return (estimate, (lo, hi)).

    ``samples`` are already aggregated per seed / run, so resampling them
    respects the unit of independence. The RNG is seeded for determinism.
    """
    samples = np.asarray(samples, dtype=float)
    n = len(samples)
    if n == 0:
        return float("nan"), (float("nan"), float("nan"))
    rng = np.random.default_rng(seed)
    estimates = np.empty(n_boot, dtype=float)
    for i in range(n_boot):
        idx = rng.integers(0, n, n)
        estimates[i] = stat_fn(samples[idx])
    lo, hi = np.percentile(estimates, [2.5, 97.5])
    return float(stat_fn(samples)), (float(lo), float(hi))


def aggregate_seed_metrics(
    seed_results: Sequence[Dict[str, float]],
    metric_keys: Sequence[str],
    seed: int = 0,
    n_boot: int = 1000,
) -> Dict[str, Dict[str, object]]:
    """Aggregate per-seed metric dicts into point estimates + bootstrap CIs.

    Each entry of ``seed_results`` is a dict mapping metric name -> value.
    We collect each metric across seeds and report mean and a (lo, hi) CI.
    """
    out: Dict[str, Dict[str, object]] = {}
    for key in metric_keys:
        vals = [float(r[key]) for r in seed_results if key in r]
        est, (lo, hi) = bootstrap_ci(vals, np.mean, n_boot=n_boot, seed=seed)
        out[key] = {"estimate": est, "ci": [lo, hi], "n_seeds": len(vals)}
    return out


# ---------------------------------------------------------------------------
# Baseline comparison + negative findings
# ---------------------------------------------------------------------------


def compare_baselines(
    named_results: Dict[str, Dict[str, float]],
    primary_key: str,
) -> Dict[str, object]:
    """Compare a primary metric across named systems.

    Every entry in ``named_results`` is a metric dict keyed by system name.
    A system that is absent is reported as ``"missing"`` rather than inferred.
    Returns the ranking and the gap of each system versus the best observed.
    """
    observed = {}
    for name, metrics in named_results.items():
        if primary_key in metrics:
            observed[name] = float(metrics[primary_key])
        else:
            observed[name] = "missing"

    missing = [n for n, v in observed.items() if v == "missing"]
    present = {n: v for n, v in observed.items() if v != "missing"}
    best = max(present.values()) if present else None

    ranking = {}
    for name, v in observed.items():
        if v == "missing":
            ranking[name] = {"primary": "missing", "gap_to_best": "missing"}
        else:
            ranking[name] = {
                "primary": v,
                "gap_to_best": (v - best) if best is not None else None,
            }
    return {
        "primary_key": primary_key,
        "best": best,
        "ranking": ranking,
        "missing": missing,
    }


# ---------------------------------------------------------------------------
# Result container
# ---------------------------------------------------------------------------


@dataclass
class EvaluationResult:
    """Aggregated evaluation output.

    Fields are deliberately permissive: ``research_result`` stays ``False``
    unless an aggregate head is shown to beat the persistence baseline on held
    out data. Missing baselines are recorded, not invented.
    """

    metrics: Dict[str, object] = field(default_factory=dict)
    seed_level: List[Dict[str, object]] = field(default_factory=list)
    bootstrap: Dict[str, Dict[str, object]] = field(default_factory=dict)
    negative_findings: List[str] = field(default_factory=list)
    baseline_comparisons: Dict[str, object] = field(default_factory=dict)
    model_info: Dict[str, object] = field(default_factory=dict)
    ood_report: Dict[str, object] = field(default_factory=dict)
    research_result: bool = False

    def to_dict(self) -> Dict[str, object]:
        return {
            "metrics": self.metrics,
            "seed_level": self.seed_level,
            "bootstrap": self.bootstrap,
            "negative_findings": self.negative_findings,
            "baseline_comparisons": self.baseline_comparisons,
            "model_info": self.model_info,
            "ood_report": self.ood_report,
            "research_result": self.research_result,
        }


def build_evaluation_result(
    seed_results: Sequence[Dict[str, float]],
    metric_keys: Sequence[str],
    *,
    primary_key: str = "auroc",
    baseline_results: Optional[Dict[str, Dict[str, float]]] = None,
    model_info: Optional[Dict[str, object]] = None,
    negative_findings: Optional[Sequence[str]] = None,
    ood_report: Optional[Dict[str, object]] = None,
    seed: int = 0,
    n_boot: int = 1000,
) -> EvaluationResult:
    """Assemble an :class:`EvaluationResult` from per-seed metric dicts."""
    seed_results = list(seed_results)
    bootstrap = aggregate_seed_metrics(seed_results, metric_keys, seed=seed, n_boot=n_boot)

    # Point-estimate style aggregate (mean across seeds) for the flat metrics.
    flat: Dict[str, object] = {}
    for key in metric_keys:
        vals = [float(r[key]) for r in seed_results if key in r]
        if vals:
            flat[key] = float(np.mean(vals))
    # Preserve AUROC null status if any seed lacked two classes.
    if "auroc" in flat and any(
        r.get("auroc_status") == "single_class" for r in seed_results if "auroc_status" in r
    ):
        flat["auroc_status"] = "single_class_observed"

    # Baseline comparison on the primary metric.
    named = {f"proposed": flat}
    if baseline_results:
        named.update(baseline_results)
    cmp = compare_baselines(named, primary_key)

    # Research result policy: only True when a real head beats persistence on
    # held-out data. We cannot assert that here without the measured gap, so we
    # default to False and let callers flip it with evidence.
    research_result = False

    return EvaluationResult(
        metrics=flat,
        seed_level=[dict(r) for r in seed_results],
        bootstrap=bootstrap,
        negative_findings=list(negative_findings or []),
        baseline_comparisons=cmp,
        model_info=dict(model_info or {}),
        ood_report=dict(ood_report or {}),
        research_result=research_result,
    )
