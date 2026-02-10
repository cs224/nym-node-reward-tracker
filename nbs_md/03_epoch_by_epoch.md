# Epoch-by-epoch reward replay

This notebook builds a cache-first, event-sourced replay that reconstructs wallet earnings per epoch and exports a multi-sheet Excel report.

Sections:
- data models and constants
- watch-node discovery from cache
- canonical reward-event selection + replay math
- sheet builders and consistency checks
- cache-first CLI entrypoint


```python
#| hide
from IPython.display import display, HTML
```


```python
#| hide
for css in ["<style>.container { width:70% !important; }</style>", "<style>:root { --jp-notebook-max-width: 70% !important; }</style>"]:
    display(HTML(css))
```


<style>.container { width:70% !important; }</style>



<style>:root { --jp-notebook-max-width: 70% !important; }</style>


## Imports + constants

Intent: define shared constants, typed row models, and reusable parsing helpers for replay and export.


```python
#| default_exp epoch_by_epoch
#| export
from __future__ import annotations

import logging
import sqlite3
from collections import defaultdict
from decimal import Decimal
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Sequence, Tuple

from pydantic import BaseModel, ConfigDict

from pytest import approx

from nym_node_reward_tracker.cache import (
    DEFAULT_DB_PATH,
    DEFAULT_MIXNET_CONTRACT,
    DEFAULT_NYX_WASM_REST,
    connect_db,
    get_owned_node_id,
    get_pending_delegator_reward,
    run_cache,
    wallet_nodes_from_cache,
)
from nym_node_reward_tracker.common import (
    MICRO,
    build_session,
    read_wallets_csv,
    resolve_under_dir,
    setup_logging,
    smart_query,
    to_int,
)

DELEGATION_DENOMINATOR = Decimal("1000000000")
APPROX = {"rel": 1e-9, "abs": 1e-12}

DEFAULT_EPOCH_OUT = "epoch_by_epoch_rewards.xlsx"


class SeedWallet(BaseModel):
    """Wallet seed row used to start cache-backed epoch replay."""
    model_config = ConfigDict(frozen=True)

    address: str
    tag: str = ""


class EpochEarningRow(BaseModel):
    """Per-wallet, per-node, per-epoch replayed earning breakdown."""
    model_config = ConfigDict(frozen=True)

    wallet_address: str
    wallet_tag: str = ""
    node_id: int
    epoch: int
    epoch_reward_height: int
    epoch_reward_timestamp_utc: str
    epoch_reward_txhash: str
    path: str
    amount_unym: str
    amount_nym: str = ""


class NodeEpochTotalRow(BaseModel):
    """Node-level epoch totals aggregated from replayed reward events."""
    model_config = ConfigDict(frozen=True)

    node_id: int
    epoch: int
    epoch_reward_height: int
    epoch_reward_timestamp_utc: str
    epoch_reward_txhash: str
    operator_reward_unym: str
    delegates_reward_unym: str
    total_reward_unym: str
    owner_wallet_address: str = ""


def _to_decimal(x: Any) -> Decimal:
    if x in (None, ""):
        return Decimal(0)
    return Decimal(str(x))


def _dec_str(x: Decimal) -> str:
    s = format(x, "f")
    if "." in s:
        s = s.rstrip("0").rstrip(".")
    return s or "0"

```


```python
seed = SeedWallet(address="n1abc", tag="demo")
assert seed.address == "n1abc"
assert _dec_str(Decimal("10.5000")) == "10.5"
assert _to_decimal("12") == Decimal("12")
```

## Cache-first seed wallet loading

Intent: load seed wallets from CSV and keep `wallet_tag` mapping stable for export sheets.


```python
#| export
def load_seed_wallets(wallets_csv: str | Path) -> List[SeedWallet]:
    return [SeedWallet(address=a, tag=t) for a, t in read_wallets_csv(wallets_csv)]


def seed_wallet_tag_map(seed_wallets: Sequence[SeedWallet]) -> Dict[str, str]:
    return {w.address: w.tag for w in seed_wallets}

```


```python
ws = [SeedWallet(address="n1a", tag="A"), SeedWallet(address="n1b", tag="")]
assert seed_wallet_tag_map(ws)["n1a"] == "A"
```

## Watch-node discovery (cache first)

Intent: discover watch nodes using cache tables first, then fallback to `get_owned_nym_node` only when operator relation is missing.


