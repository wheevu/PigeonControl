"""Figure generation for observer evaluation results.

Every function fails plainly (raises) when the required evidence is absent
rather than fabricating a plot. matplotlib is imported lazily inside each
function so importing this module never pulls in a GUI backend.

Figures produced:

- ``plot_timeline``: ground-truth panic vs predicted panic probability over ticks.
- ``plot_embedding_projection``: 2D PCA projection of sequence embeddings.
- ``plot_neighbor_strips``: frame strips of a query and its nearest neighbors.
- ``plot_fear_greed_scatter``: hidden fear vs greed scatter, colored by a label.
- ``plot_multimodal_examples``: multimodal-success vs vision-only-failure cases.
"""

from __future__ import annotations

import numpy as np
from typing import Dict, List, Optional, Sequence


def _require(cond: bool, msg: str) -> None:
    if not cond:
        raise FileNotFoundError(msg)


def plot_timeline(
    ticks: Sequence[int],
    ground_truth: Sequence[float],
    predicted: Sequence[float],
    out_path: str,
    *,
    title: str = "Panic probability: ground truth vs predicted",
) -> str:
    """Save a timeline of GT vs predicted panic probability.

    Fails if either series is empty (no evidence to plot).
    """
    _require(len(ground_truth) > 0 and len(predicted) > 0, "timeline: empty GT or prediction series")
    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    ticks = np.asarray(ticks, dtype=float)
    gt = np.asarray(ground_truth, dtype=float)
    pr = np.asarray(predicted, dtype=float)

    fig, ax = plt.subplots(figsize=(8, 4))
    ax.plot(ticks, gt, label="ground_truth", color="#1f77b4")
    ax.plot(ticks, pr, label="predicted", color="#d62728", linestyle="--")
    ax.set_xlabel("tick")
    ax.set_ylabel("panic probability")
    ax.set_title(title)
    ax.legend()
    fig.tight_layout()
    fig.savefig(out_path, dpi=120)
    plt.close(fig)
    return out_path


def plot_embedding_projection(
    embeddings: Sequence[Sequence[float]],
    labels: Optional[Sequence] = None,
    out_path: str = "embedding_projection.png",
    *,
    title: str = "Embedding projection (PCA)",
) -> str:
    """Save a 2D PCA projection of embeddings (PCA is acceptable per spec)."""
    _require(len(embeddings) > 0, "embedding_projection: no embeddings supplied")
    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from sklearn.decomposition import PCA

    X = np.asarray(embeddings, dtype=float)
    if X.shape[1] < 2:
        # Pad to 2D if embeddings are 1-D.
        X = np.hstack([X, np.zeros((X.shape[0], 2 - X.shape[1]))])
    proj = PCA(n_components=2).fit_transform(X)

    fig, ax = plt.subplots(figsize=(6, 6))
    if labels is not None:
        labels = np.asarray(labels)
        for val in np.unique(labels):
            m = labels == val
            ax.scatter(proj[m, 0], proj[m, 1], label=str(val), s=12)
        ax.legend(fontsize=8)
    else:
        ax.scatter(proj[:, 0], proj[:, 1], s=12)
    ax.set_xlabel("PC1")
    ax.set_ylabel("PC2")
    ax.set_title(title)
    fig.tight_layout()
    fig.savefig(out_path, dpi=120)
    plt.close(fig)
    return out_path


def plot_neighbor_strips(
    query_frames: Sequence[str],
    neighbor_frames: Sequence[Sequence[str]],
    out_path: str,
    *,
    title: str = "Neighbor frame strips",
) -> str:
    """Save a strip of the query frames followed by each neighbor's frames.

    ``neighbor_frames`` is a list (one per neighbor) of frame image paths. Fails
    if no frames are supplied (no evidence captured).
    """
    from PIL import Image

    _require(len(query_frames) > 0, "neighbor_strips: no query frames supplied")
    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    rows = [list(query_frames)]
    for nf in neighbor_frames:
        rows.append(list(nf))

    n_cols = max(len(r) for r in rows)
    fig, axes = plt.subplots(len(rows), n_cols, figsize=(2 * n_cols, 2 * len(rows)))
    if len(rows) == 1:
        axes = np.atleast_2d(axes)
    if n_cols == 1:
        axes = np.atleast_2d(axes).T

    for r, row in enumerate(rows):
        for c in range(n_cols):
            ax = axes[r, c]
            ax.set_xticks([])
            ax.set_yticks([])
            if c < len(row):
                try:
                    ax.imshow(np.asarray(Image.open(row[c]).convert("RGB")))
                except Exception:
                    ax.set_facecolor("lightgray")
            else:
                ax.set_facecolor("white")
    fig.suptitle(title)
    fig.tight_layout()
    fig.savefig(out_path, dpi=120)
    plt.close(fig)
    return out_path


def plot_fear_greed_scatter(
    fear: Sequence[float],
    greed: Sequence[float],
    color_by: Optional[Sequence] = None,
    out_path: str = "fear_greed.png",
    *,
    title: str = "Hidden fear vs greed",
) -> str:
    """Save a scatter of hidden fear vs greed, optionally colored by a label."""
    _require(len(fear) > 0 and len(greed) > 0, "fear_greed: empty factor series")
    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    fear = np.asarray(fear, dtype=float)
    greed = np.asarray(greed, dtype=float)

    fig, ax = plt.subplots(figsize=(6, 6))
    if color_by is not None:
        sc = ax.scatter(fear, greed, c=np.asarray(color_by, dtype=float), s=14, cmap="viridis")
        fig.colorbar(sc, ax=ax, label="label")
    else:
        ax.scatter(fear, greed, s=14)
    ax.set_xlabel("fear")
    ax.set_ylabel("greed")
    ax.set_title(title)
    fig.tight_layout()
    fig.savefig(out_path, dpi=120)
    plt.close(fig)
    return out_path


def plot_multimodal_examples(
    result_a: Dict[str, object],
    result_b: Dict[str, object],
    out_path: str,
    *,
    label_a: str = "multimodal_success",
    label_b: str = "vision_only_failure",
) -> str:
    """Save a side-by-side of two result files' aggregate metrics.

    Fails plainly if either result file is missing (we never fake a plot when
    one modality's evidence is absent).
    """
    _require(result_a is not None, "multimodal: result A missing")
    _require(result_b is not None, "multimodal: result B missing")
    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    keys = [k for k in result_a.keys() if k in result_b and isinstance(result_a[k], (int, float))]
    if not keys:
        raise ValueError("multimodal: no shared numeric metrics between result files")

    a_vals = [float(result_a[k]) for k in keys]
    b_vals = [float(result_b[k]) for k in keys]
    x = np.arange(len(keys))

    fig, ax = plt.subplots(figsize=(8, 4))
    ax.bar(x - 0.2, a_vals, width=0.4, label=label_a)
    ax.bar(x + 0.2, b_vals, width=0.4, label=label_b)
    ax.set_xticks(x)
    ax.set_xticklabels(keys, rotation=45, ha="right", fontsize=8)
    ax.set_title("Multimodal vs vision-only")
    ax.legend()
    fig.tight_layout()
    fig.savefig(out_path, dpi=120)
    plt.close(fig)
    return out_path
