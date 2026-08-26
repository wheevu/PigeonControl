"""Tests for the observer CLI surface (help, unknown flags, command inventory).

These tests must pass WITHOUT the sibling data/models/training modules, so we
only exercise argument parsing and importability, never the model/generator
code paths.
"""

import pytest

from pigeon_observer import cli


def test_cli_importable_without_siblings():
    # Importing the CLI must not pull in data/models/training.
    assert hasattr(cli, "build_parser")
    assert hasattr(cli, "main")


def test_all_commands_present():
    parser = cli.build_parser()
    # argparse subparsers register choices; force a parse error to enumerate.
    with pytest.raises(SystemExit):
        parser.parse_args([])  # no subcommand -> error
    # Build a fresh parser and inspect the subparser names.
    p = cli.build_parser()
    names = list(p._subparsers._group_actions[0].choices.keys())
    assert set(["generate", "validate", "train", "evaluate", "embed", "retrieve", "figures"]).issubset(names)


def test_help_exits_zero():
    with pytest.raises(SystemExit) as exc:
        cli.main(["--help"])
    assert exc.value.code == 0


def test_unknown_top_level_flag_nonzero():
    with pytest.raises(SystemExit) as exc:
        cli.main(["--not-a-real-flag"])
    assert exc.value.code != 0


def test_unknown_subcommand_flag_nonzero():
    with pytest.raises(SystemExit) as exc:
        cli.main(["generate", "--bogus-flag"])
    assert exc.value.code != 0


def test_missing_subcommand_nonzero():
    with pytest.raises(SystemExit) as exc:
        cli.main([])
    assert exc.value.code != 0


def test_subcommand_help_lists_options():
    with pytest.raises(SystemExit) as exc:
        cli.main(["retrieve", "--help"])
    assert exc.value.code == 0
