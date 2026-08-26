"""Explicit field schema and variable-class contract for the PigeonControl observer.

This module is the single source of truth for:

* The raw ingest contract (``pigeon-observer-raw-v1``). Raw Julia/CSV exports are
  parsed with *explicit* Arrow types. There is **no type inference** on raw CSV.
* The variable-class taxonomy that decides which fields may become model
  features versus which are privileged ground truth or derived targets.
* The algorithmic label constants used by :mod:`pigeon_observer.data`.

Ownership: ``observer/src/pigeon_observer/schema.py``. Do not depend on runtime
state here; this module is import-safe and side-effect free.
"""

from __future__ import annotations

import enum
from dataclasses import dataclass
from typing import Dict, List

import pyarrow as pa

# --------------------------------------------------------------------------- #
# Versioning
# --------------------------------------------------------------------------- #

#: Raw ingest contract version. Stamped into every converted run manifest and
#: into Arrow schema metadata of every raw-derived parquet table.
RAW_SCHEMA_VERSION = "pigeon-observer-raw-v1"

#: Final structured dataset version. Stamped into dataset ``manifest.json`` and
#: Arrow schema metadata of converted tables.
DATASET_VERSION = "pigeon-observer-v1"

# --------------------------------------------------------------------------- #
# Variable classes
# --------------------------------------------------------------------------- #


class VariableClass(str, enum.Enum):
    """Observability class of a field.

    These classes are the contract that prevents privileged information from
    leaking into model features.

    * ``EXTERNALLY_VISIBLE`` - observable to any outside observer: position,
      velocity (when derived from recent position or explicitly selected
      telemetry), state, archetype, visible food positions, rendered RGB,
      combat state.
    * ``PARTIALLY_OBSERVABLE`` - observable only in aggregate / with noise:
      hunger, transient fear, local density, aggregate geometry.
    * ``PRIVILEGED_GROUND_TRUTH`` - never observable to a real observer and
      never a feature: genome fields, seed, scenario/config, food amount,
      energy/timers/target_food, authoritative threat position, future labels.
    """

    EXTERNALLY_VISIBLE = "externally_visible"
    PARTIALLY_OBSERVABLE = "partially_observable"
    PRIVILEGED_GROUND_TRUTH = "privileged_ground_truth"


# Field names that must never appear as model features.
FORBIDDEN_FEATURE_FIELDS = frozenset(
    {
        "seed",
        "run_id",
        "scenario",
        "config_name",
        "target_food",
        "energy",
        "fight_timer",
        "fight_cooldown",
        "age",
    }
)

# Genome field names (always privileged ground truth).
GENOME_FIELDS = (
    "cohesion",
    "separation",
    "alignment",
    "greed",
    "fear",
    "aggression",
    "curiosity",
    "speed",
    "vision",
    "size",
    "metabolism",
)


# --------------------------------------------------------------------------- #
# Field specification
# --------------------------------------------------------------------------- #


@dataclass(frozen=True)
class FieldSpec:
    """One column in a raw CSV table.

    ``var_class`` decides observability. ``is_feature`` marks columns that may
    be aggregated into the telemetry feature vector. ``is_target`` marks columns
    that only ever appear on the target/labels side.
    """

    name: str
    pa_type: "pa.DataType"
    var_class: "VariableClass"
    description: str = ""
    nullable: bool = False
    is_feature: bool = False
    is_target: bool = False

    def arrow_field(self) -> "pa.Field":
        meta = {
            "var_class": self.var_class.value.encode(),
            "is_feature": b"1" if self.is_feature else b"0",
            "is_target": b"1" if self.is_target else b"0",
        }
        if self.description:
            meta["description"] = self.description.encode()
        return pa.field(self.name, self.pa_type, nullable=self.nullable, metadata=meta)


def _f(
    name: str,
    pa_type: "pa.DataType",
    var_class: "VariableClass",
    description: str = "",
    *,
    nullable: bool = False,
    feature: bool = False,
    target: bool = False,
) -> FieldSpec:
    return FieldSpec(
        name=name,
        pa_type=pa_type,
        var_class=var_class,
        description=description,
        nullable=nullable,
        is_feature=feature,
        is_target=target,
    )


_EV = VariableClass.EXTERNALLY_VISIBLE
_PO = VariableClass.PARTIALLY_OBSERVABLE
_PG = VariableClass.PRIVILEGED_GROUND_TRUTH

