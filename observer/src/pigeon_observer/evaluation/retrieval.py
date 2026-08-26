"""Behavior-based sequence retrieval for the observer dataset.

Retrieval is deliberately *behavior-anchored*: relevance between a query
sequence and a candidate sequence is decided by their resulting behavior
factors (e.g. mean panic / fear / greed, combat occurrence), never by sharing
a seed or a scenario. This prevents the trivial "same seed = neighbor" shortcut
and forces the embedding space to be judged on actual behavior similarity.

All functions are pure numpy so they are easy to test and free of sibling
imports.
"""

from __future__ import annotations

import numpy as np
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Sequence


# ---------------------------------------------------------------------------
# Distances
# ---------------------------------------------------------------------------


def cosine_distance(a: Sequence[float], b: Sequence[float]) -> float:
    """1 - cosine similarity, with explicit handling of degenerate vectors."""
    a = np.asarray(a, dtype=float)
    b = np.asarray(b, dtype=float)
    na = float(np.linalg.norm(a))
    nb = float(np.linalg.norm(b))
    if na == 0.0 and nb == 0.0:
        return 0.0  # two degenerate vectors are treated as identical
    if na == 0.0 or nb == 0.0:
        return 1.0  # one undefined vector is maximally far
    return 1.0 - float(np.dot(a, b) / (na * nb))


def _factor_dict(meta: Dict[str, object]) -> Dict[str, float]:
    """Extract the behavior-factor sub-dict, tolerating flat factor dicts."""
    bf = meta.get("behavior_factors")
    if isinstance(bf, dict):
        return bf
    return meta


def behavior_factor_distance(
    meta_a: Dict[str, object],
    meta_b: Dict[str, object],
    factors: Sequence[str],
) -> float:
    """Euclidean distance over the selected behavior factors of two metadatas.

    Each metadata may carry its factors either flat or nested under a
    ``behavior_factors`` key. Only the listed ``factors`` are used, so grouping
    is always behavior-driven and never includes seed / scenario identifiers.
    """
    fa = _factor_dict(meta_a)
    fb = _factor_dict(meta_b)
    va = np.asarray([float(fa.get(f, 0.0)) for f in factors], dtype=float)
    vb = np.asarray([float(fb.get(f, 0.0)) for f in factors], dtype=float)
    return float(np.linalg.norm(va - vb))


def behavior_relevant(
    query_meta: Dict[str, object],
    cand_meta: Dict[str, object],
    factors: Sequence[str],
    threshold: float,
) -> bool:
    """True when a candidate's behavior factors are within ``threshold``."""
    return behavior_factor_distance(query_meta, cand_meta, factors) <= threshold


# ---------------------------------------------------------------------------
# Neighbor search
# ---------------------------------------------------------------------------


@dataclass
class Neighbor:
    index: int
    sequence_id: str
    distance: float
    behavior_distance: float
    metadata: Dict[str, object] = field(default_factory=dict)


def _query_index(query_sequence_id: str, index_metadata: Sequence[Dict[str, object]]) -> int:
    for j, m in enumerate(index_metadata):
        if str(m.get("sequence_id")) == query_sequence_id:
            return j
    return 0


def retrieve_neighbors(
    query_embedding: Sequence[float],
    index_embeddings: Sequence[Sequence[float]],
    index_metadata: Sequence[Dict[str, object]],
    *,
    query_sequence_id: Optional[str] = None,
    behavior_factors: Optional[Sequence[str]] = None,
    top_k: int = 5,
    exclude_same_sequence: bool = True,
) -> List[Neighbor]:
    """Return the nearest index sequences to ``query_embedding`` by cosine.

    The exact same sequence (matched on ``sequence_id``) is excluded when
    ``exclude_same_sequence`` is set, so a sequence is never its own neighbor.
    ``behavior_distance`` is filled only when ``behavior_factors`` is provided.
    """
    q = np.asarray(query_embedding, dtype=float)
    embs = [np.asarray(e, dtype=float) for e in index_embeddings]

    dists = np.array([cosine_distance(q, e) for e in embs], dtype=float)
    order = np.argsort(dists, kind="stable")

    out: List[Neighbor] = []
    for i in order:
        i = int(i)
        meta = dict(index_metadata[i])
        seq_id = str(meta.get("sequence_id", f"seq_{i}"))
        if exclude_same_sequence and query_sequence_id is not None and seq_id == query_sequence_id:
            continue
        bd: float = float("nan")
        if behavior_factors is not None and query_sequence_id is not None:
            bd = behavior_factor_distance(
                index_metadata[_query_index(query_sequence_id, index_metadata)],
                meta,
                behavior_factors,
            )
        out.append(
            Neighbor(
                index=i,
                sequence_id=seq_id,
                distance=float(dists[i]),
                behavior_distance=bd,
                metadata=meta,
            )
        )
        if len(out) >= top_k:
            break
    return out


