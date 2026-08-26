# Observer Experiment

This document defines the observer research plan before any model is trained.
It is the contract for the offline evaluation lane in `observer/`.
Everything here is scoped to population-level behavior factors, not individual pigeon identity.

## Research question

Can an offline observer predict panic onset and recover behavior-level sequence similarity from snapshot and telemetry sequences?
We restrict the question to population mean genome fear and greed and to behavior-factor retrieval, deliberately avoiding any individual-pigeon claim.

## V0 narrow milestone

V0 covers exactly three deliverables and nothing more.
The first deliverable is panic onset classification and per-tick panic probability regression.
The second deliverable is regression of the population mean genome fear and greed trajectories.
The third deliverable is behavior retrieval: given one sequence, find other sequences that are behavior-similar by their factors, not by shared seed or scenario.

## Variable classes

Features are divided into telemetry features and frame features.
Telemetry features are fixed-dimensional per-tick vectors derived from snapshots (positions, velocities, densities, nearest-neighbor statistics).
Frame features are optional rendered images captured by Godot for the same ticks.
Labels are panic ground truth per tick, population mean fear ground truth, population mean greed ground truth, and the panic onset tick.
Behavior factors are the reporting summary of a sequence: panic mean, fear mean, greed mean, and a combat flag.
Metadata is seed, scenario, run id, and sequence id, and it is carried only as reporting metadata, never as a model feature.

## Schema and layout

A built dataset directory contains `raw/`, `frames/` (when captured), `sequences/` parquet files, and `manifest.json`.
Each sequence parquet has columns `tick` (int), `feature` (variable-shaped telemetry), and `frame_path` (string or empty).
The manifest records version, the synthetic flag, the seed list, the scenario list, the behavior factor names, and one entry per sequence with its id, seed, scenario, tick count, parquet path, and behavior factors.
The checked-in smoke fixture under `observer/tests/fixtures/v1/` follows this exact layout and is explicitly synthetic.

## Algorithmic labels

Panic ground truth is the population fraction of birds in the fleeing or fighting state at each tick.
Panic onset tick is the first tick where the population panic fraction crosses a fixed threshold (default 0.2).
Population mean fear is the mean of genome fear weights over all birds in the plaza at each tick.
Population mean greed is the mean of genome greed weights over all birds at each tick.
The combat flag is true for a sequence when any bird entered the fighting state during the run.

## Seed split and no leakage

Seeds are partitioned once into train, validation, and test sets.
No seed appears in more than one split, so generalization is measured across independent simulations.
Sequence ids are derived from seed and run, and the split assignment is stored in the manifest so it is reproducible and auditable.
Train, validation, and test readers consult the manifest split field and never mix seeds.

## Scenario matrix (all 12)

The generator accepts exactly these twelve scenario names.
1. `baseline_idle`: no intervention, pigeons mill about.
2. `bread_drop_single`: one bread drop, localized competition.
3. `bread_drop_cluster`: several bread drops, contested foraging.
4. `human_walkthrough`: a human crosses the plaza, local fleeing.
5. `human_corner_threat`: a human loiters in a corner, sustained avoidance.
6. `flock_split`: two food sources pull the flock apart.
7. `combat_brawl`: forced fighting via dense bread and humans.
8. `extreme_density`: population pushed to the upper limit.
9. `combat_heavy`: combat-archetype heavy mix with weapons.
10. `bread_human_competition`: bread and a human contend for attention.
11. `sparse_foraging`: low density, calm feeding.
12. `low_vision_night`: reduced vision radius, noisier fear response.

## Model, baseline, ablation, and OOD plans

The primary model is a late-fusion network over telemetry and frame features producing panic probability, fear regression, greed regression, and an embedding.
Vision-only and telemetry-only variants are trained to isolate each modality's contribution.
Baselines are persistence (predict the previous tick or the population mean), linear regression, and logistic regression on telemetry only.
Ablations remove the vision branch, shrink the history window, and drop intervention metadata to measure each component.
The OOD plan trains on the normal bread and human scenarios and evaluates on the extreme density and combat-heavy metadata.
Unseen population, archetype, and intervention-timing slices are recorded as separate reportable rows so degradation is visible rather than hidden.

## Metrics and success, defined before training

We report classification accuracy, macro F1, and AUROC (null when a split has a single class).
We report regression MAE, RMSE, and R2 for fear and greed.
We report calibration via ECE and Brier score.
We report panic onset lead time as the error between true and predicted onset ticks.
We report retrieval Recall at K and MRR where relevance is defined by behavior-factor proximity, not by seed or scenario.
We report model parameter count and measured inference latency.
Success for a head requires beating the persistence baseline on held-out seeds with a bootstrap confidence interval that excludes zero improvement.
If that interval includes zero, the result is a negative finding, not a success.

## Immutable runs

Every `evaluate` invocation writes to a new timestamped directory under the requested base path.
Previously written evaluation files are never overwritten or mutated.
Raw fixtures and the smoke evidence file are committed and treated as immutable artifacts.

## Negative finding policy

A missing baseline or missing comparison is reported as missing, never inferred or silently dropped.
Single-class AUROC yields a null value and a warning, never a crash.
If a proposed head does not beat persistence on held-out data, we record the negative finding explicitly.
We do not claim world-model status unless a future aggregate head beats persistence with the required evidence.

## Explicit deferrals

We defer any claim of individual pigeon understanding; the V0 factors are population level only.
We defer any claim of a general world model; the observer scores behavior, it does not simulate.
We defer any trained research result until data beyond the synthetic smoke fixture exists.

## Current evidence status

No research training result has been established by the fixture smoke evidence.
The file `observer/evidence/smoke_metrics.json` is synthetic and smoke-only, with `research_result` set to false.
We make no claim of individual-pigeon understanding and no claim of a general world model.