```python
#| export
def _query_distinct_node_ids_for_wallet(conn: sqlite3.Connection, wallet: str) -> set[int]:
    out: set[int] = set(wallet_nodes_from_cache(conn, wallet).keys())

    rows = conn.execute(
        "SELECT DISTINCT node_id FROM wallet_nodes WHERE wallet_address=? AND node_id IS NOT NULL",
        (wallet,),
    ).fetchall()
    out.update(int(r[0]) for r in rows if to_int(r[0]) is not None)

    for table in ("delegation_events", "withdraw_events"):
        rows = conn.execute(
            f"SELECT DISTINCT node_id FROM {table} WHERE delegator=? AND node_id IS NOT NULL",
            (wallet,),
        ).fetchall()
        out.update(int(r[0]) for r in rows if to_int(r[0]) is not None)

    return out


def resolve_owner_wallet_for_node(
    session: Any,
    *,
    node_id: int,
    contract: str = DEFAULT_MIXNET_CONTRACT,
    nyx_wasm_rest: str = DEFAULT_NYX_WASM_REST,
    timeout: int = 60,
    logger: Optional[logging.Logger] = None,
) -> str:
    js = smart_query(
        session,
        nyx_wasm_rest=nyx_wasm_rest,
        contract=contract,
        payload={"get_nym_node_details": {"node_id": int(node_id)}},
        timeout=timeout,
        logger=logger,
    )
    return str(
        ((js.get("data") or {}).get("details") or {}).get("bond_information", {}).get("owner") or ""
    ).strip()


def discover_watch_nodes(
    conn: sqlite3.Connection,
    seed_wallets: Sequence[SeedWallet],
    *,
    session: Any,
    contract: str = DEFAULT_MIXNET_CONTRACT,
    nyx_wasm_rest: str = DEFAULT_NYX_WASM_REST,
    timeout: int = 60,
    logger: Optional[logging.Logger] = None,
) -> Tuple[set[int], Dict[int, str]]:
    log = logger or logging.getLogger("nym_epoch_by_epoch")
    watch_nodes: set[int] = set()
    owner_by_node: Dict[int, str] = {}

    for sw in seed_wallets:
        cache_nodes = _query_distinct_node_ids_for_wallet(conn, sw.address)
        watch_nodes.update(cache_nodes)

        op_rows = conn.execute(
            "SELECT node_id FROM wallet_nodes WHERE wallet_address=? AND relation='operator'",
            (sw.address,),
        ).fetchall()
        cached_owned = {int(r[0]) for r in op_rows if to_int(r[0]) is not None}
        for nid in cached_owned:
            owner_by_node[nid] = sw.address
        watch_nodes.update(cached_owned)

        if not cached_owned:
            try:
                owned = get_owned_node_id(
                    session,
                    sw.address,
                    contract=contract,
                    nyx_wasm_rest=nyx_wasm_rest,
                    timeout=timeout,
                    logger=log,
                )
            except Exception as exc:
                log.warning("owned-node fallback failed wallet=%s err=%s", sw.address, exc)
                owned = None
            if owned is not None:
                watch_nodes.add(int(owned))
                owner_by_node[int(owned)] = sw.address

    return watch_nodes, owner_by_node

```


```python
conn = sqlite3.connect(":memory:")
conn.execute("CREATE TABLE wallet_nodes (wallet_address TEXT, node_id INTEGER, relation TEXT, start_height INTEGER, updated_at TEXT)")
conn.execute("CREATE TABLE delegation_events (node_id INTEGER, delegator TEXT)")
conn.execute("CREATE TABLE withdraw_events (node_id INTEGER, delegator TEXT)")
conn.execute("CREATE TABLE wallet_actions (wallet_address TEXT, node_id INTEGER, height INTEGER)")
conn.execute("INSERT INTO wallet_nodes VALUES ('n1a', 14, 'delegator', 1, '')")
conn.execute("INSERT INTO wallet_nodes VALUES ('n1a', 9, 'operator', 1, '')")
conn.execute("INSERT INTO delegation_events VALUES (2933, 'n1a')")
conn.execute("INSERT INTO withdraw_events VALUES (2196, 'n1a')")
conn.commit()

nodes, owners = discover_watch_nodes(conn, [SeedWallet(address='n1a', tag='')], session=object())
assert {9, 14, 2933, 2196}.issubset(nodes)
assert owners[9] == 'n1a'
conn.close()
```

## Canonical reward-event selection

Intent: enforce one canonical reward event per `(node_id, epoch)` using `(height, msg_index, txhash)` ordering, and keep traceability fields for every epoch row.


```python
#| export
def _canonical_reward_rows(rows: Sequence[Dict[str, Any]]) -> List[Dict[str, Any]]:
    chosen: Dict[int, Dict[str, Any]] = {}

    for r in rows:
        ep = to_int(r.get("epoch"))
        if ep is None:
            continue
        key = (
            int(to_int(r.get("height"), 0) or 0),
            int(to_int(r.get("msg_index"), -1) or -1),
            str(r.get("txhash") or ""),
        )
        cur = chosen.get(int(ep))
        if cur is None:
            rr = dict(r)
            rr["_canon_key"] = key
            chosen[int(ep)] = rr
            continue
        if key < cur["_canon_key"]:
            rr = dict(r)
            rr["_canon_key"] = key
            chosen[int(ep)] = rr

    out = list(chosen.values())
    out.sort(key=lambda r: r["_canon_key"])
    for r in out:
        r.pop("_canon_key", None)
    return out

```


