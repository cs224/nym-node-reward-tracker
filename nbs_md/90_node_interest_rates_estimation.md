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


# Node Interest Rates Walkthrough on Nyx (last 120 hours)

This notebook estimates **node-level yield** from **historical reward distribution events** on **Nyx mainnet** (via `https://api.nymtech.net`) over the **last 120 hours (UTC)**.

We compute two yields per node:

## 1. Delegator yield (pure on-chain from reward events)

$$
r_{delegator} = \frac{delegates\_reward}{prior\_delegates}
$$

## 2. Total-bond yield (proxy) (node "total stake" return)

$$
r_{total} \approx 
\frac{delegates\_reward + operator\_reward}
{prior\_delegates + pledge\_proxy}
$$

where `pledge_proxy` is the node’s **current original pledge** from `get_nym_node_details`  
(a proxy; not a historical snapshot).

For each node we also compute:

- **active_set_pct** = fraction of epochs in this window where the node was rewarded
- **APR_simple** from the arithmetic mean of **zero-filled** per-epoch returns
- **APY_eff** from the geometric mean of **zero-filled** per-epoch returns
- optional: near-saturation cohorts based on the **stake saturation point** from `get_rewarding_params`



## Side Note: How Operator Bond Affects Rewards

From mixnet contract reward logic (`mixnode.rs`):
- Operator profit share uses:
  `profit * (profit_margin + (1 - profit_margin) * operator_share)`
  where `operator_share = operator / (operator + delegates)`.
- Operator cost is paid to operator first (`node_cost`) before residual profit split.

So operator bond matters in two places: reward size (saturation terms) and profit split weighting.

## Data sources (on-chain)

We use only Nyx REST + CosmWasm smart queries:

- Reward distribution events: `wasm-v2_node_rewarding` (indexed by `_contract_address`)
- Role assignment events: `wasm-v2_role_assignment` + `assign_roles` message payload
- Epoch boundaries: timestamps embedded in reward tx responses (for annualization)
- Rewarding parameters (incl. saturation point): `get_rewarding_params`
- Node pledge proxy: `get_nym_node_details → bond_information.original_pledge.amount`

### Why role assignment reconstruction?

The on-chain contract query `get_role_assignment` returns **current** assignment, not historical.
To label **historical rewarded nodes** as `mixnode / entry-gateway / exit-gateway`, we reconstruct role assignment per epoch from historical tx payloads and join them to reward events.

### “Define → use → verify” notebook style

Each helper is introduced by a short intent paragraph, then defined, then immediately exercised and sanity-checked.


## Quick API tour (curl + jq)

These cells show the raw Nyx endpoints used in this notebook.


```bash
%%bash
#| eval: false
# latest block (height + time)
set -euo pipefail

NYX="https://api.nymtech.net"

curl -s "$NYX/cosmos/base/tendermint/v1beta1/blocks/latest" \
| jq '{height: .block.header.height, time: .block.header.time}'
```

    {
      "height": "22371649",
      "time": "2026-02-12T12:37:04.938952219Z"
    }



```bash
%%bash
#| eval: false
# tx search for reward events in a height window
set -euo pipefail

NYX="https://api.nymtech.net"
CONTRACT="n17srjznxl9dvzdkpwpw24gg668wc73val88a6m5ajg6ankwvz9wtst0cznr"

LATEST=$(curl -s "$NYX/cosmos/base/tendermint/v1beta1/blocks/latest" | jq -r '.block.header.height')
START=$((LATEST-5000))

QUERY="tx.height>=$START AND tx.height<=$LATEST AND wasm-v2_node_rewarding._contract_address='$CONTRACT'"

curl -sG "$NYX/cosmos/tx/v1beta1/txs" \
  --data-urlencode "query=$QUERY" \
  --data-urlencode "pagination.limit=3" \
  --data-urlencode "order_by=ORDER_BY_DESC" \
| jq '{tx_count: (.tx_responses|length), next_key: .pagination.next_key}'
```

    {
      "tx_count": 8,
      "next_key": null
    }



```bash
%%bash
#| eval: false
# smart query `get_rewarding_params` (saturation point)
set -euo pipefail

NYX="https://api.nymtech.net"
CONTRACT="n17srjznxl9dvzdkpwpw24gg668wc73val88a6m5ajg6ankwvz9wtst0cznr"

PAYLOAD=$(jq -cn '{"get_rewarding_params":{}}' | base64 -w0)

curl -s "$NYX/cosmwasm/wasm/v1/contract/$CONTRACT/smart/$PAYLOAD" \
| jq '.. | .stake_saturation_point? // empty' | head
```

    "253163718700.247841124046267451"



```bash
%%bash
#| eval: false
# smart query `get_role_assignment` example
set -euo pipefail

NYX="https://api.nymtech.net"
CONTRACT="n17srjznxl9dvzdkpwpw24gg668wc73val88a6m5ajg6ankwvz9wtst0cznr"

PAYLOAD=$(jq -cn '{"get_role_assignment":{"role":"entry_gateway"}}' | base64 -w0)

curl -s "$NYX/cosmwasm/wasm/v1/contract/$CONTRACT/smart/$PAYLOAD" \
| jq '{role: "entry_gateway", epoch_id: .data.epoch_id, node_count: ((.data.nodes // [])|length)}'
```

    {
      "role": "entry_gateway",
      "epoch_id": 28435,
      "node_count": 80
    }



```bash
%%bash
#| eval: false
# smart query `get_nym_node_details` shape
set -euo pipefail

NYX="https://api.nymtech.net"
CONTRACT="n17srjznxl9dvzdkpwpw24gg668wc73val88a6m5ajg6ankwvz9wtst0cznr"

NODE_ID=5
PAYLOAD=$(jq -cn --argjson nid "$NODE_ID" '{"get_nym_node_details":{"node_id":$nid}}' | base64 -w0)

curl -s "$NYX/cosmwasm/wasm/v1/contract/$CONTRACT/smart/$PAYLOAD" \
| jq '.data.details.bond_information | {original_pledge, bonding_height, is_unbonding}'

```

    {
      "original_pledge": {
        "denom": "unym",
        "amount": "28752403445"
      },
      "bonding_height": 2

    935258,
      "is_unbonding": false
    }


# Python implementation

## Imports

We reuse project helpers from `nym_node_reward_tracker` for sessions, JSON requests, smart queries, and tx pagination.
All imports live in one cell (nbdev guardrail).



```python
from __future__ import annotations

import base64
import json
import logging
import math
import os
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from decimal import Decimal, getcontext
from pathlib import Path
from typing import Any, Iterable

import numpy as np
import pandas as pd
from tqdm.auto import tqdm

from nym_node_reward_tracker.common import (
    build_session,
    request_json,
    smart_query,
    tx_search_all_pages,
)
from nym_node_reward_tracker.cosmos_tx_parsing import extract_events
```

    /home/cs/workspaces/nym-node-reward-tracker/.venv/lib/python3.12/site-packages/tqdm/auto.py:21: TqdmWarning: IProgress not found. Please update jupyter and ipywidgets. See https://ipywidgets.readthedocs.io/en/stable/user_install.html
      from .autonotebook import tqdm as notebook_tqdm


## Global numeric/display settings

We store on-chain amounts as **strings** wherever possible and parse them using `Decimal` to avoid float rounding.


```python
getcontext().prec = 50

pd.set_option("display.max_columns", 200)
pd.set_option("display.width", 180)

logger = logging.getLogger("node-interest")
if not logger.handlers:
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
```

## Configuration

Key knobs:

- **Window:** last `WINDOW_HOURS` hours from *now UTC*
- **Network:** Nyx mainnet via `https://api.nymtech.net`
- **Contract:** mixnet contract address (override via env var)


```python
NYX_API_BASE = "https://api.nymtech.net"
NYX_TX_REST = f"{NYX_API_BASE}/cosmos/tx/v1beta1/txs"
NYX_TM_REST = f"{NYX_API_BASE}/cosmos/base/tendermint/v1beta1"
NYX_WASM_REST = f"{NYX_API_BASE}/cosmwasm/wasm/v1/contract"

# Mainnet mixnet contract (known-good default; override if needed)
MIXNET_CONTRACT = os.environ.get(
    "NYM_MIXNET_CONTRACT",
    "n17srjznxl9dvzdkpwpw24gg668wc73val88a6m5ajg6ankwvz9wtst0cznr",
)

REWARD_EVENT_TYPE = "wasm-v2_node_rewarding"
ROLE_ASSIGN_EVENT_TYPE = "wasm-v2_role_assignment"
ADVANCE_EPOCH_EVENT_TYPE = "wasm-v2_advance_epoch"

MICRO = Decimal("1000000")

WINDOW_HOURS = 120
HEIGHT_WINDOW_SIZE = 10_000

TX_PAGE_SIZE = 100
TX_MAX_PAGES = 400
HTTP_TIMEOUT_S = 60

FORCE_RESCAN = False

PROJECT_ROOT = Path.cwd()
if PROJECT_ROOT.name == "nbs":
    PROJECT_ROOT = PROJECT_ROOT.parent

DATA_DIR = PROJECT_ROOT / "data/notebook_interest_rates"
DATA_DIR.mkdir(parents=True, exist_ok=True)

CACHE_REWARDS_CSV = DATA_DIR / "reward_events_last120h.csv"  # optional human-readable backup

CACHE_ROLE_HISTORY_JSON = DATA_DIR / "role_assignments_last120h.json"
CACHE_PLEDGE_PROXY_JSON = DATA_DIR / "pledge_proxy_unym.json"

CACHE_SUMMARY_CSV = DATA_DIR / "node_interest_summary_last120h.csv"

CACHE_NEAR_SAT_CSV = DATA_DIR / "near_saturation_nodes_last120h.csv"
```

## HTTP session

We use the project helper `build_session()` which configures retries/backoff.
We keep a single session for sequential calls and create new sessions inside thread pools (requests sessions are not thread-safe).


```python
session = build_session("node-interest-estimation/1.0")
```

## Time → height window

We want “last 120 hours” by **time**, not by approximate heights.

Plan:

1. Read latest block (height + time).
2. Binary-search for the first height whose block time is **≥ start_utc**.



```python
def parse_rfc3339_utc(ts: str) -> datetime:
    """Parse RFC3339 timestamps (Nyx returns '...Z') into timezone-aware UTC datetimes."""
    return datetime.fromisoformat(str(ts).replace("Z", "+00:00")).astimezone(timezone.utc)


def latest_block(session) -> tuple[int, datetime]:
    """Return (height, time_utc) for the latest block."""
    js = request_json(session, f"{NYX_TM_REST}/blocks/latest", timeout=HTTP_TIMEOUT_S)
    h = int(js["block"]["header"]["height"])
    t = parse_rfc3339_utc(js["block"]["header"]["time"])
    return h, t


def block_time(session, height: int) -> datetime:
    """Return block time (UTC) for a given height."""
    js = request_json(session, f"{NYX_TM_REST}/blocks/{int(height)}", timeout=HTTP_TIMEOUT_S)
    return parse_rfc3339_utc(js["block"]["header"]["time"])


def height_at_or_after_time(session, target_utc: datetime, hi_height: int, lo_height: int = 1) -> int:
    """
    Binary-search: smallest height whose block time >= target_utc.
    Assumes monotonic block times (true for finalized chain history).
    """
    lo, hi = int(lo_height), int(hi_height)
    while lo < hi:
        mid = (lo + hi) // 2
        t_mid = block_time(session, mid)
        if t_mid < target_utc:
            lo = mid + 1
        else:
            hi = mid
    return lo
```


```python
# Use
latest_height, latest_time = latest_block(session)

now_utc = datetime.now(timezone.utc)
start_utc = now_utc - timedelta(hours=WINDOW_HOURS)

# loose lower bound to speed up binary search
lo_guess = max(1, latest_height - 5_000_000)
start_height = height_at_or_after_time(session, start_utc, hi_height=latest_height, lo_height=lo_guess)

print("now_utc      =", now_utc.isoformat())
print("start_utc    =", start_utc.isoformat())
print("latest_height=", latest_height, "latest_time=", latest_time.isoformat())
print("start_height =", start_height)

# Verify
assert latest_height > 0
assert start_height <= latest_height
assert block_time(session, start_height) >= start_utc
```

    now_utc      = 2026-02-12T12:37:13.602092+00:00
    start_utc    = 2026-02-07T12:37:13.602092+00:00
    latest_height= 22371649 latest_time= 2026-02-12T12:37:04.938952+00:00
    start_height = 22295720


## Reward event scan (historical)

We scan historical reward distribution events:

- Event type: `wasm-v2_node_rewarding`
- Indexed attribute: `_contract_address = MIXNET_CONTRACT`
- Scan by height windows to avoid massive single queries.

We parse each tx’s event list and extract the fields we need:

- `node_id`
- `epoch` (from `interval_details`)
- `prior_delegates`
- `delegates_reward`
- `operator_reward`

We then canonicalize to **one row per (node_id, epoch)**.



```python
def reward_query_window(h_start: int, h_end: int) -> str:
    return (
        f"tx.height>={int(h_start)} AND tx.height<={int(h_end)} "
        f"AND {REWARD_EVENT_TYPE}._contract_address='{MIXNET_CONTRACT}'"
    )


def extract_reward_rows(txr: dict[str, Any]) -> list[dict[str, Any]]:
    """
    Extract reward events from a single tx_response.
    Returns one row per reward event inside the tx.
    """
    out: list[dict[str, Any]] = []
    height = int(txr.get("height") or 0)
    txhash = str(txr.get("txhash") or "")
    timestamp = str(txr.get("timestamp") or "")

    for ev in extract_events(txr):
        if ev.get("type") != REWARD_EVENT_TYPE:
            continue
        attrs = ev.get("attributes") or {}
        if attrs.get("_contract_address") != MIXNET_CONTRACT:
            continue

        try:
            node_id = int(attrs.get("node_id") or 0)
            epoch = int(attrs.get("interval_details") or 0)

            prior_delegates = Decimal(attrs.get("prior_delegates") or "0")
            delegates_reward = Decimal(attrs.get("delegates_reward") or "0")
            operator_reward = Decimal(attrs.get("operator_reward") or "0")

            msg_index = int(attrs.get("msg_index") or -1)
        except Exception:
            continue

        out.append(
            {
                "node_id": node_id,
                "epoch": epoch,
                "height": height,
                "txhash": txhash,
                "timestamp": timestamp,
                "msg_index": msg_index,
                # store as strings for stable csv roundtrips
                "prior_delegates_unym": str(prior_delegates),
                "delegates_reward_unym": str(delegates_reward),
                "operator_reward_unym": str(operator_reward),
            }
        )

    return out


def scan_reward_events(session, start_height: int, end_height: int) -> pd.DataFrame:
    """
    Scan reward events in [start_height, end_height], windowed by HEIGHT_WINDOW_SIZE.
    Canonicalizes to one row per (node_id, epoch).
    """
    rows: list[dict[str, Any]] = []
    h_end = int(end_height)
    total_h = max(0, h_end - int(start_height) + 1)

    pbar = tqdm(total=total_h, desc="scan reward windows", unit="height")
    while h_end >= start_height:
        h_start = max(int(start_height), h_end - HEIGHT_WINDOW_SIZE + 1)
        query = reward_query_window(h_start, h_end)

        txs = tx_search_all_pages(
            session,
            nyx_tx_rest=NYX_TX_REST,
            query=query,
            page_size=TX_PAGE_SIZE,
            max_pages=TX_MAX_PAGES,
            timeout=HTTP_TIMEOUT_S,
            strict=False,
        )
        for txr in txs:
            rows.extend(extract_reward_rows(txr))

        pbar.update(h_end - h_start + 1)
        h_end = h_start - 1

    pbar.close()

    if not rows:
        return pd.DataFrame(
            columns=[
                "node_id",
                "epoch",
                "height",
                "txhash",
                "timestamp",
                "msg_index",
                "prior_delegates_unym",
                "delegates_reward_unym",
                "operator_reward_unym",
            ]
        )

    df = pd.DataFrame(rows).drop_duplicates(subset=["node_id", "epoch", "height", "txhash", "msg_index"])

    # normalize dtypes
    df["node_id"] = pd.to_numeric(df["node_id"], errors="coerce").astype("Int64")
    df["epoch"] = pd.to_numeric(df["epoch"], errors="coerce").astype("Int64")
    df["height"] = pd.to_numeric(df["height"], errors="coerce").astype("Int64")
    df["msg_index"] = pd.to_numeric(df["msg_index"], errors="coerce").astype("Int64")
    df = df.dropna(subset=["node_id", "epoch", "height"]).copy()

    # canonical per (node_id, epoch): smallest (height, msg_index, txhash)
    df = df.sort_values(["node_id", "epoch", "height", "msg_index", "txhash"])
    df = df.drop_duplicates(subset=["node_id", "epoch"], keep="first").reset_index(drop=True)
    return df
```


