```python
#| hide
from IPython.display import display, HTML
```


```python
#| hide
for css in [
    "<style>.container { width:70% !important; }</style>",
    "<style>:root { --jp-notebook-max-width: 70% !important; }</style>",
]:
    display(HTML(css))
```


<style>.container { width:70% !important; }</style>



<style>:root { --jp-notebook-max-width: 70% !important; }</style>


## Cache: chain-native event cache for epoch-by-epoch rewards

This notebook builds a **local SQLite cache** that makes epoch-by-epoch reward reconstruction feasible and repeatable.

Why it exists:
* CosmWasm smart queries (`/cosmwasm/wasm/v1/contract/.../smart/...`) only expose **current state**.
* Epoch-by-epoch reconstruction needs **historical events**, which come from Cosmos tx search (`/cosmos/tx/v1beta1/txs`).
* Tx search must be queried in **height slices**; large queries time out.

What the cache stores:
* Node-level reward events (`wasm-v2_node_rewarding`)
* Node-level delegation/undelegation and withdrawal events
* Wallet-level “actions” (delegation, undelegation, withdraw…) so we can discover nodes a wallet interacted with **in the past**
* A scan manifest table so scans are **incremental and idempotent**

Design rules:
* Idempotent inserts via UNIQUE constraints
* Store big numbers as TEXT to avoid float surprises



```python
#| default_exp cache
```

### Imports and constants

Intent: define endpoints, defaults, and event type taxonomy once, at the top.


```python
#| export
from __future__ import annotations

import logging
import sqlite3
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Sequence, Tuple

from tqdm import tqdm

from nym_node_reward_tracker.common import (
    MICRO,
    NYM_DENOM,
    build_session,
    iter_windows,
    parse_unym_amount,
    read_wallets_csv,
    request_json,
    setup_logging,
    smart_query,
    to_int,
    tx_search_all_pages,
    utc_now_iso,
)

DEFAULT_NYX_API_BASE = "https://api.nymtech.net"
DEFAULT_NYX_WASM_REST = f"{DEFAULT_NYX_API_BASE}/cosmwasm/wasm/v1/contract"
DEFAULT_NYX_TX_REST = f"{DEFAULT_NYX_API_BASE}/cosmos/tx/v1beta1/txs"
DEFAULT_TENDERMINT_REST = f"{DEFAULT_NYX_API_BASE}/cosmos/base/tendermint/v1beta1"

DEFAULT_MIXNET_CONTRACT = "n17srjznxl9dvzdkpwpw24gg668wc73val88a6m5ajg6ankwvz9wtst0cznr"

DEFAULT_DB_PATH = "data/nym_cache.sqlite"
DEFAULT_TIMEOUT_S = 60

REWARD_EVENT_TYPE = "wasm-v2_node_rewarding"

DELEGATION_EVENT_TYPES = (
    # Effective transitions used for replay
    "wasm-v2_delegation",
    "wasm-v2_undelegation",
    # Queued / pending - diagnostics
    "wasm-v2_pending_delegation",
    "wasm-v2_pending_undelegation",
    "wasm-v2_pending_undelegate",
    "wasm-v2_pending_delegation_removal",
)

WITHDRAW_EVENT_TYPES = (
    "wasm-v2_withdraw_delegator_reward",
    "wasm-v2_withdraw_operator_reward",
)

# Wallet-action classification: includes both mixnet contract actions and generic wallet tx actions.
WALLET_ACTION_KIND: Dict[str, str] = {
    "wasm-v2_delegation": "delegation",
    "wasm-v2_pending_delegation": "delegation_pending",
    "wasm-v2_undelegation": "undelegation",
    "wasm-v2_pending_undelegation": "undelegation_pending",
    "wasm-v2_pending_undelegate": "undelegation_pending",
    "wasm-v2_pending_delegation_removal": "undelegation_pending",
    "wasm-v2_withdraw_delegator_reward": "withdraw_delegator_reward",
    "wasm-v2_withdraw_operator_reward": "withdraw_operator_reward",
    "transfer": "transfer",
    "coin_spent": "coin_spent",
    "coin_received": "coin_received",
    "message": "message_sender",
}



```

### API “shape” probes (bash cells)

Intent: demonstrate the Cosmos tx search query format and the shape of `tx_responses[].events[]`.


```bash
%%bash
#| eval: false
NYX_TX="https://api.nymtech.net/cosmos/tx/v1beta1/txs"
NODE_ID="14"
START="21312000"
END="21314000"

curl -sG "$NYX_TX"   --data-urlencode "query=tx.height>=$START AND tx.height<=$END AND wasm-v2_node_rewarding.node_id='$NODE_ID'"   --data-urlencode "pagination.limit=1"   --data-urlencode "pagination.offset=0"   --data-urlencode "order_by=ORDER_BY_DESC" | jq '.tx_responses[0] | {height, txhash, timestamp, rewarding_events: ([.events[] | select(.type=="wasm-v2_node_rewarding")][0:1])}'

```

    {
      "height": "21313861",
      "txhash": "B734F05F2CD884206FAB4A51AEBCBD185D421F51736E82D4AE7D98263159F

    DFA",
      "timestamp": "2025-12-04T18:26:53Z",
      "rewarding_events": [
        {
          "type": "wasm-v2_no

    de_rewarding",
          "attributes": [
            {
              "key": "_contract_address",
              "valu

    e": "n17srjznxl9dvzdkpwpw24gg668wc73val88a6m5ajg6ankwvz9wtst0cznr",
              "index": true
            

    },
            {
              "key": "interval_details",
              "value": "26760",
              "index": tru

    e
            },
            {
              "key": "prior_delegates",
              "value": "1073730365040.3300271

    10287110781",
              "index": true
            },
            {
              "key": "prior_unit_reward",
       

           "value": "270818456.314079051771011094",
              "index": true
            },
            {
           

       "key": "node_id",
              "value": "14",
              "index": true
            },
            {
             

     "key": "operator_reward",
              "value": "4272973.556427493591543445",
              "index": true


            },
            {
              "key": "delegates_reward",
              "value": "11419372.2242254389665

    8992",
              "index": true
            },
            {
              "key": "msg_index",
              "value":

     "0",
              "index": true
            }
          ]
        }
      ]
    }


Intent: demonstrate a wallet-driven query (message.sender + contract) for discovering historical delegation/withdraw actions.


```bash
%%bash
#| eval: false
NYX_TX="https://api.nymtech.net/cosmos/tx/v1beta1/txs"
WALLET="n127c69pasr35p76amfczemusnutr8mtw78s8xl7"
START="22000000"
END="22300000"

curl -sG "$NYX_TX"   --data-urlencode "query=tx.height>=$START AND tx.height<=$END AND message.sender='$WALLET'"   --data-urlencode "pagination.limit=1"   --data-urlencode "pagination.offset=0"   --data-urlencode "order_by=ORDER_BY_DESC" | jq '{total: .pagination.total, sample: (.tx_responses[0] | {height, txhash, wallet_events: ([.events[] | select((.type|startswith("wasm-v2_")) or .type=="transfer" or .type=="coin_spent" or .type=="coin_received")][0:6])})}'

```

    {
      "total": null,
      "sample": {
        "height": "22250074",
        "txhash": "C2AFFF3A8A967B59EB18B4C8ED

    F4A180688D7EA5E8B1BE3F37916B98723DC420",
        "wallet_events": [
          {
            "type": "coin_spent"

    ,
            "attributes": [
              {
                "key": "spender",
                "value": "n127c69pas

    r35p76amfczemusnutr8mtw78s8xl7",
                "index": true
              },
              {
                "key

    ": "amount",
                "value": "4874unym",
                "index": true
              }
            ]
          

    },
          {
            "type": "coin_received",
            "attributes": [
              {
                "key": "

    receiver",
                "value": "n17xpfvakm2amg962yls6f84z3kell8c5lza5z5c",
                "index": tru

    e
              },
              {
                "key": "amount",
                "value": "4874unym",
               

     "index": true
              }
            ]
          },
          {
            "type": "transfer",
            "attribute

    s": [
              {
                "key": "recipient",
                "value": "n17xpfvakm2amg962yls6f84z3ke

    ll8c5lza5z5c",
                "index": true
              },
              {
                "key": "sender",
         

           "value": "n127c69pasr35p76amfczemusnutr8mtw78s8xl7",
                "index": true
              },
     

             {
                "key": "amount",
                "value": "4874unym",
                "index": true
     

             }
            ]
          },
          {
            "type": "wasm-v2_pending_cost_params_update",
            

    "attributes": [
              {
                "key": "_contract_address",
                "value": "n17srjznxl

    9dvzdkpwpw24gg668wc73val88a6m5ajg6ankwvz9wtst0cznr",
                "index": true
              },
            

      {
                "key": "node_id",
                "value": "2196",
                "index": true
              }

    ,
              {
                "key": "updated_mixnode_cost_params",
                "value": "{\"profit_marg

    in_percent\":\"0.2\",\"interval_operating_cost\":{\"denom\":\"unym\",\"amount\":\"400000000\"}}",
      

              "index": true
              },
              {
                "key": "msg_index",
                "value"

    : "0",
                "index": true
              }
            ]
          }
        ]
      }
    }


### Shared tx parsing imports

Intent: reuse shared tx-shape parsing helpers from `00_cosmos_tx_parsing.ipynb` instead of maintaining duplicate local parsers in cache and reward notebooks.


```python
#| export
from nym_node_reward_tracker.cosmos_tx_parsing import (
    attr_map as _attr_map,
    extract_events,
    node_id_from_attrs as _node_id_from_attrs,
)

```


```python
sample = extract_events({"events": [{"type": "x", "attributes": [{"key": "a", "value": "1"}]}]})
assert sample[0]["attributes"]["a"] == "1"
```

### Row extractors (node-centric and wallet-centric)

Intent: standardize how we read height/txhash/timestamp and how we derive node_id from event attributes.


```python
#| export
def _tx_meta(tx_response: Dict[str, Any]) -> Tuple[int, str, str]:
    return (
        to_int(tx_response.get("height"), 0) or 0,
        str(tx_response.get("txhash") or ""),
        str(tx_response.get("timestamp") or ""),
    )

```


```python
assert _node_id_from_attrs({"node_id": "14"}) == 14
assert _node_id_from_attrs({"delegation_target": "2933"}) == 2933
assert _node_id_from_attrs({}) is None
```

#### Reward rows (node_rewarding)

Intent: extract **only** the minimal fields needed for epoch-by-epoch replay from `wasm-v2_node_rewarding` events for a given node_id.


```python
#| export
def reward_rows_from_tx(
    tx_response: Dict[str, Any],
    node_id: int,
    *,
    contract: str = DEFAULT_MIXNET_CONTRACT,
) -> List[Dict[str, Any]]:
    height, txhash, timestamp = _tx_meta(tx_response)
    out: List[Dict[str, Any]] = []

    for ev in extract_events(tx_response):
        if ev.get("type") != REWARD_EVENT_TYPE:
            continue
        attrs = ev["attributes"]

        # Client-side contract filter: safer than relying on query stacking.
        if attrs.get("_contract_address") != contract:
            continue
        if to_int(attrs.get("node_id")) != node_id:
            continue

        out.append(
            {
                "node_id": node_id,
                "height": height,
                "txhash": txhash,
                "timestamp": timestamp,
                "epoch": to_int(attrs.get("interval_details")),
                "prior_unit_reward": attrs.get("prior_unit_reward") or "",
                "prior_delegates": attrs.get("prior_delegates") or "",
                "delegates_reward": attrs.get("delegates_reward") or "",
                "operator_reward": attrs.get("operator_reward") or "",
                "msg_index": to_int(attrs.get("msg_index"), -1),
                "contract_address": attrs.get("_contract_address") or "",
            }
        )
    return out
```


```python
synth = {
    "height": "10",
    "txhash": "H",
    "timestamp": "2026-01-01T00:00:00Z",
    "events": [
        {
            "type": "wasm-v2_node_rewarding",
            "attributes": [
                {"key": "_contract_address", "value": DEFAULT_MIXNET_CONTRACT},
                {"key": "node_id", "value": "14"},
                {"key": "interval_details", "value": "2"},
                {"key": "prior_unit_reward", "value": "2.0"},
                {"key": "prior_delegates", "value": "1.0"},
                {"key": "delegates_reward", "value": "3.0"},
                {"key": "operator_reward", "value": "4.0"},
                {"key": "msg_index", "value": "0"},
            ],
        }
    ],
}
rows = reward_rows_from_tx(synth, 14)
assert rows and rows[0]["epoch"] == 2 and rows[0]["operator_reward"] == "4.0"
```

#### Delegation rows (node-centric)

Intent: cache delegation and undelegation events per node, including a signed delta where available.

Note: some undelegation events may not include an amount; replay logic can treat them as “full removal”.