```python
rows = [
    {"epoch": 7, "height": 20, "msg_index": 1, "txhash": "b"},
    {"epoch": 7, "height": 20, "msg_index": 0, "txhash": "c"},
    {"epoch": 7, "height": 19, "msg_index": 9, "txhash": "a"},
]
out = _canonical_reward_rows(rows)
assert len(out) == 1
assert out[0]["txhash"] == "a"
```

## Replay math helpers

Intent: apply event-sourced delegation state transitions and reward-split formulas exactly at reward heights.


```python
#| export
def stake_value_unym(a: Decimal, c: Decimal, U: Decimal, D: Decimal = DELEGATION_DENOMINATOR) -> Decimal:
    return a * (U + D) / (c + D)


def delta_u(R: Decimal, U: Decimal, D: Decimal, P: Decimal) -> Decimal:
    if P == 0:
        return Decimal(0)
    return R * (U + D) / P


def delegator_reward_epoch(a: Decimal, c: Decimal, dU: Decimal, D: Decimal = DELEGATION_DENOMINATOR) -> Decimal:
    return a * dU / (c + D)


def pending_unym(a: Decimal, c: Decimal, U: Decimal, D: Decimal = DELEGATION_DENOMINATOR) -> Decimal:
    return stake_value_unym(a, c, U, D) - a

```


```python
a = Decimal("100")
c = Decimal("0")
U = Decimal("0")
R = Decimal("10")
P = Decimal("100")
dU = delta_u(R, U, DELEGATION_DENOMINATOR, P)
assert delegator_reward_epoch(a, c, dU) == Decimal("10")
assert pending_unym(a, c, U) == Decimal("0")
```

## Node replay

Intent: replay one node from cache events and produce wallet-epoch rows + node totals from the same canonical reward stream.