```python
DECIMAL_TEXT_COLS = ["prior_delegates_unym", "delegates_reward_unym", "operator_reward_unym"]

def _load_rewards_cache() -> pd.DataFrame:
    if CACHE_REWARDS_CSV.exists():
        return pd.read_csv(
            CACHE_REWARDS_CSV,
            dtype={
                "node_id": "Int64",
                "epoch": "Int64",
                "height": "Int64",
                "msg_index": "Int64",
                "txhash": "string",
                "timestamp": "string",
                "prior_delegates_unym": "string",
                "delegates_reward_unym": "string",
                "operator_reward_unym": "string",
            },
        )
    raise FileNotFoundError("No reward cache found")

if CACHE_REWARDS_CSV.exists() and not FORCE_RESCAN:
    rewards = _load_rewards_cache()
    logger.info("Loaded cached rewards: %s rows", len(rewards))
else:
    rewards = scan_reward_events(session, start_height=start_height, end_height=latest_height)
    logger.info("Scanned rewards: %s rows", len(rewards))
    rewards.to_csv(CACHE_REWARDS_CSV, index=False)
    logger.info("Wrote cache: %s", CACHE_REWARDS_CSV)

# Verify: decimals survived roundtrip as plain strings (no scientific notation)
for c in DECIMAL_TEXT_COLS:
    rewards[c] = rewards[c].astype(str)
    assert (~rewards[c].str.contains(r"e\+|e-", case=False, regex=True)).all(), f"{c} contains scientific notation"

assert not rewards.empty, "No reward events found in scan window."
print(len(rewards))
rewards.head()
```

    INFO Loaded cached rewards: 28800 rows


    28800





<div>
<style scoped>
    .dataframe tbody tr th:only-of-type {
        vertical-align: middle;
    }

    .dataframe tbody tr th {
        vertical-align: top;
    }

    .dataframe thead th {
        text-align: right;
    }
</style>
<table border="1" class="dataframe">
  <thead>
    <tr style="text-align: right;">
      <th></th>
      <th>node_id</th>
      <th>epoch</th>
      <th>height</th>
      <th>txhash</th>
      <th>timestamp</th>
      <th>msg_index</th>
      <th>prior_delegates_unym</th>
      <th>delegates_reward_unym</th>
      <th>operator_reward_unym</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <th>0</th>
      <td>5</td>
      <td>28316</td>
      <td>22296873</td>
      <td>06B32C73F11786AD89CB70BE42C54BF02CAE7D866F6EF4...</td>
      <td>2026-02-07T14:26:43Z</td>
      <td>0</td>
      <td>199828135817.617679863612881728</td>
      <td>9858268.188210850434496251</td>
      <td>4312355.024213485903426761</td>
    </tr>
    <tr>
      <th>1</th>
      <td>5</td>
      <td>28320</td>
      <td>22299397</td>
      <td>FA04DBEA1DD671E157354A27C3F4E59AB8E9FC5AD99D20...</td>
      <td>2026-02-07T18:26:42Z</td>
      <td>0</td>
      <td>199837994085.805890714047377979</td>
      <td>9858805.793093700779222767</td>
      <td>4312764.680060223219625242</td>
    </tr>
    <tr>
      <th>2</th>
      <td>5</td>
      <td>28322</td>
      <td>22300663</td>
      <td>267FFD30FBEB2372C575C45DFBDAA985AB1438FE6AD1BB...</td>
      <td>2026-02-07T20:26:42Z</td>
      <td>0</td>
      <td>199847852891.598984414826600746</td>
      <td>9859343.434066008468098728</td>
      <td>4313174.373777645492685154</td>
    </tr>
    <tr>
      <th>3</th>
      <td>5</td>
      <td>28323</td>
      <td>22301297</td>
      <td>AFE2CCCCE4B42FC7FADF96764EC3A82A42561606971599...</td>
      <td>2026-02-07T21:26:39Z</td>
      <td>0</td>
      <td>199857712235.033050423294699474</td>
      <td>9859881.111131074837276682</td>
      <td>4313584.105369752490551158</td>
    </tr>
    <tr>
      <th>4</th>
      <td>5</td>
      <td>28324</td>
      <td>22301932</td>
      <td>AFE4B25B33D3945120C30582DC6C12C874A571F983BBEE...</td>
      <td>2026-02-07T22:26:40Z</td>
      <td>0</td>
      <td>199867572116.144181498131976156</td>
      <td>9860418.824292197025336139</td>
      <td>4313993.874840542511989329</td>
    </tr>
  </tbody>
</table>
</div>



## Verify: epoch grid and scan completeness

A good sanity check is:

- every epoch in the window has the same number of reward rows
- epochs are consecutive (no missing epochs)
- timestamps are monotonic by epoch

For Nyx mainnet today, “reward rows per epoch” should match the rewarded set size (often 240).



```python
# verify + derive annualization base
```


```python
rewards["ts"] = pd.to_datetime(rewards["timestamp"], utc=True, errors="coerce")
rewards = rewards.dropna(subset=["ts"]).copy()

rewards["epoch"] = pd.to_numeric(rewards["epoch"], errors="coerce").astype("Int64")
rewards["node_id"] = pd.to_numeric(rewards["node_id"], errors="coerce").astype("Int64")
rewards = rewards.dropna(subset=["epoch", "node_id"]).copy()

epochs = sorted(rewards["epoch"].astype(int).unique().tolist())
n_epochs_total = len(epochs)
assert n_epochs_total > 0

count_per_epoch = rewards.groupby("epoch", as_index=True).size().sort_index()
rewarded_nodes_per_epoch = int(count_per_epoch.mode().iloc[0])

assert (count_per_epoch == rewarded_nodes_per_epoch).all(), "Not all epochs have same reward row count"
assert epochs[-1] - epochs[0] + 1 == n_epochs_total, "Epochs are not consecutive in window"

epoch_times = rewards.groupby("epoch", as_index=False)["ts"].min().sort_values("epoch")
assert epoch_times["epoch"].is_monotonic_increasing
assert epoch_times["ts"].is_monotonic_increasing

epoch_seconds = float(epoch_times["ts"].diff().dt.total_seconds().median())
if not np.isfinite(epoch_seconds) or epoch_seconds <= 0:
    epoch_seconds = 3600.0  # fallback

epochs_per_year = (365.0 * 24.0 * 3600.0) / epoch_seconds
window_hours_observed = (epoch_times["ts"].max() - epoch_times["ts"].min()).total_seconds() / 3600.0

print("unique epochs in window =", n_epochs_total)
print("reward rows per epoch   =", rewarded_nodes_per_epoch)
print("median epoch_seconds    =", epoch_seconds)
print("epochs_per_year         =", epochs_per_year)
print("observed window hours   =", window_hours_observed)

assert rewarded_nodes_per_epoch > 0
assert 100 <= n_epochs_total <= 200  # expected ~120 for a 120h window
```

    unique epochs in window = 120
    reward rows per epoch   = 240
    median epoch_seconds    = 3600.0
    epochs_per_year         = 8760.0
    observed window hours   = 119.00138888888888


## Fetch saturation point (`stake_saturation_point`)

We query the mixnet contract:

- `get_rewarding_params` → contains `stake_saturation_point`

We use a recursive JSON search to avoid coupling to response nesting details.



```python
def find_key_recursive(obj: Any, key: str, out: list[Any]) -> None:
    if isinstance(obj, dict):
        for k, v in obj.items():
            if k == key:
                out.append(v)
            find_key_recursive(v, key, out)
    elif isinstance(obj, list):
        for v in obj:
            find_key_recursive(v, key, out)


def fetch_saturation_point_unym(session) -> Decimal:
    js = smart_query(
        session,
        nyx_wasm_rest=NYX_WASM_REST,
        contract=MIXNET_CONTRACT,
        payload={"get_rewarding_params": {}},
        timeout=HTTP_TIMEOUT_S,
    )
    vals: list[Any] = []
    find_key_recursive(js, "stake_saturation_point", vals)
    if not vals:
        raise RuntimeError("stake_saturation_point not found in get_rewarding_params response")
    v = vals[0]
    if isinstance(v, dict) and "amount" in v:
        return Decimal(str(v["amount"]))
    return Decimal(str(v))
```


```python
sat_unym = fetch_saturation_point_unym(session)
sat_nym = sat_unym / MICRO

print("stake_saturation_point (NYM) =", float(sat_nym))
assert sat_unym > 0
```

    stake_saturation_point (NYM) = 253163.71870024785


## Historical role assignment reconstruction

Goal: label each **reward row** `(epoch, node_id)` as:

- `entry-gateway` (role `entry_gateway`)
- `exit-gateway` (role `exit_gateway`)
- `mixnode` (roles `layer1`, `layer2`, `layer3`)

We reconstruct this from **historical** tx payloads:

- Tx search for `wasm-v2_role_assignment` events (contract-indexed)
- Decode execute-contract messages to read `assign_roles.assignment`
- Use `wasm-v2_advance_epoch` event to identify which epoch the assignment belongs to

We then join these assignments back to reward rows.

Important nuance: the “epoch id” in role assignment txs may be offset vs the reward event’s `interval_details`.
We detect the offset empirically by matching node-id sets.



```python
def tx_search_pages_with_txs(
    session,
    query: str,
    page_size: int = TX_PAGE_SIZE,
    max_pages: int = TX_MAX_PAGES,
    order_by: str = "ORDER_BY_DESC",
) -> list[dict[str, Any]]:
    """
    Cosmos tx search that returns BOTH `txs` and `tx_responses` per result row.

    We paginate using `pagination.next_key` (not offset) to be robust.
    """
    out: list[dict[str, Any]] = []
    page_key: str | None = None

    for _ in range(max_pages):
        params = {
            "query": query,
            "pagination.limit": str(page_size),
            "order_by": order_by,
        }
        if page_key:
            params["pagination.key"] = page_key

        js = request_json(session, NYX_TX_REST, params=params, timeout=HTTP_TIMEOUT_S)
        txs = js.get("txs") or []
        txrs = js.get("tx_responses") or []
        next_key = (js.get("pagination") or {}).get("next_key")

        n = min(len(txs), len(txrs))
        for i in range(n):
            out.append({"tx": txs[i], "tx_response": txrs[i]})

        if not next_key:
            break
        page_key = next_key

    return out


def decode_wasm_msg_field(msg_field: Any) -> dict[str, Any]:
    """
    Robustly decode CosmWasm MsgExecuteContract `msg`:
    - if already dict: return as-is
    - if base64 string: decode + json.loads
    - else: return {}
    """
    if isinstance(msg_field, dict):
        return msg_field
    if isinstance(msg_field, str):
        try:
            raw = base64.b64decode(msg_field)
            return json.loads(raw.decode("utf-8"))
        except Exception:
            return {}
    return {}
```


```python
# Use: do a small recent window query for role assignments to prove shapes
sample_rows= []
h_end = latest_height
h_start = start_height
h_mid = (start_height + latest_height) // 2

q = (
    f"tx.height>={h_start} AND tx.height<={h_mid} "
    f"AND {ROLE_ASSIGN_EVENT_TYPE}._contract_address='{MIXNET_CONTRACT}'"
)

sample_rows += tx_search_pages_with_txs(session, q, page_size=500, max_pages=10)

q = (
    f"tx.height>={h_mid} AND tx.height<={h_end} "
    f"AND {ROLE_ASSIGN_EVENT_TYPE}._contract_address='{MIXNET_CONTRACT}'"
)

sample_rows += tx_search_pages_with_txs(session, q, page_size=500, max_pages=10)

print("sample role-assignment tx rows:", len(sample_rows))

# Verify: response shape
if sample_rows:
    assert "tx" in sample_rows[0] and "tx_response" in sample_rows[0]
```

    sample role-assignment tx rows: 120


## Parsing role assignment txs

We extract:

- `assignment_epoch`: from the `wasm-v2_advance_epoch` event attribute `new_current_epoch`
- `by_role`: from decoded execute msg payload `assign_roles.assignment`

This yields a mapping:
`role_assign_history[assignment_epoch][role] = [node_ids...]`

Roles we care about:
- `entry_gateway`, `exit_gateway`, `layer1`, `layer2`, `layer3`