```python
#| export
def delegation_rows_from_tx(
    tx_response: Dict[str, Any],
    node_id: int,
    *,
    contract: str = DEFAULT_MIXNET_CONTRACT,
) -> List[Dict[str, Any]]:
    height, txhash, timestamp = _tx_meta(tx_response)
    out: List[Dict[str, Any]] = []

    for ev in extract_events(tx_response):
        ev_type = str(ev.get("type") or "")
        if ev_type not in DELEGATION_EVENT_TYPES:
            continue

        attrs = ev["attributes"]
        if attrs.get("_contract_address") != contract:
            continue
        if _node_id_from_attrs(attrs) != node_id:
            continue

        amt = parse_unym_amount(attrs.get("amount"))
        if amt and ev_type in (
            "wasm-v2_undelegation",
            "wasm-v2_pending_undelegation",
            "wasm-v2_pending_undelegate",
            "wasm-v2_pending_delegation_removal",
        ):
            amt = f"-{amt}"

        out.append(
            {
                "node_id": node_id,
                "height": height,
                "txhash": txhash,
                "timestamp": timestamp,
                "event_type": ev_type,
                "delegator": attrs.get("delegator") or attrs.get("owner") or "",
                "delta_amount_unym": amt or "",
                "contract_address": attrs.get("_contract_address") or "",
            }
        )

    return out
```


```python
# verify_delegation_rows_from_tx
synth = {
    "height": "1",
    "txhash": "D",
    "timestamp": "2026-01-01T00:00:00Z",
    "events": [{"type": "wasm-v2_delegation", "attributes": [
        {"key": "_contract_address", "value": DEFAULT_MIXNET_CONTRACT},
        {"key": "delegation_target", "value": "14"},
        {"key": "owner", "value": "n1"},
        {"key": "amount", "value": "10unym"},
    ]}],
}
rows = delegation_rows_from_tx(synth, 14)
assert len(rows) == 1
assert rows[0]["delegator"] == "n1"

```

#### Withdraw rows (node-centric)

Intent: cache reward withdrawals per node (delegator + operator withdrawals) so replay can reset bookmarks appropriately.


```python
#| export
def withdraw_rows_from_tx(
    tx_response: Dict[str, Any],
    node_id: int,
    *,
    contract: str = DEFAULT_MIXNET_CONTRACT,
) -> List[Dict[str, Any]]:
    height, txhash, timestamp = _tx_meta(tx_response)
    out: List[Dict[str, Any]] = []

    for ev in extract_events(tx_response):
        ev_type = str(ev.get("type") or "")
        if ev_type not in WITHDRAW_EVENT_TYPES:
            continue

        attrs = ev["attributes"]
        if attrs.get("_contract_address") != contract:
            continue
        if _node_id_from_attrs(attrs) != node_id:
            continue

        out.append(
            {
                "node_id": node_id,
                "height": height,
                "txhash": txhash,
                "timestamp": timestamp,
                "event_type": ev_type,
                "delegator": attrs.get("delegator") or attrs.get("owner") or "",
                "amount_unym": parse_unym_amount(attrs.get("amount")) or "",
                "contract_address": attrs.get("_contract_address") or "",
            }
        )
    return out
```


```python
# verify_withdraw_rows_from_tx
synth = {
    "height": "1",
    "txhash": "W",
    "timestamp": "2026-01-01T00:00:00Z",
    "events": [{"type": "wasm-v2_withdraw_operator_reward", "attributes": [
        {"key": "_contract_address", "value": DEFAULT_MIXNET_CONTRACT},
        {"key": "mix_id", "value": "14"},
        {"key": "owner", "value": "n1"},
        {"key": "amount", "value": "9unym"},
    ]}],
}
rows = withdraw_rows_from_tx(synth, 14)
assert len(rows) == 1
assert rows[0]["amount_unym"] == "9"

```

#### Wallet action rows

Intent: cache “wallet actions” so we can answer: “which nodes has this wallet ever interacted with?”

Without it, the cache only knows about **currently-delegated** nodes and cannot reconstruct historical wallet income flows.


```python
#| export
def wallet_action_rows_from_tx(
    tx_response: Dict[str, Any],
    wallet_address: str,
    *,
    contract: str = DEFAULT_MIXNET_CONTRACT,
) -> List[Dict[str, Any]]:
    """
    Extract wallet-centric actions from tx events.

    Output rows are minimal and stable:
      - wallet_address, action_kind, event_type
      - node_id (if any)
      - amount_unym (if any)
      - height/txhash/timestamp

    Notes:
    - mixnet contract events are filtered by `_contract_address == contract`
    - generic bank events (transfer/coin_spent/coin_received/message) are wallet-scoped
      and do not require mixnet contract filtering
    """
    height, txhash, timestamp = _tx_meta(tx_response)
    out: List[Dict[str, Any]] = []

    for ev in extract_events(tx_response):
        ev_type = str(ev.get("type") or "")
        if ev_type not in WALLET_ACTION_KIND:
            continue

        attrs = ev["attributes"]
        action_kind: Optional[str] = None
        node_id: Optional[int] = None
        amount_unym = ""

        if ev_type.startswith("wasm-v2_"):
            if attrs.get("_contract_address") != contract:
                continue
            who = attrs.get("delegator") or attrs.get("owner") or ""
            if who != wallet_address:
                continue
            action_kind = WALLET_ACTION_KIND[ev_type]
            node_id = _node_id_from_attrs(attrs)
            amount_unym = parse_unym_amount(attrs.get("amount")) or ""

        elif ev_type == "transfer":
            sender = attrs.get("sender") or ""
            recipient = attrs.get("recipient") or ""
            if sender == wallet_address and recipient == wallet_address:
                action_kind = "transfer_self"
            elif sender == wallet_address:
                action_kind = "transfer_send"
            elif recipient == wallet_address:
                action_kind = "transfer_receive"
            else:
                continue
            amount_unym = parse_unym_amount(attrs.get("amount")) or ""

        elif ev_type == "coin_spent":
            if (attrs.get("spender") or "") != wallet_address:
                continue
            action_kind = WALLET_ACTION_KIND[ev_type]
            amount_unym = parse_unym_amount(attrs.get("amount")) or ""

        elif ev_type == "coin_received":
            if (attrs.get("receiver") or "") != wallet_address:
                continue
            action_kind = WALLET_ACTION_KIND[ev_type]
            amount_unym = parse_unym_amount(attrs.get("amount")) or ""

        elif ev_type == "message":
            if (attrs.get("sender") or "") != wallet_address:
                continue
            action_kind = WALLET_ACTION_KIND[ev_type]

        if not action_kind:
            continue

        out.append(
            {
                "wallet_address": wallet_address,
                "height": height,
                "txhash": txhash,
                "timestamp": timestamp,
                "action_kind": action_kind,
                "event_type": ev_type,
                "node_id": node_id,
                "amount_unym": amount_unym,
                "msg_index": to_int(attrs.get("msg_index"), -1),
                "contract_address": attrs.get("_contract_address") or "",
            }
        )

    return out

```


```python
wallet = "n1wallet"
synth_wallet_tx = {
    "height": "50",
    "txhash": "TX",
    "timestamp": "2026-01-01T00:00:00Z",
    "events": [
        {"type": "wasm-v2_pending_delegation", "attributes": [
            {"key": "_contract_address", "value": DEFAULT_MIXNET_CONTRACT},
            {"key": "delegator", "value": wallet},
            {"key": "delegation_target", "value": "2933"},
            {"key": "amount", "value": "123unym"},
        ]},
        {"type": "wasm-v2_withdraw_delegator_reward", "attributes": [
            {"key": "_contract_address", "value": DEFAULT_MIXNET_CONTRACT},
            {"key": "delegator", "value": wallet},
            {"key": "delegation_target", "value": "2933"},
            {"key": "amount", "value": "77unym"},
        ]},
        {"type": "transfer", "attributes": [
            {"key": "sender", "value": "n1other"},
            {"key": "recipient", "value": wallet},
            {"key": "amount", "value": "5unym"},
        ]},
    ],
}
rows = wallet_action_rows_from_tx(synth_wallet_tx, wallet)
assert {r["action_kind"] for r in rows} == {"delegation_pending", "withdraw_delegator_reward", "transfer_receive"}
assert next(r for r in rows if r["action_kind"] == "delegation_pending")["node_id"] == 2933

```

### SQLite schema (with a dedicated wallet-actions table)

Intent: define a schema that is:
* minimal (stores only what replay needs),
* idempotent (UNIQUE constraints),
* incrementally scannable (scan windows manifest),
* and wallet-history aware (wallet actions table).


```python
#| export
def connect_db(path: str | Path = DEFAULT_DB_PATH) -> sqlite3.Connection:
    """
    Open a SQLite DB with sane defaults for a write-heavy cache:
    - creates parent dir
    - row_factory=sqlite3.Row for dict(row)
    - WAL mode for better concurrent read/write
    """
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)

    conn = sqlite3.connect(p)
    conn.row_factory = sqlite3.Row

    # Pragmas are best-effort (some can fail in read-only contexts).
    try:
        conn.execute("PRAGMA journal_mode=WAL;")
        conn.execute("PRAGMA synchronous=NORMAL;")
        conn.execute("PRAGMA foreign_keys=ON;")
        conn.execute("PRAGMA busy_timeout=3000;")
    except Exception:
        pass

    return conn
```


```python
import tempfile

```


```python
with tempfile.TemporaryDirectory() as td:
    c = connect_db(Path(td) / "t.sqlite")
    assert isinstance(c, sqlite3.Connection)

```

#### init_schema