```python
#| export
def replay_node_epoch_rows(
    *,
    node_id: int,
    owner_wallet: str,
    reward_rows: Sequence[Dict[str, Any]],
    delegation_rows: Sequence[Dict[str, Any]],
    withdraw_rows: Sequence[Dict[str, Any]],
    current_total_unit_reward: Decimal,
    D: Decimal = DELEGATION_DENOMINATOR,
) -> Dict[str, Any]:
    rewards = _canonical_reward_rows(reward_rows)

    deleg_interactions: List[Dict[str, Any]] = []
    for r in delegation_rows:
        ev_type = str(r.get("event_type") or "")
        if ev_type not in {"wasm-v2_delegation", "wasm-v2_undelegation"}:
            continue
        raw_delta = r.get("delta_amount_unym")
        full_remove = ev_type == "wasm-v2_undelegation" and (raw_delta is None or str(raw_delta).strip() == "")
        deleg_interactions.append(
            {
                "kind": "delegation",
                "height": int(to_int(r.get("height"), 0) or 0),
                "delegator": str(r.get("delegator") or ""),
                "delta": _to_decimal(raw_delta),
                "full_remove": full_remove,
                "event_type": ev_type,
            }
        )

    for r in withdraw_rows:
        ev_type = str(r.get("event_type") or "")
        if ev_type != "wasm-v2_withdraw_delegator_reward":
            continue
        deleg_interactions.append(
            {
                "kind": "withdraw",
                "height": int(to_int(r.get("height"), 0) or 0),
                "delegator": str(r.get("delegator") or ""),
                "event_type": ev_type,
            }
        )

    interactions = sorted(
        deleg_interactions,
        key=lambda x: (x["height"], 0 if x["kind"] == "withdraw" else 1, x.get("delegator") or "", x.get("event_type") or ""),
    )

    state: Dict[str, Dict[str, Decimal]] = {}
    i_int = 0
    wallet_rows: List[Dict[str, Any]] = []
    node_totals: List[Dict[str, Any]] = []

    op_earned = Decimal(0)
    op_withdrawn = Decimal(0)

    for r in withdraw_rows:
        if str(r.get("event_type") or "") == "wasm-v2_withdraw_operator_reward" and str(r.get("delegator") or "") == owner_wallet:
            op_withdrawn += _to_decimal(r.get("amount_unym"))

    for ev in rewards:
        U = _to_decimal(ev.get("prior_unit_reward"))
        while i_int < len(interactions) and interactions[i_int]["height"] <= int(to_int(ev.get("height"), 0) or 0):
            it = interactions[i_int]
            who = str(it.get("delegator") or "")
            if it["kind"] == "withdraw":
                if who in state:
                    state[who]["c"] = U
            else:
                if it.get("full_remove"):
                    state.pop(who, None)
                else:
                    delta = _to_decimal(it.get("delta"))
                    if who not in state:
                        base = Decimal(0)
                        c = U
                    else:
                        base = stake_value_unym(state[who]["a"], state[who]["c"], U, D)
                        c = U
                    new_a = base + delta
                    if new_a < 0:
                        new_a = Decimal(0)
                    state[who] = {"a": new_a, "c": c}
            i_int += 1

        P = _to_decimal(ev.get("prior_delegates"))
        R = _to_decimal(ev.get("delegates_reward"))
        O = _to_decimal(ev.get("operator_reward"))
        ep = int(to_int(ev.get("epoch"), -1) or -1)
        h = int(to_int(ev.get("height"), 0) or 0)
        ts = str(ev.get("timestamp") or "")
        txh = str(ev.get("txhash") or "")

        dU = delta_u(R, U, D, P)

        split_sum = Decimal(0)
        for delegator, st in state.items():
            amt = delegator_reward_epoch(st["a"], st["c"], dU, D)
            if amt <= 0:
                continue
            split_sum += amt
            wallet_rows.append(
                {
                    "wallet_address": delegator,
                    "node_id": node_id,
                    "epoch": ep,
                    "epoch_reward_height": h,
                    "epoch_reward_timestamp_utc": ts,
                    "epoch_reward_txhash": txh,
                    "path": "delegator_reward",
                    "amount_unym": _dec_str(amt),
                }
            )

        if owner_wallet and O != 0:
            wallet_rows.append(
                {
                    "wallet_address": owner_wallet,
                    "node_id": node_id,
                    "epoch": ep,
                    "epoch_reward_height": h,
                    "epoch_reward_timestamp_utc": ts,
                    "epoch_reward_txhash": txh,
                    "path": "operator_reward",
                    "amount_unym": _dec_str(O),
                }
            )
        op_earned += O

        node_totals.append(
            {
                "node_id": node_id,
                "epoch": ep,
                "epoch_reward_height": h,
                "epoch_reward_timestamp_utc": ts,
                "epoch_reward_txhash": txh,
                "operator_reward_unym": _dec_str(O),
                "delegates_reward_unym": _dec_str(R),
                "total_reward_unym": _dec_str(O + R),
                "owner_wallet_address": owner_wallet,
                "delegator_split_sum_unym": _dec_str(split_sum),
            }
        )

    pending_by_wallet: Dict[str, Decimal] = {}
    for who, st in state.items():
        pending = pending_unym(st["a"], st["c"], current_total_unit_reward, D)
        if pending > 0:
            pending_by_wallet[who] = pending

    return {
        "wallet_rows": wallet_rows,
        "node_totals": node_totals,
        "pending_by_wallet": pending_by_wallet,
        "operator_pending_unym": max(op_earned - op_withdrawn, Decimal(0)),
    }

```


```python
demo = replay_node_epoch_rows(
    node_id=1,
    owner_wallet="n1owner",
    reward_rows=[
        {"epoch": 1, "height": 10, "timestamp": "2026-01-01T00:00:00Z", "txhash": "tx1", "msg_index": 0,
         "prior_unit_reward": "0", "prior_delegates": "100", "delegates_reward": "10", "operator_reward": "2"}
    ],
    delegation_rows=[
        {"height": 5, "event_type": "wasm-v2_delegation", "delegator": "n1d", "delta_amount_unym": "100"}
    ],
    withdraw_rows=[],
    current_total_unit_reward=Decimal("0"),
)
assert len(demo["wallet_rows"]) == 2
assert any(r["path"] == "operator_reward" for r in demo["wallet_rows"])
assert any(r["path"] == "delegator_reward" for r in demo["wallet_rows"])
```

## Involved-wallet closure and consistency checks

Intent: derive full wallet scope for Sheet 2 from watch nodes and enforce node-epoch reconciliation (`delegator splits ~= delegates_reward`).