```python
ACTIVE_ROLE_KEYS = ["entry_gateway", "exit_gateway", "layer1", "layer2", "layer3"]

def normalize_contract_role(raw_role: str | None) -> str | None:
    if raw_role is None:
        return None
    m = {
        "eg": "entry_gateway",
        "entry_gateway": "entry_gateway",
        "entry": "entry_gateway",
        "xg": "exit_gateway",
        "exit_gateway": "exit_gateway",
        "exit": "exit_gateway",
        "l1": "layer1",
        "layer1": "layer1",
        "l2": "layer2",
        "layer2": "layer2",
        "l3": "layer3",
        "layer3": "layer3",
        "standby": "standby",
        "stb": "standby",
    }
    return m.get(str(raw_role).strip().lower())


def extract_assignment_epoch(txr: dict[str, Any]) -> int | None:
    for ev in extract_events(txr):
        if ev.get("type") != ADVANCE_EPOCH_EVENT_TYPE:
            continue
        attrs = ev.get("attributes") or {}
        if attrs.get("_contract_address") != MIXNET_CONTRACT:
            continue
        v = attrs.get("new_current_epoch")
        try:
            return int(v)
        except Exception:
            return None
    return None


def parse_assign_roles_from_tx(tx: dict[str, Any]) -> dict[str, list[int]]:
    """
    From tx body messages, decode wasm msg payload and extract assign_roles assignments.
    Returns role->sorted(node_ids) for roles present in this tx.
    """
    by_role: dict[str, set[int]] = {}

    msgs = ((tx.get("body") or {}).get("messages") or [])
    for msg in msgs:
        # depending on encoding, this may be raw dict or base64 string
        msg_payload = decode_wasm_msg_field(msg.get("msg"))
        assign = (((msg_payload.get("assign_roles") or {}).get("assignment")) or {})
        if not assign:
            continue

        role_norm = normalize_contract_role(assign.get("role"))
        if not role_norm:
            continue

        nodes_raw = assign.get("nodes") or []
        s: set[int] = set()
        for n in nodes_raw:
            try:
                s.add(int(n))
            except Exception:
                continue

        if s:
            by_role.setdefault(role_norm, set()).update(s)

    return {k: sorted(v) for k, v in by_role.items()}
```


```python
if sample_rows:
    tx = sample_rows[0]["tx"]
    txr = sample_rows[0]["tx_response"]

    ep = extract_assignment_epoch(txr)
    by_role = parse_assign_roles_from_tx(tx)

    print("assignment_epoch:", ep)
    print("roles parsed:", sorted(by_role.keys()))

    # Verify minimal expectations (may be empty if sample window had none)
    if by_role:
        assert all(isinstance(v, list) for v in by_role.values())

```

    assignment_epoch: 28375
    roles parsed: ['entry_gateway', 'exit_gateway', 'layer1', 'layer2', 'layer3']


## Scan role assignments for the full analysis window

We scan `wasm-v2_role_assignment` txs across the same height window as rewards.
Then we run hard integrity checks:

For each assignment epoch we expect:

- all active roles present: entry/exit/layer1/layer2/layer3
- total nodes across roles == `rewarded_nodes_per_epoch` (typically 240)
- no duplicates across roles (union size == total size)



```python
def role_assignment_query_window(h_start: int, h_end: int) -> str:
    return (
        f"tx.height>={int(h_start)} AND tx.height<={int(h_end)} "
        f"AND {ROLE_ASSIGN_EVENT_TYPE}._contract_address='{MIXNET_CONTRACT}'"
    )


def scan_role_assignments(session, start_height: int, end_height: int) -> dict[int, dict[str, list[int]]]:
    """
    Returns: {assignment_epoch: {role: [node_ids...]}}
    """
    out: dict[int, dict[str, list[int]]] = {}

    h_end = int(end_height)
    while h_end >= start_height:
        h_start = max(int(start_height), h_end - HEIGHT_WINDOW_SIZE + 1)
        query = role_assignment_query_window(h_start, h_end)

        tx_rows = tx_search_pages_with_txs(session, query, page_size=TX_PAGE_SIZE, max_pages=TX_MAX_PAGES)
        for item in tx_rows:
            tx = item["tx"]
            txr = item["tx_response"]

            assignment_epoch = extract_assignment_epoch(txr)
            by_role = parse_assign_roles_from_tx(tx)

            if assignment_epoch is None or not by_role:
                continue
            out[int(assignment_epoch)] = by_role

        h_end = h_start - 1

    return out

if CACHE_ROLE_HISTORY_JSON.exists() and not FORCE_RESCAN:
    role_assign_history = {int(k): v for k, v in json.loads(CACHE_ROLE_HISTORY_JSON.read_text()).items()}
    logger.info("Loaded cached role assignments: %s epochs", len(role_assign_history))
else:
    scan_safety_buffer = 5000
    role_assign_history = scan_role_assignments(session, start_height=start_height - scan_safety_buffer, end_height=latest_height)
    CACHE_ROLE_HISTORY_JSON.write_text(json.dumps({str(k): v for k, v in role_assign_history.items()}))
    logger.info("Scanned role assignments: %s epochs", len(role_assign_history))

assert len(role_assign_history) > 0, "No role assignment epochs found."

# Integrity check: each epoch’s union size should match reward rows per epoch
bad = []
for ep, by_role in role_assign_history.items():
    # roles may be missing on partial epochs; we only validate epochs in-range later
    if not all(rk in by_role for rk in ACTIVE_ROLE_KEYS):
        continue

    all_nodes: list[int] = []
    for rk in ACTIVE_ROLE_KEYS:
        all_nodes.extend([int(x) for x in (by_role.get(rk) or [])])

    if len(all_nodes) != rewarded_nodes_per_epoch or len(set(all_nodes)) != rewarded_nodes_per_epoch:
        bad.append(ep)

print("role assignment epochs cached:", len(role_assign_history))
print("epochs failing union-size checks (subset):", bad[:10])
```

    INFO Loaded cached role assignments: 128 epochs


    role assignment epochs cached: 128
    epochs failing union-size checks (subset): []


## Reward epoch ↔ assignment epoch offset

Reward events carry an `epoch` id (`interval_details`).
Role assignment txs carry `new_current_epoch` in the `wasm-v2_advance_epoch` event.

These two epoch identifiers may be offset by 1 (or occasionally more) depending on when roles are assigned relative to reward distribution.

We detect the offset by comparing sets:

- reward_set[e] = {node_ids rewarded in epoch e} (from reward events)
- role_set[k] = {node_ids assigned for epoch k} (union across active roles)

We pick the offset that maximizes average Jaccard similarity between reward_set[e] and role_set[e + offset].



```python
def jaccard(a: set[int], b: set[int]) -> float:
    if not a and not b:
        return 1.0
    if not a or not b:
        return 0.0
    return len(a & b) / float(len(a | b))


def derive_epoch_offset(
    rewards: pd.DataFrame,
    role_assign_history: dict[int, dict[str, list[int]]],
    candidate_offsets: Iterable[int] = (-2, -1, 0, 1, 2),
) -> tuple[int, pd.DataFrame]:
    reward_set = {
        int(ep): set(map(int, rewards.loc[rewards["epoch"].astype(int) == int(ep), "node_id"].astype(int).tolist()))
        for ep in sorted(rewards["epoch"].astype(int).unique().tolist())
    }

    role_set = {}
    for ep, by_role in role_assign_history.items():
        # only consider epochs with all active roles
        if not all(rk in by_role for rk in ACTIVE_ROLE_KEYS):
            continue
        s: set[int] = set()
        for rk in ACTIVE_ROLE_KEYS:
            s |= set(map(int, by_role.get(rk) or []))
        role_set[int(ep)] = s

    rows = []
    for off in candidate_offsets:
        sims = []
        exact = 0
        used = 0
        for ep in reward_set:
            rs = reward_set[ep]
            ts = role_set.get(ep + off)
            if ts is None:
                continue
            used += 1
            sim = jaccard(rs, ts)
            sims.append(sim)
            if sim == 1.0:
                exact += 1
        rows.append(
            {
                "offset": off,
                "epochs_compared": used,
                "avg_jaccard": float(np.mean(sims)) if sims else 0.0,
                "exact_match_frac": (exact / used) if used else 0.0,
            }
        )

    df = pd.DataFrame(rows).sort_values(["avg_jaccard", "exact_match_frac"], ascending=False).reset_index(drop=True)
    best = int(df.iloc[0]["offset"])
    return best, df
```


```python
offset, offset_table = derive_epoch_offset(rewards, role_assign_history)
offset_table
```




<div>
<style scoped>
    .dataframe tbody tr th:only-of-type {
        vertical-align: middle;
    }

    .dataframe tbody tr th {
        vertical-align: top;
    }

    .dataframe thead th {
        text-align: right;
    }
</style>
<table border="1" class="dataframe">
  <thead>
    <tr style="text-align: right;">
      <th></th>
      <th>offset</th>
      <th>epochs_compared</th>
      <th>avg_jaccard</th>
      <th>exact_match_frac</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <th>0</th>
      <td>0</td>
      <td>120</td>
      <td>1.000000</td>
      <td>1.0</td>
    </tr>
    <tr>
      <th>1</th>
      <td>1</td>
      <td>120</td>
      <td>0.332530</td>
      <td>0.0</td>
    </tr>
    <tr>
      <th>2</th>
      <td>-1</td>
      <td>120</td>
      <td>0.331187</td>
      <td>0.0</td>
    </tr>
    <tr>
      <th>3</th>
      <td>2</td>
      <td>119</td>
      <td>0.329007</td>
      <td>0.0</td>
    </tr>
    <tr>
      <th>4</th>
      <td>-2</td>
      <td>120</td>
      <td>0.328060</td>
      <td>0.0</td>
    </tr>
  </tbody>
</table>
</div>




```python
print("derived epoch offset =", offset)

# Verify we have meaningful signal
best_row = offset_table.iloc[0]
assert best_row["epochs_compared"] >= n_epochs_total * 0.5
assert best_row["avg_jaccard"] > 0.95, "Offset match is weak; role parsing may be incomplete"
```

    derived epoch offset = 0


## Join role assignment to reward rows

We build a lookup:

- `role_of(assignment_epoch, node_id) -> role_key`

Then for each reward row `(reward_epoch, node_id)` we map:

- `assignment_epoch = reward_epoch + offset`
- `role_key = role_of(assignment_epoch, node_id)`
- `node_type = entry-gateway / exit-gateway / mixnode`

We **assert** that every reward row can be classified.
If this assert fails, we fix the role assignment parsing rather than “fallback to explorers”.


```python
ROLE_TO_TYPE = {
    "entry_gateway": "entry-gateway",
    "exit_gateway": "exit-gateway",
    "layer1": "mixnode",
    "layer2": "mixnode",
    "layer3": "mixnode",
}

# (assignment_epoch, node_id) -> role_key
role_lookup: dict[tuple[int, int], str] = {}
for ep, by_role in role_assign_history.items():
    if not all(rk in by_role for rk in ACTIVE_ROLE_KEYS):
        continue
    for rk in ACTIVE_ROLE_KEYS:
        for nid in by_role.get(rk, []):
            role_lookup[(int(ep), int(nid))] = rk

work = rewards.copy()
work["assignment_epoch"] = work["epoch"].astype(int) + int(offset)
work["role_key"] = work.apply(lambda r: role_lookup.get((int(r["assignment_epoch"]), int(r["node_id"]))), axis=1)
work["node_type_row"] = work["role_key"].map(lambda k: ROLE_TO_TYPE.get(str(k), "unknown"))

missing = int((work["node_type_row"] == "unknown").sum())
print("untyped reward rows =", missing)

# Verify: we can type all reward rows
assert missing == 0, "Some reward rows could not be typed from on-chain role history"
```

    untyped reward rows = 0


## Pledge proxy for total-bond denominator

The reward event contains `prior_delegates` but not the operator stake snapshot.
To estimate total-bond return we add a pledge proxy:

- `pledge_proxy = get_nym_node_details → bond_information.original_pledge.amount`

This is **current-state** and not an historical per-epoch operator stake.
It is still useful as a stable proxy to avoid the “numerator includes operator_reward but denominator excludes operator stake” bias.



```python
def parse_original_pledge_unym(details_js: dict[str, Any]) -> Decimal:
    data = details_js.get("data") or details_js
    details = data.get("details") or data.get("node_details") or data
    bond = details.get("bond_information") or {}
    op = bond.get("original_pledge") or {}
    if isinstance(op, dict) and "amount" in op:
        return Decimal(str(op["amount"]))
    return Decimal(0)


def fetch_pledge_proxy_unym(session, node_id: int) -> Decimal:
    js = smart_query(
        session,
        nyx_wasm_rest=NYX_WASM_REST,
        contract=MIXNET_CONTRACT,
        payload={"get_nym_node_details": {"node_id": int(node_id)}},
        timeout=HTTP_TIMEOUT_S,
    )
    return parse_original_pledge_unym(js)
```


```python
node_ids = sorted(work["node_id"].astype(int).unique().tolist())
print("unique nodes in window:", len(node_ids))

if CACHE_PLEDGE_PROXY_JSON.exists() and not FORCE_RESCAN:
    pledge_proxy_map = {int(k): str(v) for k, v in json.loads(CACHE_PLEDGE_PROXY_JSON.read_text()).items()}
    logger.info("Loaded cached pledge proxies: %s", len(pledge_proxy_map))
else:
    pledge_proxy_map = {}

missing = [nid for nid in node_ids if nid not in pledge_proxy_map]
print("missing pledge proxies:", len(missing))

def _fetch_one(nid: int) -> tuple[int, str]:
    s = build_session("node-interest-pledge/1.0")
    try:
        v = fetch_pledge_proxy_unym(s, nid)
        return nid, str(v)
    except Exception:
        return nid, "0"

if missing:
    with ThreadPoolExecutor(max_workers=8) as ex:
        futs = [ex.submit(_fetch_one, nid) for nid in missing]
        for fut in tqdm(as_completed(futs), total=len(futs), desc="fetch pledge proxy"):
            nid, v = fut.result()
            pledge_proxy_map[int(nid)] = str(v)

    CACHE_PLEDGE_PROXY_JSON.write_text(json.dumps({str(k): v for k, v in pledge_proxy_map.items()}))
    logger.info("Wrote pledge proxy cache: %s", CACHE_PLEDGE_PROXY_JSON)

# Verify: every node has a pledge proxy entry (may be "0" if errors)
assert all(nid in pledge_proxy_map for nid in node_ids)

# quick inspection
sample = node_ids[:5]
print({nid: pledge_proxy_map[nid] for nid in sample})
```

    INFO Loaded cached pledge proxies: 589


    unique nodes in window: 589
    missing pledge proxies: 0
    {5: '28752403445', 8: '4999999983', 9: '121000045', 14: '266408785', 21: '1275221138'}


## Row-level returns

We compute two per-epoch returns per reward row:

- **delegator-only:**

$$
r_d = \frac{delegates\_reward}{prior\_delegates}
$$

- **total-bond proxy:**

$$
r_t \approx 
\frac{delegates\_reward + operator\_reward}
{prior\_delegates + pledge\_proxy}
$$

We keep everything as `Decimal` until we need arrays for NumPy (then convert to `float`).