```python
#| export
SCHEMA_VERSION = 2

def _get_schema_version(conn: sqlite3.Connection) -> int:
    conn.execute("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
    row = conn.execute("SELECT value FROM meta WHERE key='schema_version'").fetchone()
    if not row:
        return 0
    return int(to_int(row["value"], 0) or 0)

def _set_schema_version(conn: sqlite3.Connection, version: int) -> None:
    conn.execute(
        "INSERT INTO meta (key, value) VALUES ('schema_version', ?) "
        "ON CONFLICT(key) DO UPDATE SET value=excluded.value",
        (str(int(version)),),
    )

def _ensure_scan_windows_v2(conn: sqlite3.Connection) -> None:
    """
    Upgrade legacy scan_windows(node_id, ...) tables to v2 shape
    scan_windows(entity_type, entity_id, ...).

    This runs before CREATE INDEX statements that reference v2 columns.
    """
    cols = [r["name"] for r in conn.execute("PRAGMA table_info(scan_windows)").fetchall()]
    if not cols:
        return
    if "entity_type" in cols and "entity_id" in cols:
        return

    if "node_id" in cols:
        conn.execute("ALTER TABLE scan_windows RENAME TO scan_windows_v1;")
        conn.execute(
            """
            CREATE TABLE scan_windows (
                entity_type TEXT NOT NULL,
                entity_id TEXT NOT NULL,
                event_kind TEXT NOT NULL,
                start_height INTEGER NOT NULL,
                end_height INTEGER NOT NULL,
                status TEXT NOT NULL,
                fetched_at TEXT NOT NULL,
                endpoint TEXT,
                note TEXT,
                UNIQUE (entity_type, entity_id, event_kind, start_height, end_height)
            );
            """
        )
        conn.execute(
            """
            INSERT OR IGNORE INTO scan_windows (
                entity_type, entity_id, event_kind, start_height, end_height,
                status, fetched_at, endpoint, note
            )
            SELECT
                'node',
                CAST(node_id AS TEXT),
                event_kind,
                start_height,
                end_height,
                status,
                fetched_at,
                endpoint,
                note
            FROM scan_windows_v1;
            """
        )
        conn.execute("DROP TABLE scan_windows_v1;")
    else:
        conn.execute("DROP TABLE scan_windows;")
        conn.execute(
            """
            CREATE TABLE scan_windows (
                entity_type TEXT NOT NULL,
                entity_id TEXT NOT NULL,
                event_kind TEXT NOT NULL,
                start_height INTEGER NOT NULL,
                end_height INTEGER NOT NULL,
                status TEXT NOT NULL,
                fetched_at TEXT NOT NULL,
                endpoint TEXT,
                note TEXT,
                UNIQUE (entity_type, entity_id, event_kind, start_height, end_height)
            );
            """
        )


def init_schema(conn: sqlite3.Connection) -> None:
    """
    Create or migrate schema.

    Migration policy (simple, notebook-friendly):
    - version 0: create fresh schema
    - version 1: attempt to migrate scan_windows(node_id,...) -> scan_windows(entity_type, entity_id,...)
    - then ensure wallet_actions exists
    """
    v = _get_schema_version(conn)

    # Ensure legacy scan_windows layouts are upgraded before index DDL below.
    _ensure_scan_windows_v2(conn)

    if v == 1:
        _set_schema_version(conn, 2)
        conn.commit()
        v = 2

    if v == 0:
        conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS node_metadata (
                node_id INTEGER PRIMARY KEY,
                bonding_height INTEGER NOT NULL,
                unit_delegation TEXT,
                mixnet_contract TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS wallet_nodes (
                wallet_address TEXT NOT NULL,
                node_id INTEGER NOT NULL,
                relation TEXT NOT NULL,
                start_height INTEGER,
                updated_at TEXT NOT NULL,
                PRIMARY KEY (wallet_address, node_id, relation)
            );

            CREATE TABLE IF NOT EXISTS reward_events (
                node_id INTEGER NOT NULL,
                height INTEGER NOT NULL,
                txhash TEXT NOT NULL,
                timestamp TEXT,
                epoch INTEGER,
                prior_unit_reward TEXT,
                prior_delegates TEXT,
                delegates_reward TEXT,
                operator_reward TEXT,
                msg_index INTEGER NOT NULL,
                contract_address TEXT,
                UNIQUE (node_id, height, txhash, msg_index)
            );
            CREATE INDEX IF NOT EXISTS ix_reward_events_node_height ON reward_events(node_id, height);

            CREATE TABLE IF NOT EXISTS delegation_events (
                node_id INTEGER NOT NULL,
                height INTEGER NOT NULL,
                txhash TEXT NOT NULL,
                timestamp TEXT,
                event_type TEXT NOT NULL,
                delegator TEXT NOT NULL,
                delta_amount_unym TEXT,
                contract_address TEXT,
                UNIQUE (node_id, height, txhash, event_type, delegator)
            );
            CREATE INDEX IF NOT EXISTS ix_delegation_events_node_height ON delegation_events(node_id, height);

            CREATE TABLE IF NOT EXISTS withdraw_events (
                node_id INTEGER NOT NULL,
                height INTEGER NOT NULL,
                txhash TEXT NOT NULL,
                timestamp TEXT,
                event_type TEXT NOT NULL,
                delegator TEXT NOT NULL,
                amount_unym TEXT,
                contract_address TEXT,
                UNIQUE (node_id, height, txhash, event_type, delegator)
            );
            CREATE INDEX IF NOT EXISTS ix_withdraw_events_node_height ON withdraw_events(node_id, height);

            -- NEW: wallet actions cache
            CREATE TABLE IF NOT EXISTS wallet_actions (
                wallet_address TEXT NOT NULL,
                height INTEGER NOT NULL,
                txhash TEXT NOT NULL,
                timestamp TEXT,
                action_kind TEXT NOT NULL,
                event_type TEXT NOT NULL,
                node_id INTEGER,
                amount_unym TEXT,
                msg_index INTEGER NOT NULL,
                contract_address TEXT
            );
            CREATE INDEX IF NOT EXISTS ix_wallet_actions_wallet_height ON wallet_actions(wallet_address, height);
            CREATE INDEX IF NOT EXISTS ix_wallet_actions_wallet_node ON wallet_actions(wallet_address, node_id);
            CREATE UNIQUE INDEX IF NOT EXISTS ux_wallet_actions_dedupe
                ON wallet_actions(wallet_address, height, txhash, action_kind, event_type, msg_index, COALESCE(node_id, -1));

            -- Generic scan manifest: supports node + wallet scans
            CREATE TABLE IF NOT EXISTS scan_windows (
                entity_type TEXT NOT NULL,
                entity_id TEXT NOT NULL,
                event_kind TEXT NOT NULL,
                start_height INTEGER NOT NULL,
                end_height INTEGER NOT NULL,
                status TEXT NOT NULL,
                fetched_at TEXT NOT NULL,
                endpoint TEXT,
                note TEXT,
                UNIQUE (entity_type, entity_id, event_kind, start_height, end_height)
            );
            CREATE INDEX IF NOT EXISTS ix_scan_windows_entity_kind ON scan_windows(entity_type, entity_id, event_kind, status);

            CREATE TABLE IF NOT EXISTS current_rewarding_state (
                node_id INTEGER PRIMARY KEY,
                total_unit_reward TEXT,
                unique_delegations INTEGER,
                updated_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS current_delegation_state (
                node_id INTEGER NOT NULL,
                delegator TEXT NOT NULL,
                amount_unym TEXT,
                cumulative_reward_ratio TEXT,
                updated_at TEXT NOT NULL,
                PRIMARY KEY (node_id, delegator)
            );

            CREATE TABLE IF NOT EXISTS current_pending_reward_state (
                node_id INTEGER NOT NULL,
                delegator TEXT NOT NULL,
                amount_staked_unym TEXT,
                amount_earned_unym TEXT,
                amount_earned_detailed TEXT,
                node_still_fully_bonded INTEGER,
                mixnode_still_fully_bonded INTEGER,
                updated_at TEXT NOT NULL,
                PRIMARY KEY (node_id, delegator)
            );
            """
        )
        _set_schema_version(conn, SCHEMA_VERSION)

    # Ensure meta exists even if created elsewhere
    conn.execute("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
    if _get_schema_version(conn) == 0:
        _set_schema_version(conn, SCHEMA_VERSION)

    conn.commit()

```


```python
import tempfile

```


```python
with tempfile.TemporaryDirectory() as td:
    conn = connect_db(Path(td) / "unit.sqlite")
    init_schema(conn)
    v = conn.execute("SELECT value FROM meta WHERE key='schema_version'").fetchone()[0]
    assert int(v) == SCHEMA_VERSION

```

#### Idempotent insert helpers

Intent: small, obvious helpers that insert derived rows and rely on UNIQUE constraints for idempotency.


```python
#| export
def upsert_node_metadata(
    conn: sqlite3.Connection,
    *,
    node_id: int,
    bonding_height: int,
    unit_delegation: str,
    contract: str,
) -> None:
    conn.execute(
        """
        INSERT INTO node_metadata (node_id, bonding_height, unit_delegation, mixnet_contract, updated_at)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(node_id) DO UPDATE SET
            bonding_height=excluded.bonding_height,
            unit_delegation=excluded.unit_delegation,
            mixnet_contract=excluded.mixnet_contract,
            updated_at=excluded.updated_at
        """,
        (node_id, bonding_height, unit_delegation, contract, utc_now_iso()),
    )


def upsert_wallet_node_link(
    conn: sqlite3.Connection,
    *,
    wallet_address: str,
    node_id: int,
    relation: str,
    start_height: Optional[int],
) -> None:
    conn.execute(
        """
        INSERT INTO wallet_nodes (wallet_address, node_id, relation, start_height, updated_at)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(wallet_address, node_id, relation) DO UPDATE SET
            start_height=excluded.start_height,
            updated_at=excluded.updated_at
        """,
        (wallet_address, node_id, relation, start_height, utc_now_iso()),
    )


def upsert_current_rewarding_state(
    conn: sqlite3.Connection,
    *,
    node_id: int,
    total_unit_reward: str,
    unique_delegations: int,
) -> None:
    conn.execute(
        """
        INSERT INTO current_rewarding_state (node_id, total_unit_reward, unique_delegations, updated_at)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(node_id) DO UPDATE SET
            total_unit_reward=excluded.total_unit_reward,
            unique_delegations=excluded.unique_delegations,
            updated_at=excluded.updated_at
        """,
        (node_id, total_unit_reward, unique_delegations, utc_now_iso()),
    )


def replace_current_delegation_state(
    conn: sqlite3.Connection,
    *,
    node_id: int,
    rows: List[Dict[str, Any]],
) -> None:
    conn.execute("DELETE FROM current_delegation_state WHERE node_id=?", (node_id,))
    vals = [
        (
            node_id,
            str(r.get("owner") or r.get("delegator") or ""),
            str((r.get("amount") or {}).get("amount") or r.get("amount_unym") or ""),
            str(r.get("cumulative_reward_ratio") or ""),
            utc_now_iso(),
        )
        for r in rows
        if str(r.get("owner") or r.get("delegator") or "")
    ]
    if vals:
        conn.executemany(
            """
            INSERT OR REPLACE INTO current_delegation_state (
                node_id, delegator, amount_unym, cumulative_reward_ratio, updated_at
            ) VALUES (?, ?, ?, ?, ?)
            """,
            vals,
        )


def replace_current_pending_reward_state(
    conn: sqlite3.Connection,
    *,
    node_id: int,
    rows: List[Dict[str, Any]],
) -> None:
    conn.execute("DELETE FROM current_pending_reward_state WHERE node_id=?", (node_id,))
    vals = [
        (
            node_id,
            str(r.get("delegator") or ""),
            str(r.get("amount_staked_unym") or ""),
            str(r.get("amount_earned_unym") or ""),
            str(r.get("amount_earned_detailed") or ""),
            1 if r.get("node_still_fully_bonded") else 0,
            1 if r.get("mixnode_still_fully_bonded") else 0,
            utc_now_iso(),
        )
        for r in rows
        if str(r.get("delegator") or "")
    ]
    if vals:
        conn.executemany(
            """
            INSERT OR REPLACE INTO current_pending_reward_state (
                node_id, delegator, amount_staked_unym, amount_earned_unym,
                amount_earned_detailed, node_still_fully_bonded,
                mixnode_still_fully_bonded, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            vals,
        )


def _insert_many(
    conn: sqlite3.Connection,
    sql: str,
    rows: List[Dict[str, Any]],
    keys: Sequence[str],
) -> int:
    if not rows:
        return 0
    vals = [tuple(r.get(k) for k in keys) for r in rows]
    before = conn.total_changes
    conn.executemany(sql, vals)
    return conn.total_changes - before


def insert_reward_rows(conn: sqlite3.Connection, rows: List[Dict[str, Any]]) -> int:
    return _insert_many(
        conn,
        """
        INSERT OR IGNORE INTO reward_events (
            node_id, height, txhash, timestamp, epoch, prior_unit_reward, prior_delegates,
            delegates_reward, operator_reward, msg_index, contract_address
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        rows,
        (
            "node_id", "height", "txhash", "timestamp", "epoch",
            "prior_unit_reward", "prior_delegates", "delegates_reward", "operator_reward",
            "msg_index", "contract_address",
        ),
    )


def insert_delegation_rows(conn: sqlite3.Connection, rows: List[Dict[str, Any]]) -> int:
    return _insert_many(
        conn,
        """
        INSERT OR IGNORE INTO delegation_events (
            node_id, height, txhash, timestamp, event_type, delegator, delta_amount_unym, contract_address
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """,
        rows,
        ("node_id", "height", "txhash", "timestamp", "event_type", "delegator", "delta_amount_unym", "contract_address"),
    )


def insert_withdraw_rows(conn: sqlite3.Connection, rows: List[Dict[str, Any]]) -> int:
    return _insert_many(
        conn,
        """
        INSERT OR IGNORE INTO withdraw_events (
            node_id, height, txhash, timestamp, event_type, delegator, amount_unym, contract_address
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """,
        rows,
        ("node_id", "height", "txhash", "timestamp", "event_type", "delegator", "amount_unym", "contract_address"),
    )


def insert_wallet_action_rows(conn: sqlite3.Connection, rows: List[Dict[str, Any]]) -> int:
    return _insert_many(
        conn,
        """
        INSERT OR IGNORE INTO wallet_actions (
            wallet_address, height, txhash, timestamp, action_kind, event_type,
            node_id, amount_unym, msg_index, contract_address
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        rows,
        (
            "wallet_address", "height", "txhash", "timestamp",
            "action_kind", "event_type", "node_id", "amount_unym",
            "msg_index", "contract_address",
        ),
    )

```


```python
import tempfile

```


```python
with tempfile.TemporaryDirectory() as td:
    conn = connect_db(Path(td) / "t.sqlite")
    init_schema(conn)

    local_tx = {
        "height": "10",
        "txhash": "H",
        "timestamp": "2026-01-01T00:00:00Z",
        "events": [{
            "type": "wasm-v2_node_rewarding",
            "attributes": [
                {"key": "_contract_address", "value": DEFAULT_MIXNET_CONTRACT},
                {"key": "node_id", "value": "14"},
                {"key": "interval_details", "value": "2"},
                {"key": "prior_unit_reward", "value": "2.0"},
                {"key": "prior_delegates", "value": "1.0"},
                {"key": "delegates_reward", "value": "3.0"},
                {"key": "operator_reward", "value": "4.0"},
                {"key": "msg_index", "value": "0"},
            ],
        }],
    }

    r = reward_rows_from_tx(local_tx, 14)
    assert insert_reward_rows(conn, r) == 1
    assert insert_reward_rows(conn, r) == 0  # idempotent

```

### Scan manifest helpers (generic entity_type/entity_id)

Intent: record which height windows have been scanned successfully, so cache updates are incremental and restartable.


