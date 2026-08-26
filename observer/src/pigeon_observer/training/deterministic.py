"""Deterministic training primitives.

* ``seed_everything`` - seeds python/numpy/torch and enables deterministic algos.
* ``make_deterministic_dataloader`` - DataLoader backed by a seeded generator
  with a worker init fn so each worker is reproducible.
"""
from __future__ import annotations

import random
from typing import Optional

import numpy as np
import torch
from torch.utils.data import DataLoader


def seed_everything(seed: int = 0, deterministic: bool = True) -> None:
    random.seed(seed)
    np.random.seed(seed)
    torch.manual_seed(seed)
    if torch.cuda.is_available():
        torch.cuda.manual_seed_all(seed)
    if deterministic:
        try:
            torch.use_deterministic_algorithms(True)
        except RuntimeError:
            # Some builds / ops may reject this; degrade gracefully but keep
            # the rest of the deterministic setup intact.
            pass
        torch.backends.cudnn.deterministic = True
        torch.backends.cudnn.benchmark = False


def worker_init_fn(worker_id: int) -> None:
    base = torch.initial_seed() % (2 ** 32)
    random.seed(base)
    np.random.seed(base)


def make_deterministic_dataloader(dataset, batch_size: int = 32,
                                  shuffle: bool = True, num_workers: int = 0,
                                  seed: int = 0, collate_fn=None):
    generator = torch.Generator()
    generator.manual_seed(seed)
    return DataLoader(
        dataset,
        batch_size=batch_size,
        shuffle=shuffle,
        num_workers=num_workers,
        generator=generator,
        worker_init_fn=worker_init_fn,
        collate_fn=collate_fn,
        drop_last=False,
    )