```python
def dec_series(s: pd.Series) -> pd.Series:
    return s.fillna("0").astype(str).map(lambda x: Decimal(x) if x else Decimal(0))

work["prior_delegates_d"] = dec_series(work["prior_delegates_unym"])
work["delegates_reward_d"] = dec_series(work["delegates_reward_unym"])
work["operator_reward_d"] = dec_series(work["operator_reward_unym"])

work["total_reward_d"] = work["delegates_reward_d"] + work["operator_reward_d"]

work["pledge_proxy_d"] = work["node_id"].astype(int).map(lambda nid: Decimal(str(pledge_proxy_map.get(int(nid), "0"))))
work["stake_total_proxy_d"] = work["prior_delegates_d"] + work["pledge_proxy_d"]

work["ret_delegator"] = work.apply(
    lambda r: (r["delegates_reward_d"] / r["prior_delegates_d"]) if r["prior_delegates_d"] > 0 else Decimal(0),
    axis=1,
)

work["ret_total_bond_proxy"] = work.apply(
    lambda r: (r["total_reward_d"] / r["stake_total_proxy_d"]) if r["stake_total_proxy_d"] > 0 else Decimal(0),
    axis=1,
)

# Verify basic constraints
assert (work["ret_delegator"] >= 0).all()
assert (work["ret_total_bond_proxy"] >= 0).all()

work[["node_id", "epoch", "node_type_row", "ret_delegator", "ret_total_bond_proxy"]].head()
```




<div>
<style scoped>
    .dataframe tbody tr th:only-of-type {
        vertical-align: middle;
    }

    .dataframe tbody tr th {
        vertical-align: top;
    }

    .dataframe thead th {
        text-align: right;
    }
</style>
<table border="1" class="dataframe">
  <thead>
    <tr style="text-align: right;">
      <th></th>
      <th>node_id</th>
      <th>epoch</th>
      <th>node_type_row</th>
      <th>ret_delegator</th>
      <th>ret_total_bond_proxy</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <th>0</th>
      <td>5</td>
      <td>28316</td>
      <td>mixnode</td>
      <td>0.00004933373445073045862076641506204409059694...</td>
      <td>0.00006199400551830711381450187238083265221772...</td>
    </tr>
    <tr>
      <th>1</th>
      <td>5</td>
      <td>28320</td>
      <td>mixnode</td>
      <td>0.00004933399095699766553240533275662162905134...</td>
      <td>0.00006199547586527162911371677099972872057392...</td>
    </tr>
    <tr>
      <th>2</th>
      <td>5</td>
      <td>28322</td>
      <td>mixnode</td>
      <td>0.00004933424748583058832607549300774986548895...</td>
      <td>0.00006199694626315529940519939361317661759676...</td>
    </tr>
    <tr>
      <th>3</th>
      <td>5</td>
      <td>28323</td>
      <td>mixnode</td>
      <td>0.00004933450403723142723802337955442806446372...</td>
      <td>0.00006199841671196331312714162064128490588746...</td>
    </tr>
    <tr>
      <th>4</th>
      <td>5</td>
      <td>28324</td>
      <td>mixnode</td>
      <td>0.00004933476061120235970416331324848999447425...</td>
      <td>0.00006199988721170083049365701976567602428010...</td>
    </tr>
  </tbody>
</table>
</div>



## Per-node aggregation

For each node we build a per-epoch return series of length `n_epochs_total`:

- if the node is rewarded in epoch `e`: use the event return for that epoch
- else: return is 0 (zero-filled)

Then:

- `APR_simple = mean_zero_arith * epochs_per_year`
- `APY_eff = exp(mean(log1p(ret_zero)) * epochs_per_year) - 1`

We also compute stake-weighted mean returns across rewarded epochs:
- `sum(reward) / sum(stake)`



```python
def median_decimal(vals: list[Decimal]) -> Decimal:
    if not vals:
        return Decimal(0)
    s = sorted(vals)
    n = len(s)
    mid = n // 2
    if n % 2:
        return s[mid]
    return (s[mid - 1] + s[mid]) / Decimal(2)


first_epoch = int(min(epochs))
last_epoch = int(max(epochs))

rows = []
for nid, g in work.groupby("node_id"):
    nid = int(nid)
    rewarded_epochs = sorted(int(e) for e in g["epoch"].astype(int).tolist())
    n_reward_epochs = len(set(rewarded_epochs))
    active_set_pct = n_reward_epochs / float(n_epochs_total)

    # epoch->return maps (rewarded only)
    rd = {int(r.epoch): float(r.ret_delegator) for r in g[["epoch", "ret_delegator"]].itertuples(index=False)}
    rt = {int(r.epoch): float(r.ret_total_bond_proxy) for r in g[["epoch", "ret_total_bond_proxy"]].itertuples(index=False)}

    # zero-filled arrays
    rd0 = np.array([rd.get(ep, 0.0) for ep in epochs], dtype=float)
    rt0 = np.array([rt.get(ep, 0.0) for ep in epochs], dtype=float)

    # arithmetic / geometric means
    mean_zero_arith_delegator = float(np.mean(rd0)) if len(rd0) else 0.0
    mean_zero_arith_total = float(np.mean(rt0)) if len(rt0) else 0.0

    mean_zero_log_delegator = float(np.mean(np.log1p(rd0))) if len(rd0) else 0.0
    mean_zero_log_total = float(np.mean(np.log1p(rt0))) if len(rt0) else 0.0

    apr_simple_delegator = mean_zero_arith_delegator * epochs_per_year
    apr_simple_total = mean_zero_arith_total * epochs_per_year

    apy_eff_delegator = math.expm1(mean_zero_log_delegator * epochs_per_year)
    apy_eff_total = math.expm1(mean_zero_log_total * epochs_per_year)

    # stake-weighted mean over rewarded epochs
    sum_delegates_reward = sum(g["delegates_reward_d"]) if len(g) else Decimal(0)
    sum_total_reward = sum(g["total_reward_d"]) if len(g) else Decimal(0)

    sum_prior_delegates = sum(g["prior_delegates_d"]) if len(g) else Decimal(0)
    sum_total_stake = sum(g["stake_total_proxy_d"]) if len(g) else Decimal(0)

    mean_rewarded_weighted_delegator = float(sum_delegates_reward / sum_prior_delegates) if sum_prior_delegates > 0 else 0.0
    mean_rewarded_weighted_total = float(sum_total_reward / sum_total_stake) if sum_total_stake > 0 else 0.0

    # role history counts
    role_counts = g["role_key"].value_counts().to_dict()
    entry_epochs = int(role_counts.get("entry_gateway", 0))
    exit_epochs = int(role_counts.get("exit_gateway", 0))
    mix_epochs = int(role_counts.get("layer1", 0) + role_counts.get("layer2", 0) + role_counts.get("layer3", 0))

    # primary node type by majority of rewarded epochs
    if exit_epochs>0:
        node_type = "exit-gateway"
    elif entry_epochs >0:
        node_type = "entry-gateway"
    else:
        node_type = "mixnode"
    # if max(entry_epochs, exit_epochs, mix_epochs) == entry_epochs:
    #     node_type = "entry-gateway"
    # elif max(entry_epochs, exit_epochs, mix_epochs) == exit_epochs:
    #     node_type = "exit-gateway"
    # else:
    #     node_type = "mixnode"

    node_type_changed = sum(1 for v in [entry_epochs, exit_epochs, mix_epochs] if v > 0) > 1
    node_role_history = f"entry_gateway:{entry_epochs};exit_gateway:{exit_epochs};mixnode:{mix_epochs}"

    # stake stats (delegates and total proxy)
    min_delegates = min(g["prior_delegates_d"]) if len(g) else Decimal(0)
    med_delegates = median_decimal(list(g["prior_delegates_d"])) if len(g) else Decimal(0)

    min_total_stake = min(g["stake_total_proxy_d"]) if len(g) else Decimal(0)
    med_total_stake = median_decimal(list(g["stake_total_proxy_d"])) if len(g) else Decimal(0)

    rows.append(
        {
            "node_id": nid,
            "node_type": node_type,
            "node_type_changed": bool(node_type_changed),
            "node_role_history": node_role_history,
            "n_reward_epochs": n_reward_epochs,
            "n_epochs_total": n_epochs_total,
            "active_set_pct": active_set_pct,
            # "mean_rewarded_weighted_delegator": mean_rewarded_weighted_delegator,
            # "mean_rewarded_weighted_total_bond_proxy": mean_rewarded_weighted_total,
            "apr_simple_delegator": apr_simple_delegator,
            "apr_simple_total_bond_proxy": apr_simple_total,
            "apy_eff_delegator": apy_eff_delegator,
            "apy_eff_total_bond_proxy": apy_eff_total,
            "sum_total_rewards_nym": float(sum_total_reward / MICRO),
            "min_prior_delegates_nym": float(min_delegates / MICRO),
            # "median_prior_delegates_nym": float(med_delegates / MICRO),
            "min_total_stake_proxy_nym": float(min_total_stake / MICRO),
            # "median_total_stake_proxy_nym": float(med_total_stake / MICRO),
        }
    )

summary = pd.DataFrame(rows).sort_values("apy_eff_total_bond_proxy", ascending=False).reset_index(drop=True)
columns = ['node_id', 'node_type', 'node_type_changed', 'node_role_history', 'active_set_pct', 'apy_eff_delegator', 'apy_eff_total_bond_proxy', 'sum_total_rewards_nym', 'min_prior_delegates_nym', 'min_total_stake_proxy_nym']
summary.head(20)[columns]
```




<div>
<style scoped>
    .dataframe tbody tr th:only-of-type {
        vertical-align: middle;
    }

    .dataframe tbody tr th {
        vertical-align: top;
    }

    .dataframe thead th {
        text-align: right;
    }
</style>
<table border="1" class="dataframe">
  <thead>
    <tr style="text-align: right;">
      <th></th>
      <th>node_id</th>
      <th>node_type</th>
      <th>node_type_changed</th>
      <th>node_role_history</th>
      <th>active_set_pct</th>
      <th>apy_eff_delegator</th>
      <th>apy_eff_total_bond_proxy</th>
      <th>sum_total_rewards_nym</th>
      <th>min_prior_delegates_nym</th>
      <th>min_total_stake_proxy_nym</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <th>0</th>
      <td>1331</td>
      <td>exit-gateway</td>
      <td>True</td>
      <td>entry_gateway:33;exit_gateway:47;mixnode:0</td>
      <td>0.666667</td>
      <td>0.301367</td>
      <td>0.499592</td>
      <td>1033.548239</td>
      <td>183371.651310</td>
      <td>185871.651310</td>
    </tr>
    <tr>
      <th>1</th>
      <td>2581</td>
      <td>exit-gateway</td>
      <td>True</td>
      <td>entry_gateway:38;exit_gateway:35;mixnode:0</td>
      <td>0.608333</td>
      <td>0.305527</td>
      <td>0.491884</td>
      <td>1181.019829</td>
      <td>109581.488867</td>
      <td>210388.488867</td>
    </tr>
    <tr>
      <th>2</th>
      <td>1902</td>
      <td>exit-gateway</td>
      <td>True</td>
      <td>entry_gateway:42;exit_gateway:43;mixnode:0</td>
      <td>0.708333</td>
      <td>0.348409</td>
      <td>0.484888</td>
      <td>1340.865672</td>
      <td>222134.799907</td>
      <td>247134.799907</td>
    </tr>
    <tr>
      <th>3</th>
      <td>2313</td>
      <td>exit-gateway</td>
      <td>True</td>
      <td>entry_gateway:35;exit_gateway:46;mixnode:0</td>
      <td>0.675000</td>
      <td>0.288886</td>
      <td>0.469287</td>
      <td>954.414110</td>
      <td>180573.354303</td>
      <td>180673.354303</td>
    </tr>
    <tr>
      <th>4</th>
      <td>2310</td>
      <td>exit-gateway</td>
      <td>True</td>
      <td>entry_gateway:42;exit_gateway:38;mixnode:0</td>
      <td>0.666667</td>
      <td>0.285728</td>
      <td>0.462510</td>
      <td>944.339184</td>
      <td>180870.462149</td>
      <td>180970.462149</td>
    </tr>
    <tr>
      <th>5</th>
      <td>2650</td>
      <td>exit-gateway</td>
      <td>True</td>
      <td>entry_gateway:40;exit_gateway:46;mixnode:0</td>
      <td>0.716667</td>
      <td>0.314541</td>
      <td>0.460855</td>
      <td>1250.958145</td>
      <td>240000.000000</td>
      <td>240100.000000</td>
    </tr>
    <tr>
      <th>6</th>
      <td>2124</td>
      <td>exit-gateway</td>
      <td>True</td>
      <td>entry_gateway:49;exit_gateway:37;mixnode:0</td>
      <td>0.716667</td>
      <td>0.350050</td>
      <td>0.456468</td>
      <td>1301.917529</td>
      <td>251829.815504</td>
      <td>251929.815504</td>
    </tr>
    <tr>
      <th>7</th>
      <td>2435</td>
      <td>exit-gateway</td>
      <td>True</td>
      <td>entry_gateway:35;exit_gateway:44;mixnode:0</td>
      <td>0.658333</td>
      <td>0.285058</td>
      <td>0.447660</td>
      <td>1014.456955</td>
      <td>198833.343081</td>
      <td>199833.343081</td>
    </tr>
    <tr>
      <th>8</th>
      <td>2803</td>
      <td>exit-gateway</td>
      <td>True</td>
      <td>entry_gateway:38;exit_gateway:46;mixnode:0</td>
      <td>0.700000</td>
      <td>0.338567</td>
      <td>0.445811</td>
      <td>1184.455841</td>
      <td>233715.394870</td>
      <td>233815.394870</td>
    </tr>
    <tr>
      <th>9</th>
      <td>2524</td>
      <td>exit-gateway</td>
      <td>True</td>
      <td>entry_gateway:40;exit_gateway:39;mixnode:0</td>
      <td>0.658333</td>
      <td>0.289076</td>
      <td>0.440824</td>
      <td>1205.033334</td>
      <td>240000.000000</td>
      <td>240100.000000</td>
    </tr>
    <tr>
      <th>10</th>
      <td>2393</td>
      <td>exit-gateway</td>
      <td>True</td>
      <td>entry_gateway:51;exit_gateway:32;mixnode:0</td>
      <td>0.691667</td>
      <td>0.331343</td>
      <td>0.439751</td>
      <td>1253.582033</td>
      <td>249610.317963</td>
      <td>249710.317963</td>
    </tr>
    <tr>
      <th>11</th>
      <td>2320</td>
      <td>exit-gateway</td>
      <td>True</td>
      <td>entry_gateway:29;exit_gateway:49;mixnode:0</td>
      <td>0.650000</td>
      <td>0.288293</td>
      <td>0.435522</td>
      <td>891.520345</td>
      <td>134779.195402</td>
      <td>179779.195402</td>
    </tr>
    <tr>
      <th>12</th>
      <td>2120</td>
      <td>exit-gateway</td>
      <td>True</td>
      <td>entry_gateway:35;exit_gateway:39;mixnode:0</td>
      <td>0.616667</td>
      <td>0.273502</td>
      <td>0.429333</td>
      <td>913.659873</td>
      <td>186307.336371</td>
      <td>186407.336371</td>
    </tr>
    <tr>
      <th>13</th>
      <td>2702</td>
      <td>exit-gateway</td>
      <td>True</td>
      <td>entry_gateway:44;exit_gateway:37;mixnode:0</td>
      <td>0.675000</td>
      <td>0.316048</td>
      <td>0.428287</td>
      <td>1219.330462</td>
      <td>248873.253978</td>
      <td>249273.253978</td>
    </tr>
    <tr>
      <th>14</th>
      <td>2045</td>
      <td>exit-gateway</td>
      <td>True</td>
      <td>entry_gateway:45;exit_gateway:36;mixnode:0</td>
      <td>0.675000</td>
      <td>0.314998</td>
      <td>0.427043</td>
      <td>1074.330637</td>
      <td>220027.398067</td>
      <td>220128.398067</td>
    </tr>
    <tr>
      <th>15</th>
      <td>2782</td>
      <td>exit-gateway</td>
      <td>True</td>
      <td>entry_gateway:33;exit_gateway:48;mixnode:0</td>
      <td>0.675000</td>
      <td>0.323674</td>
      <td>0.426468</td>
      <td>1035.683102</td>
      <td>206993.866747</td>
      <td>207193.866747</td>
    </tr>
    <tr>
      <th>16</th>
      <td>2521</td>
      <td>exit-gateway</td>
      <td>True</td>
      <td>entry_gateway:38;exit_gateway:38;mixnode:0</td>
      <td>0.633333</td>
      <td>0.277045</td>
      <td>0.420134</td>
      <td>1157.137890</td>
      <td>240000.000000</td>
      <td>240100.000000</td>
    </tr>
    <tr>
      <th>17</th>
      <td>2315</td>
      <td>exit-gateway</td>
      <td>True</td>
      <td>entry_gateway:38;exit_gateway:36;mixnode:0</td>
      <td>0.616667</td>
      <td>0.262547</td>
      <td>0.418432</td>
      <td>917.542700</td>
      <td>191134.089768</td>
      <td>191234.089768</td>
    </tr>
    <tr>
      <th>18</th>
      <td>2309</td>
      <td>exit-gateway</td>
      <td>True</td>
      <td>entry_gateway:30;exit_gateway:44;mixnode:0</td>
      <td>0.616667</td>
      <td>0.261681</td>
      <td>0.416647</td>
      <td>892.081078</td>
      <td>186546.288061</td>
      <td>186646.288061</td>
    </tr>
    <tr>
      <th>19</th>
      <td>2542</td>
      <td>exit-gateway</td>
      <td>True</td>
      <td>entry_gateway:42;exit_gateway:41;mixnode:0</td>
      <td>0.691667</td>
      <td>0.317779</td>
      <td>0.415685</td>
      <td>1265.641020</td>
      <td>265185.546447</td>
      <td>265285.546447</td>
    </tr>
  </tbody>
