# Study 3: thresholded structured observer evaluation

Study 3 expands the structured telemetry pilot and separates probability ranking from the operating decision threshold.

The dataset contains 32 runs from four scenario generators: `baseline_flocking`, `repeated_human_interventions`, `high_fear_populations`, and `sparse_bread`.
Each run has 16 pigeons, 40 simulation steps, and a two-tick sample cadence.
Seeds 51 to 54 are training seeds, 55 and 56 are validation seeds, and 57 and 58 are held-out test seeds.
All three splits contain positive and negative panic windows.

The fixed input history is eight sampled ticks and the prediction horizon is six sampled ticks.
Telemetry-only GRU and Transformer models were trained with three model seeds and a fixed 30-step CPU budget.
The GRU has 97,757 parameters and the Transformer has 354,461 parameters.

## Threshold policy

Each checkpoint gets its panic threshold by maximizing validation F1 over thresholds from 0.05 through 0.95.
That threshold is then frozen before test evaluation.
AUROC and PR-AUC remain threshold-independent.
No test labels are used to choose a threshold.

## Result status

Measurements are in `observer/evidence/study3_structured.json`.
The report records held-out windows from two independent seeds, class counts, validation-selected thresholds, AUROC, PR-AUC, F1, calibration, and latent fear/greed regression.

This remains a structured pilot.
The two held-out seeds are an improvement over Study 2 but are not enough for a stable estimate across the full scenario matrix.
The GRU and Transformer are not parameter matched, so this study does not establish architectural superiority.
No vision, fusion, retrieval, lead-time, or causal intervention result is claimed.

The study supports a narrower conclusion: panic ranking and classification should be reported separately, and a fixed 0.5 threshold can understate a useful ranking signal.
The latent-trait heads remain unproven until target spread and independent-seed performance are adequate.

## Reproduction

Generate the 32 raw runs, convert them to Parquet, write the explicit seed manifest, train the six checkpoints, and run:

```bash
PYTHONPATH=observer/src python3 observer/scripts/run_study1.py \
  --dataset /path/to/dataset \
  --runs /path/to/checkpoints \
  --output observer/evidence/study3_structured.json
```

The script name remains for compatibility with the pilot command.
Its output now applies validation-only threshold selection.