```python
#| export
def _window_done(
    conn: sqlite3.Connection,
    *,
    entity_type: str,
    entity_id: str,
    event_kind: str,
    start_height: int,
    end_height: int,
) -> bool:
    row = conn.execute(
        """
        SELECT 1 FROM scan_windows
        WHERE entity_type=? AND entity_id=? AND event_kind=?
          AND start_height=? AND end_height=? AND status='ok'
        LIMIT 1
        """,
        (entity_type, entity_id, event_kind, start_height, end_height),
    ).fetchone()
    return row is not None


def _record_scan_window(
    conn: sqlite3.Connection,
    *,
    entity_type: str,
    entity_id: str,
    event_kind: str,
    start_height: int,
    end_height: int,
    status: str,
    endpoint: str,
    note: str = "",
) -> None:
    conn.execute(
        """
        INSERT INTO scan_windows (
            entity_type, entity_id, event_kind, start_height, end_height,
            status, fetched_at, endpoint, note
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(entity_type, entity_id, event_kind, start_height, end_height) DO UPDATE SET
            status=excluded.status,
            fetched_at=excluded.fetched_at,
            endpoint=excluded.endpoint,
            note=excluded.note
        """,
        (entity_type, entity_id, event_kind, start_height, end_height, status, utc_now_iso(), endpoint, note),
    )


def _max_scanned_end_height(
    conn: sqlite3.Connection,
    *,
    entity_type: str,
    entity_id: str,
    event_kind: str,
) -> Optional[int]:
    row = conn.execute(
        """
        SELECT MAX(end_height) AS h
        FROM scan_windows
        WHERE entity_type=? AND entity_id=? AND event_kind=? AND status='ok'
        """,
        (entity_type, entity_id, event_kind),
    ).fetchone()
    return to_int((dict(row) if row else {}).get("h")) if row else None

# Backward-compatible wrappers (node-only) used by existing code


def _min_scanned_start_height(
    conn: sqlite3.Connection,
    *,
    entity_type: str,
    entity_id: str,
    event_kind: str,
) -> Optional[int]:
    row = conn.execute(
        """
        SELECT MIN(start_height) AS h
        FROM scan_windows
        WHERE entity_type=? AND entity_id=? AND event_kind=? AND status='ok'
        """,
        (entity_type, entity_id, event_kind),
    ).fetchone()
    return to_int((dict(row) if row else {}).get("h")) if row else None


def window_done(conn: sqlite3.Connection, *, node_id: int, event_kind: str, start_height: int, end_height: int) -> bool:
    return _window_done(conn, entity_type="node", entity_id=str(node_id), event_kind=event_kind, start_height=start_height, end_height=end_height)

def record_scan_window(conn: sqlite3.Connection, *, node_id: int, event_kind: str, start_height: int, end_height: int, status: str, endpoint: str, note: str="") -> None:
    return _record_scan_window(conn, entity_type="node", entity_id=str(node_id), event_kind=event_kind, start_height=start_height, end_height=end_height, status=status, endpoint=endpoint, note=note)

def max_scanned_end_height(conn: sqlite3.Connection, *, node_id: int, event_kind: str) -> Optional[int]:
    return _max_scanned_end_height(conn, entity_type="node", entity_id=str(node_id), event_kind=event_kind)


def min_scanned_start_height(conn: sqlite3.Connection, *, node_id: int, event_kind: str) -> Optional[int]:
    return _min_scanned_start_height(conn, entity_type="node", entity_id=str(node_id), event_kind=event_kind)

# New wallet-specific wrappers
def wallet_window_done(conn: sqlite3.Connection, *, wallet_address: str, event_kind: str, start_height: int, end_height: int) -> bool:
    return _window_done(conn, entity_type="wallet", entity_id=wallet_address, event_kind=event_kind, start_height=start_height, end_height=end_height)

def record_wallet_scan_window(conn: sqlite3.Connection, *, wallet_address: str, event_kind: str, start_height: int, end_height: int, status: str, endpoint: str, note: str="") -> None:
    return _record_scan_window(conn, entity_type="wallet", entity_id=wallet_address, event_kind=event_kind, start_height=start_height, end_height=end_height, status=status, endpoint=endpoint, note=note)

def max_wallet_scanned_end_height(conn: sqlite3.Connection, *, wallet_address: str, event_kind: str) -> Optional[int]:
    return _max_scanned_end_height(conn, entity_type="wallet", entity_id=wallet_address, event_kind=event_kind)


def min_wallet_scanned_start_height(conn: sqlite3.Connection, *, wallet_address: str, event_kind: str) -> Optional[int]:
    return _min_scanned_start_height(conn, entity_type="wallet", entity_id=wallet_address, event_kind=event_kind)

```


```python
import tempfile

```


```python
with tempfile.TemporaryDirectory() as td:
    conn = connect_db(Path(td) / "w.sqlite")
    init_schema(conn)
    record_wallet_scan_window(conn, wallet_address="n1", event_kind="wallet_actions", start_height=1, end_height=10, status="ok", endpoint=DEFAULT_NYX_TX_REST)
    conn.commit()
    assert wallet_window_done(conn, wallet_address="n1", event_kind="wallet_actions", start_height=1, end_height=10)

```

### Window scanners

Intent: a single generic window scanning loop that:
* enforces height slicing,
* supports multiple queries per window,
* deduplicates txhash across queries,
* performs idempotent inserts,
* records scan status.



```python
#| export
def _scan_windows_generic(
    conn: sqlite3.Connection,
    session: Any,
    *,
    entity_type: str,
    entity_id: str,
    event_kind: str,
    start_height: int,
    end_height: int,
    window_size: int,
    nyx_tx_rest: str,
    queries_for_window: Callable[[int, int], List[str]],
    extract_rows: Callable[[Dict[str, Any], Any], List[Dict[str, Any]]],
    insert_rows: Callable[[sqlite3.Connection, List[Dict[str, Any]]], int],
    force: bool,
    page_size: int,
    max_pages: int,
    timeout: int,
    logger: logging.Logger,
) -> Dict[str, int]:
    stats = {"windows": 0, "tx": 0, "rows": 0, "inserted": 0, "skipped": 0, "errors": 0}

    for s, e in tqdm(iter_windows(start_height, end_height, window_size), desc=f"{event_kind}:{entity_id}", unit="window"):
        stats["windows"] += 1

        if entity_type == "node":
            done = window_done(conn, node_id=int(entity_id), event_kind=event_kind, start_height=s, end_height=e)
        else:
            done = wallet_window_done(conn, wallet_address=entity_id, event_kind=event_kind, start_height=s, end_height=e)

        if not force and done:
            stats["skipped"] += 1
            continue

        try:
            t_win = time.perf_counter()
            seen_txhash: set[str] = set()
            tx_rows: List[Dict[str, Any]] = []

            for q in queries_for_window(s, e):
                for txr in tx_search_all_pages(
                    session,
                    nyx_tx_rest=nyx_tx_rest,
                    query=q,
                    page_size=page_size,
                    max_pages=max_pages,
                    timeout=timeout,
                    logger=logger,
                    strict=True,
                ):
                    txhash = str((txr or {}).get("txhash") or "")
                    if txhash and txhash in seen_txhash:
                        continue
                    if txhash:
                        seen_txhash.add(txhash)
                    tx_rows.append(txr)

            stats["tx"] += len(tx_rows)

            extracted: List[Dict[str, Any]] = []
            for txr in tx_rows:
                extracted.extend(extract_rows(txr, entity_id))

            stats["rows"] += len(extracted)
            inserted = insert_rows(conn, extracted)
            stats["inserted"] += inserted

            note = f"tx={len(tx_rows)} rows={len(extracted)} inserted={inserted}"
            if entity_type == "node":
                record_scan_window(conn, node_id=int(entity_id), event_kind=event_kind, start_height=s, end_height=e, status="ok", endpoint=nyx_tx_rest, note=note)
            else:
                record_wallet_scan_window(conn, wallet_address=entity_id, event_kind=event_kind, start_height=s, end_height=e, status="ok", endpoint=nyx_tx_rest, note=note)

            conn.commit()

            win_elapsed_s = time.perf_counter() - t_win
            if win_elapsed_s >= 1.0:
                logger.info(
                    "scan_window slow entity=%s:%s kind=%s range=%s-%s tx=%s rows=%s inserted=%s elapsed=%.3fs",
                    entity_type,
                    entity_id,
                    event_kind,
                    s,
                    e,
                    len(tx_rows),
                    len(extracted),
                    inserted,
                    win_elapsed_s,
                )

        except Exception as exc:
            stats["errors"] += 1
            note = str(exc)[:500]
            if entity_type == "node":
                record_scan_window(conn, node_id=int(entity_id), event_kind=event_kind, start_height=s, end_height=e, status="error", endpoint=nyx_tx_rest, note=note)
            else:
                record_wallet_scan_window(conn, wallet_address=entity_id, event_kind=event_kind, start_height=s, end_height=e, status="error", endpoint=nyx_tx_rest, note=note)

            conn.commit()
            logger.warning("Window failed entity=%s:%s kind=%s range=%s-%s err=%s", entity_type, entity_id, event_kind, s, e, exc)

    return stats

```


```python
# verify_scan_windows_generic
import tempfile

```


```python
class _NoCallSession:
    def get(self, *args, **kwargs):
        raise AssertionError("no network call expected")

with tempfile.TemporaryDirectory() as td:
    conn = connect_db(Path(td) / "t.sqlite")
    init_schema(conn)

    def _queries(_s, _e):
        return []

    def _extract(_tx, _entity):
        return []

    def _insert(_conn, rows):
        assert rows == []
        return 0

    stats = _scan_windows_generic(
        conn,
        _NoCallSession(),
        entity_type="node",
        entity_id="14",
        event_kind="reward",
        start_height=10,
        end_height=9,
        window_size=1000,
        nyx_tx_rest=DEFAULT_NYX_TX_REST,
        queries_for_window=_queries,
        extract_rows=_extract,
        insert_rows=_insert,
        force=False,
        page_size=100,
        max_pages=5,
        timeout=5,
        logger=logging.getLogger("test"),
    )
    assert stats["windows"] == 0
    assert stats["errors"] == 0

```

    reward:14: 0window [00:00, ?window/s]

    reward:14: 0window [00:00, ?window/s]

    


#### concrete scanners


```python
#| export
def scan_node_rewards(
    conn: sqlite3.Connection,
    session: Any,
    node_id: int,
    start_height: int,
    end_height: int,
    *,
    window_size: int = 2000,
    force: bool = False,
    page_size: int = 100,
    max_pages: int = 200,
    timeout: int = DEFAULT_TIMEOUT_S,
    nyx_tx_rest: str = DEFAULT_NYX_TX_REST,
    contract: str = DEFAULT_MIXNET_CONTRACT,
    logger: Optional[logging.Logger] = None,
) -> Dict[str, int]:
    log = logger or logging.getLogger("nym_cache")

    def queries(s: int, e: int) -> List[str]:
        return [f"tx.height>={s} AND tx.height<={e} AND wasm-v2_node_rewarding.node_id='{node_id}'"]

    def extract(txr: Dict[str, Any], _entity_id: Any) -> List[Dict[str, Any]]:
        return reward_rows_from_tx(txr, node_id, contract=contract)

    return _scan_windows_generic(
        conn, session,
        entity_type="node", entity_id=str(node_id), event_kind="reward",
        start_height=start_height, end_height=end_height, window_size=window_size,
        nyx_tx_rest=nyx_tx_rest,
        queries_for_window=queries,
        extract_rows=extract,
        insert_rows=insert_reward_rows,
        force=force, page_size=page_size, max_pages=max_pages, timeout=timeout, logger=log,
    )
```


```python
# verify_scan_node_rewards
import tempfile

```


```python
class _NoCallSession:
    def get(self, *args, **kwargs):
        raise AssertionError("no network call expected")

with tempfile.TemporaryDirectory() as td:
    conn = connect_db(Path(td) / "t.sqlite")
    init_schema(conn)
    stats = scan_node_rewards(
        conn,
        _NoCallSession(),
        node_id=14,
        start_height=10,
        end_height=9,
        logger=logging.getLogger("test"),
    )
    assert stats["windows"] == 0
    assert stats["errors"] == 0

```

    reward:14: 0window [00:00, ?window/s]

    reward:14: 0window [00:00, ?window/s]

    


Intent: scan delegation-related tx events for one node across height windows.