```python
#| export
def involved_wallets_for_watch_nodes(
    conn: sqlite3.Connection,
    watch_nodes: Sequence[int],
    *,
    owner_by_node: Dict[int, str],
) -> set[str]:
    wallets: set[str] = set(w for w in owner_by_node.values() if w)
    if not watch_nodes:
        return wallets

    placeholders = ",".join(["?"] * len(watch_nodes))

    rows = conn.execute(
        f"SELECT DISTINCT delegator FROM delegation_events WHERE node_id IN ({placeholders}) AND delegator <> ''",
        tuple(watch_nodes),
    ).fetchall()
    wallets.update(str(r[0]) for r in rows if str(r[0]))

    rows = conn.execute(
        f"SELECT DISTINCT delegator FROM current_delegation_state WHERE node_id IN ({placeholders}) AND delegator <> ''",
        tuple(watch_nodes),
    ).fetchall()
    wallets.update(str(r[0]) for r in rows if str(r[0]))

    rows = conn.execute(
        f"SELECT DISTINCT delegator FROM withdraw_events WHERE node_id IN ({placeholders}) AND delegator <> ''",
        tuple(watch_nodes),
    ).fetchall()
    wallets.update(str(r[0]) for r in rows if str(r[0]))

    return wallets


def check_node_epoch_consistency(
    all_wallet_rows: Sequence[Dict[str, Any]],
    node_totals: Sequence[Dict[str, Any]],
    *,
    logger: logging.Logger,
    rel_tol: Decimal = Decimal("1e-8"),
    abs_tol: Decimal = Decimal("1e-6"),
) -> None:
    split_by_key: Dict[Tuple[int, int], Decimal] = defaultdict(lambda: Decimal(0))
    for r in all_wallet_rows:
        if str(r.get("path")) != "delegator_reward":
            continue
        key = (int(to_int(r.get("node_id"), 0) or 0), int(to_int(r.get("epoch"), -1) or -1))
        split_by_key[key] += _to_decimal(r.get("amount_unym"))

    for nt in node_totals:
        key = (int(nt["node_id"]), int(nt["epoch"]))
        got = split_by_key.get(key, Decimal(0))
        exp = _to_decimal(nt.get("delegates_reward_unym"))
        diff = (got - exp).copy_abs()
        scale = max(got.copy_abs(), exp.copy_abs(), Decimal(1))
        tol = max(abs_tol, rel_tol * scale)
        if diff > tol:
            logger.warning(
                "delegator split mismatch node_id=%s epoch=%s got=%s expected=%s diff=%s tol=%s",
                key[0],
                key[1],
                _dec_str(got),
                _dec_str(exp),
                _dec_str(diff),
                _dec_str(tol),
            )

```


```python
rows = [{"node_id": 1, "epoch": 1, "path": "delegator_reward", "amount_unym": "10"}]
node = [{"node_id": 1, "epoch": 1, "delegates_reward_unym": "10"}]
logger = logging.getLogger("verify")
check_node_epoch_consistency(rows, node, logger=logger)
assert callable(involved_wallets_for_watch_nodes)
assert callable(check_node_epoch_consistency)

```

## Pending-value comparison against API + cache

Intent: compare replay-derived pending values against live smart-query values for all involved wallets on watched nodes, and against cached pending state for traceability. Always log INFO summaries and emit WARNING on tolerance mismatches.


