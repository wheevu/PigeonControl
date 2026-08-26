"""Tests for deterministic training: tiny CPU training run, immutable output
refusal, checkpoint reload equality, config TOML round-trip, baselines, and
ablation derivation.
"""
from __future__ import annotations

import os
import tempfile

import torch

from pigeon_observer.models import ObserverModelConfig, build_model
from pigeon_observer.training import (
    train_model, load_checkpoint, RunDir, prepare_run_dir,
    save_config, load_config, BaselineModel, AblationConfig, ablation_to_model_config,
)


class SyntheticDataset(torch.utils.data.Dataset):
    def __init__(self, mode, n, F=4, T=6, H=16, W=16, K=5, seed=0,
                 with_cat=False, n_cat=3):
        self.mode = mode
        self.with_cat = with_cat
        g = torch.Generator().manual_seed(seed)
        self.tele = torch.randn(n, T, F, generator=g)
        self.frames = torch.randn(n, T, 3, H, W, generator=g)
        self.cat = torch.randint(0, n_cat, (n, T, 1), generator=g) if with_cat else None
        self.panic = (torch.rand(n, generator=g) > 0.5).float()
        self.genome = torch.randn(n, 2, generator=g)
        self.future = torch.randn(n, K, generator=g)
        self.regime = torch.randint(0, 5, (n,), generator=g)

    def __len__(self):
        return len(self.panic)

    def __getitem__(self, i):
        s = {}
        if self.mode in ("telemetry", "fusion"):
            s["telemetry"] = self.tele[i]
        if self.mode in ("vision", "fusion"):
            s["frames"] = self.frames[i]
        if self.with_cat:
            s["categorical"] = self.cat[i]
        s["targets"] = {
            "panic": self.panic[i],
            "hidden_genome": self.genome[i],
            "future_aggregates": self.future[i],
            "crowd_regime": self.regime[i],
        }
        return s


def _tiny_config(mode, tmp):
    return {
        "seed": 0,
        "model": {
            "mode": mode,
            "temporal": "transformer",
            "telemetry_dim": 4,
            "sequence_length": 6,
            "future_dim": 5,
            "image_channels": 3,
            "hidden_dim": 32,
            "embedding_dim": 16,
            "num_heads": 4,
            "num_layers": 1,
            "dropout": 0.0,
            "n_regimes": 5,
            "fusion": "concat",
        },
        "lr": 1e-2,
        "max_epochs": 1,
        "max_steps": 4,
        "batch_size": 4,
        "device": "cpu",
        "feature_schema": {"telemetry": 4, "frames": [3, 16, 16]},
        "split_manifest": {"train": 16, "val": 4},
    }


def test_tiny_cpu_training_fusion():
    with tempfile.TemporaryDirectory() as root:
        out = os.path.join(root, "run1")
        cfg = _tiny_config("fusion", out)
        train_ds = SyntheticDataset("fusion", 16, seed=1)
        val_ds = SyntheticDataset("fusion", 4, seed=2)
        result = train_model(train_ds, val_ds, cfg, out)

        # required artifacts
        for name in ("config.json", "metrics.json", "checkpoint.pt", "split_manifest.json"):
            assert os.path.exists(os.path.join(out, name)), f"missing {name}"
        assert os.path.isdir(os.path.join(out, "plots"))
        assert os.path.isdir(os.path.join(out, "failure_examples"))
        assert result["steps"] >= 1
        assert result["config_hash"]
        assert result["split_hash"]
        assert result["schema_hash"]


def test_immutable_output_refusal():
    with tempfile.TemporaryDirectory() as root:
        out = os.path.join(root, "run2")
        cfg = _tiny_config("telemetry", out)
        train_ds = SyntheticDataset("telemetry", 16, seed=1)
        train_model(train_ds, None, cfg, out)
        # existing output must be refused
        raised = False
        try:
            train_model(train_ds, None, cfg, out)
        except FileExistsError:
            raised = True
        assert raised, "train_model did not refuse existing output dir"
        # prepare_run_dir also refuses
        raised2 = False
        try:
            prepare_run_dir(out)
        except FileExistsError:
            raised2 = True
        assert raised2