```python
#| export
def scan_node_delegations(
    conn: sqlite3.Connection,
    session: Any,
    node_id: int,
    start_height: int,
    end_height: int,
    *,
    window_size: int = 10000,
    force: bool = False,
    page_size: int = 100,
    max_pages: int = 200,
    timeout: int = DEFAULT_TIMEOUT_S,
    nyx_tx_rest: str = DEFAULT_NYX_TX_REST,
    contract: str = DEFAULT_MIXNET_CONTRACT,
    logger: Optional[logging.Logger] = None,
) -> Dict[str, int]:
    log = logger or logging.getLogger("nym_cache")

    def queries(s: int, e: int) -> List[str]:
        return [
            f"tx.height>={s} AND tx.height<={e} AND wasm-v2_delegation.delegation_target='{node_id}'",
            f"tx.height>={s} AND tx.height<={e} AND wasm-v2_undelegation.mix_id='{node_id}'",
            f"tx.height>={s} AND tx.height<={e} AND wasm-v2_pending_delegation.delegation_target='{node_id}'",
            f"tx.height>={s} AND tx.height<={e} AND wasm-v2_pending_undelegation.mix_id='{node_id}'",
        ]

    def extract(txr: Dict[str, Any], _entity_id: Any) -> List[Dict[str, Any]]:
        return delegation_rows_from_tx(txr, node_id, contract=contract)

    return _scan_windows_generic(
        conn, session,
        entity_type="node", entity_id=str(node_id), event_kind="delegation",
        start_height=start_height, end_height=end_height, window_size=window_size,
        nyx_tx_rest=nyx_tx_rest,
        queries_for_window=queries,
        extract_rows=extract,
        insert_rows=insert_delegation_rows,
        force=force, page_size=page_size, max_pages=max_pages, timeout=timeout, logger=log,
    )
```


```python
# verify_scan_node_delegations
import tempfile

```


```python
class _NoCallSession:
    def get(self, *args, **kwargs):
        raise AssertionError("no network call expected")

with tempfile.TemporaryDirectory() as td:
    conn = connect_db(Path(td) / "t.sqlite")
    init_schema(conn)
    stats = scan_node_delegations(
        conn,
        _NoCallSession(),
        node_id=14,
        start_height=10,
        end_height=9,
        logger=logging.getLogger("test"),
    )
    assert stats["windows"] == 0
    assert stats["errors"] == 0

```

    delegation:14: 0window [00:00, ?window/s]

    delegation:14: 0window [00:00, ?window/s]

    


Intent: scan withdraw-related tx events for one node across height windows.


```python
#| export
def scan_node_withdrawals(
    conn: sqlite3.Connection,
    session: Any,
    node_id: int,
    start_height: int,
    end_height: int,
    *,
    window_size: int = 20000,
    force: bool = False,
    page_size: int = 100,
    max_pages: int = 200,
    timeout: int = DEFAULT_TIMEOUT_S,
    nyx_tx_rest: str = DEFAULT_NYX_TX_REST,
    contract: str = DEFAULT_MIXNET_CONTRACT,
    logger: Optional[logging.Logger] = None,
) -> Dict[str, int]:
    log = logger or logging.getLogger("nym_cache")

    def queries(s: int, e: int) -> List[str]:
        return [
            f"tx.height>={s} AND tx.height<={e} AND wasm-v2_withdraw_delegator_reward.delegation_target='{node_id}'",
            f"tx.height>={s} AND tx.height<={e} AND wasm-v2_withdraw_operator_reward.mix_id='{node_id}'",
        ]

    def extract(txr: Dict[str, Any], _entity_id: Any) -> List[Dict[str, Any]]:
        return withdraw_rows_from_tx(txr, node_id, contract=contract)

    return _scan_windows_generic(
        conn, session,
        entity_type="node", entity_id=str(node_id), event_kind="withdraw",
        start_height=start_height, end_height=end_height, window_size=window_size,
        nyx_tx_rest=nyx_tx_rest,
        queries_for_window=queries,
        extract_rows=extract,
        insert_rows=insert_withdraw_rows,
        force=force, page_size=page_size, max_pages=max_pages, timeout=timeout, logger=log,
    )
```


```python
# verify_scan_node_withdrawals
import tempfile

```


```python
class _NoCallSession:
    def get(self, *args, **kwargs):
        raise AssertionError("no network call expected")

with tempfile.TemporaryDirectory() as td:
    conn = connect_db(Path(td) / "t.sqlite")
    init_schema(conn)
    stats = scan_node_withdrawals(
        conn,
        _NoCallSession(),
        node_id=14,
        start_height=10,
        end_height=9,
        logger=logging.getLogger("test"),
    )
    assert stats["windows"] == 0
    assert stats["errors"] == 0

```

    withdraw:14: 0window [00:00, ?window/s]

    withdraw:14: 0window [00:00, ?window/s]

    


Intent: scan wallet-originated and wallet-received tx actions for discovery and history.


```python
#| export
def scan_wallet_actions(
    conn: sqlite3.Connection,
    session: Any,
    wallet_address: str,
    start_height: int,
    end_height: int,
    *,
    window_size: int = 500_000,
    force: bool = False,
    page_size: int = 100,
    max_pages: int = 200,
    timeout: int = DEFAULT_TIMEOUT_S,
    nyx_tx_rest: str = DEFAULT_NYX_TX_REST,
    contract: str = DEFAULT_MIXNET_CONTRACT,
    logger: Optional[logging.Logger] = None,
) -> Dict[str, int]:
    log = logger or logging.getLogger("nym_cache")

    def queries(s: int, e: int) -> List[str]:
        return [
            f"tx.height>={s} AND tx.height<={e} AND message.sender='{wallet_address}'",
            f"tx.height>={s} AND tx.height<={e} AND transfer.recipient='{wallet_address}'",
        ]

    def extract(txr: Dict[str, Any], _entity_id: Any) -> List[Dict[str, Any]]:
        return wallet_action_rows_from_tx(txr, wallet_address, contract=contract)

    return _scan_windows_generic(
        conn, session,
        entity_type="wallet", entity_id=wallet_address, event_kind="wallet_actions",
        start_height=start_height, end_height=end_height, window_size=window_size,
        nyx_tx_rest=nyx_tx_rest,
        queries_for_window=queries,
        extract_rows=extract,
        insert_rows=insert_wallet_action_rows,
        force=force, page_size=page_size, max_pages=max_pages, timeout=timeout, logger=log,
    )

```


```python
# verify_scan_wallet_actions
import tempfile

```


```python
class _NoCallSession:
    def get(self, *args, **kwargs):
        raise AssertionError("no network call expected")

with tempfile.TemporaryDirectory() as td:
    conn = connect_db(Path(td) / "t.sqlite")
    init_schema(conn)
    stats = scan_wallet_actions(
        conn,
        _NoCallSession(),
        wallet_address="n1",
        start_height=10,
        end_height=9,
        logger=logging.getLogger("test"),
    )
    assert stats["windows"] == 0
    assert stats["errors"] == 0

```

    wallet_actions:n1: 0window [00:00, ?window/s]

    wallet_actions:n1: 0window [00:00, ?window/s]

    


### Cached read helpers


```python
#| export
def _query_cached_rows(
    conn: sqlite3.Connection,
    table: str,
    node_id: int,
    *,
    height_min: Optional[int] = None,
    height_max: Optional[int] = None,
) -> List[Dict[str, Any]]:
    sql = f"SELECT * FROM {table} WHERE node_id=?"
    params: List[Any] = [node_id]
    if height_min is not None:
        sql += " AND height>=?"
        params.append(height_min)
    if height_max is not None:
        sql += " AND height<=?"
        params.append(height_max)
    sql += " ORDER BY height, txhash"
    return [dict(r) for r in conn.execute(sql, tuple(params)).fetchall()]


def _rows_to_frame_or_list(rows: List[Dict[str, Any]]) -> Any:
    try:
        import pandas as pd
        return pd.DataFrame(rows)
    except Exception:
        return rows


def get_cached_reward_events(conn: sqlite3.Connection, node_id: int, *, height_min: Optional[int] = None, height_max: Optional[int] = None) -> Any:
    return _rows_to_frame_or_list(_query_cached_rows(conn, "reward_events", node_id, height_min=height_min, height_max=height_max))


def get_cached_delegation_events(conn: sqlite3.Connection, node_id: int, *, height_min: Optional[int] = None, height_max: Optional[int] = None) -> Any:
    return _rows_to_frame_or_list(_query_cached_rows(conn, "delegation_events", node_id, height_min=height_min, height_max=height_max))


def get_cached_withdraw_events(conn: sqlite3.Connection, node_id: int, *, height_min: Optional[int] = None, height_max: Optional[int] = None) -> Any:
    return _rows_to_frame_or_list(_query_cached_rows(conn, "withdraw_events", node_id, height_min=height_min, height_max=height_max))


def get_cached_current_delegation_state(conn: sqlite3.Connection, node_id: int) -> Any:
    rows = [dict(r) for r in conn.execute(
        "SELECT * FROM current_delegation_state WHERE node_id=? ORDER BY delegator",
        (node_id,),
    ).fetchall()]
    return _rows_to_frame_or_list(rows)


def get_cached_current_rewarding_state(conn: sqlite3.Connection, node_id: int) -> Any:
    row = conn.execute("SELECT * FROM current_rewarding_state WHERE node_id=?", (node_id,)).fetchone()
    rows = [dict(row)] if row else []
    return _rows_to_frame_or_list(rows)


def get_cached_current_pending_reward_state(conn: sqlite3.Connection, node_id: int) -> Any:
    try:
        rows = [dict(r) for r in conn.execute(
            "SELECT * FROM current_pending_reward_state WHERE node_id=? ORDER BY delegator",
            (node_id,),
        ).fetchall()]
    except sqlite3.OperationalError:
        rows = []
    return _rows_to_frame_or_list(rows)

def get_cached_wallet_actions(
    conn: sqlite3.Connection,
    wallet_address: str,
    *,
    height_min: Optional[int] = None,
    height_max: Optional[int] = None,
) -> Any:
    sql = "SELECT * FROM wallet_actions WHERE wallet_address=?"
    params: List[Any] = [wallet_address]
    if height_min is not None:
        sql += " AND height>=?"
        params.append(height_min)
    if height_max is not None:
        sql += " AND height<=?"
        params.append(height_max)
    sql += " ORDER BY height, txhash"
    rows = [dict(r) for r in conn.execute(sql, tuple(params)).fetchall()]
    return _rows_to_frame_or_list(rows)

```


```python
# verify_query_cached_rows
import tempfile

```


```python
with tempfile.TemporaryDirectory() as td:
    conn = connect_db(Path(td) / "q.sqlite")
    init_schema(conn)
    insert_reward_rows(conn, [{
        "node_id": 14,
        "height": 1,
        "txhash": "R",
        "timestamp": "",
        "epoch": 1,
        "prior_unit_reward": "1",
        "prior_delegates": "1",
        "delegates_reward": "1",
        "operator_reward": "1",
        "msg_index": 0,
        "contract_address": DEFAULT_MIXNET_CONTRACT,
    }])
    out = _query_cached_rows(conn, "reward_events", 14)
    assert len(out) == 1

```

### Derive “historical node set” per wallet from wallet_actions

Intent: from cached wallet actions, produce the set of node_ids a wallet interacted with, including the earliest observed height per (wallet,node_id). This is used to ensure we scan nodes that were delegated to **in the past**, not only those currently delegated to.


```python
#| export
def wallet_nodes_from_cache(conn: sqlite3.Connection, wallet_address: str) -> Dict[int, int]:
    """
    Returns {node_id: first_seen_height} for nodes discovered via wallet_actions.
    """
    rows = conn.execute(
        """
        SELECT node_id, MIN(height) AS first_h
        FROM wallet_actions
        WHERE wallet_address=? AND node_id IS NOT NULL
        GROUP BY node_id
        """,
        (wallet_address,),
    ).fetchall()

    out: Dict[int, int] = {}
    for r in rows:
        nid = to_int(r["node_id"])
        h = to_int(r["first_h"], 0) or 0
        if nid is not None and h > 0:
            out[int(nid)] = int(h)
    return out
```


```python
import tempfile

```


```python
with tempfile.TemporaryDirectory() as td:
    conn = connect_db(Path(td) / "x.sqlite")
    init_schema(conn)
    insert_wallet_action_rows(conn, [{
        "wallet_address": "n1",
        "height": 10,
        "txhash": "t",
        "timestamp": "",
        "action_kind": "delegation",
        "event_type": "wasm-v2_delegation",
        "node_id": 2933,
        "amount_unym": "1",
        "msg_index": 0,
        "contract_address": DEFAULT_MIXNET_CONTRACT,
    }])
    conn.commit()
    assert wallet_nodes_from_cache(conn, "n1")[2933] == 10

```

### Current-state snapshots

Define -> use -> verify for live-state helpers used by `run_cache`:

- latest height fetch,
- node metadata,
- current node delegations,
- pending delegator rewards,
- wallet->node discovery from owned + delegated + cached historical links.

Important semantic note:
- these helpers are evaluated individually below,
- and scanner/orchestration behavior is documented based on observed runtime logs (not only intended behavior).


#### API Quick Intro (Current-State Helpers)
These `%%bash` examples mirror the REST calls used by the helper functions below. They show request shape and the key JSON fields to inspect before reading the Python wrappers.


Latest height (`fetch_latest_height`): inspect `block.header.height` and `block.header.time`.