```python
#| export
def _pending_operator_amount_detailed(
    session: Any,
    *,
    owner_wallet: str,
    contract: str,
    nyx_wasm_rest: str,
    timeout: int,
    logger: logging.Logger,
) -> Decimal:
    js = smart_query(
        session,
        nyx_wasm_rest=nyx_wasm_rest,
        contract=contract,
        payload={"get_pending_operator_reward": {"address": owner_wallet}},
        timeout=timeout,
        logger=logger,
    )
    data = js.get("data") if isinstance(js, dict) else {}
    if not isinstance(data, dict):
        return Decimal(0)
    detailed = data.get("amount_earned_detailed")
    if detailed not in (None, ""):
        return _to_decimal(detailed)
    earned = data.get("amount_earned") or data.get("reward") or {}
    if isinstance(earned, dict):
        return _to_decimal(earned.get("amount"))
    return _to_decimal(earned)


def _cached_pending_delegator_totals(
    conn: sqlite3.Connection,
    *,
    watch_nodes: Sequence[int],
) -> Dict[str, Decimal]:
    if not watch_nodes:
        return {}
    placeholders = ",".join(["?"] * len(watch_nodes))
    sql = (
        f"SELECT delegator, amount_earned_detailed, amount_earned_unym "
        f"FROM current_pending_reward_state WHERE node_id IN ({placeholders})"
    )
    out: Dict[str, Decimal] = defaultdict(lambda: Decimal(0))
    for r in conn.execute(sql, tuple(int(n) for n in watch_nodes)).fetchall():
        delegator = str(r[0] or "")
        if not delegator:
            continue
        detailed = r[1]
        unym = r[2]
        amt = _to_decimal(detailed if detailed not in (None, "") else unym)
        out[delegator] += amt
    return dict(out)


def compare_replay_vs_live_pending(
    *,
    session: Any,
    conn: sqlite3.Connection,
    seed_wallets: Sequence[SeedWallet],
    watch_nodes: Sequence[int],
    owner_by_node: Dict[int, str],
    replay_pending_delegator: Dict[Tuple[str, int], Decimal],
    replay_pending_operator: Dict[str, Decimal],
    contract: str,
    nyx_wasm_rest: str,
    timeout: int,
    logger: logging.Logger,
) -> None:
    nodes = [int(n) for n in watch_nodes]

    # 1) All-involved-wallet validation against live delegator API.
    cached_totals = _cached_pending_delegator_totals(conn, watch_nodes=nodes)
    replay_wallets = {w for (w, _nid) in replay_pending_delegator.keys()}
    all_wallets = sorted(set(cached_totals.keys()) | replay_wallets)

    for wallet in all_wallets:
        replay_total = Decimal(0)
        live_total = Decimal(0)

        for nid in nodes:
            replay_total += replay_pending_delegator.get((wallet, nid), Decimal(0))
            try:
                live = get_pending_delegator_reward(
                    session,
                    nid,
                    wallet,
                    contract=contract,
                    nyx_wasm_rest=nyx_wasm_rest,
                    timeout=timeout,
                    logger=logger,
                )
                detailed = live.get("amount_earned_detailed") if isinstance(live, dict) else None
                if detailed in (None, ""):
                    detailed = ((live.get("amount_earned") or {}) if isinstance(live, dict) else {}).get("amount")
                live_total += _to_decimal(detailed)
            except Exception as exc:
                logger.warning("pending delegator live lookup failed wallet=%s node_id=%s err=%s", wallet, nid, exc)

        diff = replay_total - live_total
        ok = approx(float(replay_total), **APPROX) == float(live_total)
        logger.info(
            "pending delegator check wallet=%s scope=all-live replay=%s live=%s diff=%s ok=%s",
            wallet,
            _dec_str(replay_total),
            _dec_str(live_total),
            _dec_str(diff),
            ok,
        )
        if not ok:
            logger.warning(
                "pending delegator live mismatch wallet=%s replay=%s live=%s",
                wallet,
                _dec_str(replay_total),
                _dec_str(live_total),
            )

    # 2) Seed-wallet operator validation against live operator API.
    for sw in seed_wallets:
        op_replay = replay_pending_operator.get(sw.address, Decimal(0))
        try:
            op_live = _pending_operator_amount_detailed(
                session,
                owner_wallet=sw.address,
                contract=contract,
                nyx_wasm_rest=nyx_wasm_rest,
                timeout=timeout,
                logger=logger,
            )
            op_diff = op_replay - op_live
            op_ok = approx(float(op_replay), **APPROX) == float(op_live)
            logger.info(
                "pending operator check wallet=%s scope=seed-live replay=%s live=%s diff=%s ok=%s",
                sw.address,
                _dec_str(op_replay),
                _dec_str(op_live),
                _dec_str(op_diff),
                op_ok,
            )
            if not op_ok:
                logger.warning(
                    "pending operator mismatch wallet=%s replay=%s live=%s",
                    sw.address,
                    _dec_str(op_replay),
                    _dec_str(op_live),
                )
        except Exception as exc:
            logger.warning("pending operator lookup failed wallet=%s err=%s", sw.address, exc)

    # 3) All-involved-wallet validation against cached pending state (traceability).
    for wallet in all_wallets:
        replay_total = Decimal(0)
        for nid in nodes:
            replay_total += replay_pending_delegator.get((wallet, nid), Decimal(0))
        cached_total = cached_totals.get(wallet, Decimal(0))
        diff = replay_total - cached_total
        ok = approx(float(replay_total), **APPROX) == float(cached_total)
        logger.info(
            "pending delegator check wallet=%s scope=all-cached replay=%s cached=%s diff=%s ok=%s",
            wallet,
            _dec_str(replay_total),
            _dec_str(cached_total),
            _dec_str(diff),
            ok,
        )
        if not ok:
            logger.warning(
                "pending delegator cached mismatch wallet=%s replay=%s cached=%s",
                wallet,
                _dec_str(replay_total),
                _dec_str(cached_total),
            )

```


```python
assert callable(_cached_pending_delegator_totals)
assert callable(compare_replay_vs_live_pending)
```

## Excel writer

Intent: write all required sheets from one replay result set without float coercion for `amount_unym`.