</table>
</div>



**Notice that all top performing nodes are exit-gateway nodes.**

### My Nodes


```python
summary[summary['node_id'].isin([2196, 2933])][columns]
```




<div>
<style scoped>
    .dataframe tbody tr th:only-of-type {
        vertical-align: middle;
    }

    .dataframe tbody tr th {
        vertical-align: top;
    }

    .dataframe thead th {
        text-align: right;
    }
</style>
<table border="1" class="dataframe">
  <thead>
    <tr style="text-align: right;">
      <th></th>
      <th>node_id</th>
      <th>node_type</th>
      <th>node_type_changed</th>
      <th>node_role_history</th>
      <th>active_set_pct</th>
      <th>apy_eff_delegator</th>
      <th>apy_eff_total_bond_proxy</th>
      <th>sum_total_rewards_nym</th>
      <th>min_prior_delegates_nym</th>
      <th>min_total_stake_proxy_nym</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <th>173</th>
      <td>2196</td>
      <td>mixnode</td>
      <td>False</td>
      <td>entry_gateway:0;exit_gateway:0;mixnode:63</td>
      <td>0.525</td>
      <td>0.228747</td>
      <td>0.298948</td>
      <td>975.089344</td>
      <td>256783.070356</td>
      <td>271783.070356</td>
    </tr>
    <tr>
      <th>487</th>
      <td>2933</td>
      <td>entry-gateway</td>
      <td>False</td>
      <td>entry_gateway:27;exit_gateway:0;mixnode:0</td>
      <td>0.225</td>
      <td>0.096164</td>
      <td>0.125410</td>
      <td>330.773381</td>
      <td>201248.316374</td>
      <td>204248.316374</td>
    </tr>
  </tbody>
</table>
</div>



### First Mixnodes


```python
summary[summary['node_type'].isin(['mixnode'])].head()[columns]
```




<div>
<style scoped>
    .dataframe tbody tr th:only-of-type {
        vertical-align: middle;
    }

    .dataframe tbody tr th {
        vertical-align: top;
    }

    .dataframe thead th {
        text-align: right;
    }
</style>
<table border="1" class="dataframe">
  <thead>
    <tr style="text-align: right;">
      <th></th>
      <th>node_id</th>
      <th>node_type</th>
      <th>node_type_changed</th>
      <th>node_role_history</th>
      <th>active_set_pct</th>
      <th>apy_eff_delegator</th>
      <th>apy_eff_total_bond_proxy</th>
      <th>sum_total_rewards_nym</th>
      <th>min_prior_delegates_nym</th>
      <th>min_total_stake_proxy_nym</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <th>68</th>
      <td>217</td>
      <td>mixnode</td>
      <td>False</td>
      <td>entry_gateway:0;exit_gateway:0;mixnode:56</td>
      <td>0.466667</td>
      <td>0.212041</td>
      <td>0.352201</td>
      <td>694.482115</td>
      <td>166454.494231</td>
      <td>167797.953516</td>
    </tr>
    <tr>
      <th>84</th>
      <td>1841</td>
      <td>mixnode</td>
      <td>False</td>
      <td>entry_gateway:0;exit_gateway:0;mixnode:65</td>
      <td>0.541667</td>
      <td>0.212149</td>
      <td>0.341678</td>
      <td>1020.761120</td>
      <td>253085.896268</td>
      <td>253185.896268</td>
    </tr>
    <tr>
      <th>100</th>
      <td>1876</td>
      <td>mixnode</td>
      <td>False</td>
      <td>entry_gateway:0;exit_gateway:0;mixnode:64</td>
      <td>0.533333</td>
      <td>0.217794</td>
      <td>0.331436</td>
      <td>943.785348</td>
      <td>238281.660640</td>
      <td>240281.660640</td>
    </tr>
    <tr>
      <th>114</th>
      <td>2561</td>
      <td>mixnode</td>
      <td>False</td>
      <td>entry_gateway:0;exit_gateway:0;mixnode:64</td>
      <td>0.533333</td>
      <td>0.249708</td>
      <td>0.325278</td>
      <td>911.402803</td>
      <td>235200.860008</td>
      <td>235377.860008</td>
    </tr>
    <tr>
      <th>131</th>
      <td>1814</td>
      <td>mixnode</td>
      <td>False</td>
      <td>entry_gateway:0;exit_gateway:0;mixnode:62</td>
      <td>0.516667</td>
      <td>0.240852</td>
      <td>0.320138</td>
      <td>921.824323</td>
      <td>241093.758158</td>
      <td>241598.758158</td>
    </tr>
  </tbody>
</table>
</div>



### First Entry Gateways


```python
summary[summary['node_type'].isin(['entry-gateway'])].head()[columns]
```




<div>
<style scoped>
    .dataframe tbody tr th:only-of-type {
        vertical-align: middle;
    }

    .dataframe tbody tr th {
        vertical-align: top;
    }

    .dataframe thead th {
        text-align: right;
    }
</style>
<table border="1" class="dataframe">
  <thead>
    <tr style="text-align: right;">
      <th></th>
      <th>node_id</th>
      <th>node_type</th>
      <th>node_type_changed</th>
      <th>node_role_history</th>
      <th>active_set_pct</th>
      <th>apy_eff_delegator</th>
      <th>apy_eff_total_bond_proxy</th>
      <th>sum_total_rewards_nym</th>
      <th>min_prior_delegates_nym</th>
      <th>min_total_stake_proxy_nym</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <th>381</th>
      <td>2212</td>
      <td>entry-gateway</td>
      <td>False</td>
      <td>entry_gateway:42;exit_gateway:0;mixnode:0</td>
      <td>0.350000</td>
      <td>0.158286</td>
      <td>0.202556</td>
      <td>634.167784</td>
      <td>250398.582277</td>
      <td>250498.582277</td>
    </tr>
    <tr>
      <th>424</th>
      <td>2226</td>
      <td>entry-gateway</td>
      <td>False</td>
      <td>entry_gateway:37;exit_gateway:0;mixnode:0</td>
      <td>0.308333</td>
      <td>0.130554</td>
      <td>0.176771</td>
      <td>539.020458</td>
      <td>240000.000000</td>
      <td>241475.000000</td>
    </tr>
    <tr>
      <th>455</th>
      <td>1797</td>
      <td>entry-gateway</td>
      <td>False</td>
      <td>entry_gateway:32;exit_gateway:0;mixnode:0</td>
      <td>0.266667</td>
      <td>0.108959</td>
      <td>0.150114</td>
      <td>419.181812</td>
      <td>218534.365641</td>
      <td>218634.365641</td>
    </tr>
    <tr>
      <th>468</th>
      <td>2235</td>
      <td>entry-gateway</td>
      <td>False</td>
      <td>entry_gateway:30;exit_gateway:0;mixnode:0</td>
      <td>0.250000</td>
      <td>0.103805</td>
      <td>0.139633</td>
      <td>414.562481</td>
      <td>230676.862436</td>
      <td>231376.862436</td>
    </tr>
    <tr>
      <th>479</th>
      <td>2233</td>
      <td>entry-gateway</td>
      <td>False</td>
      <td>entry_gateway:37;exit_gateway:0;mixnode:0</td>
      <td>0.308333</td>
      <td>0.098893</td>
      <td>0.132790</td>
      <td>562.907874</td>
      <td>321112.910009</td>
      <td>329362.910009</td>
    </tr>
  </tbody>
</table>
</div>



### Top Annual Percentage Yield Quantile Nodes per Node Type


```python
def filter_top_quantile_by_node_type(
    summary,
    node_type,
    stake_multiple,
    quantile_level,
    sat_nym,
    columns=None
):
    """
    Filters summary dataframe by node_type and stake threshold,
    normalizes min_total_stake_proxy_nym by sat_nym,
    and returns rows at or above the specified quantile of
    apy_eff_total_bond_proxy.
    
    Parameters
    ----------
    summary : pd.DataFrame
    sat_nym : float
    node_type : str
    stake_multiple : float
        Multiplier applied to sat_nym for stake threshold (e.g. 0.7)
    quantile_level : float
        Quantile cutoff (e.g. 0.9 for 90th percentile)
    columns : list, optional
        Columns to select
        
    Returns
    -------
    pd.DataFrame
    """

    if columns is None:
        columns = summary.columns.tolist()

    # Filter by node type and stake threshold
    df = summary[
        (summary['node_type'].isin([node_type])) &
        (summary['min_total_stake_proxy_nym'] >= stake_multiple * float(sat_nym))
    ][columns].copy()

    # Normalize stake column
    df['min_total_stake_proxy_nym'] = (
        df['min_total_stake_proxy_nym'] / float(sat_nym)
    )

    # Compute quantile threshold
    threshold = df['apy_eff_total_bond_proxy'].quantile(quantile_level)

    # Filter top quantile
    df_top = df[df['apy_eff_total_bond_proxy'] >= threshold]

    return df_top
```


```python
filter_top_quantile_by_node_type(summary, 'exit-gateway', 0.7, 0.9, float(sat_nym), columns)
```




<div>
<style scoped>
    .dataframe tbody tr th:only-of-type {
        vertical-align: middle;
    }

    .dataframe tbody tr th {
        vertical-align: top;
    }

    .dataframe thead th {
        text-align: right;
    }