```bash
%%bash
TM="https://api.nymtech.net/cosmos/base/tendermint/v1beta1"
curl -s "$TM/blocks/latest" | jq '{height:.block.header.height, time:.block.header.time}'

```

    {
      "height": "22344408",
      "time": "2026-02-10T17:31:10.992531581Z"
    }


Node metadata (`get_node_metadata`): inspect bonding height, identity, and rewarding fields.



```bash
%%bash
WASM="https://api.nymtech.net/cosmwasm/wasm/v1/contract"
CONTRACT="n17srjznxl9dvzdkpwpw24gg668wc73val88a6m5ajg6ankwvz9wtst0cznr"
NODE_ID=2196

Q_DETAILS=$(jq -cn --argjson node_id "$NODE_ID" '{"get_nym_node_details":{"node_id":$node_id}}' | base64 | tr -d '\n')
Q_REWARD=$(jq -cn --argjson node_id "$NODE_ID" '{"get_node_rewarding_details":{"node_id":$node_id}}' | base64 | tr -d '\n')

DETAILS=$(curl -s "$WASM/$CONTRACT/smart/$Q_DETAILS")
REWARD=$(curl -s "$WASM/$CONTRACT/smart/$Q_REWARD")

jq -n --argjson d "$DETAILS" --argjson r "$REWARD" '{
  bonding_height: $d.data.details.bond_information.bonding_height,
  identity_key: $d.data.details.bond_information.identity_key,
  total_unit_reward: $r.data.rewarding_details.total_unit_reward,
  unique_delegations: $r.data.rewarding_details.unique_delegations
}'

```

    {
      "bonding_height": 16380988,
      "identity_key": null,
      "total_unit_reward": "66087553.13215734781

    6839083",
      "unique_delegations": 4
    }


Current node delegations (`get_node_delegations_current`): inspect `delegations[]` and `start_next_after` for pagination.



```bash
%%bash
WASM="https://api.nymtech.net/cosmwasm/wasm/v1/contract"
CONTRACT="n17srjznxl9dvzdkpwpw24gg668wc73val88a6m5ajg6ankwvz9wtst0cznr"
NODE_ID=2196

Q=$(jq -cn --argjson node_id "$NODE_ID" '{"get_node_delegations":{"node_id":$node_id,"start_after":null,"limit":2}}' | base64 | tr -d '\n')

curl -s "$WASM/$CONTRACT/smart/$Q" | jq '{count:(.data.delegations|length), next_key:.data.start_next_after, sample:(.data.delegations[0] // {})}'

```

    {
      "count": 2,
      "next_key": "n1hhl9jd3rwk63sdkqjq58le7677lemtkgnq7mmh",
      "sample": {
        "owner":

     "n1gx3s4zenfs7qz0m742xvte2m0nh86rkz9ygq0q",
        "node_id": 2196,
        "cumulative_reward_ratio": "44

    429242.232656255693475965",
        "amount": {
          "denom": "unym",
          "amount": "5000146592"
        

    },
        "height": 20917079,
        "proxy": null
      }
    }


Owned node lookup (`get_owned_node_id`): inspect `data.details.bond_information.node_id`.



```bash
%%bash
WASM="https://api.nymtech.net/cosmwasm/wasm/v1/contract"
CONTRACT="n17srjznxl9dvzdkpwpw24gg668wc73val88a6m5ajg6ankwvz9wtst0cznr"
WALLET="n127c69pasr35p76amfczemusnutr8mtw78s8xl7"

Q=$(jq -cn --arg wallet "$WALLET" '{"get_owned_nym_node":{"address":$wallet}}' | base64 | tr -d '\n')

curl -s "$WASM/$CONTRACT/smart/$Q" | jq '{node_id: .data.details.bond_information.node_id, details_present:(.data.details != null)}'

```

    {
      "node_id": 2196,
      "details_present": true
    }


Delegator delegations (`get_delegator_delegations`): inspect `delegations[]` and `start_next_after`.



```bash
%%bash
WASM="https://api.nymtech.net/cosmwasm/wasm/v1/contract"
CONTRACT="n17srjznxl9dvzdkpwpw24gg668wc73val88a6m5ajg6ankwvz9wtst0cznr"
WALLET="n127c69pasr35p76amfczemusnutr8mtw78s8xl7"

Q=$(jq -cn --arg wallet "$WALLET" '{"get_delegator_delegations":{"delegator":$wallet,"start_after":null,"limit":2}}' | base64 | tr -d '\n')

curl -s "$WASM/$CONTRACT/smart/$Q" | jq '{count:(.data.delegations|length), next_key:.data.start_next_after, sample:(.data.delegations[0] // {})}'

```

    {
      "count": 1,
      "next_key": [
        2933,
        "n127c69pasr35p76amfczemusnutr8mtw78s8xl7"
      ],
      "sam

    ple": {
        "owner": "n127c69pasr35p76amfczemusnutr8mtw78s8xl7",
        "node_id": 2933,
        "cumulativ

    e_reward_ratio": "669788.748216958693826745",
        "amount": {
          "denom": "unym",
          "amount":

     "200977025706"
        },
        "height": 22222929,
        "proxy": null
      }
    }


Pending delegator reward (`get_pending_delegator_reward`): inspect `amount_staked`, `amount_earned`, and bond-state flags.

Null values mean the wallet currently has no active delegation for that node, or the node is not fully bonded.



```bash
%%bash
#| eval: false
WASM="https://api.nymtech.net/cosmwasm/wasm/v1/contract"
CONTRACT="n17srjznxl9dvzdkpwpw24gg668wc73val88a6m5ajg6ankwvz9wtst0cznr"
WALLET="n127c69pasr35p76amfczemusnutr8mtw78s8xl7"
NODE_ID=2933

Q=$(jq -cn --arg wallet "$WALLET" --argjson node_id "$NODE_ID" '{"get_pending_delegator_reward":{"address":$wallet,"node_id":$node_id}}' | base64 | tr -d '\n')

curl -s "$WASM/$CONTRACT/smart/$Q" | jq '{amount_staked:.data.amount_staked.amount, amount_earned:.data.amount_earned.amount, node_still_fully_bonded:.data.node_still_fully_bonded}'

```

    {
      "amount_staked": "200977025706",
      "amount_earned": "441855607",
      "node_still_fully_bonded": tr

    ue
    }


Intent: fetch the latest chain height from Tendermint REST so scanners can anchor window ranges to current chain state.\n


```python
#| export
def fetch_latest_height(
    session: Any,
    *,
    nyx_tm_rest: str = DEFAULT_TENDERMINT_REST,
    timeout: int = DEFAULT_TIMEOUT_S,
    logger: Optional[logging.Logger] = None,
) -> int:
    js = request_json(session, f"{nyx_tm_rest}/blocks/latest", timeout=timeout, logger=logger)
    return to_int(js.get("block", {}).get("header", {}).get("height"), 0) or 0
```


```python
# verify_fetch_latest_height
js = {"block": {"header": {"height": "42"}}}
class _Resp:
    status_code = 200
    text = "{}"
    def __init__(self, payload): self.payload = payload
    def raise_for_status(self): return None
    def json(self): return self.payload
class _Session:
    def __init__(self, payload): self.payload = payload
    def get(self, *args, **kwargs): return _Resp(self.payload)
assert fetch_latest_height(_Session(js), nyx_tm_rest="https://x", timeout=1) == 42

```

Intent: fetch current node metadata and rewarding state via smart queries.


```python
#| export
def get_node_metadata(
    session: Any,
    node_id: int,
    *,
    contract: str = DEFAULT_MIXNET_CONTRACT,
    nyx_wasm_rest: str = DEFAULT_NYX_WASM_REST,
    timeout: int = DEFAULT_TIMEOUT_S,
    logger: Optional[logging.Logger] = None,
) -> Dict[str, Any]:
    details = smart_query(
        session,
        nyx_wasm_rest=nyx_wasm_rest,
        contract=contract,
        payload={"get_nym_node_details": {"node_id": node_id}},
        timeout=timeout,
        logger=logger,
    )
    rewarding = smart_query(
        session,
        nyx_wasm_rest=nyx_wasm_rest,
        contract=contract,
        payload={"get_node_rewarding_details": {"node_id": node_id}},
        timeout=timeout,
        logger=logger,
    )

    rewarding_details = rewarding.get("data", {}).get("rewarding_details", {})
    bonding_height = to_int(details.get("data", {}).get("details", {}).get("bond_information", {}).get("bonding_height"), 0) or 0

    return {
        "node_id": node_id,
        "bonding_height": bonding_height,
        "unit_delegation": str(rewarding_details.get("unit_delegation") or ""),
        "total_unit_reward": str(rewarding_details.get("total_unit_reward") or ""),
        "unique_delegations": to_int(rewarding_details.get("unique_delegations"), 0) or 0,
    }
```


```python
# verify_get_node_metadata
payload = {
    "data": {
        "details": {"bond_information": {"bonding_height": 123}},
        "rewarding_details": {"cost_params": {"profit_margin_percent": "0.1"}, "operator": "5"},
    }
}
class _Resp:
    status_code = 200
    text = "{}"
    def __init__(self, payload): self.payload = payload
    def raise_for_status(self): return None
    def json(self): return self.payload
class _Session:
    def __init__(self, payload): self.payload = payload
    def get(self, *args, **kwargs): return _Resp(self.payload)
out = get_node_metadata(_Session(payload), 14, nyx_wasm_rest="https://x")
assert out["bonding_height"] == 123

```

Intent: fetch the current delegation set for a node using paginated smart queries.


```python
#| export
def get_node_delegations_current(
    session: Any,
    node_id: int,
    *,
    contract: str = DEFAULT_MIXNET_CONTRACT,
    nyx_wasm_rest: str = DEFAULT_NYX_WASM_REST,
    page_limit: int = 200,
    timeout: int = DEFAULT_TIMEOUT_S,
    max_pages: int = 30,
    logger: Optional[logging.Logger] = None,
) -> List[Dict[str, Any]]:
    out: List[Dict[str, Any]] = []
    start_after: Optional[List[Any]] = None

    for _ in range(max_pages):
        payload: Dict[str, Any] = {"node_id": node_id, "limit": page_limit}
        if start_after is not None:
            payload["start_after"] = start_after

        js = smart_query(
            session,
            nyx_wasm_rest=nyx_wasm_rest,
            contract=contract,
            payload={"get_node_delegations": payload},
            timeout=timeout,
            logger=logger,
        )
        data = js.get("data", {}) if isinstance(js, dict) else {}
        page = data.get("delegations") or []
        if not isinstance(page, list) or not page:
            break

        out.extend(page)
        nxt = data.get("start_next_after")
        if not nxt:
            break
        start_after = nxt

    return out
```


```python
# verify_get_node_delegations_current
payload = {"data": {"delegations": [{"owner": "n1", "amount": {"amount": "1"}}], "start_next_after": None}}
class _Resp:
    status_code = 200
    text = "{}"
    def __init__(self, payload): self.payload = payload
    def raise_for_status(self): return None
    def json(self): return self.payload
class _Session:
    def __init__(self, payload): self.payload = payload
    def get(self, *args, **kwargs): return _Resp(self.payload)
rows = get_node_delegations_current(_Session(payload), 14, nyx_wasm_rest="https://x")
assert len(rows) == 1
assert rows[0]["owner"] == "n1"

```

Intent: resolve a wallet's currently owned node id from contract state.


```python
#| export
def get_owned_node_id(
    session: Any,
    wallet_address: str,
    *,
    contract: str = DEFAULT_MIXNET_CONTRACT,
    nyx_wasm_rest: str = DEFAULT_NYX_WASM_REST,
    timeout: int = DEFAULT_TIMEOUT_S,
    logger: Optional[logging.Logger] = None,
) -> Optional[int]:
    js = smart_query(
        session,
        nyx_wasm_rest=nyx_wasm_rest,
        contract=contract,
        payload={"get_owned_nym_node": {"address": wallet_address}},
        timeout=timeout,
        logger=logger,
    )
    return to_int(js.get("data", {}).get("details", {}).get("bond_information", {}).get("node_id"))
```


```python
# verify_get_owned_node_id
payload = {"data": {"details": {"bond_information": {"node_id": 77}}}}
class _Resp:
    status_code = 200
    text = "{}"
    def __init__(self, payload): self.payload = payload
    def raise_for_status(self): return None
    def json(self): return self.payload
class _Session:
    def __init__(self, payload): self.payload = payload
    def get(self, *args, **kwargs): return _Resp(self.payload)
assert get_owned_node_id(_Session(payload), "n1", nyx_wasm_rest="https://x") == 77

```

Intent: fetch a wallet's current delegations with pagination support.