# --------------------------------------------------------------------------- #
# Raw CSV schemas (fixed, explicit). No type inference is performed at read time.
# --------------------------------------------------------------------------- #

RAW_TICKS_FIELDS: List[FieldSpec] = [
    _f("tick", pa.int64(), _PG, "Tick index within the run (primary key)."),
    _f("n_pigeons", pa.int64(), _PG, "Number of pigeons alive this tick."),
    _f("mean_local_density", pa.float64(), _PO, "Mean local neighbourhood density."),
    _f("dispersion", pa.float64(), _PO, "Spatial dispersion of the flock."),
    _f("fragmentation_proxy", pa.float64(), _PO, "Fragmentation proxy in [0,1]."),
    _f("frac_fleeing", pa.float64(), _PG, "Fraction fleeing this tick (ground truth)."),
    _f("frac_eating", pa.float64(), _PG, "Fraction eating this tick (ground truth)."),
    _f("frac_fighting", pa.float64(), _PG, "Fraction fighting this tick (ground truth)."),
    _f("threat_active", pa.bool_(), _PG, "Authoritative threat active."),
    _f("threat_x", pa.float64(), _PG, "Authoritative threat x (NaN if absent).", nullable=True),
    _f("threat_y", pa.float64(), _PG, "Authoritative threat y (NaN if absent).", nullable=True),
    _f("threat_z", pa.float64(), _PG, "Authoritative threat z (NaN if absent).", nullable=True),
]

RAW_PIGEONS_FIELDS: List[FieldSpec] = [
    _f("tick", pa.int64(), _PG, "Tick index (composite key)."),
    _f("pigeon_id", pa.int64(), _PG, "Pigeon id (composite key)."),
    _f("pos_x", pa.float64(), _EV, "Position x (externally visible).", feature=True),
    _f("pos_y", pa.float64(), _EV, "Position y (externally visible).", feature=True),
    _f("pos_z", pa.float64(), _EV, "Position z (externally visible).", feature=True),
    _f("vel_x", pa.float64(), _EV, "Velocity x (selected telemetry).", feature=True),
    _f("vel_y", pa.float64(), _EV, "Velocity y (selected telemetry).", feature=True),
    _f("vel_z", pa.float64(), _EV, "Velocity z (selected telemetry).", feature=True),
    _f("speed", pa.float64(), _EV, "Speed magnitude (externally visible).", feature=True),
    _f("state", pa.int64(), _EV, "Behavior state enum (externally visible).", feature=True),
    _f("archetype", pa.int64(), _EV, "Archetype enum (externally visible).", feature=True),
    _f("hunger", pa.float64(), _PO, "Hunger level 0..n (partially observable).", feature=True),
    _f("transient_fear", pa.float64(), _PO, "Transient fear level (partially observable).", feature=True),
    _f("energy", pa.float64(), _PG, "Energy (privileged timer)."),
    _f("fight_timer", pa.float64(), _PG, "Fight timer (privileged)."),
    _f("fight_cooldown", pa.float64(), _PG, "Fight cooldown (privileged)."),
    _f("target_food", pa.int64(), _PG, "Target food id (privileged)."),
    _f("age", pa.float64(), _PG, "Age (privileged timer)."),
] + [
    _f(f"genome_{g}", pa.float64(), _PG, f"Genome {g} (privileged ground truth).")
    for g in GENOME_FIELDS
]

RAW_FOODS_FIELDS: List[FieldSpec] = [
    _f("tick", pa.int64(), _PG, "Tick index (composite key)."),
    _f("food_id", pa.int64(), _PG, "Food id (composite key)."),
    _f("pos_x", pa.float64(), _EV, "Food position x (visible food position).", feature=True),
    _f("pos_y", pa.float64(), _EV, "Food position y (visible food position).", feature=True),
    _f("pos_z", pa.float64(), _EV, "Food position z (visible food position).", feature=True),
    _f("amount", pa.float64(), _PG, "Remaining food amount (privileged)."),
]

RAW_INTERVENTIONS_FIELDS: List[FieldSpec] = [
    _f("tick", pa.int64(), _PG, "Tick the intervention is scheduled at (primary key)."),
    _f("order_index", pa.int64(), _PG, "Stable application order."),
    _f("command", pa.string(), _PG, "Applied command."),
    _f("result", pa.string(), _PG, "Application result."),
]