def test_checkpoint_reload_equal():
    with tempfile.TemporaryDirectory() as root:
        out = os.path.join(root, "run3")
        cfg = _tiny_config("fusion", out)
        train_ds = SyntheticDataset("fusion", 16, seed=1)
        train_model(train_ds, None, cfg, out)

        ckpt_path = os.path.join(out, "checkpoint.pt")
        model, metadata = load_checkpoint(ckpt_path)
        # metadata has required fields, no weights
        for key in ("model_config", "epoch", "normalization", "schema_hash",
                    "split_hash", "config_hash"):
            assert key in metadata, f"metadata missing {key}"

        # reconstruct reference and load same weights -> identical outputs
        ref = build_model(ObserverModelConfig.from_dict(metadata["model_config"]))
        ref.load_state_dict(model.state_dict())
        if metadata.get("normalization"):
            ref.set_normalization(
                metadata["normalization"]["mean"], metadata["normalization"]["std"]
            )

        batch = {
            "telemetry": torch.randn(2, 6, 4),
            "frames": torch.randn(2, 6, 3, 16, 16),
        }
        model.eval(); ref.eval()
        with torch.no_grad():
            o1 = model(batch)
            o2 = ref(batch)
        for k in o1:
            assert torch.allclose(o1[k], o2[k], atol=1e-5), f"reload mismatch {k}"

        # second load is deterministic vs first
        model2, _ = load_checkpoint(ckpt_path, map_location="cpu")
        model2.eval()
        with torch.no_grad():
            o3 = model2(batch)
        for k in o1:
            assert torch.equal(o1[k], o3[k]), f"non-deterministic reload {k}"


def test_config_toml_roundtrip():
    cfg = _tiny_config("fusion", "/tmp/x")
    with tempfile.TemporaryDirectory() as root:
        p = os.path.join(root, "cfg.toml")
        save_config(cfg, p)
        loaded = load_config(p)
        assert loaded["seed"] == cfg["seed"]
        assert loaded["model"]["mode"] == "fusion"
        assert loaded["model"]["hidden_dim"] == 32
        assert loaded["feature_schema"]["telemetry"] == 4
        # json path too
        pj = os.path.join(root, "cfg.json")
        save_config(cfg, pj)
        loaded_j = load_config(pj)
        assert loaded_j["model"]["fusion"] == "concat"


def test_baseline_fit_predict_persist():
    ds = SyntheticDataset("fusion", 32, seed=3)
    base = BaselineModel(embedding_dim=16).fit(ds)
    batch = {
        "telemetry": torch.randn(3, 6, 4),
        "frames": torch.randn(3, 6, 3, 16, 16),
    }
    out = base.predict(batch)
    for k in ("embedding", "panic_logits", "hidden_genome", "future_aggregates", "crowd_regime_logits"):
        assert k in out
    assert tuple(out["embedding"].shape) == (3, 16)
    assert tuple(out["hidden_genome"].shape) == (3, 2)

    with tempfile.TemporaryDirectory() as root:
        p = os.path.join(root, "base.json")
        base.save(p)
        loaded = BaselineModel.load(p)
        out2 = loaded.predict(batch)
        for k in out:
            assert torch.allclose(out[k], out2[k]), f"baseline reload mismatch {k}"


def test_ablation_derivation():
    base = ObserverModelConfig(mode="fusion", telemetry_dim=4, sequence_length=16,
                               future_dim=5, hidden_dim=32, embedding_dim=16,
                               num_heads=4, num_layers=2, dropout=0.1)
    # no temporal -> T=1, gru
    ab = AblationConfig(name="no_temporal", no_temporal=True)
    c = ablation_to_model_config(base, ab)
    assert c.sequence_length == 1
    assert c.temporal == "gru"
    # disable telemetry -> vision only
    ab2 = AblationConfig(name="novis", no_vision_to_telemetry=True)
    c2 = ablation_to_model_config(base, ab2)
    assert c2.mode == "telemetry"
    # both disabled -> error
    ab3 = AblationConfig(no_telemetry_to_vision=True, no_vision_to_telemetry=True)
    raised = False
    try:
        ablation_to_model_config(base, ab3)
    except ValueError:
        raised = True
    assert raised


def _run():
    test_tiny_cpu_training_fusion()
    test_immutable_output_refusal()
    test_checkpoint_reload_equal()
    test_config_toml_roundtrip()
    test_baseline_fit_predict_persist()
    test_ablation_derivation()
    print("test_training: ALL PASSED")


if __name__ == "__main__":
    _run()