```python
#| export
def get_delegator_delegations(
    session: Any,
    wallet_address: str,
    *,
    contract: str = DEFAULT_MIXNET_CONTRACT,
    nyx_wasm_rest: str = DEFAULT_NYX_WASM_REST,
    page_limit: int = 200,
    timeout: int = DEFAULT_TIMEOUT_S,
    max_pages: int = 30,
    logger: Optional[logging.Logger] = None,
) -> List[Dict[str, Any]]:
    out: List[Dict[str, Any]] = []
    start_after: Optional[List[Any]] = None

    for _ in range(max_pages):
        payload: Dict[str, Any] = {"delegator": wallet_address, "limit": page_limit}
        if start_after is not None:
            payload["start_after"] = start_after

        js = smart_query(
            session,
            nyx_wasm_rest=nyx_wasm_rest,
            contract=contract,
            payload={"get_delegator_delegations": payload},
            timeout=timeout,
            logger=logger,
        )
        data = js.get("data", {}) if isinstance(js, dict) else {}
        page = data.get("delegations") or []
        if not isinstance(page, list) or not page:
            break

        out.extend(page)
        nxt = data.get("start_next_after")
        if not nxt:
            break
        start_after = nxt

    return out
```


```python
# verify_get_delegator_delegations
payload = {"data": {"delegations": [{"node_id": 14, "height": 10}], "start_next_after": None}}
class _Resp:
    status_code = 200
    text = "{}"
    def __init__(self, payload): self.payload = payload
    def raise_for_status(self): return None
    def json(self): return self.payload
class _Session:
    def __init__(self, payload): self.payload = payload
    def get(self, *args, **kwargs): return _Resp(self.payload)
rows = get_delegator_delegations(_Session(payload), "n1", nyx_wasm_rest="https://x")
assert rows[0]["node_id"] == 14

```

Intent: combine cached historical links with current contract state to discover relevant node ids.


```python
#| export
def discover_wallet_nodes(
    conn: sqlite3.Connection,
    session: Any,
    wallets: List[Tuple[str, str]],
    *,
    contract: str = DEFAULT_MIXNET_CONTRACT,
    nyx_wasm_rest: str = DEFAULT_NYX_WASM_REST,
    timeout: int = DEFAULT_TIMEOUT_S,
    logger: Optional[logging.Logger] = None,
) -> Dict[int, Dict[str, Any]]:
    out: Dict[int, Dict[str, Any]] = {}

    for wallet_address, _tag in wallets:
        # Historical discovery from wallet tx cache (wallet-first)
        for nid, first_h in wallet_nodes_from_cache(conn, wallet_address).items():
            e = out.setdefault(nid, {"node_id": nid, "wallet_links": []})
            e["wallet_links"].append((wallet_address, "historical", first_h))

        # Current operator relation
        owned_node = get_owned_node_id(
            session,
            wallet_address,
            contract=contract,
            nyx_wasm_rest=nyx_wasm_rest,
            timeout=timeout,
            logger=logger,
        )
        if owned_node is not None:
            e = out.setdefault(owned_node, {"node_id": owned_node, "wallet_links": []})
            e["wallet_links"].append((wallet_address, "operator", None))

        # Current delegations relation
        for d in get_delegator_delegations(
            session,
            wallet_address,
            contract=contract,
            nyx_wasm_rest=nyx_wasm_rest,
            timeout=timeout,
            logger=logger,
        ):
            nid = to_int(d.get("node_id"))
            if nid is None:
                continue
            h = to_int(d.get("height"))
            e = out.setdefault(int(nid), {"node_id": int(nid), "wallet_links": []})
            e["wallet_links"].append((wallet_address, "delegator", h))

    return out
```


```python
# verify_discover_wallet_nodes
import tempfile

```


```python
class _Resp:
    status_code = 200
    text = "{}"
    def __init__(self, payload): self.payload = payload
    def raise_for_status(self): return None
    def json(self): return self.payload
class _Session:
    def get(self, *args, **kwargs):
        # get_owned_nym_node and get_delegator_delegations shape
        return _Resp({"data": {"details": {}, "delegations": [], "start_next_after": None}})
with tempfile.TemporaryDirectory() as td:
    conn = connect_db(Path(td) / "t.sqlite")
    init_schema(conn)
    out = discover_wallet_nodes(conn, _Session(), [("n1", "tag")], nyx_wasm_rest="https://x")
    assert isinstance(out, dict)

```

Intent: fetch pending delegator reward details for one (node, delegator) pair.


```python
#| export
def get_pending_delegator_reward(
    session: Any,
    node_id: int,
    delegator: str,
    *,
    contract: str = DEFAULT_MIXNET_CONTRACT,
    nyx_wasm_rest: str = DEFAULT_NYX_WASM_REST,
    timeout: int = DEFAULT_TIMEOUT_S,
    logger: Optional[logging.Logger] = None,
) -> Dict[str, Any]:
    js = smart_query(
        session,
        nyx_wasm_rest=nyx_wasm_rest,
        contract=contract,
        payload={"get_pending_delegator_reward": {"address": delegator, "node_id": node_id}},
        timeout=timeout,
        logger=logger,
    )
    data = js.get("data", {}) if isinstance(js, dict) else {}
    return data if isinstance(data, dict) else {}


```


```python
# verify_get_pending_delegator_reward
payload = {"data": {"amount_staked": {"amount": "1"}, "amount_earned": {"amount": "2"}}}
class _Resp:
    status_code = 200
    text = "{}"
    def __init__(self, payload): self.payload = payload
    def raise_for_status(self): return None
    def json(self): return self.payload
class _Session:
    def __init__(self, payload): self.payload = payload
    def get(self, *args, **kwargs): return _Resp(self.payload)
out = get_pending_delegator_reward(_Session(payload), 14, "n1", nyx_wasm_rest="https://x")
assert out["amount_staked"]["amount"] == "1"

```

### run_cache orchestration (wallet actions first)

Intent: update cache end-to-end with incremental behavior and explicit tradeoffs:

- scan wallet actions incrementally (with backfill if an older range is missing),
- discover node ids from wallet history plus current contract state,
- refresh current-state snapshot tables,
- scan reward/delegation/withdraw windows with strict tx paging.

Important semantic notes:
- adaptive reward window sizing can improve request count but changes window boundaries,
- boundary changes may reduce scan-window reuse against historical fixed-window runs,
- large windows can trigger payload-limit errors; cap and logs should be treated as operational safety signals.


Intent: update the cache end-to-end:

* scan wallet actions for each wallet (incremental)
* discover node_ids from wallet actions + owned nodes + current delegations
* refresh current state snapshots per node
* scan reward/delegation/withdraw windows per node (incremental)


