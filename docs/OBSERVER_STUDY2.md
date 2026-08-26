# Study 2: class-balanced structured observer evaluation

This study fixes the first pilot's single-class test issue without changing the observer architecture.

The dataset contains 16 runs from four scenario generators: baseline flocking, repeated human interventions, high-fear populations, and sparse bread.
Each run has 16 pigeons, 40 simulation steps, and a two-tick sample cadence.
Seeds 41 and 42 are training seeds, 43 is validation, and 44 is held out for testing.
The held-out split contains 28 windows, with 21 negative and 7 positive panic targets.
The training and validation splits also contain both classes.

The fixed input history is eight sampled ticks and the future horizon is six sampled ticks.
The compared models are telemetry-only GRU and Transformer encoders, each trained with three random seeds.
The GRU has 97,757 parameters and the Transformer has 354,461 parameters, so the encoder comparison is not parameter matched.

## Results

The results are stored in `observer/evidence/study2_structured.json`.
The file records per-seed model outputs, class counts, AUROC, PR-AUC, F1, calibration, fear and greed regression metrics, and parameter counts.

The results are still a pilot rather than a final research claim.
There is one held-out simulation seed, the CPU budget is short, and the current evidence does not include bootstrap confidence intervals, lead-time analysis, retrieval baselines, or scenario-family transfer.
No vision or fusion result is reported because synchronized rendered frames were unavailable.

The negative result is useful: balancing windows inside a seed makes classification metrics computable, but it does not provide enough independent held-out seeds for a strong generalization claim.
The next run should expand the seed count while preserving the same seed-level split rule and check class composition before training.

## Reproduction

Generate and convert the runs, write the explicit seed split, train the six checkpoints, then run:

```bash
PYTHONPATH=observer/src python3 observer/scripts/run_study1.py \
  --dataset /path/to/dataset \
  --runs /path/to/checkpoints \
  --output observer/evidence/study2_structured.json
```

This script is intentionally small and reports only tasks supported by the current telemetry dataset.
It does not label rendered frames, expose genome values as features, or claim individual-pigeon understanding.
