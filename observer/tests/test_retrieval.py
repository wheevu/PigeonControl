"""Tests for pigeon_observer.evaluation.retrieval (pure, behavior-anchored)."""

import numpy as np
import pytest

from pigeon_observer.evaluation.retrieval import (
    behavior_factor_distance,
    behavior_relevant,
    cosine_distance,
    evaluate_retrieval,
    recall_at_k,
    retrieve_neighbors,
)

FACTORS = ["panic_mean", "fear_mean", "greed_mean"]


def test_cosine_distance_known():
    assert cosine_distance([1.0, 0.0], [1.0, 0.0]) == pytest.approx(0.0)
    assert cosine_distance([1.0, 0.0], [0.0, 1.0]) == pytest.approx(1.0)
    # Degenerate vectors: both zero identical, one zero maximal.
    assert cosine_distance([0.0, 0.0], [0.0, 0.0]) == pytest.approx(0.0)
    assert cosine_distance([0.0, 0.0], [1.0, 0.0]) == pytest.approx(1.0)


def test_behavior_factor_distance():
    a = {"panic_mean": 0.9, "fear_mean": 0.2, "greed_mean": 0.3}
    b = {"panic_mean": 0.9, "fear_mean": 0.2, "greed_mean": 0.3}
    assert behavior_factor_distance(a, b, FACTORS) == pytest.approx(0.0)
    c = {"panic_mean": 0.1, "fear_mean": 0.8, "greed_mean": 0.7}
    d = behavior_factor_distance(a, c, FACTORS)
    assert d > 0.5


def _index():
    """Build an index where embeddings cluster by behavior, not by seed."""
    # High-panic cluster embedding ~ [1,0]; low-panic cluster ~ [0,1].
    base = {
        "seq_high_s1": dict(seed=1, behavior_factors={"panic_mean": 0.9, "fear_mean": 0.2, "greed_mean": 0.3}),
        "seq_high_s2": dict(seed=2, behavior_factors={"panic_mean": 0.9, "fear_mean": 0.2, "greed_mean": 0.3}),
        "seq_low_s1": dict(seed=1, behavior_factors={"panic_mean": 0.1, "fear_mean": 0.8, "greed_mean": 0.7}),
        "seq_low_s3": dict(seed=3, behavior_factors={"panic_mean": 0.1, "fear_mean": 0.8, "greed_mean": 0.7}),
    }
    emb = {
        "seq_high_s1": [1.0, 0.0],
        "seq_high_s2": [0.98, 0.05],
        "seq_low_s1": [0.0, 1.0],
        "seq_low_s3": [0.05, 0.97],
    }
    index = []
    for sid, meta in base.items():
        meta = dict(meta)
        meta["sequence_id"] = sid
        meta["embedding"] = emb[sid]
        index.append(meta)
    return index


def test_retrieve_excludes_same_sequence():
    index = _index()
    embs = [e["embedding"] for e in index]
    meta = [e for e in index]
    neigh = retrieve_neighbors(
        index[0]["embedding"], embs, meta,
        query_sequence_id=index[0]["sequence_id"], behavior_factors=FACTORS, top_k=3,
    )
    assert all(n.sequence_id != index[0]["sequence_id"] for n in neigh)


def test_relevance_is_behavior_not_seed():
    # Query: a high-panic sequence from seed 1.
    query = {
        "sequence_id": "seq_high_s1",
        "seed": 1,
        "behavior_factors": {"panic_mean": 0.9, "fear_mean": 0.2, "greed_mean": 0.3},
        "embedding": [1.0, 0.0],
    }
    index = _index()
    # Same seed but DIFFERENT behavior (low panic) must be irrelevant.
    same_seed_diff_behavior = next(e for e in index if e["seed"] == 1 and e["behavior_factors"]["panic_mean"] < 0.5)
    assert not behavior_relevant(query, same_seed_diff_behavior, FACTORS, threshold=0.3)
    # Different seed but SAME behavior (high panic) must be relevant.
    diff_seed_same_behavior = next(e for e in index if e["seed"] != 1 and e["behavior_factors"]["panic_mean"] > 0.5)
    assert behavior_relevant(query, diff_seed_same_behavior, FACTORS, threshold=0.3)


def test_evaluate_retrieval_recall_uses_behavior():
    index = _index()
    # Query is the high-panic seed-1 sequence; it is excluded from its own
    # neighbors, so the relevant set is the high-panic sequence from seed 2.
    query = {
        "sequence_id": "seq_high_s1",
        "seed": 1,
        "behavior_factors": {"panic_mean": 0.9, "fear_mean": 0.2, "greed_mean": 0.3},
        "embedding": [1.0, 0.0],
    }
    res = evaluate_retrieval(
        [query], index,
        embedding_key="embedding", behavior_factors=FACTORS,
        behavior_threshold=0.3, top_k=3,
    )
    assert res["relevance"] == "behavior_factor_proximity"
    # Recall@1 should be 1.0: the top neighbor is the other high-panic sequence.
    assert res["recall_at_k"][1] == pytest.approx(1.0)
    assert res["mrr"] == pytest.approx(1.0)


def test_recall_at_k_edge():
    assert np.isnan(recall_at_k([], ["a", "b"], 2))
    assert recall_at_k(["a"], ["a", "b"], 1) == pytest.approx(1.0)
    assert recall_at_k(["a"], ["b", "a"], 1) == pytest.approx(0.0)
