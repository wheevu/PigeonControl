"""Baseline model utilities.

Lightweight, dependency-modest baselines used as a floor for the learned model:

* ``train-mean`` future aggregates and hidden genome,
* ``majority`` panic probability / crowd regime,
* an optional linear/logistic telemetry baseline (sklearn if available, else a
  closed-form torch least-squares / logistic fit).

Archetype conditioning is applied only when an observable ``archetype``
categorical aggregate is present in the data; otherwise the baseline stays
global.
"""
from __future__ import annotations

import json
from typing import Dict, List, Optional

import numpy as np
import torch

try:
    from sklearn.linear_model import LinearRegression, LogisticRegression
    _HAVE_SKLEARN = True
except Exception:  # pragma: no cover - optional dependency
    _HAVE_SKLEARN = False


def _mean_over_time(x: np.ndarray) -> np.ndarray:
    # x: [N, T, F] -> [N, F] (reduce only the time axis)
    if x.ndim == 3:
        return x.mean(axis=1)
    return x


class BaselineModel:
    def __init__(self, embedding_dim: int = 64, archetype_index: Optional[int] = None):
        self.embedding_dim = embedding_dim
        self.archetype_index = archetype_index
        self.future_mean: Optional[np.ndarray] = None
        self.genome_mean: Optional[np.ndarray] = None
        self.panic_prob: float = 0.5
        self.regime_counts: Optional[np.ndarray] = None
        # per-archetype overrides
        self.arch_future: Dict[int, np.ndarray] = {}
        self.arch_genome: Dict[int, np.ndarray] = {}
        self.arch_panic: Dict[int, float] = {}
        self.arch_regime: Dict[int, int] = {}
        # sklearn models (optional)
        self.future_lr = None
        self.genome_lr = None
        self.panic_lr = None
        self.regime_lr = None
        self._fitted = False

    # -- fitting ----------------------------------------------------------
    def fit(self, dataset, telemetry_key: str = "telemetry") -> "BaselineModel":
        tel_list, fut_list, gen_list, pan_list, reg_list, arch_list = [], [], [], [], [], []
        for sample in dataset:
            if telemetry_key in sample and sample[telemetry_key] is not None:
                t = np.asarray(sample[telemetry_key], dtype=np.float32)
                tel_list.append(_mean_over_time(t))
            if "targets" in sample:
                tg = sample["targets"]
                if "future_aggregates" in tg and tg["future_aggregates"] is not None:
                    fut_list.append(np.asarray(tg["future_aggregates"], dtype=np.float32))
                if "hidden_genome" in tg and tg["hidden_genome"] is not None:
                    gen_list.append(np.asarray(tg["hidden_genome"], dtype=np.float32))
                if "panic" in tg and tg["panic"] is not None:
                    pan_list.append(float(np.asarray(tg["panic"]).reshape(-1)[0]))
                if "crowd_regime" in tg and tg["crowd_regime"] is not None:
                    reg_list.append(int(np.asarray(tg["crowd_regime"]).reshape(-1)[0]))
            if self.archetype_index is not None and "categorical" in sample \
                    and sample["categorical"] is not None:
                c = np.asarray(sample["categorical"])
                arch_list.append(int(c.reshape(-1)[self.archetype_index]))

        tel = _mean_over_time(np.array(tel_list)) if tel_list else None
        if fut_list:
            self.future_mean = np.mean(np.array(fut_list), axis=0)
        if gen_list:
            self.genome_mean = np.mean(np.array(gen_list), axis=0)
        if pan_list:
            self.panic_prob = float(np.mean(pan_list))
        if reg_list:
            self.regime_counts = np.bincount(np.array(reg_list)).astype(np.float64)

        # archetype-conditioned stats
        if arch_list and (fut_list or gen_list or pan_list or reg_list):
            arch_arr = np.array(arch_list)
            for a in np.unique(arch_arr):
                mask = arch_arr == a
                if fut_list:
                    self.arch_future[int(a)] = np.mean(np.array(fut_list)[mask], axis=0)
                if gen_list:
                    self.arch_genome[int(a)] = np.mean(np.array(gen_list)[mask], axis=0)
                if pan_list:
                    self.arch_panic[int(a)] = float(np.mean(np.array(pan_list)[mask]))
                if reg_list:
                    self.arch_regime[int(a)] = int(np.bincount(np.array(reg_list)[mask]).argmax())

        # optional linear/logistic telemetry baseline
        self.lr_params: Dict[str, Dict] = {}
        if tel is not None and (fut_list or gen_list or pan_list or reg_list):
            if _HAVE_SKLEARN:
                if fut_list:
                    self.future_lr = LinearRegression().fit(tel, np.array(fut_list))
                    self.lr_params["future"] = _capture_lr(self.future_lr, "lin")
                if gen_list:
                    self.genome_lr = LinearRegression().fit(tel, np.array(gen_list))
                    self.lr_params["genome"] = _capture_lr(self.genome_lr, "lin")
                if pan_list:
                    self.panic_lr = LogisticRegression(max_iter=200).fit(tel, np.array(pan_list))
                    self.lr_params["panic"] = _capture_lr(self.panic_lr, "log")
                if reg_list:
                    self.regime_lr = LogisticRegression(max_iter=200).fit(tel, np.array(reg_list))
                    self.lr_params["regime"] = _capture_lr(self.regime_lr, "log")
            else:
                # torch closed-form fallback (least squares for continuous; logistic skipped)
                X = torch.tensor(tel, dtype=torch.float32)
                if fut_list:
                    W = _torch_lstsq(X, torch.tensor(np.array(fut_list), dtype=torch.float32))
                    self.future_lr = W
                    self.lr_params["future"] = {"kind": "lstsq", "W": W.tolist()}
                if gen_list:
                    W = _torch_lstsq(X, torch.tensor(np.array(gen_list), dtype=torch.float32))
                    self.genome_lr = W
                    self.lr_params["genome"] = {"kind": "lstsq", "W": W.tolist()}

        self._fitted = True
        return self

    # -- prediction -------------------------------------------------------
    def predict(self, batch: Dict) -> Dict[str, torch.Tensor]:
        if not self._fitted:
            raise RuntimeError("BaselineModel.predict called before fit()")
        B = self._batch_size(batch)
        device = "cpu"

        emb = torch.zeros(B, self.embedding_dim)
        genome = torch.tensor(
            np.broadcast_to(self.genome_mean if self.genome_mean is not None else np.zeros(2), (B, 2)),
            dtype=torch.float32,
        )
        future = torch.tensor(
            np.broadcast_to(self.future_mean if self.future_mean is not None else np.zeros(1), (B, self.future_mean.shape[0] if self.future_mean is not None else 1)),
            dtype=torch.float32,
        )
        panic_logits = torch.full((B,), _logit(self.panic_prob))
        regime_logits = torch.zeros(B, max(1, int(self.regime_counts.shape[0]) if self.regime_counts is not None else 5))
        if self.regime_counts is not None:
            majority = int(np.argmax(self.regime_counts))
            regime_logits = torch.zeros(B, len(self.regime_counts))
            regime_logits[:, majority] = 1.0

        # per-archetype overrides
        if self.archetype_index is not None and batch.get("categorical") is not None:
            c = np.asarray(batch["categorical"]).reshape(B, -1)
            for i in range(B):
                a = int(c[i, self.archetype_index])
                if a in self.arch_genome:
                    genome[i] = torch.tensor(self.arch_genome[a], dtype=torch.float32)
                if a in self.arch_future:
                    future[i] = torch.tensor(self.arch_future[a], dtype=torch.float32)
                if a in self.arch_panic:
                    panic_logits[i] = _logit(self.arch_panic[a])
                if a in self.arch_regime:
                    regime_logits[i] = 0.0
                    regime_logits[i, self.arch_regime[a]] = 1.0

        # sklearn / torch telemetry overrides
        tel = batch.get("telemetry")
        if tel is not None:
            t = _mean_over_time(np.asarray(tel, dtype=np.float32))
            X = torch.tensor(t, dtype=torch.float32)
            if self.future_lr is not None:
                future = torch.tensor(self._apply_lr(self.future_lr, X), dtype=torch.float32)
            if self.genome_lr is not None:
                genome = torch.tensor(self._apply_lr(self.genome_lr, X), dtype=torch.float32)
            if self.panic_lr is not None:
                panic_logits = torch.tensor(self._apply_clf(self.panic_lr, X, self.panic_prob), dtype=torch.float32)
            if self.regime_lr is not None:
                rl = self._apply_clf(self.regime_lr, X, 0)
                regime_logits = torch.tensor(rl, dtype=torch.float32)

        return {
            "embedding": emb,
            "panic_logits": panic_logits,
            "hidden_genome": genome,
            "future_aggregates": future,
            "crowd_regime_logits": regime_logits,
        }

    # -- persistence -------------------------------------------------------
    def save(self, path) -> None:
        state = {
            "embedding_dim": self.embedding_dim,
            "archetype_index": self.archetype_index,
            "future_mean": None if self.future_mean is None else self.future_mean.tolist(),
            "genome_mean": None if self.genome_mean is None else self.genome_mean.tolist(),
            "panic_prob": self.panic_prob,
            "regime_counts": None if self.regime_counts is None else self.regime_counts.tolist(),
            "arch_future": {str(k): v.tolist() for k, v in self.arch_future.items()},
            "arch_genome": {str(k): v.tolist() for k, v in self.arch_genome.items()},
            "arch_panic": {str(k): v for k, v in self.arch_panic.items()},
            "arch_regime": {str(k): v for k, v in self.arch_regime.items()},
            "lr_params": getattr(self, "lr_params", {}),
            "sklearn_used": _HAVE_SKLEARN,
        }
        with open(path, "w", encoding="utf-8") as f:
            json.dump(state, f, indent=2)

    @classmethod
    def load(cls, path) -> "BaselineModel":
        with open(path, "r", encoding="utf-8") as f:
            state = json.load(f)
        m = cls(embedding_dim=state["embedding_dim"], archetype_index=state["archetype_index"])
        m.future_mean = None if state["future_mean"] is None else np.array(state["future_mean"])
        m.genome_mean = None if state["genome_mean"] is None else np.array(state["genome_mean"])
        m.panic_prob = state["panic_prob"]
        m.regime_counts = None if state["regime_counts"] is None else np.array(state["regime_counts"])
        m.arch_future = {int(k): np.array(v) for k, v in state["arch_future"].items()}
        m.arch_genome = {int(k): np.array(v) for k, v in state["arch_genome"].items()}
        m.arch_panic = {int(k): float(v) for k, v in state["arch_panic"].items()}
        m.arch_regime = {int(k): int(v) for k, v in state["arch_regime"].items()}
        for name, params in state.get("lr_params", {}).items():
            setattr(m, f"{name}_lr", _rebuild_lr(params))
        m._fitted = True
        return m

    # -- internals --------------------------------------------------------
    def _batch_size(self, batch: Dict) -> int:
        for k in ("telemetry", "frames", "categorical"):
            if batch.get(k) is not None:
                return int(np.asarray(batch[k]).shape[0])
        if "targets" in batch and batch["targets"]:
            any_t = next(iter(batch["targets"].values()))
            if any_t is not None:
                return int(np.asarray(any_t).shape[0])
        return 1

    def _apply_lr(self, model, X):
        if _HAVE_SKLEARN:
            return model.predict(X.numpy())
        # torch lstsq solution stored as weight matrix [F, out]
        return X.numpy() @ model

    def _apply_clf(self, model, X, fallback):
        if _HAVE_SKLEARN:
            scores = model.decision_function(X.numpy())
            # return logit-like scores (raw decision function)
            return scores
        return np.full(X.shape[0], _logit(fallback))