# ---------------------------------------------------------------------------
# Retrieval quality (behavior-based relevance)
# ---------------------------------------------------------------------------


def recall_at_k(relevant_ids: Sequence[str], retrieved_ids: Sequence[str], k: int) -> float:
    """Fraction of relevant ids present in the top-k retrieved ids."""
    if not relevant_ids:
        return float("nan")
    top = list(retrieved_ids[:k])
    hits = sum(1 for r in relevant_ids if r in top)
    return hits / len(relevant_ids)


def mrr(relevant_lists: Sequence[Sequence[str]], retrieved_lists: Sequence[Sequence[str]]) -> float:
    """Mean reciprocal rank over queries (1/rank of first relevant)."""
    if not relevant_lists:
        return float("nan")
    rr = []
    for rel, ret in zip(relevant_lists, retrieved_lists):
        rel_set = set(rel)
        rank = None
        for i, r in enumerate(ret, start=1):
            if r in rel_set:
                rank = i
                break
        rr.append(1.0 / rank if rank is not None else 0.0)
    return float(np.mean(rr))


def evaluate_retrieval(
    queries: Sequence[Dict[str, object]],
    index: Sequence[Dict[str, object]],
    *,
    embedding_key: str = "embedding",
    behavior_factors: Sequence[str],
    behavior_threshold: float,
    top_k: int = 5,
    exclude_same_sequence: bool = True,
) -> Dict[str, object]:
    """Recall@K and MRR where relevance is behavior-factor proximity.

    Each query and index entry is a dict containing at least a sequence id, an
    embedding, and the behavior ``factors``. A candidate is relevant to a query
    iff its behavior factors are within ``behavior_threshold`` (same seed /
    scenario is irrelevant). Results are reported per-k for k=1..top_k plus MRR.
    """
    index_embs = [np.asarray(q[embedding_key], dtype=float) for q in index]
    index_meta = [dict(q) for q in index]

    per_k: Dict[int, List[float]] = {k: [] for k in range(1, top_k + 1)}
    mrr_rows: List[float] = []

    for q in queries:
        q_emb = np.asarray(q[embedding_key], dtype=float)
        q_meta = dict(q)
        q_id = str(q_meta.get("sequence_id", ""))

        neigh = retrieve_neighbors(
            q_emb,
            index_embs,
            index_meta,
            query_sequence_id=q_id,
            behavior_factors=behavior_factors,
            top_k=top_k,
            exclude_same_sequence=exclude_same_sequence,
        )
        retrieved_ids = [n.sequence_id for n in neigh]

        relevant_ids = [
            str(e.get("sequence_id"))
            for e in index
            if behavior_relevant(q_meta, dict(e), behavior_factors, behavior_threshold)
            and str(e.get("sequence_id")) != q_id
        ]

        for k in range(1, top_k + 1):
            per_k[k].append(recall_at_k(relevant_ids, retrieved_ids, k))
        mrr_rows.append(mrr([relevant_ids], [retrieved_ids]))

    recall_summary = {k: float(np.mean(v)) if v else float("nan") for k, v in per_k.items()}
    return {
        "recall_at_k": recall_summary,
        "mrr": float(np.mean(mrr_rows)) if mrr_rows else float("nan"),
        "top_k": top_k,
        "behavior_factors": list(behavior_factors),
        "behavior_threshold": behavior_threshold,
        "relevance": "behavior_factor_proximity",
    }