</style>
<table border="1" class="dataframe">
  <thead>
    <tr style="text-align: right;">
      <th></th>
      <th>node_id</th>
      <th>node_type</th>
      <th>node_type_changed</th>
      <th>node_role_history</th>
      <th>active_set_pct</th>
      <th>apy_eff_delegator</th>
      <th>apy_eff_total_bond_proxy</th>
      <th>sum_total_rewards_nym</th>
      <th>min_prior_delegates_nym</th>
      <th>min_total_stake_proxy_nym</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <th>0</th>
      <td>1331</td>
      <td>exit-gateway</td>
      <td>True</td>
      <td>entry_gateway:33;exit_gateway:47;mixnode:0</td>
      <td>0.666667</td>
      <td>0.301367</td>
      <td>0.499592</td>
      <td>1033.548239</td>
      <td>183371.651310</td>
      <td>0.734195</td>
    </tr>
    <tr>
      <th>1</th>
      <td>2581</td>
      <td>exit-gateway</td>
      <td>True</td>
      <td>entry_gateway:38;exit_gateway:35;mixnode:0</td>
      <td>0.608333</td>
      <td>0.305527</td>
      <td>0.491884</td>
      <td>1181.019829</td>
      <td>109581.488867</td>
      <td>0.831037</td>
    </tr>
    <tr>
      <th>2</th>
      <td>1902</td>
      <td>exit-gateway</td>
      <td>True</td>
      <td>entry_gateway:42;exit_gateway:43;mixnode:0</td>
      <td>0.708333</td>
      <td>0.348409</td>
      <td>0.484888</td>
      <td>1340.865672</td>
      <td>222134.799907</td>
      <td>0.976186</td>
    </tr>
    <tr>
      <th>3</th>
      <td>2313</td>
      <td>exit-gateway</td>
      <td>True</td>
      <td>entry_gateway:35;exit_gateway:46;mixnode:0</td>
      <td>0.675000</td>
      <td>0.288886</td>
      <td>0.469287</td>
      <td>954.414110</td>
      <td>180573.354303</td>
      <td>0.713662</td>
    </tr>
    <tr>
      <th>4</th>
      <td>2310</td>
      <td>exit-gateway</td>
      <td>True</td>
      <td>entry_gateway:42;exit_gateway:38;mixnode:0</td>
      <td>0.666667</td>
      <td>0.285728</td>
      <td>0.462510</td>
      <td>944.339184</td>
      <td>180870.462149</td>
      <td>0.714836</td>
    </tr>
    <tr>
      <th>5</th>
      <td>2650</td>
      <td>exit-gateway</td>
      <td>True</td>
      <td>entry_gateway:40;exit_gateway:46;mixnode:0</td>
      <td>0.716667</td>
      <td>0.314541</td>
      <td>0.460855</td>
      <td>1250.958145</td>
      <td>240000.000000</td>
      <td>0.948398</td>
    </tr>
    <tr>
      <th>6</th>
      <td>2124</td>
      <td>exit-gateway</td>
      <td>True</td>
      <td>entry_gateway:49;exit_gateway:37;mixnode:0</td>
      <td>0.716667</td>
      <td>0.350050</td>
      <td>0.456468</td>
      <td>1301.917529</td>
      <td>251829.815504</td>
      <td>0.995126</td>
    </tr>
    <tr>
      <th>7</th>
      <td>2435</td>
      <td>exit-gateway</td>
      <td>True</td>
      <td>entry_gateway:35;exit_gateway:44;mixnode:0</td>
      <td>0.658333</td>
      <td>0.285058</td>
      <td>0.447660</td>
      <td>1014.456955</td>
      <td>198833.343081</td>
      <td>0.789344</td>
    </tr>
    <tr>
      <th>8</th>
      <td>2803</td>
      <td>exit-gateway</td>
      <td>True</td>
      <td>entry_gateway:38;exit_gateway:46;mixnode:0</td>
      <td>0.700000</td>
      <td>0.338567</td>
      <td>0.445811</td>
      <td>1184.455841</td>
      <td>233715.394870</td>
      <td>0.923574</td>
    </tr>
    <tr>
      <th>9</th>
      <td>2524</td>
      <td>exit-gateway</td>
      <td>True</td>
      <td>entry_gateway:40;exit_gateway:39;mixnode:0</td>
      <td>0.658333</td>
      <td>0.289076</td>
      <td>0.440824</td>
      <td>1205.033334</td>
      <td>240000.000000</td>
      <td>0.948398</td>
    </tr>
    <tr>
      <th>10</th>
      <td>2393</td>
      <td>exit-gateway</td>
      <td>True</td>
      <td>entry_gateway:51;exit_gateway:32;mixnode:0</td>
      <td>0.691667</td>
      <td>0.331343</td>
      <td>0.439751</td>
      <td>1253.582033</td>
      <td>249610.317963</td>
      <td>0.986359</td>
    </tr>
    <tr>
      <th>11</th>
      <td>2320</td>
      <td>exit-gateway</td>
      <td>True</td>
      <td>entry_gateway:29;exit_gateway:49;mixnode:0</td>
      <td>0.650000</td>
      <td>0.288293</td>
      <td>0.435522</td>
      <td>891.520345</td>
      <td>134779.195402</td>
      <td>0.710130</td>
    </tr>
    <tr>
      <th>12</th>
      <td>2120</td>
      <td>exit-gateway</td>
      <td>True</td>
      <td>entry_gateway:35;exit_gateway:39;mixnode:0</td>
      <td>0.616667</td>
      <td>0.273502</td>
      <td>0.429333</td>
      <td>913.659873</td>
      <td>186307.336371</td>
      <td>0.736311</td>
    </tr>
    <tr>
      <th>13</th>
      <td>2702</td>
      <td>exit-gateway</td>
      <td>True</td>
      <td>entry_gateway:44;exit_gateway:37;mixnode:0</td>
      <td>0.675000</td>
      <td>0.316048</td>
      <td>0.428287</td>
      <td>1219.330462</td>
      <td>248873.253978</td>
      <td>0.984633</td>
    </tr>
    <tr>
      <th>14</th>
      <td>2045</td>
      <td>exit-gateway</td>
      <td>True</td>
      <td>entry_gateway:45;exit_gateway:36;mixnode:0</td>
      <td>0.675000</td>
      <td>0.314998</td>
      <td>0.427043</td>
      <td>1074.330637</td>
      <td>220027.398067</td>
      <td>0.869510</td>
    </tr>
    <tr>
      <th>15</th>
      <td>2782</td>
      <td>exit-gateway</td>
      <td>True</td>
      <td>entry_gateway:33;exit_gateway:48;mixnode:0</td>
      <td>0.675000</td>
      <td>0.323674</td>
      <td>0.426468</td>
      <td>1035.683102</td>
      <td>206993.866747</td>
      <td>0.818418</td>
    </tr>
    <tr>
      <th>16</th>
      <td>2521</td>
      <td>exit-gateway</td>
      <td>True</td>
      <td>entry_gateway:38;exit_gateway:38;mixnode:0</td>
      <td>0.633333</td>
      <td>0.277045</td>
      <td>0.420134</td>
      <td>1157.137890</td>
      <td>240000.000000</td>
      <td>0.948398</td>
    </tr>
    <tr>
      <th>17</th>
      <td>2315</td>
      <td>exit-gateway</td>
      <td>True</td>
      <td>entry_gateway:38;exit_gateway:36;mixnode:0</td>
      <td>0.616667</td>
      <td>0.262547</td>
      <td>0.418432</td>
      <td>917.542700</td>
      <td>191134.089768</td>
      <td>0.755377</td>
    </tr>
    <tr>
      <th>18</th>
      <td>2309</td>
      <td>exit-gateway</td>
      <td>True</td>
      <td>entry_gateway:30;exit_gateway:44;mixnode:0</td>
      <td>0.616667</td>
      <td>0.261681</td>
      <td>0.416647</td>
      <td>892.081078</td>
      <td>186546.288061</td>
      <td>0.737255</td>
    </tr>
    <tr>
      <th>19</th>
      <td>2542</td>
      <td>exit-gateway</td>
      <td>True</td>
      <td>entry_gateway:42;exit_gateway:41;mixnode:0</td>
      <td>0.691667</td>
      <td>0.317779</td>
      <td>0.415685</td>
      <td>1265.641020</td>
      <td>265185.546447</td>
      <td>1.047881</td>
    </tr>
  </tbody>
</table>
</div>




```python
filter_top_quantile_by_node_type(summary, 'entry-gateway', 0.7, 0.9, float(sat_nym), columns)
```




<div>
<style scoped>
    .dataframe tbody tr th:only-of-type {
        vertical-align: middle;
    }

    .dataframe tbody tr th {
        vertical-align: top;
    }

    .dataframe thead th {
        text-align: right;
    }
</style>
<table border="1" class="dataframe">
  <thead>
    <tr style="text-align: right;">
      <th></th>
      <th>node_id</th>
      <th>node_type</th>
      <th>node_type_changed</th>
      <th>node_role_history</th>
      <th>active_set_pct</th>
      <th>apy_eff_delegator</th>
      <th>apy_eff_total_bond_proxy</th>
      <th>sum_total_rewards_nym</th>
      <th>min_prior_delegates_nym</th>
      <th>min_total_stake_proxy_nym</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <th>381</th>
      <td>2212</td>
      <td>entry-gateway</td>
      <td>False</td>
      <td>entry_gateway:42;exit_gateway:0;mixnode:0</td>
      <td>0.35</td>
      <td>0.158286</td>
      <td>0.202556</td>
      <td>634.167784</td>
      <td>250398.582277</td>
      <td>0.989473</td>
    </tr>
  </tbody>
</table>
</div>




```python
filter_top_quantile_by_node_type(summary, 'mixnode', 0.7, 0.9, float(sat_nym), columns)
```




<div>
<style scoped>
    .dataframe tbody tr th:only-of-type {
        vertical-align: middle;
    }

    .dataframe tbody tr th {
        vertical-align: top;
    }

    .dataframe thead th {
        text-align: right;
    }
</style>
<table border="1" class="dataframe">
  <thead>
    <tr style="text-align: right;">
      <th></th>
      <th>node_id</th>
      <th>node_type</th>
      <th>node_type_changed</th>
      <th>node_role_history</th>
      <th>active_set_pct</th>
      <th>apy_eff_delegator</th>
      <th>apy_eff_total_bond_proxy</th>
      <th>sum_total_rewards_nym</th>
      <th>min_prior_delegates_nym</th>
      <th>min_total_stake_proxy_nym</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <th>84</th>
      <td>1841</td>
      <td>mixnode</td>
      <td>False</td>
      <td>entry_gateway:0;exit_gateway:0;mixnode:65</td>
      <td>0.541667</td>
      <td>0.212149</td>
      <td>0.341678</td>
      <td>1020.761120</td>
      <td>253085.896268</td>
      <td>1.000088</td>
    </tr>
    <tr>
      <th>100</th>
      <td>1876</td>
      <td>mixnode</td>
      <td>False</td>
      <td>entry_gateway:0;exit_gateway:0;mixnode:64</td>
      <td>0.533333</td>
      <td>0.217794</td>
      <td>0.331436</td>
      <td>943.785348</td>
      <td>238281.660640</td>
      <td>0.949116</td>
    </tr>
    <tr>
      <th>114</th>
      <td>2561</td>
      <td>mixnode</td>
      <td>False</td>
      <td>entry_gateway:0;exit_gateway:0;mixnode:64</td>
      <td>0.533333</td>
      <td>0.249708</td>
      <td>0.325278</td>
      <td>911.402803</td>
      <td>235200.860008</td>
      <td>0.929746</td>
    </tr>
    <tr>
      <th>131</th>
      <td>1814</td>
      <td>mixnode</td>
      <td>False</td>
      <td>entry_gateway:0;exit_gateway:0;mixnode:62</td>
      <td>0.516667</td>
      <td>0.240852</td>
      <td>0.320138</td>
      <td>921.824323</td>
      <td>241093.758158</td>
      <td>0.954318</td>
    </tr>
    <tr>
      <th>133</th>
      <td>1644</td>
      <td>mixnode</td>
      <td>False</td>
      <td>entry_gateway:0;exit_gateway:0;mixnode:55</td>
      <td>0.458333</td>
      <td>0.234681</td>
      <td>0.318524</td>
      <td>913.066886</td>
      <td>165673.119387</td>
      <td>0.951195</td>
    </tr>
    <tr>
      <th>150</th>
      <td>2501</td>
      <td>mixnode</td>
      <td>False</td>
      <td>entry_gateway:0;exit_gateway:0;mixnode:62</td>
      <td>0.516667</td>
      <td>0.236659</td>
      <td>0.312688</td>
      <td>930.933706</td>
      <td>249000.000000</td>
      <td>0.983948</td>
    </tr>
    <tr>
      <th>155</th>
      <td>8</td>
      <td>mixnode</td>
      <td>False</td>
      <td>entry_gateway:0;exit_gateway:0;mixnode:61</td>
      <td>0.508333</td>
      <td>0.214947</td>
      <td>0.310293</td>
      <td>871.538202</td>
      <td>230110.354320</td>
      <td>0.928689</td>
    </tr>
    <tr>
      <th>159</th>
      <td>1528</td>
      <td>mixnode</td>
      <td>False</td>
      <td>entry_gateway:0;exit_gateway:0;mixnode:61</td>
      <td>0.508333</td>
      <td>0.212129</td>
      <td>0.307822</td>
      <td>824.624950</td>
      <td>223754.401266</td>
      <td>0.884232</td>
    </tr>
    <tr>
      <th>173</th>
      <td>2196</td>
      <td>mixnode</td>
      <td>False</td>
      <td>entry_gateway:0;exit_gateway:0;mixnode:63</td>
      <td>0.525000</td>
      <td>0.228747</td>
      <td>0.298948</td>
      <td>975.089344</td>
      <td>256783.070356</td>
      <td>1.073547</td>
    </tr>
    <tr>
      <th>180</th>
      <td>5</td>
      <td>mixnode</td>
      <td>False</td>
      <td>entry_gateway:0;exit_gateway:0;mixnode:59</td>
      <td>0.491667</td>
      <td>0.229279</td>
      <td>0.296218</td>
      <td>879.720706</td>
      <td>199828.135818</td>
      <td>0.902896</td>
    </tr>
    <tr>
      <th>183</th>
      <td>2557</td>
      <td>mixnode</td>
      <td>False</td>
      <td>entry_gateway:0;exit_gateway:0;mixnode:58</td>
      <td>0.483333</td>
      <td>0.203399</td>
      <td>0.295435</td>
      <td>885.071948</td>
      <td>248851.294284</td>
      <td>0.983558</td>
    </tr>
    <tr>
      <th>185</th>
      <td>1842</td>
      <td>mixnode</td>
      <td>False</td>
      <td>entry_gateway:0;exit_gateway:0;mixnode:56</td>
      <td>0.466667</td>
      <td>0.204925</td>
      <td>0.294634</td>
      <td>631.489087</td>
      <td>178190.254955</td>
      <td>0.704249</td>
    </tr>
  </tbody>
</table>
</div>



### Bottom Annual Percentage Yield Quantile Nodes per Node Type


```python
def filter_bottom_quantile_by_node_type(
    summary,
    node_type,
    stake_multiple,
    quantile_level,
    sat_nym,
    columns=None
):
    """
    Filters summary dataframe by node_type and stake threshold,
    normalizes min_total_stake_proxy_nym by sat_nym,
    and returns rows at or above the specified quantile of
    apy_eff_total_bond_proxy.
    
    Parameters
    ----------
    summary : pd.DataFrame
    sat_nym : float
    node_type : str
    stake_multiple : float
        Multiplier applied to sat_nym for stake threshold (e.g. 0.7)
    quantile_level : float
        Quantile cutoff (e.g. 0.9 for 90th percentile)
    columns : list, optional
        Columns to select
        
    Returns
    -------
    pd.DataFrame
    """

    if columns is None:
        columns = summary.columns.tolist()

    # Filter by node type and stake threshold
    df = summary[
        (summary['node_type'].isin([node_type])) &
        (summary['min_total_stake_proxy_nym'] >= stake_multiple * float(sat_nym))
    ][columns].copy()

    # Normalize stake column
    df['min_total_stake_proxy_nym'] = (
        df['min_total_stake_proxy_nym'] / float(sat_nym)
    )

    # Compute quantile threshold
    threshold = df['apy_eff_total_bond_proxy'].quantile(quantile_level)

    # Filter top quantile
    df_bottom = df[df['apy_eff_total_bond_proxy'] <= threshold]
    df_bottom = df_bottom.sort_values("apy_eff_total_bond_proxy", ascending=True).reset_index(drop=True)

    return df_bottom
```


```python
filter_bottom_quantile_by_node_type(summary, 'exit-gateway', 0.7, 0.1, float(sat_nym), columns)
```




<div>
<style scoped>
    .dataframe tbody tr th:only-of-type {
        vertical-align: middle;
    }

    .dataframe tbody tr th {
        vertical-align: top;
    }

    .dataframe thead th {
        text-align: right;
    }