def _logit(p: float) -> float:
    p = min(max(p, 1e-6), 1.0 - 1e-6)
    return float(np.log(p / (1.0 - p)))


def _torch_lstsq(X: torch.Tensor, Y: torch.Tensor) -> np.ndarray:
    # closed-form least squares: W = (X^T X + lambda I)^-1 X^T Y, returned as [F, out]
    lam = 1e-6
    XtX = X.t().matmul(X) + lam * torch.eye(X.shape[1])
    XtY = X.t().matmul(Y)
    W = torch.linalg.solve(XtX, XtY)
    return W.numpy()


def _capture_lr(model, kind: str) -> Dict:
    if kind == "lin":
        return {"kind": "lin",
                "coef": np.asarray(model.coef_).tolist(),
                "intercept": np.asarray(model.intercept_).tolist()}
    return {"kind": "log",
            "coef": np.asarray(model.coef_).tolist(),
            "intercept": np.asarray(model.intercept_).tolist(),
            "classes": np.asarray(model.classes_).tolist()}


def _rebuild_lr(params: Dict):
    if params["kind"] == "lstsq":
        return np.array(params["W"])
    if params["kind"] == "lin":
        m = LinearRegression()
        m.coef_ = np.array(params["coef"])
        m.intercept_ = np.array(params["intercept"])
        m.n_features_in_ = m.coef_.shape[-1]
        m.n_outputs_ = 1 if m.coef_.ndim == 1 else m.coef_.shape[0]
        return m
    # logistic
    m = LogisticRegression()
    m.coef_ = np.array(params["coef"])
    m.intercept_ = np.array(params["intercept"])
    m.classes_ = np.array(params["classes"])
    m.n_features_in_ = m.coef_.shape[1]
    m.n_classes_ = len(m.classes_)
    return m