```python
#| export
def write_epoch_by_epoch_excel(
    *,
    out_path: str | Path,
    wallet_seed_rows: Sequence[Dict[str, Any]],
    wallet_all_rows: Sequence[Dict[str, Any]],
    node_total_rows: Sequence[Dict[str, Any]],
) -> None:
    try:
        from openpyxl import Workbook
    except ImportError as exc:
        raise RuntimeError("openpyxl is required for .xlsx output") from exc

    p = Path(out_path)
    if p.suffix.lower() != ".xlsx":
        raise ValueError(f"epoch-by-epoch export requires .xlsx output, got: {p}")
    p.parent.mkdir(parents=True, exist_ok=True)

    wb = Workbook()

    def _write_sheet(name: str, rows: Sequence[Dict[str, Any]], columns: Sequence[str]) -> None:
        ws = wb.create_sheet(name)
        ws.append(list(columns))
        for r in rows:
            ws.append([r.get(c, "") for c in columns])

    wb.remove(wb.active)

    cols_wallet = [
        "wallet_address",
        "wallet_tag",
        "node_id",
        "epoch",
        "epoch_reward_height",
        "epoch_reward_timestamp_utc",
        "epoch_reward_txhash",
        "path",
        "amount_unym",
        "amount_nym",
    ]
    cols_node = [
        "node_id",
        "epoch",
        "epoch_reward_height",
        "epoch_reward_timestamp_utc",
        "epoch_reward_txhash",
        "operator_reward_unym",
        "delegates_reward_unym",
        "total_reward_unym",
        "owner_wallet_address",
    ]

    _write_sheet("wallet_seed_epoch_earnings", wallet_seed_rows, cols_wallet)
    _write_sheet("wallet_all_epoch_earnings", wallet_all_rows, cols_wallet)
    _write_sheet("node_epoch_totals", node_total_rows, cols_node)

    wb.save(p)

```


```python
assert callable(write_epoch_by_epoch_excel)
```

## Main entrypoint

Intent: run cache refresh first, replay watch nodes from cached events, emit three-sheet Excel output, and warn on replay-vs-live mismatches.


