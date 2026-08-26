"""Schema contract tests: variable classes, raw schemas, and leakage guards."""

from __future__ import annotations

import pyarrow as pa

import pigeon_observer.schema as S


def test_versions_exposed():
    assert S.RAW_SCHEMA_VERSION == "pigeon-observer-raw-v1"
    assert S.DATASET_VERSION == "pigeon-observer-v1"


def test_variable_classes():
    assert {v.value for v in S.VariableClass} == {
        "externally_visible",
        "partially_observable",
        "privileged_ground_truth",
    }


def test_no_feature_leakage():
    violations = S.assert_features_are_clean()
    assert violations == [], violations
    assert S.is_clean_feature_set()


def test_targets_not_in_features():
    for t in S.TARGET_NAMES:
        assert t not in S.TELEMETRY_FEATURE_NAMES
    assert "seed" not in S.TELEMETRY_FEATURE_NAMES
    assert "scenario" not in S.TELEMETRY_FEATURE_NAMES
    assert "config_name" not in S.TELEMETRY_FEATURE_NAMES


def test_raw_schemas_have_explicit_types():
    # pigeons: 2 keys + 9 EV (pos3, vel3, speed, state, archetype)
    # + 2 PO (hunger, fear) + 5 privileged (energy, fight_timer,
    # fight_cooldown, target_food, age) + 11 genome = 29
    expected = {
        "ticks": 12,
        "pigeons": 29,
        "foods": 6,
        "interventions": 4,
        "frame_index": 4,
    }
    for name, n in expected.items():
        assert len(S.field_specs(name)) == n, (name, len(S.field_specs(name)))
    for table in S.RAW_SCHEMAS:
        schema = S.raw_schema(table)
        assert schema.metadata.get(b"schema_version") == S.RAW_SCHEMA_VERSION.encode()


def test_pigeons_schema_field_types_and_classes():
    schema = S.raw_schema("pigeons")
    names = schema.names
    # position externally visible
    assert "pos_x" in names and schema.field("pos_x").type == pa.float64()
    # genome privileged
    gf = schema.field("genome_fear")
    assert gf.type == pa.float64()
    assert gf.metadata.get(b"var_class") == b"privileged_ground_truth"
    # feature flags set
    assert schema.field("pos_x").metadata.get(b"is_feature") == b"1"
    assert schema.field("genome_fear").metadata.get(b"is_feature") is None or \
        schema.field("genome_fear").metadata.get(b"is_feature") == b"0"


def test_label_constants_documented():
    assert S.PANIC_FLEE_FRACTION_THRESHOLD == 0.10
    assert S.REGIME_COMBAT_FIGHT_FRACTION == 0.05
    assert S.REGIME_PANIC_FLEE_FRACTION == 0.10
    assert S.REGIME_FEEDING_EAT_FRACTION == 0.10
    assert S.REGIME_FRAGMENTED_PROXY == 0.50


def test_regime_precedence_order():
    # Integer encoding orders by severity: calm < feeding < panic < fragmented < combat.
    assert S.REGIME_CALM == 0
    assert S.REGIME_FEEDING == 1
    assert S.REGIME_PANIC == 2
    assert S.REGIME_FRAGMENTED == 3
    assert S.REGIME_COMBAT == 4
    assert S.REGIME_COMBAT > S.REGIME_FRAGMENTED > S.REGIME_PANIC > S.REGIME_FEEDING > S.REGIME_CALM
    assert S.FUTURE_AGGREGATE_DIM == 5
    assert S.RELEVANCE_FACTOR_DIM == 3
    assert S.HIDDEN_GENOME_DIM == 2
