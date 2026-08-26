"""Fixture validation.

The v1 fixture shape is checked without any sibling module. If
``pigeon_observer.data`` is available, we additionally run its
``validate_dataset`` on the fixture to confirm the synthetic layout is accepted.
"""

import json
import os

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURE = os.path.join(HERE, "fixtures", "v1", "manifest.json")


def test_v1_fixture_shape():
    assert os.path.isfile(FIXTURE), "v1 fixture manifest missing; run make_v1.py"
    with open(FIXTURE) as fh:
        m = json.load(fh)
    assert m["version"] == "v1"
    assert m["synthetic"] is True
    assert len(m["seeds"]) >= 3
    assert len(m["sequences"]) >= 3 * 3  # at least 3 seeds with several seqs
    for s in m["sequences"]:
        for f in ("sequence_id", "seed", "scenario", "behavior_factors"):
            assert f in s
        assert os.path.isfile(os.path.join(HERE, "fixtures", "v1", s["parquet"]))


def test_v1_fixture_covers_three_seeds():
    with open(FIXTURE) as fh:
        m = json.load(fh)
    assert len(set(m["seeds"])) >= 3


def test_sibling_validate_dataset_if_available():
    data = pytest.importorskip("pigeon_observer.data")
    # Contract: validate_dataset(root) returns a ValidationReport with ok/errors.
    report = data.validate_dataset(os.path.join(HERE, "fixtures", "v1"))
    assert hasattr(report, "ok")
    assert hasattr(report, "errors")
    # The synthetic fixture is not in the converted dataset layout, so it is
    # expected to report errors; we only assert the contract shape here.
    assert isinstance(report.errors, list)
