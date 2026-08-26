"""Tests for pigeon_observer.evaluation.metrics (pure, no sibling deps)."""

import numpy as np
import pytest

from pigeon_observer.evaluation.metrics import (
    EvaluationResult,
    aggregate_seed_metrics,
    bootstrap_ci,
    brier_score,
    build_evaluation_result,
    classification_metrics,
    compare_baselines,
    ece,
    lead_time_metrics,
    calibration_metrics,
    regression_metrics,
)


def test_classification_perfect():
    y = [1, 0, 1, 0, 1, 0]
    yp = [1, 0, 1, 0, 1, 0]
    ys = [0.9, 0.1, 0.8, 0.2, 0.7, 0.3]
    m = classification_metrics(y, yp, ys)
    assert m["accuracy"] == pytest.approx(1.0)
    assert m["f1_macro"] == pytest.approx(1.0)
    assert m["auroc"] == pytest.approx(1.0)
    assert m["auroc_status"] == "ok"


def test_auroc_single_class_is_none_not_crash():
    m = classification_metrics([0, 0, 0], [0, 0, 0], [0.1, 0.2, 0.3])
    assert m["auroc"] is None
    assert m["auroc_status"] == "single_class"
    assert m["accuracy"] == pytest.approx(1.0)


def test_regression_known():
    yt = [0.0, 1.0, 2.0, 3.0]
    yp = [0.0, 1.0, 2.0, 3.0]
    r = regression_metrics(yt, yp)
    assert r["mae"] == pytest.approx(0.0)
    assert r["rmse"] == pytest.approx(0.0)
    assert r["r2"] == pytest.approx(1.0)


def test_regression_r2_zero_ss_tot_is_nan():
    r = regression_metrics([0.0, 0.0, 0.0], [1.0, 1.0, 1.0])
    assert np.isnan(r["r2"])


def test_ece_extreme():
    # All wrong confidence: prob 1, truth 0 -> ECE 1.0 in one bin.
    assert ece([0, 0, 0], [1.0, 1.0, 1.0]) == pytest.approx(1.0)
    # Perfect calibration: each bin's confidence equals its accuracy.
    assert ece([1, 0], [0.5, 0.5]) == pytest.approx(0.0, abs=1e-9)


def test_brier_known():
    assert brier_score([1, 0], [1.0, 0.0]) == pytest.approx(0.0)
    assert brier_score([1, 0], [0.5, 0.5]) == pytest.approx(0.25)


def test_calibration_metrics_bundles():
    c = calibration_metrics([1, 0], [0.5, 0.5])
    assert c["brier"] == pytest.approx(0.25)
    assert c["ece"] == pytest.approx(0.0, abs=1e-9)


def test_lead_time_perfect_and_never():
    assert lead_time_metrics([10, 20], [10, 20])["lead_mae"] == pytest.approx(0.0)
    # "never predicted" (-1) falls back to horizon; not NaN.
    lt = lead_time_metrics([10], [-1])
    assert not np.isnan(lt["lead_mae"])


def test_bootstrap_ci_deterministic():
    rng = np.random.default_rng(0)
    samples = list(rng.normal(size=200))
    est1, (lo1, hi1) = bootstrap_ci(samples, np.mean, n_boot=500, seed=42)
    est2, (lo2, hi2) = bootstrap_ci(samples, np.mean, n_boot=500, seed=42)
    assert est1 == pytest.approx(est2)
    assert lo1 == pytest.approx(lo2)
    assert hi1 == pytest.approx(hi2)
    # Different seed -> (almost surely) different resample, but still finite.
    _, (lo3, hi3) = bootstrap_ci(samples, np.mean, n_boot=500, seed=7)
    assert np.isfinite(lo3) and np.isfinite(hi3)


def test_aggregate_seed_metrics_shape():
    seeds = [{"a": 0.8, "b": 1.2}, {"a": 0.9, "b": 1.0}, {"a": 0.7, "b": 1.4}]
    out = aggregate_seed_metrics(seeds, ["a", "b"], seed=1)
    assert out["a"]["n_seeds"] == 3
    assert out["a"]["estimate"] == pytest.approx(0.8)
    assert out["a"]["ci"][0] <= out["a"]["estimate"] <= out["a"]["ci"][1]


def test_compare_baselines_reports_missing_not_inferred():
    proposed = {"auroc": 0.82}
    persistence = {"auroc": 0.80}
    missing = {}  # system absent
    cmp = compare_baselines(
        {"proposed": proposed, "persistence": persistence, "vision_only": missing},
        "auroc",
    )
    assert cmp["best"] == pytest.approx(0.82)
    assert cmp["missing"] == ["vision_only"]
    assert cmp["ranking"]["vision_only"]["primary"] == "missing"


def test_build_evaluation_result_default_research_false():
    seed_results = [
        {"seed": 1, "cls_auroc": 0.7, "fear_mae": 0.1},
        {"seed": 2, "cls_auroc": 0.75, "fear_mae": 0.12},
    ]
    res = build_evaluation_result(seed_results, ["cls_auroc", "fear_mae"], primary_key="cls_auroc")
    assert isinstance(res, EvaluationResult)
    assert res.research_result is False
    assert res.metrics["cls_auroc"] == pytest.approx(0.725)
    assert "persistence" in res.baseline_comparisons["ranking"] or res.baseline_comparisons["missing"] == []
