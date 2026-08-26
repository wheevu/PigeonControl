"""Observer training package: deterministic setup, config I/O, run dirs, loss,
checkpointing, baselines, ablation, and the training loop.
"""
from __future__ import annotations

from .deterministic import seed_everything, make_deterministic_dataloader
from .config import load_config, save_config
from .run_dir import RunDir, prepare_run_dir
from .loss import compute_loss, DEFAULT_WEIGHTS
from .checkpoint import save_checkpoint, load_checkpoint, make_hash
from .train import train_model
from .ablation import AblationConfig, ablation_to_model_config
from .baselines import BaselineModel

__all__ = [
    "seed_everything",
    "make_deterministic_dataloader",
    "load_config",
    "save_config",
    "RunDir",
    "prepare_run_dir",
    "compute_loss",
    "DEFAULT_WEIGHTS",
    "save_checkpoint",
    "load_checkpoint",
    "make_hash",
    "train_model",
    "AblationConfig",
    "ablation_to_model_config",
    "BaselineModel",
]