</style>
<table border="1" class="dataframe">
  <thead>
    <tr style="text-align: right;">
      <th></th>
      <th>node_id</th>
      <th>node_type</th>
      <th>node_type_changed</th>
      <th>node_role_history</th>
      <th>active_set_pct</th>
      <th>apy_eff_delegator</th>
      <th>apy_eff_total_bond_proxy</th>
      <th>sum_total_rewards_nym</th>
      <th>min_prior_delegates_nym</th>
      <th>min_total_stake_proxy_nym</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <th>0</th>
      <td>2856</td>
      <td>exit-gateway</td>
      <td>False</td>
      <td>entry_gateway:0;exit_gateway:2;mixnode:0</td>
      <td>0.016667</td>
      <td>0.005061</td>
      <td>0.006980</td>
      <td>19.149550</td>
      <td>2.008310e+05</td>
      <td>0.793759</td>
    </tr>
    <tr>
      <th>1</th>
      <td>2935</td>
      <td>exit-gateway</td>
      <td>False</td>
      <td>entry_gateway:0;exit_gateway:2;mixnode:0</td>
      <td>0.016667</td>
      <td>0.005154</td>
      <td>0.007002</td>
      <td>22.590791</td>
      <td>2.362197e+05</td>
      <td>0.933545</td>
    </tr>
    <tr>
      <th>2</th>
      <td>180</td>
      <td>exit-gateway</td>
      <td>True</td>
      <td>entry_gateway:28;exit_gateway:33;mixnode:0</td>
      <td>0.508333</td>
      <td>0.050199</td>
      <td>0.065626</td>
      <td>917.453032</td>
      <td>1.053218e+06</td>
      <td>4.160625</td>
    </tr>
    <tr>
      <th>3</th>
      <td>2323</td>
      <td>exit-gateway</td>
      <td>True</td>
      <td>entry_gateway:6;exit_gateway:10;mixnode:0</td>
      <td>0.133333</td>
      <td>0.049733</td>
      <td>0.072878</td>
      <td>173.513467</td>
      <td>1.799018e+05</td>
      <td>0.711010</td>
    </tr>
    <tr>
      <th>4</th>
      <td>1909</td>
      <td>exit-gateway</td>
      <td>True</td>
      <td>entry_gateway:41;exit_gateway:36;mixnode:0</td>
      <td>0.641667</td>
      <td>0.062110</td>
      <td>0.079785</td>
      <td>1190.424029</td>
      <td>1.131520e+06</td>
      <td>4.469915</td>
    </tr>
    <tr>
      <th>5</th>
      <td>42</td>
      <td>exit-gateway</td>
      <td>True</td>
      <td>entry_gateway:35;exit_gateway:31;mixnode:0</td>
      <td>0.550000</td>
      <td>0.068319</td>
      <td>0.089554</td>
      <td>999.999020</td>
      <td>8.506368e+05</td>
      <td>3.360426</td>
    </tr>
    <tr>
      <th>6</th>
      <td>2924</td>
      <td>exit-gateway</td>
      <td>True</td>
      <td>entry_gateway:10;exit_gateway:18;mixnode:0</td>
      <td>0.233333</td>
      <td>0.087389</td>
      <td>0.125430</td>
      <td>325.794017</td>
      <td>2.010516e+05</td>
      <td>0.794551</td>
    </tr>
    <tr>
      <th>7</th>
      <td>2041</td>
      <td>exit-gateway</td>
      <td>True</td>
      <td>entry_gateway:42;exit_gateway:40;mixnode:0</td>
      <td>0.683333</td>
      <td>0.116851</td>
      <td>0.152822</td>
      <td>1267.751664</td>
      <td>6.501606e+05</td>
      <td>2.568538</td>
    </tr>
    <tr>
      <th>8</th>
      <td>2694</td>
      <td>exit-gateway</td>
      <td>True</td>
      <td>entry_gateway:13;exit_gateway:21;mixnode:0</td>
      <td>0.283333</td>
      <td>0.118638</td>
      <td>0.157652</td>
      <td>368.837223</td>
      <td>1.836787e+05</td>
      <td>0.725932</td>
    </tr>
    <tr>
      <th>9</th>
      <td>1540</td>
      <td>exit-gateway</td>
      <td>True</td>
      <td>entry_gateway:34;exit_gateway:56;mixnode:0</td>
      <td>0.750000</td>
      <td>0.129185</td>
      <td>0.169749</td>
      <td>1367.189210</td>
      <td>6.359231e+05</td>
      <td>2.512300</td>
    </tr>
    <tr>
      <th>10</th>
      <td>2767</td>
      <td>exit-gateway</td>
      <td>True</td>
      <td>entry_gateway:14;exit_gateway:24;mixnode:0</td>
      <td>0.316667</td>
      <td>0.123121</td>
      <td>0.175835</td>
      <td>488.752049</td>
      <td>2.199929e+05</td>
      <td>0.869370</td>
    </tr>
    <tr>
      <th>11</th>
      <td>2060</td>
      <td>exit-gateway</td>
      <td>True</td>
      <td>entry_gateway:17;exit_gateway:21;mixnode:0</td>
      <td>0.316667</td>
      <td>0.124651</td>
      <td>0.178976</td>
      <td>478.216867</td>
      <td>2.115334e+05</td>
      <td>0.835955</td>
    </tr>
    <tr>
      <th>12</th>
      <td>933</td>
      <td>exit-gateway</td>
      <td>True</td>
      <td>entry_gateway:34;exit_gateway:47;mixnode:0</td>
      <td>0.675000</td>
      <td>0.140312</td>
      <td>0.180283</td>
      <td>1227.420288</td>
      <td>5.399829e+05</td>
      <td>2.133335</td>
    </tr>
    <tr>
      <th>13</th>
      <td>915</td>
      <td>exit-gateway</td>
      <td>True</td>
      <td>entry_gateway:19;exit_gateway:25;mixnode:0</td>
      <td>0.366667</td>
      <td>0.144979</td>
      <td>0.209120</td>
      <td>560.068350</td>
      <td>2.150042e+05</td>
      <td>0.849664</td>
    </tr>
    <tr>
      <th>14</th>
      <td>2697</td>
      <td>exit-gateway</td>
      <td>True</td>
      <td>entry_gateway:19;exit_gateway:26;mixnode:0</td>
      <td>0.375000</td>
      <td>0.146183</td>
      <td>0.215479</td>
      <td>487.348014</td>
      <td>1.820421e+05</td>
      <td>0.719464</td>
    </tr>
    <tr>
      <th>15</th>
      <td>2951</td>
      <td>exit-gateway</td>
      <td>True</td>
      <td>entry_gateway:19;exit_gateway:26;mixnode:0</td>
      <td>0.375000</td>
      <td>0.151258</td>
      <td>0.216997</td>
      <td>596.724671</td>
      <td>2.001295e+05</td>
      <td>0.790909</td>
    </tr>
    <tr>
      <th>16</th>
      <td>2839</td>
      <td>exit-gateway</td>
      <td>True</td>
      <td>entry_gateway:19;exit_gateway:26;mixnode:0</td>
      <td>0.375000</td>
      <td>0.158896</td>
      <td>0.218791</td>
      <td>523.830175</td>
      <td>1.929702e+05</td>
      <td>0.762630</td>
    </tr>
    <tr>
      <th>17</th>
      <td>1901</td>
      <td>exit-gateway</td>
      <td>True</td>
      <td>entry_gateway:16;exit_gateway:29;mixnode:0</td>
      <td>0.375000</td>
      <td>0.148421</td>
      <td>0.219700</td>
      <td>493.328484</td>
      <td>1.794937e+05</td>
      <td>0.715718</td>
    </tr>
    <tr>
      <th>18</th>
      <td>2749</td>
      <td>exit-gateway</td>
      <td>True</td>
      <td>entry_gateway:16;exit_gateway:30;mixnode:0</td>
      <td>0.383333</td>
      <td>0.149792</td>
      <td>0.221700</td>
      <td>488.688984</td>
      <td>1.778831e+05</td>
      <td>0.703036</td>
    </tr>
    <tr>
      <th>19</th>
      <td>2539</td>
      <td>exit-gateway</td>
      <td>True</td>
      <td>entry_gateway:24;exit_gateway:23;mixnode:0</td>
      <td>0.391667</td>
      <td>0.166822</td>
      <td>0.225240</td>
      <td>520.707224</td>
      <td>1.868245e+05</td>
      <td>0.738354</td>
    </tr>
  </tbody>
</table>
</div>




```python
filter_bottom_quantile_by_node_type(summary, 'entry-gateway', 0.7, 0.1, float(sat_nym), columns)
```




<div>
<style scoped>
    .dataframe tbody tr th:only-of-type {
        vertical-align: middle;
    }

    .dataframe tbody tr th {
        vertical-align: top;
    }

    .dataframe thead th {
        text-align: right;
    }
</style>
<table border="1" class="dataframe">
  <thead>
    <tr style="text-align: right;">
      <th></th>
      <th>node_id</th>
      <th>node_type</th>
      <th>node_type_changed</th>
      <th>node_role_history</th>
      <th>active_set_pct</th>
      <th>apy_eff_delegator</th>
      <th>apy_eff_total_bond_proxy</th>
      <th>sum_total_rewards_nym</th>
      <th>min_prior_delegates_nym</th>
      <th>min_total_stake_proxy_nym</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <th>0</th>
      <td>2933</td>
      <td>entry-gateway</td>
      <td>False</td>
      <td>entry_gateway:27;exit_gateway:0;mixnode:0</td>
      <td>0.225</td>
      <td>0.096164</td>
      <td>0.12541</td>
      <td>330.773381</td>
      <td>201248.316374</td>
      <td>0.806784</td>
    </tr>
  </tbody>
</table>
</div>




```python
filter_bottom_quantile_by_node_type(summary, 'mixnode', 0.7, 0.1, float(sat_nym), columns)
```




<div>
<style scoped>
    .dataframe tbody tr th:only-of-type {
        vertical-align: middle;
    }

    .dataframe tbody tr th {
        vertical-align: top;
    }

    .dataframe thead th {
        text-align: right;
    }
</style>
<table border="1" class="dataframe">
  <thead>
    <tr style="text-align: right;">
      <th></th>
      <th>node_id</th>
      <th>node_type</th>
      <th>node_type_changed</th>
      <th>node_role_history</th>
      <th>active_set_pct</th>
      <th>apy_eff_delegator</th>
      <th>apy_eff_total_bond_proxy</th>
      <th>sum_total_rewards_nym</th>
      <th>min_prior_delegates_nym</th>
      <th>min_total_stake_proxy_nym</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <th>0</th>
      <td>547</td>
      <td>mixnode</td>
      <td>False</td>
      <td>entry_gateway:0;exit_gateway:0;mixnode:1</td>
      <td>0.008333</td>
      <td>0.001156</td>
      <td>0.001515</td>
      <td>12.126666</td>
      <td>5.841651e+05</td>
      <td>2.309040</td>
    </tr>
    <tr>
      <th>1</th>
      <td>246</td>
      <td>mixnode</td>
      <td>False</td>
      <td>entry_gateway:0;exit_gateway:0;mixnode:1</td>
      <td>0.008333</td>
      <td>0.001884</td>
      <td>0.002403</td>
      <td>12.239824</td>
      <td>3.723064e+05</td>
      <td>1.470615</td>
    </tr>
    <tr>
      <th>2</th>
      <td>241</td>
      <td>mixnode</td>
      <td>False</td>
      <td>entry_gateway:0;exit_gateway:0;mixnode:3</td>
      <td>0.025000</td>
      <td>0.002398</td>
      <td>0.003154</td>
      <td>40.987595</td>
      <td>9.472118e+05</td>
      <td>3.753190</td>
    </tr>
    <tr>
      <th>3</th>
      <td>69</td>
      <td>mixnode</td>
      <td>False</td>
      <td>entry_gateway:0;exit_gateway:0;mixnode:1</td>
      <td>0.008333</td>
      <td>0.002775</td>
      <td>0.003531</td>
      <td>8.646748</td>
      <td>1.750560e+05</td>
      <td>0.707273</td>
    </tr>
    <tr>
      <th>4</th>
      <td>568</td>
      <td>mixnode</td>
      <td>False</td>
      <td>entry_gateway:0;exit_gateway:0;mixnode:1</td>
      <td>0.008333</td>
      <td>0.002705</td>
      <td>0.003548</td>
      <td>11.363405</td>
      <td>2.340943e+05</td>
      <td>0.925070</td>
    </tr>
    <tr>
      <th>5</th>
      <td>757</td>
      <td>mixnode</td>
      <td>False</td>
      <td>entry_gateway:0;exit_gateway:0;mixnode:1</td>
      <td>0.008333</td>
      <td>0.002805</td>
      <td>0.003574</td>
      <td>8.759094</td>
      <td>1.791321e+05</td>
      <td>0.707969</td>
    </tr>
    <tr>
      <th>6</th>
      <td>775</td>
      <td>mixnode</td>
      <td>False</td>
      <td>entry_gateway:0;exit_gateway:0;mixnode:2</td>
      <td>0.016667</td>
      <td>0.003073</td>
      <td>0.006811</td>
      <td>24.328879</td>
      <td>2.615235e+05</td>
      <td>1.033416</td>
    </tr>
    <tr>
      <th>7</th>
      <td>690</td>
      <td>mixnode</td>
      <td>False</td>
      <td>entry_gateway:0;exit_gateway:0;mixnode:2</td>
      <td>0.016667</td>
      <td>0.003130</td>
      <td>0.006940</td>
      <td>24.428953</td>
      <td>2.577579e+05</td>
      <td>1.018542</td>
    </tr>
    <tr>
      <th>8</th>
      <td>26</td>
      <td>mixnode</td>
      <td>False</td>
      <td>entry_gateway:0;exit_gateway:0;mixnode:5</td>
      <td>0.041667</td>
      <td>0.007145</td>
      <td>0.009441</td>
      <td>68.976595</td>
      <td>5.357516e+05</td>
      <td>2.116625</td>
    </tr>
    <tr>
      <th>9</th>
      <td>501</td>
      <td>mixnode</td>
      <td>False</td>
      <td>entry_gateway:0;exit_gateway:0;mixnode:11</td>
      <td>0.091667</td>
      <td>0.008376</td>
      <td>0.011021</td>
      <td>156.785402</td>
      <td>1.040905e+06</td>
      <td>4.124262</td>
    </tr>
    <tr>
      <th>10</th>
      <td>39</td>
      <td>mixnode</td>
      <td>False</td>
      <td>entry_gateway:0;exit_gateway:0;mixnode:15</td>
      <td>0.125000</td>
      <td>0.015188</td>
      <td>0.020031</td>
      <td>218.345254</td>
      <td>8.034912e+05</td>
      <td>3.174196</td>
    </tr>
    <tr>
      <th>11</th>
      <td>488</td>
      <td>mixnode</td>
      <td>False</td>
      <td>entry_gateway:0;exit_gateway:0;mixnode:5</td>
      <td>0.041667</td>
      <td>0.011122</td>
      <td>0.021117</td>
      <td>68.736296</td>
      <td>2.400000e+05</td>
      <td>0.948398</td>
    </tr>
  </tbody>
</table>
</div>



### Over-Staked Nodes and Effect on Annual Percentage Yield


```python
ldf = summary[columns].copy()
ldf['min_total_stake_proxy_nym'] = ldf['min_total_stake_proxy_nym'] / float(sat_nym)
ldf[ldf['min_total_stake_proxy_nym'] > 2.0]
```




<div>
<style scoped>
    .dataframe tbody tr th:only-of-type {
        vertical-align: middle;
    }

    .dataframe tbody tr th {
        vertical-align: top;
    }

    .dataframe thead th {
        text-align: right;
    }