```python
#| export
def run_epoch_by_epoch(
    *,
    data_dir: str = "data",
    wallets_csv: str = "wallet-addresses.csv",
    out_xlsx: str = DEFAULT_EPOCH_OUT,
    db_path: str = DEFAULT_DB_PATH,
    contract: str = DEFAULT_MIXNET_CONTRACT,
    nyx_wasm_rest: str = DEFAULT_NYX_WASM_REST,
    # cache refresh knobs
    window_size: Optional[int] = None,
    window_size_reward: int = 10000,
    window_size_delegation: int = 10000,
    window_size_withdraw: int = 20000,
    wallet_window_size: int = 100000,
    wallet_start_height: int = 0,
    page_size: int = 100,
    max_pages: int = 200,
    timeout: int = 60,
    force: bool = False,
    log_file: Optional[str] = "nym_epoch_by_epoch.log",
    log_level: str = "INFO",
) -> int:
    logger = setup_logging("nym_epoch_by_epoch", log_file=log_file, level=log_level)

    wallets_path = resolve_under_dir(data_dir, wallets_csv)
    out_path = resolve_under_dir(data_dir, out_xlsx)

    seed_wallets = load_seed_wallets(wallets_path)
    if not seed_wallets:
        logger.error("No wallets found in %s", wallets_path)
        return 1

    # Always refresh cache first, as required for this command.
    rc = run_cache(
        data_dir=data_dir,
        wallets_csv=str(wallets_path),
        db_path=db_path,
        contract=contract,
        nyx_wasm_rest=nyx_wasm_rest,
        window_size=window_size,
        window_size_reward=window_size_reward,
        window_size_delegation=window_size_delegation,
        window_size_withdraw=window_size_withdraw,
        wallet_window_size=wallet_window_size,
        wallet_start_height=wallet_start_height,
        page_size=page_size,
        max_pages=max_pages,
        timeout=timeout,
        force=force,
        log_file=log_file,
        log_level=log_level,
    )
    if rc != 0:
        logger.error("cache refresh failed with rc=%s", rc)
        return rc

    session = build_session("nym-node-reward-tracker/epoch-by-epoch")
    conn = connect_db(db_path)

    watch_nodes, owner_by_node = discover_watch_nodes(
        conn,
        seed_wallets,
        session=session,
        contract=contract,
        nyx_wasm_rest=nyx_wasm_rest,
        timeout=timeout,
        logger=logger,
    )
    if not watch_nodes:
        logger.warning("No watch nodes discovered")
        return 0

    for nid in sorted(watch_nodes):
        if nid in owner_by_node and owner_by_node[nid]:
            continue
        row = conn.execute(
            "SELECT wallet_address FROM wallet_nodes WHERE node_id=? AND relation='operator' ORDER BY updated_at DESC LIMIT 1",
            (nid,),
        ).fetchone()
        if row and row[0]:
            owner_by_node[nid] = str(row[0])
            continue
        try:
            owner = resolve_owner_wallet_for_node(
                session,
                node_id=int(nid),
                contract=contract,
                nyx_wasm_rest=nyx_wasm_rest,
                timeout=timeout,
                logger=logger,
            )
            if owner:
                owner_by_node[int(nid)] = owner
        except Exception as exc:
            logger.warning("owner lookup failed node_id=%s err=%s", nid, exc)

    involved = involved_wallets_for_watch_nodes(conn, sorted(watch_nodes), owner_by_node=owner_by_node)
    involved.update(w.address for w in seed_wallets)

    tag_by_wallet = seed_wallet_tag_map(seed_wallets)
    seed_set = {w.address for w in seed_wallets}

    wallet_all_rows: List[Dict[str, Any]] = []
    node_total_rows: List[Dict[str, Any]] = []

    replay_pending_delegator: Dict[Tuple[str, int], Decimal] = {}
    replay_pending_operator: Dict[str, Decimal] = defaultdict(lambda: Decimal(0))

    for nid in sorted(watch_nodes):
        reward_rows = [
            dict(r)
            for r in conn.execute(
                "SELECT * FROM reward_events WHERE node_id=? ORDER BY height, msg_index, txhash",
                (nid,),
            ).fetchall()
        ]
        if not reward_rows:
            continue

        delegation_rows = [
            dict(r)
            for r in conn.execute(
                "SELECT * FROM delegation_events WHERE node_id=? ORDER BY height, txhash",
                (nid,),
            ).fetchall()
        ]
        withdraw_rows = [
            dict(r)
            for r in conn.execute(
                "SELECT * FROM withdraw_events WHERE node_id=? ORDER BY height, txhash",
                (nid,),
            ).fetchall()
        ]

        cur = conn.execute(
            "SELECT total_unit_reward FROM current_rewarding_state WHERE node_id=?",
            (nid,),
        ).fetchone()
        current_U = _to_decimal(cur[0]) if cur and cur[0] is not None else Decimal(0)

        owner_wallet = owner_by_node.get(nid, "")
        replay = replay_node_epoch_rows(
            node_id=nid,
            owner_wallet=owner_wallet,
            reward_rows=reward_rows,
            delegation_rows=delegation_rows,
            withdraw_rows=withdraw_rows,
            current_total_unit_reward=current_U,
        )

        for r in replay["wallet_rows"]:
            if str(r.get("wallet_address") or "") not in involved:
                continue
            amt = _to_decimal(r.get("amount_unym"))
            out = dict(r)
            out["wallet_tag"] = tag_by_wallet.get(str(out.get("wallet_address") or ""), "")
            out["amount_nym"] = _dec_str(amt / MICRO)
            wallet_all_rows.append(out)

        for nt in replay["node_totals"]:
            node_total_rows.append(nt)

        for w, amt in replay["pending_by_wallet"].items():
            replay_pending_delegator[(w, int(nid))] = amt

        if owner_wallet:
            replay_pending_operator[owner_wallet] += replay["operator_pending_unym"]

    wallet_all_rows.sort(key=lambda r: (str(r.get("wallet_address") or ""), int(to_int(r.get("node_id"), 0) or 0), int(to_int(r.get("epoch"), -1) or -1), str(r.get("path") or "")))
    node_total_rows.sort(key=lambda r: (int(r.get("node_id", 0)), int(r.get("epoch", -1))))

    wallet_seed_rows = [r for r in wallet_all_rows if str(r.get("wallet_address") or "") in seed_set]

    check_node_epoch_consistency(wallet_all_rows, node_total_rows, logger=logger)

    compare_replay_vs_live_pending(
        session=session,
        conn=conn,
        seed_wallets=seed_wallets,
        watch_nodes=sorted(watch_nodes),
        owner_by_node=owner_by_node,
        replay_pending_delegator=replay_pending_delegator,
        replay_pending_operator=dict(replay_pending_operator),
        contract=contract,
        nyx_wasm_rest=nyx_wasm_rest,
        timeout=timeout,
        logger=logger,
    )

    write_epoch_by_epoch_excel(
        out_path=out_path,
        wallet_seed_rows=wallet_seed_rows,
        wallet_all_rows=wallet_all_rows,
        node_total_rows=node_total_rows,
    )

    logger.info(
        "epoch-by-epoch export written path=%s seed_rows=%s all_rows=%s node_totals=%s watch_nodes=%s",
        out_path,
        len(wallet_seed_rows),
        len(wallet_all_rows),
        len(node_total_rows),
        len(watch_nodes),
    )
    return 0

```


```python
assert callable(run_epoch_by_epoch)
```

## Live run example

This cell demonstrates a real cache-refresh + replay invocation against project data.


```python
#| eval: false
# run_epoch_by_epoch(
#     data_dir="data",
#     wallets_csv="wallet-addresses.csv",
#     out_xlsx="epoch_by_epoch_rewards.xlsx",
# )
```


```python
#| hide
import nbdev; nbdev.nbdev_export()
```
