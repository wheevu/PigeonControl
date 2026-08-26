# Study 1: structured observations

Study 1 tests whether short telemetry histories contain enough information for population-level panic and latent trait inference.

The smoke study used dataset version `pigeon-observer-v1`, three scenario generators, six seeds, 24 pigeons, 60 simulation steps, and a sample cadence of two.
Seeds 21 to 24 were training seeds, 25 was validation, and 26 was held out for testing.
Windows never crossed runs or seed splits.

The compared temporal encoders were small telemetry-only GRU and Transformer models with the same 18-dimensional observable feature vector, eight input ticks, and a six-tick prediction horizon.
Each encoder was trained with three random seeds and a short, fixed CPU budget.

## Result status

This is a smoke-scale apparatus check, not the headline research study.
The held-out seed contained only one panic class, so AUROC and regression R² were undefined.
No rendered frames were available, so this study does not evaluate vision or multimodal fusion.
The training budget was intentionally short and the result is not evidence that either neural model beats a simple baseline.

The machine-readable measurements are in `observer/evidence/study1_telemetry.json`.
They preserve the observed single-class limitation instead of converting it into a positive result.

## Reproduction

Generate raw runs with `experiments/generate_observer_dataset.jl`, convert them with `pigeon_observer.data.convert_raw_run`, and build the seed manifest with `build_dataset_manifest`.
Train the fixed configurations through `pigeon_observer.training.train_model`.
Run:

```bash
PYTHONPATH=observer/src python3 observer/scripts/run_study1.py \
  --dataset /path/to/dataset \
  --runs /path/to/checkpoints \
  --output observer/evidence/study1_telemetry.json
```

## Findings

The current smoke result supports only the engineering claim that the telemetry dataset, checkpoint reload, and evaluation path execute deterministically on held-out windows.
It does not support claims about panic lead time, trait identifiability, retrieval quality, temporal superiority, or a general world model.
The next valid run needs multiple held-out seeds with both panic classes and a longer fixed optimization budget.