```python
#| export
def _merge_scan_stats(dst: Dict[str, int], src: Dict[str, int]) -> None:
    for k in ("windows", "tx", "rows", "inserted", "skipped", "errors"):
        dst[k] = int(dst.get(k, 0)) + int(src.get(k, 0))


def _adaptive_reward_window_size(
    *,
    start_height: int,
    end_height: int,
    base_window_size: int,
    target_windows: int = 180,
    max_window_size: int = 20_000,
) -> int:
    """
    Compute a larger reward window size for long ranges to reduce request count.

    The value is rounded to a multiple of the base window size for predictable boundaries.
    """
    base = max(1, int(base_window_size))
    span = int(end_height) - int(start_height) + 1
    if span <= 0:
        return base

    # Keep current behavior for short ranges.
    if span <= base * max(1, int(target_windows)):
        return base

    raw = (span + target_windows - 1) // target_windows
    mult = max(1, (raw + base - 1) // base)
    adaptive = mult * base
    return max(base, min(int(max_window_size), int(adaptive)))


def run_cache(
    *,
    data_dir: str = "data",
    wallets_csv: str = "wallet-addresses.csv",
    db_path: str = DEFAULT_DB_PATH,
    contract: str = DEFAULT_MIXNET_CONTRACT,
    nyx_wasm_rest: str = DEFAULT_NYX_WASM_REST,
    nyx_tx_rest: str = DEFAULT_NYX_TX_REST,
    nyx_tm_rest: str = DEFAULT_TENDERMINT_REST,
    # window sizing
    window_size: Optional[int] = None,
    window_size_reward: int = 10000,
    window_size_delegation: int = 10000,
    window_size_withdraw: int = 20000,
    wallet_window_size: int = 100000,
    # paging
    page_size: int = 100,
    max_pages: int = 200,
    timeout: int = DEFAULT_TIMEOUT_S,
    # behavior
    force: bool = False,
    wallet_start_height: int = 0,
    log_file: Optional[str] = "nym_cache.log",
    log_level: str = "INFO",
) -> int:
    logger = setup_logging("nym_cache", log_file=log_file, level=log_level)
    t_run = time.perf_counter()

    wallets_path = Path(wallets_csv)
    if not wallets_path.is_absolute() and wallets_path.parent == Path("."):
        wallets_path = Path(data_dir) / wallets_csv

    wallets = read_wallets_csv(wallets_path)
    if not wallets:
        logger.error("No wallets found in %s", wallets_path)
        return 1

    session = build_session("nym-node-reward-tracker/cache")
    conn = connect_db(db_path)
    init_schema(conn)

    latest_height = fetch_latest_height(session, nyx_tm_rest=nyx_tm_rest, timeout=timeout, logger=logger)
    logger.info("Latest chain height: %s", latest_height)

    # 1) Wallet actions scan (wallet-first)
    t_wallet_phase = time.perf_counter()
    wallet_phase_stats = {"windows": 0, "tx": 0, "rows": 0, "inserted": 0, "skipped": 0, "errors": 0}

    for wallet_address, _tag in tqdm(wallets, desc="Scan wallet actions", unit="wallet"):
        prev = max_wallet_scanned_end_height(conn, wallet_address=wallet_address, event_kind="wallet_actions")
        min_start = min_wallet_scanned_start_height(conn, wallet_address=wallet_address, event_kind="wallet_actions")

        ranges: List[Tuple[int, int]] = []
        if not force and min_start is not None and min_start > wallet_start_height:
            ranges.append((wallet_start_height, min_start - 1))

        fwd_start = wallet_start_height if force or prev is None else prev + 1
        if fwd_start <= latest_height:
            ranges.append((fwd_start, latest_height))

        for start_h, end_h in ranges:
            if start_h > end_h:
                continue
            t_kind = time.perf_counter()
            wstats = scan_wallet_actions(
                conn,
                session,
                wallet_address,
                start_h,
                end_h,
                window_size=wallet_window_size,
                force=force,
                page_size=page_size,
                max_pages=max_pages,
                timeout=timeout,
                nyx_tx_rest=nyx_tx_rest,
                contract=contract,
                logger=logger,
            )
            elapsed_s = time.perf_counter() - t_kind
            _merge_scan_stats(wallet_phase_stats, wstats)
            logger.info(
                "Wallet scan summary wallet=%s kind=wallet_actions range=%s-%s window_size=%s windows=%s skipped=%s tx=%s rows=%s inserted=%s errors=%s elapsed=%.3fs",
                wallet_address,
                start_h,
                end_h,
                wallet_window_size,
                wstats.get("windows", 0),
                wstats.get("skipped", 0),
                wstats.get("tx", 0),
                wstats.get("rows", 0),
                wstats.get("inserted", 0),
                wstats.get("errors", 0),
                elapsed_s,
            )

    wallet_phase_elapsed = time.perf_counter() - t_wallet_phase
    logger.info(
        "Wallet scan phase summary wallets=%s windows=%s skipped=%s tx=%s rows=%s inserted=%s errors=%s elapsed=%.3fs",
        len(wallets),
        wallet_phase_stats.get("windows", 0),
        wallet_phase_stats.get("skipped", 0),
        wallet_phase_stats.get("tx", 0),
        wallet_phase_stats.get("rows", 0),
        wallet_phase_stats.get("inserted", 0),
        wallet_phase_stats.get("errors", 0),
        wallet_phase_elapsed,
    )

    # 2) Discover nodes from wallet cache + current contract state
    nodes = discover_wallet_nodes(
        conn,
        session,
        wallets,
        contract=contract,
        nyx_wasm_rest=nyx_wasm_rest,
        timeout=timeout,
        logger=logger,
    )

    if not nodes:
        logger.warning("No wallet-linked nodes discovered (no wallet actions, no owned nodes, no current delegations)")
        return 0

    logger.info("Discovered %d node(s) across all wallets", len(nodes))

    # 3) Node scans + current-state snapshots
    t_node_phase = time.perf_counter()
    for node_id in tqdm(sorted(nodes.keys()), desc="Scan nodes", unit="node"):
        t_node = time.perf_counter()

        node_meta = get_node_metadata(
            session,
            node_id,
            contract=contract,
            nyx_wasm_rest=nyx_wasm_rest,
            timeout=timeout,
            logger=logger,
        )
        upsert_node_metadata(
            conn,
            node_id=node_id,
            bonding_height=node_meta["bonding_height"],
            unit_delegation=node_meta["unit_delegation"],
            contract=contract,
        )
        upsert_current_rewarding_state(
            conn,
            node_id=node_id,
            total_unit_reward=node_meta["total_unit_reward"],
            unique_delegations=node_meta["unique_delegations"],
        )

        current_delegs = get_node_delegations_current(
            session,
            node_id,
            contract=contract,
            nyx_wasm_rest=nyx_wasm_rest,
            timeout=timeout,
            logger=logger,
        )
        replace_current_delegation_state(conn, node_id=node_id, rows=current_delegs)

        pending_rows: List[Dict[str, Any]] = []
        for drow in current_delegs:
            delegator = str(drow.get("owner") or drow.get("delegator") or "")
            if not delegator:
                continue
            pending = get_pending_delegator_reward(
                session,
                node_id,
                delegator,
                contract=contract,
                nyx_wasm_rest=nyx_wasm_rest,
                timeout=timeout,
                logger=logger,
            )
            pending_rows.append(
                {
                    "delegator": delegator,
                    "amount_staked_unym": parse_unym_amount((pending.get("amount_staked") or {}).get("amount")) or "",
                    "amount_earned_unym": parse_unym_amount((pending.get("amount_earned") or {}).get("amount")) or "",
                    "amount_earned_detailed": str(pending.get("amount_earned_detailed") or ""),
                    "node_still_fully_bonded": bool(pending.get("node_still_fully_bonded")),
                    "mixnode_still_fully_bonded": bool(pending.get("mixnode_still_fully_bonded")),
                }
            )
        replace_current_pending_reward_state(conn, node_id=node_id, rows=pending_rows)

        for wallet_address, relation, start_height in nodes[node_id]["wallet_links"]:
            upsert_wallet_node_link(
                conn,
                wallet_address=wallet_address,
                node_id=node_id,
                relation=relation,
                start_height=start_height,
            )

        prev_r = max_scanned_end_height(conn, node_id=node_id, event_kind="reward")
        prev_d = max_scanned_end_height(conn, node_id=node_id, event_kind="delegation")
        prev_w = max_scanned_end_height(conn, node_id=node_id, event_kind="withdraw")
        min_r = min_scanned_start_height(conn, node_id=node_id, event_kind="reward")
        min_d = min_scanned_start_height(conn, node_id=node_id, event_kind="delegation")
        min_w = min_scanned_start_height(conn, node_id=node_id, event_kind="withdraw")

        earliest_wallet_h = min(
            (h for (_w, rel, h) in nodes[node_id]["wallet_links"] if rel == "historical" and h is not None),
            default=0,
        )
        bonding_h = to_int(node_meta.get("bonding_height"), 0) or 0
        base_candidates = [h for h in [bonding_h, earliest_wallet_h, wallet_start_height] if to_int(h, 0) and to_int(h, 0) > 0]
        base_start = int(min(base_candidates)) if base_candidates else int(wallet_start_height)

        if force or prev_r is None or (min_r is not None and min_r > base_start):
            r_start = base_start
        else:
            r_start = prev_r + 1

        if force or prev_d is None or (min_d is not None and min_d > base_start):
            d_start = base_start
        else:
            d_start = prev_d + 1

        if force or prev_w is None or (min_w is not None and min_w > base_start):
            w_start = base_start
        else:
            w_start = prev_w + 1

        ws_reward_base = window_size or window_size_reward
        ws_delegation = window_size or window_size_delegation
        ws_withdraw = window_size or window_size_withdraw

        ws_reward = ws_reward_base
        if r_start <= latest_height:
            ws_reward = _adaptive_reward_window_size(
                start_height=r_start,
                end_height=latest_height,
                base_window_size=ws_reward_base,
            )
            if ws_reward != ws_reward_base:
                logger.info(
                    "Adaptive reward window size node_id=%s base=%s adaptive=%s range=%s-%s",
                    node_id,
                    ws_reward_base,
                    ws_reward,
                    r_start,
                    latest_height,
                )

        node_totals = {"windows": 0, "tx": 0, "rows": 0, "inserted": 0, "skipped": 0, "errors": 0}

        if r_start <= latest_height:
            t_kind = time.perf_counter()
            s_reward = scan_node_rewards(
                conn,
                session,
                node_id,
                r_start,
                latest_height,
                window_size=ws_reward,
                force=force,
                page_size=page_size,
                max_pages=max_pages,
                timeout=timeout,
                nyx_tx_rest=nyx_tx_rest,
                contract=contract,
                logger=logger,
            )
            reward_elapsed = time.perf_counter() - t_kind
            _merge_scan_stats(node_totals, s_reward)
            logger.info(
                "Node scan summary node_id=%s kind=reward range=%s-%s window_size=%s windows=%s skipped=%s tx=%s rows=%s inserted=%s errors=%s elapsed=%.3fs",
                node_id,
                r_start,
                latest_height,
                ws_reward,
                s_reward.get("windows", 0),
                s_reward.get("skipped", 0),
                s_reward.get("tx", 0),
                s_reward.get("rows", 0),
                s_reward.get("inserted", 0),
                s_reward.get("errors", 0),
                reward_elapsed,
            )

        if d_start <= latest_height:
            t_kind = time.perf_counter()
            s_delegation = scan_node_delegations(
                conn,
                session,
                node_id,
                d_start,
                latest_height,
                window_size=ws_delegation,
                force=force,
                page_size=page_size,
                max_pages=max_pages,
                timeout=timeout,
                nyx_tx_rest=nyx_tx_rest,
                contract=contract,
                logger=logger,
            )
            delegation_elapsed = time.perf_counter() - t_kind
            _merge_scan_stats(node_totals, s_delegation)
            logger.info(
                "Node scan summary node_id=%s kind=delegation range=%s-%s window_size=%s windows=%s skipped=%s tx=%s rows=%s inserted=%s errors=%s elapsed=%.3fs",
                node_id,
                d_start,
                latest_height,
                ws_delegation,
                s_delegation.get("windows", 0),
                s_delegation.get("skipped", 0),
                s_delegation.get("tx", 0),
                s_delegation.get("rows", 0),
                s_delegation.get("inserted", 0),
                s_delegation.get("errors", 0),
                delegation_elapsed,
            )

        if w_start <= latest_height:
            t_kind = time.perf_counter()
            s_withdraw = scan_node_withdrawals(
                conn,
                session,
                node_id,
                w_start,
                latest_height,
                window_size=ws_withdraw,
                force=force,
                page_size=page_size,
                max_pages=max_pages,
                timeout=timeout,
                nyx_tx_rest=nyx_tx_rest,
                contract=contract,
                logger=logger,
            )
            withdraw_elapsed = time.perf_counter() - t_kind
            _merge_scan_stats(node_totals, s_withdraw)
            logger.info(
                "Node scan summary node_id=%s kind=withdraw range=%s-%s window_size=%s windows=%s skipped=%s tx=%s rows=%s inserted=%s errors=%s elapsed=%.3fs",
                node_id,
                w_start,
                latest_height,
                ws_withdraw,
                s_withdraw.get("windows", 0),
                s_withdraw.get("skipped", 0),
                s_withdraw.get("tx", 0),
                s_withdraw.get("rows", 0),
                s_withdraw.get("inserted", 0),
                s_withdraw.get("errors", 0),
                withdraw_elapsed,
            )

        conn.commit()

        node_elapsed = time.perf_counter() - t_node
        logger.info(
            "Node total summary node_id=%s windows=%s skipped=%s tx=%s rows=%s inserted=%s errors=%s elapsed=%.3fs",
            node_id,
            node_totals.get("windows", 0),
            node_totals.get("skipped", 0),
            node_totals.get("tx", 0),
            node_totals.get("rows", 0),
            node_totals.get("inserted", 0),
            node_totals.get("errors", 0),
            node_elapsed,
        )

    node_phase_elapsed = time.perf_counter() - t_node_phase
    logger.info("Node scan phase summary nodes=%s elapsed=%.3fs", len(nodes), node_phase_elapsed)

    run_elapsed = time.perf_counter() - t_run
    logger.info("Cache update completed: %s (elapsed=%.3fs)", db_path, run_elapsed)
    return 0


assert callable(get_node_metadata)
assert callable(get_node_delegations_current)
assert callable(get_pending_delegator_reward)
assert callable(run_cache)

```


```python
# verify_run_cache_helpers
assert _adaptive_reward_window_size(start_height=1, end_height=100, base_window_size=10000) == 10000
assert _adaptive_reward_window_size(start_height=1, end_height=5_000_000, base_window_size=10000) <= 20000

```

### Deterministic unit checks (offline)

This section performs deterministic offline checks:

- creates a temp DB and initializes schema,
- inserts one row into each event table (including `wallet_actions`),
- records node + wallet scan windows,
- verifies idempotency for inserts and window checks.



```python
import tempfile

```


```python
with tempfile.TemporaryDirectory() as td:
    conn = connect_db(Path(td) / "unit.sqlite")
    init_schema(conn)

    reward_row = {
        "node_id": 14,
        "height": 21312001,
        "txhash": "R1",
        "timestamp": "2026-01-01T00:00:00Z",
        "epoch": 1,
        "prior_unit_reward": "1",
        "prior_delegates": "1",
        "delegates_reward": "1",
        "operator_reward": "1",
        "msg_index": 0,
        "contract_address": DEFAULT_MIXNET_CONTRACT,
    }
    delegation_row = {
        "node_id": 14,
        "height": 21312002,
        "txhash": "D1",
        "timestamp": "2026-01-01T00:00:01Z",
        "event_type": "wasm-v2_delegation",
        "delegator": "n1deleg",
        "delta_amount_unym": "100",
        "contract_address": DEFAULT_MIXNET_CONTRACT,
    }
    withdraw_row = {
        "node_id": 14,
        "height": 21312003,
        "txhash": "W1",
        "timestamp": "2026-01-01T00:00:02Z",
        "event_type": "wasm-v2_withdraw_delegator_reward",
        "delegator": "n1deleg",
        "amount_unym": "10",
        "contract_address": DEFAULT_MIXNET_CONTRACT,
    }
    wallet_row = {
        "wallet_address": "n1wallet",
        "height": 21312004,
        "txhash": "T1",
        "timestamp": "2026-01-01T00:00:03Z",
        "action_kind": "transfer_receive",
        "event_type": "transfer",
        "node_id": None,
        "amount_unym": "7",
        "msg_index": -1,
        "contract_address": "",
    }

    assert insert_reward_rows(conn, [reward_row]) == 1
    assert insert_reward_rows(conn, [reward_row]) == 0

    assert insert_delegation_rows(conn, [delegation_row]) == 1
    assert insert_delegation_rows(conn, [delegation_row]) == 0

    assert insert_withdraw_rows(conn, [withdraw_row]) == 1
    assert insert_withdraw_rows(conn, [withdraw_row]) == 0

    assert insert_wallet_action_rows(conn, [wallet_row]) == 1
    assert insert_wallet_action_rows(conn, [wallet_row]) == 0

    upsert_node_metadata(conn, node_id=14, bonding_height=21300000, unit_delegation="1", contract=DEFAULT_MIXNET_CONTRACT)
    upsert_current_rewarding_state(conn, node_id=14, total_unit_reward="12", unique_delegations=2)
    replace_current_delegation_state(conn, node_id=14, rows=[{"owner": "n1deleg", "amount": {"amount": "100"}, "cumulative_reward_ratio": "0"}])
    replace_current_pending_reward_state(conn, node_id=14, rows=[{
        "delegator": "n1deleg",
        "amount_staked_unym": "100",
        "amount_earned_unym": "1",
        "amount_earned_detailed": "1.0",
        "node_still_fully_bonded": True,
        "mixnode_still_fully_bonded": True,
    }])
    upsert_wallet_node_link(conn, wallet_address="n1wallet", node_id=14, relation="delegator", start_height=21312002)

    record_scan_window(conn, node_id=14, event_kind="reward", start_height=21312000, end_height=21312999, status="ok", endpoint=DEFAULT_NYX_TX_REST)
    record_wallet_scan_window(conn, wallet_address="n1wallet", event_kind="wallet_actions", start_height=21312000, end_height=21312999, status="ok", endpoint=DEFAULT_NYX_TX_REST)

    conn.commit()

    assert window_done(conn, node_id=14, event_kind="reward", start_height=21312000, end_height=21312999)
    assert wallet_window_done(conn, wallet_address="n1wallet", event_kind="wallet_actions", start_height=21312000, end_height=21312999)
    assert max_scanned_end_height(conn, node_id=14, event_kind="reward") == 21312999
    assert max_wallet_scanned_end_height(conn, wallet_address="n1wallet", event_kind="wallet_actions") == 21312999

    assert len(_query_cached_rows(conn, "reward_events", 14)) == 1
    assert len(_query_cached_rows(conn, "delegation_events", 14)) == 1
    assert len(_query_cached_rows(conn, "withdraw_events", 14)) == 1
    assert len([dict(r) for r in conn.execute("SELECT * FROM wallet_actions").fetchall()]) == 1

```


```python
#| hide
import nbdev; nbdev.nbdev_export()

```