RAW_FRAME_INDEX_FIELDS: List[FieldSpec] = [
    _f("tick", pa.int64(), _PG, "Tick the frame corresponds to (primary key)."),
    _f("frame_file", pa.string(), _PG, "Relative path of the frame under frames/."),
    _f("width", pa.int64(), _PG, "Frame width in pixels."),
    _f("height", pa.int64(), _PG, "Frame height in pixels."),
]


def _build_schema(fields: List[FieldSpec]) -> "pa.Schema":
    """Build an Arrow schema with per-field variable-class metadata."""
    arrow_fields = [fs.arrow_field() for fs in fields]
    meta = {
        "schema_version": RAW_SCHEMA_VERSION.encode(),
    }
    return pa.schema(arrow_fields, metadata=meta)


RAW_SCHEMAS: Dict[str, "pa.Schema"] = {
    "ticks": _build_schema(RAW_TICKS_FIELDS),
    "pigeons": _build_schema(RAW_PIGEONS_FIELDS),
    "foods": _build_schema(RAW_FOODS_FIELDS),
    "interventions": _build_schema(RAW_INTERVENTIONS_FIELDS),
    "frame_index": _build_schema(RAW_FRAME_INDEX_FIELDS),
}

#: Map of raw CSV filename -> canonical schema name.
RAW_CSV_FILES = {
    "ticks.csv": "ticks",
    "pigeons.csv": "pigeons",
    "foods.csv": "foods",
    "interventions.csv": "interventions",
    "frame_index.csv": "frame_index",
}

#: Required top-level files inside a raw run directory.
RAW_REQUIRED_FILES = (
    "raw_run.toml",
    "ticks.csv",
    "pigeons.csv",
    "foods.csv",
    "interventions.csv",
    "frame_index.csv",
)

#: Required keys in raw_run.toml (a completed run).
RAW_RUN_TOML_REQUIRED = (
    "run_id",
    "seed",
    "scenario",
    "config_name",
    "n_pigeons",
    "tick_start",
    "tick_end",
    "sample_cadence",
    "frame_cadence",
    "frame_format",
    "status",
)


def field_specs(table: str) -> List[FieldSpec]:
    """Return the ordered :class:`FieldSpec` list for a raw table name."""
    return {
        "ticks": RAW_TICKS_FIELDS,
        "pigeons": RAW_PIGEONS_FIELDS,
        "foods": RAW_FOODS_FIELDS,
        "interventions": RAW_INTERVENTIONS_FIELDS,
        "frame_index": RAW_FRAME_INDEX_FIELDS,
    }[table]


def raw_schema(table: str) -> "pa.Schema":
    """Return the explicit Arrow schema for a raw table name."""
    return RAW_SCHEMAS[table]


# --------------------------------------------------------------------------- #
# Telemetry feature contract
# --------------------------------------------------------------------------- #
#
# The model telemetry feature vector is a *fixed-width* aggregate computed per
# tick. Every feature is derived ONLY from externally-visible or partially-
# observable fields. The list below is the auditable contract used by the
# dataset builder and by the leakage tests.

@dataclass(frozen=True)
class FeatureSpec:
    name: str
    source: str
    description: str = ""


TELEMETRY_FEATURES: List[FeatureSpec] = [
    FeatureSpec("mean_pos_x", "pigeons.pos_x", "Mean position x."),
    FeatureSpec("mean_pos_y", "pigeons.pos_y", "Mean position y."),
    FeatureSpec("mean_pos_z", "pigeons.pos_z", "Mean position z."),
    FeatureSpec("mean_speed", "pigeons.speed", "Mean speed."),
    FeatureSpec("mean_hunger", "pigeons.hunger", "Mean hunger (partially observable)."),
    FeatureSpec("mean_fear", "pigeons.fear", "Mean transient fear (partially observable)."),
    FeatureSpec("local_density", "ticks.local_density", "Local density (partially observable)."),
    FeatureSpec("dispersion", "ticks.dispersion", "Dispersion (partially observable)."),
    FeatureSpec("fragmentation_proxy", "ticks.fragmentation_proxy", "Fragmentation proxy."),
    FeatureSpec("frac_flying", "pigeons.state==0", "Fraction flying."),
    FeatureSpec("frac_walking", "pigeons.state==1", "Fraction walking."),
    FeatureSpec("frac_eating", "pigeons.state==2", "Fraction eating."),
    FeatureSpec("frac_fleeing", "pigeons.state==3", "Fraction fleeing."),
    FeatureSpec("frac_landing", "pigeons.state==4", "Fraction landing."),
    FeatureSpec("frac_takeoff", "pigeons.state==5", "Fraction takeoff."),
    FeatureSpec("frac_fighting", "pigeons.state==6", "Fraction fighting."),
    FeatureSpec("frac_perching", "pigeons.state==7", "Fraction perching."),
    FeatureSpec("visible_food_count", "foods.amount>0", "Count of foods with amount>0."),
]