</style>
<table border="1" class="dataframe">
  <thead>
    <tr style="text-align: right;">
      <th></th>
      <th>node_id</th>
      <th>node_type</th>
      <th>node_type_changed</th>
      <th>node_role_history</th>
      <th>active_set_pct</th>
      <th>apy_eff_delegator</th>
      <th>apy_eff_total_bond_proxy</th>
      <th>sum_total_rewards_nym</th>
      <th>min_prior_delegates_nym</th>
      <th>min_total_stake_proxy_nym</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <th>416</th>
      <td>933</td>
      <td>exit-gateway</td>
      <td>True</td>
      <td>entry_gateway:34;exit_gateway:47;mixnode:0</td>
      <td>0.675000</td>
      <td>0.140312</td>
      <td>0.180283</td>
      <td>1227.420288</td>
      <td>5.399829e+05</td>
      <td>2.133335</td>
    </tr>
    <tr>
      <th>435</th>
      <td>1540</td>
      <td>exit-gateway</td>
      <td>True</td>
      <td>entry_gateway:34;exit_gateway:56;mixnode:0</td>
      <td>0.750000</td>
      <td>0.129185</td>
      <td>0.169749</td>
      <td>1367.189210</td>
      <td>6.359231e+05</td>
      <td>2.512300</td>
    </tr>
    <tr>
      <th>451</th>
      <td>2041</td>
      <td>exit-gateway</td>
      <td>True</td>
      <td>entry_gateway:42;exit_gateway:40;mixnode:0</td>
      <td>0.683333</td>
      <td>0.116851</td>
      <td>0.152822</td>
      <td>1267.751664</td>
      <td>6.501606e+05</td>
      <td>2.568538</td>
    </tr>
    <tr>
      <th>471</th>
      <td>82</td>
      <td>mixnode</td>
      <td>False</td>
      <td>entry_gateway:0;exit_gateway:0;mixnode:58</td>
      <td>0.483333</td>
      <td>0.107267</td>
      <td>0.136453</td>
      <td>899.052112</td>
      <td>4.950082e+05</td>
      <td>2.023150</td>
    </tr>
    <tr>
      <th>474</th>
      <td>1041</td>
      <td>mixnode</td>
      <td>False</td>
      <td>entry_gateway:0;exit_gateway:0;mixnode:65</td>
      <td>0.541667</td>
      <td>0.099615</td>
      <td>0.134777</td>
      <td>1000.532466</td>
      <td>5.758654e+05</td>
      <td>2.280324</td>
    </tr>
    <tr>
      <th>478</th>
      <td>1674</td>
      <td>mixnode</td>
      <td>False</td>
      <td>entry_gateway:0;exit_gateway:0;mixnode:57</td>
      <td>0.475000</td>
      <td>0.098258</td>
      <td>0.133925</td>
      <td>881.293161</td>
      <td>5.113411e+05</td>
      <td>2.020594</td>
    </tr>
    <tr>
      <th>498</th>
      <td>195</td>
      <td>mixnode</td>
      <td>False</td>
      <td>entry_gateway:0;exit_gateway:0;mixnode:63</td>
      <td>0.525000</td>
      <td>0.089460</td>
      <td>0.118752</td>
      <td>960.073165</td>
      <td>6.240255e+05</td>
      <td>2.465606</td>
    </tr>
    <tr>
      <th>499</th>
      <td>961</td>
      <td>mixnode</td>
      <td>False</td>
      <td>entry_gateway:0;exit_gateway:0;mixnode:57</td>
      <td>0.475000</td>
      <td>0.085909</td>
      <td>0.113979</td>
      <td>867.326193</td>
      <td>5.848510e+05</td>
      <td>2.315699</td>
    </tr>
    <tr>
      <th>500</th>
      <td>29</td>
      <td>mixnode</td>
      <td>False</td>
      <td>entry_gateway:0;exit_gateway:0;mixnode:62</td>
      <td>0.516667</td>
      <td>0.083902</td>
      <td>0.111260</td>
      <td>943.216294</td>
      <td>6.521368e+05</td>
      <td>2.576688</td>
    </tr>
    <tr>
      <th>501</th>
      <td>131</td>
      <td>mixnode</td>
      <td>False</td>
      <td>entry_gateway:0;exit_gateway:0;mixnode:67</td>
      <td>0.558333</td>
      <td>0.084761</td>
      <td>0.109977</td>
      <td>1123.033704</td>
      <td>7.173511e+05</td>
      <td>3.102024</td>
    </tr>
    <tr>
      <th>502</th>
      <td>300</td>
      <td>mixnode</td>
      <td>False</td>
      <td>entry_gateway:0;exit_gateway:0;mixnode:53</td>
      <td>0.441667</td>
      <td>0.085753</td>
      <td>0.108819</td>
      <td>835.288331</td>
      <td>5.603467e+05</td>
      <td>2.330471</td>
    </tr>
    <tr>
      <th>504</th>
      <td>1719</td>
      <td>mixnode</td>
      <td>False</td>
      <td>entry_gateway:0;exit_gateway:0;mixnode:67</td>
      <td>0.558333</td>
      <td>0.078220</td>
      <td>0.107234</td>
      <td>1022.042147</td>
      <td>7.309496e+05</td>
      <td>2.891605</td>
    </tr>
    <tr>
      <th>506</th>
      <td>21</td>
      <td>mixnode</td>
      <td>False</td>
      <td>entry_gateway:0;exit_gateway:0;mixnode:62</td>
      <td>0.516667</td>
      <td>0.079134</td>
      <td>0.105006</td>
      <td>947.078525</td>
      <td>6.384951e+05</td>
      <td>2.527101</td>
    </tr>
    <tr>
      <th>509</th>
      <td>117</td>
      <td>mixnode</td>
      <td>False</td>
      <td>entry_gateway:0;exit_gateway:0;mixnode:61</td>
      <td>0.508333</td>
      <td>0.076333</td>
      <td>0.098328</td>
      <td>953.325238</td>
      <td>7.216465e+05</td>
      <td>2.929513</td>
    </tr>
    <tr>
      <th>510</th>
      <td>106</td>
      <td>mixnode</td>
      <td>False</td>
      <td>entry_gateway:0;exit_gateway:0;mixnode:56</td>
      <td>0.466667</td>
      <td>0.075602</td>
      <td>0.095788</td>
      <td>851.847978</td>
      <td>6.745690e+05</td>
      <td>2.683928</td>
    </tr>
    <tr>
      <th>512</th>
      <td>267</td>
      <td>mixnode</td>
      <td>False</td>
      <td>entry_gateway:0;exit_gateway:0;mixnode:57</td>
      <td>0.475000</td>
      <td>0.070061</td>
      <td>0.092773</td>
      <td>863.884980</td>
      <td>7.103897e+05</td>
      <td>2.806483</td>
    </tr>
    <tr>
      <th>513</th>
      <td>439</td>
      <td>mixnode</td>
      <td>False</td>
      <td>entry_gateway:0;exit_gateway:0;mixnode:45</td>
      <td>0.375000</td>
      <td>0.066085</td>
      <td>0.090708</td>
      <td>745.429561</td>
      <td>5.584715e+05</td>
      <td>2.474571</td>
    </tr>
    <tr>
      <th>514</th>
      <td>42</td>
      <td>exit-gateway</td>
      <td>True</td>
      <td>entry_gateway:35;exit_gateway:31;mixnode:0</td>
      <td>0.550000</td>
      <td>0.068319</td>
      <td>0.089554</td>
      <td>999.999020</td>
      <td>8.506368e+05</td>
      <td>3.360426</td>
    </tr>
    <tr>
      <th>518</th>
      <td>64</td>
      <td>mixnode</td>
      <td>False</td>
      <td>entry_gateway:0;exit_gateway:0;mixnode:65</td>
      <td>0.541667</td>
      <td>0.064416</td>
      <td>0.085186</td>
      <td>991.584272</td>
      <td>7.859461e+05</td>
      <td>3.105211</td>
    </tr>
    <tr>
      <th>521</th>
      <td>1909</td>
      <td>exit-gateway</td>
      <td>True</td>
      <td>entry_gateway:41;exit_gateway:36;mixnode:0</td>
      <td>0.641667</td>
      <td>0.062110</td>
      <td>0.079785</td>
      <td>1190.424029</td>
      <td>1.131520e+06</td>
      <td>4.469915</td>
    </tr>
    <tr>
      <th>522</th>
      <td>207</td>
      <td>mixnode</td>
      <td>False</td>
      <td>entry_gateway:0;exit_gateway:0;mixnode:52</td>
      <td>0.433333</td>
      <td>0.057447</td>
      <td>0.075889</td>
      <td>790.731622</td>
      <td>7.885205e+05</td>
      <td>3.115921</td>
    </tr>
    <tr>
      <th>523</th>
      <td>14</td>
      <td>mixnode</td>
      <td>False</td>
      <td>entry_gateway:0;exit_gateway:0;mixnode:49</td>
      <td>0.408333</td>
      <td>0.052919</td>
      <td>0.073644</td>
      <td>747.993335</td>
      <td>7.678882e+05</td>
      <td>3.034221</td>
    </tr>
    <tr>
      <th>525</th>
      <td>234</td>
      <td>mixnode</td>
      <td>False</td>
      <td>entry_gateway:0;exit_gateway:0;mixnode:60</td>
      <td>0.500000</td>
      <td>0.054894</td>
      <td>0.072482</td>
      <td>913.760223</td>
      <td>9.527318e+05</td>
      <td>3.763976</td>
    </tr>
    <tr>
      <th>526</th>
      <td>2222</td>
      <td>mixnode</td>
      <td>False</td>
      <td>entry_gateway:0;exit_gateway:0;mixnode:57</td>
      <td>0.475000</td>
      <td>0.055868</td>
      <td>0.071742</td>
      <td>987.573041</td>
      <td>9.380934e+05</td>
      <td>4.108699</td>
    </tr>
    <tr>
      <th>527</th>
      <td>265</td>
      <td>mixnode</td>
      <td>False</td>
      <td>entry_gateway:0;exit_gateway:0;mixnode:53</td>
      <td>0.441667</td>
      <td>0.049786</td>
      <td>0.065696</td>
      <td>809.568378</td>
      <td>9.275794e+05</td>
      <td>3.667606</td>
    </tr>
    <tr>
      <th>528</th>
      <td>180</td>
      <td>exit-gateway</td>
      <td>True</td>
      <td>entry_gateway:28;exit_gateway:33;mixnode:0</td>
      <td>0.508333</td>
      <td>0.050199</td>
      <td>0.065626</td>
      <td>917.453032</td>
      <td>1.053218e+06</td>
      <td>4.160625</td>
    </tr>
    <tr>
      <th>529</th>
      <td>416</td>
      <td>mixnode</td>
      <td>False</td>
      <td>entry_gateway:0;exit_gateway:0;mixnode:42</td>
      <td>0.350000</td>
      <td>0.048505</td>
      <td>0.063977</td>
      <td>629.791516</td>
      <td>7.407572e+05</td>
      <td>2.927424</td>
    </tr>
    <tr>
      <th>533</th>
      <td>164</td>
      <td>mixnode</td>
      <td>False</td>
      <td>entry_gateway:0;exit_gateway:0;mixnode:46</td>
      <td>0.383333</td>
      <td>0.046707</td>
      <td>0.061597</td>
      <td>699.158611</td>
      <td>8.533922e+05</td>
      <td>3.371647</td>
    </tr>
    <tr>
      <th>537</th>
      <td>513</td>
      <td>mixnode</td>
      <td>False</td>
      <td>entry_gateway:0;exit_gateway:0;mixnode:44</td>
      <td>0.366667</td>
      <td>0.039853</td>
      <td>0.055590</td>
      <td>677.816996</td>
      <td>9.123657e+05</td>
      <td>3.611756</td>
    </tr>
    <tr>
      <th>539</th>
      <td>223</td>
      <td>mixnode</td>
      <td>False</td>
      <td>entry_gateway:0;exit_gateway:0;mixnode:34</td>
      <td>0.283333</td>
      <td>0.043298</td>
      <td>0.054618</td>
      <td>513.489137</td>
      <td>7.041682e+05</td>
      <td>2.783497</td>
    </tr>
    <tr>
      <th>550</th>
      <td>193</td>
      <td>mixnode</td>
      <td>False</td>
      <td>entry_gateway:0;exit_gateway:0;mixnode:22</td>
      <td>0.183333</td>
      <td>0.027042</td>
      <td>0.035774</td>
      <td>332.154936</td>
      <td>6.896129e+05</td>
      <td>2.724375</td>
    </tr>
    <tr>
      <th>553</th>
      <td>450</td>
      <td>mixnode</td>
      <td>False</td>
      <td>entry_gateway:0;exit_gateway:0;mixnode:20</td>
      <td>0.166667</td>
      <td>0.025588</td>
      <td>0.033858</td>
      <td>297.234018</td>
      <td>6.455219e+05</td>
      <td>2.550219</td>
    </tr>
    <tr>
      <th>557</th>
      <td>254</td>
      <td>mixnode</td>
      <td>False</td>
      <td>entry_gateway:0;exit_gateway:0;mixnode:26</td>
      <td>0.216667</td>
      <td>0.023261</td>
      <td>0.030563</td>
      <td>386.713868</td>
      <td>9.371951e+05</td>
      <td>3.703419</td>
    </tr>
    <tr>
      <th>561</th>
      <td>39</td>
      <td>mixnode</td>
      <td>False</td>
      <td>entry_gateway:0;exit_gateway:0;mixnode:15</td>
      <td>0.125000</td>
      <td>0.015188</td>
      <td>0.020031</td>
      <td>218.345254</td>
      <td>8.034912e+05</td>
      <td>3.174196</td>
    </tr>
    <tr>
      <th>567</th>
      <td>501</td>
      <td>mixnode</td>
      <td>False</td>
      <td>entry_gateway:0;exit_gateway:0;mixnode:11</td>
      <td>0.091667</td>
      <td>0.008376</td>
      <td>0.011021</td>
      <td>156.785402</td>
      <td>1.040905e+06</td>
      <td>4.124262</td>
    </tr>
    <tr>
      <th>569</th>
      <td>26</td>
      <td>mixnode</td>
      <td>False</td>
      <td>entry_gateway:0;exit_gateway:0;mixnode:5</td>
      <td>0.041667</td>
      <td>0.007145</td>
      <td>0.009441</td>
      <td>68.976595</td>
      <td>5.357516e+05</td>
      <td>2.116625</td>
    </tr>
    <tr>
      <th>586</th>
      <td>241</td>
      <td>mixnode</td>
      <td>False</td>
      <td>entry_gateway:0;exit_gateway:0;mixnode:3</td>
      <td>0.025000</td>
      <td>0.002398</td>
      <td>0.003154</td>
      <td>40.987595</td>
      <td>9.472118e+05</td>
      <td>3.753190</td>
    </tr>
    <tr>
      <th>588</th>
      <td>547</td>
      <td>mixnode</td>
      <td>False</td>
      <td>entry_gateway:0;exit_gateway:0;mixnode:1</td>
      <td>0.008333</td>
      <td>0.001156</td>
      <td>0.001515</td>
      <td>12.126666</td>
      <td>5.841651e+05</td>
      <td>2.309040</td>
    </tr>
  </tbody>
</table>
</div>




```python

```
