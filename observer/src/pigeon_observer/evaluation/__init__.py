"""Evaluation subpackage for the PigeonControl observer experiments.

Re-exports the pure metric, retrieval, and figure helpers. Importing this
module is cheap: matplotlib is only loaded inside figure functions, and the
sibling ``data`` / ``models`` / ``training`` modules are never imported here.
"""

from .metrics import (
    EvaluationResult,
    bootstrap_ci,
    brier_score,
    build_evaluation_result,
    ece,
    calibration_metrics,
    classification_metrics,
    compare_baselines,
    aggregate_seed_metrics,
    lead_time_metrics,
    regression_metrics,
)
from .retrieval import (
    Neighbor,
    behavior_factor_distance,
    behavior_relevant,
    cosine_distance,
    evaluate_retrieval,
    mrr,
    recall_at_k,
    retrieve_neighbors,
)
from .figures import (
    plot_embedding_projection,
    plot_fear_greed_scatter,
    plot_multimodal_examples,
    plot_neighbor_strips,
    plot_timeline,
)

__all__ = [
    # metrics
    "classification_metrics",
    "regression_metrics",
    "calibration_metrics",
    "ece",
    "brier_score",
    "lead_time_metrics",
    "bootstrap_ci",
    "aggregate_seed_metrics",
    "compare_baselines",
    "build_evaluation_result",
    "EvaluationResult",
    # retrieval
    "cosine_distance",
    "behavior_factor_distance",
    "behavior_relevant",
    "retrieve_neighbors",
    "Neighbor",
    "recall_at_k",
    "mrr",
    "evaluate_retrieval",
    # figures
    "plot_timeline",
    "plot_embedding_projection",
    "plot_neighbor_strips",
    "plot_fear_greed_scatter",
    "plot_multimodal_examples",
]