TELEMETRY_FEATURE_NAMES: List[str] = [f.name for f in TELEMETRY_FEATURES]
TELEMETRY_FEATURE_DIM: int = len(TELEMETRY_FEATURES)

#: State enum values (mirror src/protocol/snapshot.jl).
STATE_FLYING = 0
STATE_WALKING = 1
STATE_EATING = 2
STATE_FLEEING = 3
STATE_LANDING = 4
STATE_TAKEOFF = 5
STATE_FIGHTING = 6
STATE_PERCHING = 7

# --------------------------------------------------------------------------- #
# Target / label contract
# --------------------------------------------------------------------------- #

#: Names of the keys returned under ``targets``. None of these may ever be part
#: of the feature vector.
TARGET_NAMES = (
    "panic",
    "hidden_genome",
    "future_aggregates",
    "crowd_regime",
)

# Algorithmic label constants (documented in README-worthy clarity here).
PANIC_FLEE_FRACTION_THRESHOLD = 0.10  # panic if future flee fraction >= this
REGIME_COMBAT_FIGHT_FRACTION = 0.05   # precedence: combat if fight >= this
REGIME_PANIC_FLEE_FRACTION = 0.10     # panic regime if flee >= this
REGIME_FEEDING_EAT_FRACTION = 0.10    # feeding regime if eat >= this
REGIME_FRAGMENTED_PROXY = 0.50        # fragmented if fragmentation >= this

#: Integer encoding for ``crowd_regime`` (ordered by severity: higher = more disrupted).
REGIME_CALM = 0
REGIME_FEEDING = 1
REGIME_PANIC = 2
REGIME_FRAGMENTED = 3
REGIME_COMBAT = 4

#: Order of the ``future_aggregates`` vector.
FUTURE_AGGREGATE_NAMES = ("flee_fraction", "eat_fraction", "fight_fraction", "dispersion", "local_density")
FUTURE_AGGREGATE_DIM = len(FUTURE_AGGREGATE_NAMES)

#: Order of the retrieval relevance behavior-factor vector (resulting behavior).
RELEVANCE_FACTOR_NAMES = ("flee_fraction", "eat_fraction", "fight_fraction")
RELEVANCE_FACTOR_DIM = len(RELEVANCE_FACTOR_NAMES)

# Hidden genome target is [mean genome fear, mean genome greed].
HIDDEN_GENOME_DIM = 2

# --------------------------------------------------------------------------- #
# Split contract
# --------------------------------------------------------------------------- #

SPLIT_TRAIN = "train"
SPLIT_VALIDATION = "validation"
SPLIT_TEST = "test"
SPLIT_NAMES = (SPLIT_TRAIN, SPLIT_VALIDATION, SPLIT_TEST)

#: Stable 80/10/10 bucketing. Hash mod 10 -> bucket.
SPLIT_BUCKET_TRAIN_MAX = 7   # 0..7 -> train (8/10)
SPLIT_BUCKET_VALIDATION = 8  # 8 -> validation (1/10)
SPLIT_BUCKET_TEST = 9        # 9 -> test (1/10)

DEFAULT_SPLIT_SALT = "pigeon-observer-v1"


# --------------------------------------------------------------------------- #
# Leakage guard
# --------------------------------------------------------------------------- #


def assert_features_are_clean() -> List[str]:
    """Return a list of violations if any feature is not clean.

    A feature is *clean* when it is derived only from externally-visible or
    partially-observable fields, and never from a forbidden or target field.
    """
    violations: List[str] = []
    for f in TELEMETRY_FEATURES:
        if f.name in FORBIDDEN_FEATURE_FIELDS:
            violations.append(f"feature '{f.name}' is a forbidden field")
    for t in TARGET_NAMES:
        if t in TELEMETRY_FEATURE_NAMES:
            violations.append(f"target '{t}' present in telemetry features")
    return violations


def is_clean_feature_set() -> bool:
    """True when :func:`assert_features_are_clean` reports no violations."""
    return not assert_features_are_clean()
