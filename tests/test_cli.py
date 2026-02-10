import importlib

import pytest


def test_cli_requires_command():
    cli = importlib.import_module("nym_node_reward_tracker.cli")
    parser = cli.build_parser()
    with pytest.raises(SystemExit) as exc:
        parser.parse_args([])
    assert exc.value.code == 2


def test_cli_snapshot_parse():
    cli = importlib.import_module("nym_node_reward_tracker.cli")
    parser = cli.build_parser()
    args = parser.parse_args(["snapshot"])
    assert args.command == "snapshot"


def test_cli_reward_transactions_parse():
    cli = importlib.import_module("nym_node_reward_tracker.cli")
    parser = cli.build_parser()
    args = parser.parse_args(["reward-transactions"])
    assert args.command == "reward-transactions"


def test_cli_epoch_by_epoch_parse():
    cli = importlib.import_module("nym_node_reward_tracker.cli")
    parser = cli.build_parser()
    args = parser.parse_args(["epoch-by-epoch"])
    assert args.command == "epoch-by-epoch"
