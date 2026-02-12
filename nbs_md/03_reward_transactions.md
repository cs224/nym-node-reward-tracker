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


# Reward transaction export

This notebook implements the `reward-transactions` CLI command:

- query Nyx tx history for one or more wallets,
- detect *reward-withdrawal* contract executions,
- compute the actual received NYM from on-chain events,
- (optionally) value each receipt in fiat using CoinGecko.

## Design constraints

- Wallet-first narrative: wallet → tx search → reward filter → amount extraction → pricing.
- Define → use → verify: each helper is introduced, used immediately, and verified with a small assert.

## What this export represents (and what it doesn't)

- This exports *withdrawn* rewards (on-chain receipts), not “pending rewards”.
- Amounts are derived from `transfer` / `coin_received` events for the wallet address.
- `net_nym` subtracts an equal share of tx fees across reward messages in the same tx (approximation).


```python
#| default_exp reward_transactions
```

## Quick API proof (curl)

### Nyx tx search API quick intro (curl)

The examples below intentionally expose the exact JSON shape this notebook needs:
- `txs[].body.messages[]` execute message type/contract/action,
- `tx_responses[].logs[].events[]` reward/transfer/coin_received attributes,
- and `pagination.next_key` for paging.




```bash
%%bash
#| eval: false
NYX_TX_REST="https://api.nymtech.net/cosmos/tx/v1beta1/txs"
WALLET="n127c69pasr35p76amfczemusnutr8mtw78s8xl7"

curl -sG "$NYX_TX_REST"   --data-urlencode "query=message.sender='${WALLET}'"   --data-urlencode "pagination.limit=1"   --data-urlencode "pagination.count_total=true"   --data-urlencode "order_by=ORDER_BY_DESC" | jq '{
  pagination: .pagination,
  tx_meta: (.tx_responses[0] | {txhash, height, timestamp}),
  reward_exec_messages: (
    .txs[0].body.messages
    | to_entries
    | map(
        select((.value."@type" // "") | endswith("MsgExecuteContract"))
        | {
            msg_index: .key,
            type: .value."@type",
            contract: (.value.contract // ""),
            action_keys: (
              if (.value.msg | type) == "object" then ((.value.msg // {}) | keys)
              elif (.value.msg | type) == "string" then
                (try ((.value.msg | @base64d | fromjson) | keys)
                 catch try ((.value.msg | fromjson) | keys)
                 catch [])
              else [] end
            )
          }
      )
  ),
  relevant_events: [
    .tx_responses[0].logs[]?.events[]?
    | select((.type == "transfer") or (.type == "coin_received") or (.type | startswith("wasm")))
    | {
        type,
        msg_index: ([.attributes[]? | select(.key == "msg_index") | .value][0]),
        amount: ([.attributes[]? | select(.key == "amount") | .value][0]),
        recipient: ([.attributes[]? | select((.key == "recipient") or (.key == "receiver")) | .value][0]),
        node_id: ([.attributes[]? | select((.key == "node_id") or (.key == "mix_id")) | .value][0])
      }
  ]
}'

```

    {
      "pagination": null,
      "tx_meta": {
        "txhash": "C2AFFF3A8A967B59EB18B4C8EDF4A180688D7EA5E8B1BE

    3F37916B98723DC420",
        "height": "22250074",
        "timestamp": "2026-02-04T12:18:10Z"
      },
      "rewar

    d_exec_messages": [
        {
          "msg_index": 0,
          "type": "/cosmwasm.wasm.v1.MsgExecuteContract"

    ,
          "contract": "n17srjznxl9dvzdkpwpw24gg668wc73val88a6m5ajg6ankwvz9wtst0cznr",
          "action_ke

    ys": [
            "update_cost_params"
          ]
        }
      ],
      "relevant_events": []
    }



```bash
%%bash
#| eval: false
NYX_TX_REST="https://api.nymtech.net/cosmos/tx/v1beta1/txs"
WALLET="n127c69pasr35p76amfczemusnutr8mtw78s8xl7"

RESP1=$(curl -sG "$NYX_TX_REST"   --data-urlencode "query=message.sender='${WALLET}'"   --data-urlencode "pagination.limit=1"   --data-urlencode "pagination.count_total=true"   --data-urlencode "order_by=ORDER_BY_DESC")

echo "$RESP1" | jq '{page: 1, next_key: .pagination.next_key, txhash: .tx_responses[0].txhash}'

NEXT=$(echo "$RESP1" | jq -r '.pagination.next_key')
if [ "$NEXT" = "null" ] || [ -z "$NEXT" ]; then
  echo "No next_key returned (only one page of results)."
  exit 0
fi

RESP2=$(curl -sG "$NYX_TX_REST"   --data-urlencode "query=message.sender='${WALLET}'"   --data-urlencode "pagination.limit=1"   --data-urlencode "pagination.key=$NEXT"   --data-urlencode "order_by=ORDER_BY_DESC")

echo "$RESP2" | jq '{page: 2, next_key: .pagination.next_key, txhash: .tx_responses[0].txhash}'

```

    {
      "page": 1,
      "next_key": null,
      "txhash": "C2AFFF3A8A967B59EB18B4C8EDF4A180688D7EA5E8B1BE3F3791

    6B98723DC420"
    }


    No next_key returned (only one page of results).


## Imports + constants

We reuse shared helpers from `nym_node_reward_tracker.common`:
- `build_session` (requests.Session with headers)
- `request_json` (GET JSON with retry/backoff + logging)
- numeric parsing helpers (`to_int`, `to_decimal`)



```python
#| export
from __future__ import annotations

import base64
import bisect
import csv
import datetime as dt
import json
import logging
from decimal import Decimal
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Tuple

from pydantic import BaseModel, ConfigDict
from tabulate import tabulate
from tqdm import tqdm

from nym_node_reward_tracker.cosmos_tx_parsing import (
    attr_map,
    events_by_msg_index,
    extract_events,
    node_id_from_attrs,
    parse_coins,
    sum_incoming_nym_from_events,
)
from nym_node_reward_tracker.common import (
    DEFAULT_TIMEOUT_S,
    MICRO,
    NYM_DENOM,
    build_session,
    build_tx_query,
    iter_txs_by_query,
    parse_date_filters,
    parse_rfc3339_to_utc,
    read_wallets_csv,
    request_json,
    setup_logging,
    to_decimal,
    to_int,
)

DEFAULT_NYX_API_BASE = "https://api.nymtech.net"
DEFAULT_NYX_TX_REST = f"{DEFAULT_NYX_API_BASE}/cosmos/tx/v1beta1/txs"

DEFAULT_COINGECKO_BASE = "https://api.coingecko.com/api/v3"
DEFAULT_TX_API_BASE = DEFAULT_NYX_TX_REST
DEFAULT_TX_RPC_BASE = "https://rpc.nymtech.net"

# Keep this overrideable via CLI arg --mixnet-contract.
DEFAULT_MIXNET_CONTRACT = "n17srjznxl9dvzdkpwpw24gg668wc73val88a6m5ajg6ankwvz9wtst0cznr"

REWARD_ACTION_KEYS = {
    "withdraw_operator_reward",
    "withdraw_delegator_reward",
    "withdraw_operator_reward_on_behalf",
    "withdraw_delegator_reward_on_behalf",
    "compound_operator_reward",
    "compound_delegator_reward",
    "claim_operator_reward",
    "claim_delegator_reward",
}

```

## Wallet rows

We read `wallet-addresses.csv` (`address,tag`) into small Pydantic models so validation and serialization are explicit.



```python
#| export
class WalletRow(BaseModel):
    """Wallet input row from CSV (`address`, optional `tag`)."""
    model_config = ConfigDict(frozen=True)

    address: str
    tag: str = ""

class RewardMessage(BaseModel):
    """Parsed reward withdrawal message with resolved `node_id` and action kind."""
    msg_index: int
    action: str
    node_id: int | None = None


class RewardTxRow(BaseModel):
    """Normalized reward-withdrawal transaction row before fiat enrichment/export."""
    timestamp_utc: str
    wallet: str
    tag: str = ""
    txhash: str
    tx_url: str
    height: str = ""
    msg_index: int
    action: str
    node_id: int | None = None
    amount_nym: str
    tx_fee_nym: str
    fee_alloc_nym: str
    net_nym: str
    price_timestamp_utc: str = ""
    price_time_diff_seconds: str = ""


def load_wallets(wallets_csv: str | Path) -> List[WalletRow]:
    rows = read_wallets_csv(wallets_csv)
    return [WalletRow(address=a, tag=t) for a, t in rows]

```


```python
from tempfile import TemporaryDirectory

```


```python
with TemporaryDirectory() as td:
    p = Path(td) / "wallets.csv"
    p.write_text("address,tag\nn1abc,test\n", encoding="utf-8")
    ws = load_wallets(p)
    assert ws == [WalletRow(address="n1abc", tag="test")]

ws

```




    [WalletRow(address='n1abc', tag='test')]



## Reused common date + tx query helpers


The generic infrastructure helpers now live in `00_common.ipynb` and are imported here:
- `parse_rfc3339_to_utc`
- `parse_date_filters`
- `build_tx_query`
- `iter_txs_by_query`

This keeps wallet tx pagination and date semantics identical across notebooks.




```python
from nym_node_reward_tracker.common import _FakeResp, _FakeSession

```


```python
assert parse_rfc3339_to_utc("2025-12-04T16:31:51Z").tzinfo == dt.timezone.utc

s, e = parse_date_filters("2025-01-01", "2025-01-01")
assert s.isoformat().startswith("2025-01-01T00:00:00")
assert e.isoformat().startswith("2025-01-02T00:00:00")

page1 = {
    "txs": [{"body": {"messages": []}, "auth_info": {"fee": {"amount": []}}}],
    "tx_responses": [{"txhash": "A", "timestamp": "2025-01-01T00:00:00Z"}],
    "pagination": {"next_key": "K1", "total": "2"},
}
page2 = {
    "txs": [{"body": {"messages": []}, "auth_info": {"fee": {"amount": []}}}],
    "tx_responses": [{"txhash": "B", "timestamp": "2025-01-02T00:00:00Z"}],
    "pagination": {"next_key": None, "total": "2"},
}

fake = _FakeSession([_FakeResp(page1), _FakeResp(page2)])
rows = list(iter_txs_by_query(fake, nyx_tx_rest="https://example", query="q", page_limit=1))
assert [r[1]["txhash"] for r in rows] == ["A", "B"]

assert build_tx_query("n1x", "sender") == "message.sender='n1x'"
assert build_tx_query("n1x", "recipient") == "transfer.recipient='n1x'"

```

## Decode execute msgs + reward detection

We import shared tx parsing helpers from `00_cosmos_tx_parsing.ipynb` and keep only reward-specific message decoding here for optional action-label enrichment.


```python
#| export
def decode_execute_msg(msg_field: Any) -> Optional[Dict[str, Any]]:
    if isinstance(msg_field, dict):
        return msg_field
    if isinstance(msg_field, str):
        s = msg_field.strip()
        if not s:
            return None
        try:
            raw = base64.b64decode(s)
            return json.loads(raw.decode("utf-8"))
        except Exception:
            try:
                return json.loads(s)
            except Exception:
                return None
    return None


def extract_action(exec_msg: Dict[str, Any]) -> str:
    return next(iter(exec_msg.keys()), "") if isinstance(exec_msg, dict) else ""

```


```python
raw = {"withdraw_operator_reward": {"mix_id": 7}}
b64 = base64.b64encode(json.dumps(raw).encode("utf-8")).decode("utf-8")
assert decode_execute_msg(raw) == raw
assert decode_execute_msg(b64) == raw
assert extract_action(raw) == "withdraw_operator_reward"

```

Now we detect rewards from withdraw wasm events (event-first). Optional message decoding is used only to enrich the action label.


```python
#| export
WITHDRAW_WASM_EVENT_TO_ACTION = {
    "wasm-v2_withdraw_operator_reward": "withdraw_operator_reward",
    "wasm-v2_withdraw_delegator_reward": "withdraw_delegator_reward",
}


def _reward_withdrawals_from_events_by_index(
    ev_by_idx: Dict[int, List[Dict[str, Any]]],
    *,
    mixnet_contract: str,
) -> List[Dict[str, Any]]:
    out: List[Dict[str, Any]] = []
    for msg_index, evs in sorted(ev_by_idx.items()):
        base_action: Optional[str] = None
        node_id: Optional[int] = None
        for ev in evs:
            et = str(ev.get("type") or "")
            if et not in WITHDRAW_WASM_EVENT_TO_ACTION:
                continue
            attrs = attr_map(ev.get("attributes"))
            contract = attrs.get("_contract_address") or ""
            if contract and mixnet_contract and contract != mixnet_contract:
                continue
            base_action = WITHDRAW_WASM_EVENT_TO_ACTION[et]
            node_id = node_id_from_attrs(attrs)
            break
        if base_action:
            out.append({"msg_index": int(msg_index), "action": base_action, "node_id": node_id})
    return out


def _enrich_action_from_message(
    messages: List[Dict[str, Any]],
    *,
    msg_index: int,
    mixnet_contract: str,
) -> Optional[str]:
    if msg_index < 0 or msg_index >= len(messages):
        return None
    msg = messages[msg_index]
    if str(msg.get("@type") or "").endswith("MsgExecuteContract") is False:
        return None
    if mixnet_contract and str(msg.get("contract") or "").strip() != mixnet_contract:
        return None
    exec_msg = decode_execute_msg(msg.get("msg"))
    if not exec_msg:
        return None
    action = extract_action(exec_msg)
    return action if action in REWARD_ACTION_KEYS else None

```


```python
logs = {
    "logs": [{
        "msg_index": "0",
        "events": [{
            "type": "wasm-v2_withdraw_operator_reward",
            "attributes": [{"key": "_contract_address", "value": DEFAULT_MIXNET_CONTRACT}, {"key": "mix_id", "value": "2196"}],
        }],
    }]
}
by_idx = events_by_msg_index(logs)
found = _reward_withdrawals_from_events_by_index(by_idx, mixnet_contract=DEFAULT_MIXNET_CONTRACT)
assert found == [{"msg_index": 0, "action": "withdraw_operator_reward", "node_id": 2196}]

msgs = [{"@type": "/cosmwasm.wasm.v1.MsgExecuteContract", "contract": DEFAULT_MIXNET_CONTRACT, "msg": {"withdraw_operator_reward": {}}}]
assert _enrich_action_from_message(msgs, msg_index=0, mixnet_contract=DEFAULT_MIXNET_CONTRACT) == "withdraw_operator_reward"

```

## Event interpretation (amount + node_id fallback)

To compute received NYM and node identifiers, we reuse `parse_coins`, `events_by_msg_index`, and incoming-amount helpers from `00_cosmos_tx_parsing.ipynb`. Local helpers only handle reward-specific fallback semantics.


```python
#| export
def node_id_from_wasm_events(events: List[Dict[str, Any]]) -> Optional[int]:
    for ev in events:
        et = str(ev.get("type") or "")
        if not et.startswith("wasm"):
            continue
        nid = node_id_from_attrs(attr_map(ev.get("attributes")))
        if nid is not None:
            return nid
    return None


def node_id_from_tx_response_events(tx_resp: Dict[str, Any]) -> Optional[int]:
    for ev in extract_events(tx_resp):
        et = str(ev.get("type") or "")
        if not et.startswith("wasm"):
            continue
        nid = node_id_from_attrs(ev.get("attributes") or {})
        if nid is not None:
            return nid
    return None

```


```python
assert parse_coins("100unym,5ufoo") == [(100, "unym"), (5, "ufoo")]
```

We group events by `msg_index` with shared logic from `00_cosmos_tx_parsing.ipynb`.


```python
evs = events_by_msg_index({"logs": [{"msg_index": "0", "events": [{"type": "transfer", "attributes": []}]}]})
assert 0 in evs and evs[0][0]["type"] == "transfer"
```


```python
fake_resp = {"logs": [{"msg_index": "0", "events": [{"type": "transfer", "attributes": []}]}]}
evs = events_by_msg_index(fake_resp, logger=logging.getLogger("t"), txhash="x")
assert 0 in evs and evs[0][0]["type"] == "transfer"
```

### sum incoming NYM (shared helper)


```python
addr = "n1abc"

# transfer + coin_received mirror the same movement -> count once
events = [
    {"type": "transfer", "attributes": [{"key": "recipient", "value": addr}, {"key": "amount", "value": "2000000unym"}]},
    {"type": "coin_received", "attributes": [{"key": "receiver", "value": addr}, {"key": "amount", "value": "2000000unym"}]},
]
assert sum_incoming_nym_from_events(events, addr) == Decimal("2")

# fallback: if transfer is absent, use coin_received
events_coin_only = [
    {"type": "coin_received", "attributes": [{"key": "receiver", "value": addr}, {"key": "amount", "value": "1000000unym"}]},
]
assert sum_incoming_nym_from_events(events_coin_only, addr) == Decimal("1")

```


```python
addr = "n1abc"

# transfer + coin_received mirror the same movement -> count once
events = [
    {"type": "transfer", "attributes": [{"key": "recipient", "value": addr}, {"key": "amount", "value": "2000000unym"}]},
    {"type": "coin_received", "attributes": [{"key": "receiver", "value": addr}, {"key": "amount", "value": "2000000unym"}]},
]
assert sum_incoming_nym_from_events(events, addr) == Decimal("2")

# fallback: if transfer is absent, use coin_received
events_coin_only = [
    {"type": "coin_received", "attributes": [{"key": "receiver", "value": addr}, {"key": "amount", "value": "1000000unym"}]},
]
assert sum_incoming_nym_from_events(events_coin_only, addr) == Decimal("1")

```

### tx fee in NYM + node_id fallback



```python
#| export
def sum_fee_nym(tx: Dict[str, Any]) -> Decimal:
    fee = (((tx or {}).get("auth_info") or {}).get("fee") or {})
    total_unym = 0
    for c in (fee.get("amount") or []):
        if not isinstance(c, dict):
            continue
        if c.get("denom") == NYM_DENOM:
            total_unym += int(to_int(c.get("amount"), 0) or 0)
    return Decimal(total_unym) / MICRO

```


```python
tx = {"auth_info": {"fee": {"amount": [{"denom": "unym", "amount": "3000"}]}}}
assert sum_fee_nym(tx) == Decimal("0.003")

wasm_events = [{"type": "wasm-v2_withdraw_operator_reward", "attributes": [{"key": "mix_id", "value": "2196"}]}]
assert node_id_from_wasm_events(wasm_events) == 2196

tx_resp = {"events": [{"type": "wasm-v2_withdraw_operator_reward", "attributes": [{"key": "mix_id", "value": "2196"}]}]}
assert node_id_from_tx_response_events(tx_resp) == 2196


```

### Build export rows from a tx

For each reward message we create one row.

If a tx contains multiple reward messages, we allocate the tx fee evenly across them.

### Tx URL fallback chain


We resolve a robust `tx_url` per transaction with this chain: primary tx base (default Nyx tx REST), then explicit tx API base, then RPC `/tx` query.


```python
#| export
def _tx_url_candidates(
    txhash: str,
    *,
    explorer_base: str,
    tx_api_base: str,
    tx_rpc_base: str,
) -> List[Tuple[str, str]]:
    h = txhash.strip()
    raw = [
        ("explorer", f"{explorer_base.rstrip('/')}/{h}"),
        ("tx_api", f"{tx_api_base.rstrip('/')}/{h}"),
        ("tx_rpc", f"{tx_rpc_base.rstrip('/')}/tx?hash=0x{h}&prove=false"),
    ]
    out: List[Tuple[str, str]] = []
    seen: set[str] = set()
    for kind, url in raw:
        if url in seen:
            continue
        seen.add(url)
        out.append((kind, url))
    return out


def _tx_url_is_reachable(
    session: Any,
    *,
    kind: str,
    url: str,
    timeout: int,
    logger: logging.Logger,
) -> bool:
    try:
        if kind in ("tx_api", "tx_rpc"):
            js = request_json(session, url, timeout=timeout, retries=2, logger=logger)
            if not isinstance(js, dict):
                return False
            if kind == "tx_api":
                return isinstance(js.get("tx_response"), dict)
            return isinstance(js.get("result"), dict)

        resp = session.get(url, timeout=timeout)
        return int(getattr(resp, "status_code", 0) or 0) < 400
    except Exception as exc:
        logger.debug("tx_url check failed kind=%s url=%s err=%s", kind, url, exc)
        return False


def resolve_tx_url(
    txhash: str,
    *,
    session: Any | None,
    explorer_base: str,
    tx_api_base: str,
    tx_rpc_base: str,
    timeout: int,
    logger: logging.Logger,
) -> str:
    candidates = _tx_url_candidates(
        txhash,
        explorer_base=explorer_base,
        tx_api_base=tx_api_base,
        tx_rpc_base=tx_rpc_base,
    )
    if session is None:
        return candidates[0][1]

    for kind, url in candidates:
        if _tx_url_is_reachable(session, kind=kind, url=url, timeout=timeout, logger=logger):
            return url

    return candidates[0][1]

```


```python
from nym_node_reward_tracker.common import _FakeResp, _FakeSession

```


```python
sess = _FakeSession([
    _FakeResp({}, status_code=404),
    _FakeResp({"tx_response": {"txhash": "H"}}, status_code=200),
])
url = resolve_tx_url(
    "H",
    session=sess,
    explorer_base="https://example.invalid/nyx/tx",
    tx_api_base="https://api.nymtech.net/cosmos/tx/v1beta1/txs",
    tx_rpc_base="https://rpc.nymtech.net",
    timeout=5,
    logger=logging.getLogger("t"),
)
assert url.endswith('/cosmos/tx/v1beta1/txs/H')

```

Intent: convert one transaction into zero or more normalized reward rows, combining event and message-derived fields.


```python
#| export
def build_reward_rows_for_tx(
    *,
    wallet: WalletRow,
    tx: Dict[str, Any],
    tx_resp: Dict[str, Any],
    mixnet_contract: str,
    explorer_base: str,
    tx_api_base: str,
    tx_rpc_base: str,
    logger: logging.Logger,
    session: Any | None = None,
) -> List[Dict[str, Any]]:
    txhash = str(tx_resp.get("txhash") or tx_resp.get("hash") or "")
    if not txhash:
        return []

    timestamp = str(tx_resp.get("timestamp") or "")
    if not timestamp:
        return []
    ts_dt = parse_rfc3339_to_utc(timestamp)

    messages = (((tx or {}).get("body") or {}).get("messages") or [])
    if not isinstance(messages, list):
        messages = []
    messages = [m for m in messages if isinstance(m, dict)]

    ev_by_idx = events_by_msg_index(tx_resp, logger=logger, txhash=txhash)
    reward_msgs = _reward_withdrawals_from_events_by_index(ev_by_idx, mixnet_contract=mixnet_contract)
    if not reward_msgs:
        return []

    tx_url = resolve_tx_url(
        txhash,
        session=session,
        explorer_base=explorer_base,
        tx_api_base=tx_api_base,
        tx_rpc_base=tx_rpc_base,
        timeout=DEFAULT_TIMEOUT_S,
        logger=logger,
    )
    tx_fee_nym = sum_fee_nym(tx)
    fee_alloc = tx_fee_nym / Decimal(max(len(reward_msgs), 1))

    rows: List[Dict[str, Any]] = []
    for rm in reward_msgs:
        i = int(rm["msg_index"])
        evs = ev_by_idx.get(i, [])

        action = str(rm["action"])
        enriched = _enrich_action_from_message(messages, msg_index=i, mixnet_contract=mixnet_contract)
        if enriched:
            action = enriched

        amount_nym = sum_incoming_nym_from_events(evs, wallet.address)
        node_id = rm.get("node_id") or node_id_from_wasm_events(evs) or node_id_from_tx_response_events(tx_resp)
        net_nym = amount_nym - fee_alloc

        row = RewardTxRow(
            timestamp_utc=ts_dt.isoformat(),
            wallet=wallet.address,
            tag=wallet.tag,
            txhash=txhash,
            tx_url=tx_url,
            height=str(tx_resp.get("height") or ""),
            msg_index=i,
            action=action,
            node_id=node_id,
            amount_nym=f"{amount_nym:.6f}",
            tx_fee_nym=f"{tx_fee_nym:.6f}",
            fee_alloc_nym=f"{fee_alloc:.6f}",
            net_nym=f"{net_nym:.6f}",
        ).model_dump()
        if row.get("node_id") is None:
            row["node_id"] = ""
        rows.append(row)

    return rows

```


```python
w = WalletRow(address="n1abc", tag="t")
tx = {
    "body": {
        "messages": [
            {
                "@type": "/cosmwasm.wasm.v1.MsgExecuteContract",
                "contract": DEFAULT_MIXNET_CONTRACT,
                "msg": {"withdraw_operator_reward": {}},
            }
        ]
    },
    "auth_info": {"fee": {"amount": [{"denom": "unym", "amount": "1000"}]}}
}

tx_resp = {
    "txhash": "H",
    "height": "1",
    "timestamp": "2025-01-01T00:00:00Z",
    "logs": [{
        "msg_index": "0",
        "events": [
            {"type": "wasm-v2_withdraw_operator_reward", "attributes": [{"key": "_contract_address", "value": DEFAULT_MIXNET_CONTRACT}, {"key": "mix_id", "value": "2196"}]},
            {"type": "transfer", "attributes": [{"key": "recipient", "value": "n1abc"}, {"key": "amount", "value": "1000000unym"}]},
        ],
    }],
}

rows = build_reward_rows_for_tx(
    wallet=w,
    tx=tx,
    tx_resp=tx_resp,
    mixnet_contract=DEFAULT_MIXNET_CONTRACT,
    explorer_base=DEFAULT_NYX_TX_REST,
    tx_api_base=DEFAULT_TX_API_BASE,
    tx_rpc_base=DEFAULT_TX_RPC_BASE,
    logger=logging.getLogger("t"),
)
assert rows and rows[0]["node_id"] == 2196
assert rows[0]["amount_nym"] == "1.000000"
assert rows[0]["action"] == "withdraw_operator_reward"

```

### Live Nyx extraction proof (real API)



```python
#| eval: false

wallet = WalletRow(address="n127c69pasr35p76amfczemusnutr8mtw78s8xl7", tag="operator")
session = build_session("nym-node-reward-tracker/reward-transactions-live-demo")
query = build_tx_query(wallet.address, "sender")

l = list(iter_txs_by_query(session, nyx_tx_rest=DEFAULT_NYX_TX_REST, query=query, page_limit=20, order_by="ORDER_BY_DESC", progress_desc=None))
print(len(l))

```

    14



```python
#| eval: false
logger = logging.getLogger("live_reward_demo")
for i in range(len(l)):
    tx, tx_resp = l[i]
    ev_by_idx = events_by_msg_index(tx_resp, logger=logger, txhash=str(tx_resp.get("txhash") or ""))
    reward_msgs = _reward_withdrawals_from_events_by_index(ev_by_idx, mixnet_contract=DEFAULT_MIXNET_CONTRACT)
    if reward_msgs:
        print(i, tx_resp.get("txhash"), reward_msgs)
        break

```

    12 30C980A159389BC26BA2B199CD13EEF4F269DF63D82F588AA67C2882EFEF295C [{'msg_index': 0, 'action': 'withdraw_operator_reward', 'node_id': 2196}]



```python
#| eval: false
idx = reward_msgs[0]["msg_index"]
evs = ev_by_idx[idx]
ev_types = [str(e.get("type") or "") for e in evs]
print(ev_types)

```

    ['message', 'execute', 'wasm-v2_withdraw_operator_reward', 'coin_spent', 'coin_received', 'transfer']



```python
#| eval: false
amount_nym = sum_incoming_nym_from_events(evs, wallet.address)
print(amount_nym)

```

    3009.552561



```python
#| eval: false

wallet = WalletRow(address="n127c69pasr35p76amfczemusnutr8mtw78s8xl7", tag="operator")
session = build_session("nym-node-reward-tracker/reward-transactions-live-demo")
query = build_tx_query(wallet.address, "sender")

scanned = 0
live_rows: List[Dict[str, Any]] = []
for tx, resp in iter_txs_by_query(
    session,
    nyx_tx_rest=DEFAULT_NYX_TX_REST,
    query=query,
    page_limit=20,
    order_by="ORDER_BY_DESC",
    progress_desc=None,
):
    scanned += 1
    live_rows.extend(
        build_reward_rows_for_tx(
            wallet=wallet,
            tx=tx,
            tx_resp=resp,
            mixnet_contract=DEFAULT_MIXNET_CONTRACT,
            explorer_base=DEFAULT_NYX_TX_REST,
            tx_api_base=DEFAULT_TX_API_BASE,
            tx_rpc_base=DEFAULT_TX_RPC_BASE,
            logger=logging.getLogger("live_reward_demo"),
            session=session,
        )
    )
    if len(live_rows) >= 3 or scanned >= 200:
        break

print({"scanned_txs": scanned, "reward_rows_found": len(live_rows)})
for row in live_rows[:3]:
    print({
        "txhash": row["txhash"],
        "msg_index": row["msg_index"],
        "action": row["action"],
        "node_id": row["node_id"],
        "amount_nym": row["amount_nym"],
        "tx_fee_nym": row["tx_fee_nym"],
    })
live_rows
```

    {'scanned_txs': 14, 'reward_rows_found': 1}
    {'txhash': '30C980A159389BC26BA2B199CD13EEF4F269DF63D82F588AA67C2882EFEF295C', 'msg_index': 0, 'action': 'withdraw_operator_reward', 'node_id': 2196, 'amount_nym': '3009.552561', 'tx_fee_nym': '0.005163'}





    [{'timestamp_utc': '2025-12-04T16:31:51+00:00',
      'wallet': 'n127c69pasr35p76amfczemusnutr8mtw78s8xl7',
      'tag': 'operator',
      'txhash': '30C980A159389BC26BA2B199CD13EEF4F269DF63D82F588AA67C2882EFEF295C',
      'tx_url': 'https://api.nymtech.net/cosmos/tx/v1beta1/txs/30C980A159389BC26BA2B199CD13EEF4F269DF63D82F588AA67C2882EFEF295C',
      'height': '21312646',
      'msg_index': 0,
      'action': 'withdraw_operator_reward',
      'node_id': 2196,
      'amount_nym': '3009.552561',
      'tx_fee_nym': '0.005163',
      'fee_alloc_nym': '0.005163',
      'net_nym': '3009.547398',
      'price_timestamp_utc': '',
      'price_time_diff_seconds': ''}]



## Pricing (CoinGecko) + nearest-point selection


We fetch a price series over the minimal time window that covers all receipts,
then select the nearest price point per tx timestamp.

Note: for interface compatibility we keep the `cache_dir` argument in `run_reward_transactions`,
but this rewrite intentionally does not cache price responses.


```python
#| export
def fetch_coingecko_prices_range(
    session: Any,
    *,
    coingecko_base: str,
    coin_id: str,
    vs_currency: str,
    from_ts: int,
    to_ts: int,
    api_key: Optional[str],
    timeout: int = DEFAULT_TIMEOUT_S,
    retries: int = 6,
    logger: Optional[logging.Logger] = None,
) -> List[Tuple[int, Decimal]]:
    url = f"{coingecko_base.rstrip('/')}/coins/{coin_id}/market_chart/range"
    params = {"vs_currency": vs_currency, "from": str(from_ts), "to": str(to_ts)}

    headers: Dict[str, str] = {}
    if api_key:
        headers["x-cg-demo-api-key"] = api_key

    js = request_json(
        session,
        url,
        params=params,
        headers=headers or None,
        timeout=timeout,
        retries=retries,
        logger=logger,
    )
    if not isinstance(js, dict):
        return []

    points: List[Tuple[int, Decimal]] = []
    for item in (js.get("prices") or []):
        if not isinstance(item, (list, tuple)) or len(item) < 2:
            continue
        t_ms, px = item[0], item[1]
        dec_px = to_decimal(px)
        if dec_px is None:
            continue
        points.append((int(int(t_ms) / 1000), dec_px))

    points.sort(key=lambda x: x[0])
    dedup: Dict[int, Decimal] = {}
    for t, px in points:
        dedup[t] = px
    return sorted(dedup.items(), key=lambda x: x[0])


def nearest_price(points: List[Tuple[int, Decimal]], ts: int) -> Tuple[Optional[int], Optional[Decimal], Optional[int]]:
    if not points:
        return (None, None, None)
    times = [p[0] for p in points]
    i = bisect.bisect_left(times, ts)

    candidates: List[Tuple[int, Decimal]] = []
    if i > 0:
        candidates.append(points[i - 1])
    if i < len(points):
        candidates.append(points[i])

    best = min(candidates, key=lambda p: abs(ts - p[0]))
    return (best[0], best[1], abs(ts - best[0]))
```


```python
assert nearest_price([(100, Decimal("1.0")), (200, Decimal("2.0"))], 180)[1] == Decimal("2.0")

# Fake CoinGecko response

```


```python
from nym_node_reward_tracker.common import _FakeResp, _FakeSession

```


```python
fake = _FakeSession([_FakeResp({"prices": [[1000, 0.5]]})])
pts = fetch_coingecko_prices_range(
    fake,
    coingecko_base="https://example",
    coin_id="nym",
    vs_currency="eur",
    from_ts=0,
    to_ts=2,
    api_key=None,
)
assert pts == [(1, Decimal("0.5"))]

```

### enrich rows


```python
#| export
def enrich_rows_with_prices(
    rows: List[Dict[str, Any]],
    *,
    session: Any,
    currency: str,
    coingecko_base: str,
    coin_id: str,
    api_key: Optional[str],
    logger: logging.Logger,
) -> None:
    if not rows:
        return

    stamps = [int(parse_rfc3339_to_utc(r["timestamp_utc"]).timestamp()) for r in rows]
    from_ts = int(min(stamps)) - 3600
    to_ts = int(max(stamps)) + 3600

    logger.info("CoinGecko price window unix=%s..%s (%s)", from_ts, to_ts, currency)

    points = fetch_coingecko_prices_range(
        session,
        coingecko_base=coingecko_base,
        coin_id=coin_id,
        vs_currency=currency,
        from_ts=from_ts,
        to_ts=to_ts,
        api_key=api_key,
        logger=logger,
    )
    logger.info("Loaded %d price points", len(points))

    for r in rows:
        ts = int(parse_rfc3339_to_utc(r["timestamp_utc"]).timestamp())
        p_ts, px, diff = nearest_price(points, ts)

        amt = Decimal(str(r.get("amount_nym") or "0"))
        if px is None:
            r[f"price_{currency}_per_nym"] = ""
            r[f"value_{currency}"] = ""
            r["price_timestamp_utc"] = ""
            r["price_time_diff_seconds"] = ""
            continue

        value = amt * px
        r[f"price_{currency}_per_nym"] = f"{px:.8f}"
        r[f"value_{currency}"] = f"{value:.2f}"
        r["price_timestamp_utc"] = dt.datetime.fromtimestamp(int(p_ts), tz=dt.timezone.utc).isoformat() if p_ts else ""
        r["price_time_diff_seconds"] = str(diff if diff is not None else "")
```


```python
rows = [{
    "timestamp_utc": "2025-01-01T00:00:00+00:00",
    "amount_nym": "1.000000",
}]
fake = _FakeSession([_FakeResp({"prices": [[1735689600000, 0.5]]})])  # 2025-01-01T00:00:00Z
enrich_rows_with_prices(
    rows,
    session=fake,
    currency="eur",
    coingecko_base="https://example",
    coin_id="nym",
    api_key=None,
    logger=logging.getLogger("t"),
)
assert rows[0]["price_eur_per_nym"] != ""
assert rows[0]["value_eur"] == "0.50"
```

##  Output writing + CLI-friendly table log

- We log a compact table (CLI visibility).
- We write `.csv` or `.xlsx` based on output filename suffix.


```python
#| export
def log_rows_table(rows: List[Dict[str, Any]], *, currency: str, logger: logging.Logger) -> None:
    headers = [
        "timestamp_utc",
        "wallet",
        "action",
        "node_id",
        "amount_nym",
        "net_nym",
        f"price_{currency}_per_nym",
        f"value_{currency}",
    ]
    view = [
        [
            r.get("timestamp_utc", ""),
            r.get("wallet", ""),
            r.get("action", ""),
            r.get("node_id", ""),
            r.get("amount_nym", ""),
            r.get("net_nym", ""),
            r.get(f"price_{currency}_per_nym", ""),
            r.get(f"value_{currency}", ""),
        ]
        for r in rows
    ]
    logger.info("")
    logger.info("Reward transactions (table)")
    logger.info("\n%s", tabulate(view, headers=headers, tablefmt="github", stralign="right", disable_numparse=True))


def write_rows(rows: List[Dict[str, Any]], *, currency: str, out_path: str | Path) -> None:
    p = Path(out_path)
    p.parent.mkdir(parents=True, exist_ok=True)

    fieldnames = [
        "timestamp_utc",
        "wallet",
        "tag",
        "txhash",
        "tx_url",
        "height",
        "msg_index",
        "action",
        "node_id",
        "amount_nym",
        "tx_fee_nym",
        "fee_alloc_nym",
        "net_nym",
        f"price_{currency}_per_nym",
        f"value_{currency}",
        "price_timestamp_utc",
        "price_time_diff_seconds",
    ]

    suffix = p.suffix.lower()
    if suffix == ".xlsx":
        try:
            from openpyxl import Workbook
        except ImportError as exc:
            raise RuntimeError("openpyxl is required for .xlsx output") from exc

        wb = Workbook()
        ws = wb.active
        ws.title = "reward_transactions"
        ws.append(fieldnames)
        for r in rows:
            ws.append([r.get(k, "") for k in fieldnames])
        wb.save(p)
        return

    if suffix not in ("", ".csv"):
        raise ValueError(f"Unsupported output extension '{suffix}' for {p}. Use .csv or .xlsx")

    with p.open("w", newline="", encoding="utf-8") as f:
        wtr = csv.DictWriter(f, fieldnames=fieldnames)
        wtr.writeheader()
        for r in rows:
            wtr.writerow(r)
```


```python
from tempfile import TemporaryDirectory

```


```python
with TemporaryDirectory() as td:
    p = Path(td) / "out.csv"
    write_rows([{"timestamp_utc": "x", "wallet": "w"}], currency="eur", out_path=p)
    assert p.exists()

```

## Main entrypoint

This is the CLI-facing function imported by `10_cli.md`.

- return `2` when wallets CSV is empty / has no wallets,
- return `0` when no reward receipts are found (and log a warning),
- always query Nyx directly (no SQLite cache involvement).
- resolve `tx_url` via fallback chain: explorer -> tx API -> tx RPC.



```python
#| export
def run_reward_transactions(
    *,
    wallets_csv: str = "wallet-addresses.csv",
    out_csv: str = "nym_rewards_tax_export.csv",
    currency: str = "eur",
    start: Optional[str] = None,
    end: Optional[str] = None,
    nyx_api_base: Optional[str] = None,
    mixnet_contract: Optional[str] = None,
    coin_id: Optional[str] = None,
    coingecko_base: Optional[str] = None,
    coingecko_api_key: Optional[str] = None,
    cache_dir: Optional[str] = ".cache",
    search_mode: str = "sender",
    explorer_base: Optional[str] = None,
    tx_api_base: Optional[str] = None,
    tx_rpc_base: Optional[str] = None,
    log_file: Optional[str] = None,
    log_level: str = "INFO",
) -> int:
    logger = setup_logging("nym_tax_export", log_file=log_file, level=log_level)

    if cache_dir:
        logger.debug("cache_dir is currently unused in this rewrite (fresh API calls). cache_dir=%s", cache_dir)

    wallets = load_wallets(wallets_csv)
    if not wallets:
        logger.error("No wallets found in %s", wallets_csv)
        return 2

    start_dt, end_dt = parse_date_filters(start, end)

    nyx_base = (nyx_api_base or DEFAULT_NYX_API_BASE).rstrip("/")
    nyx_tx_rest = f"{nyx_base}/cosmos/tx/v1beta1/txs"

    mixnet_addr = mixnet_contract or DEFAULT_MIXNET_CONTRACT
    explorer = explorer_base or DEFAULT_NYX_TX_REST
    tx_api = tx_api_base or nyx_tx_rest
    tx_rpc = tx_rpc_base or DEFAULT_TX_RPC_BASE
    cg_base = coingecko_base or DEFAULT_COINGECKO_BASE
    cg_coin = coin_id or "nym"

    session = build_session("nym-node-reward-tracker/reward-transactions")

    rows: List[Dict[str, Any]] = []

    with tqdm(total=len(wallets), desc="Wallets", unit="wallet") as wbar:
        for w in wallets:
            q = build_tx_query(w.address, search_mode)
            logger.info("Scanning wallet=%s tag=%s query=%r", w.address, w.tag, q)

            for tx, resp in iter_txs_by_query(
                session,
                nyx_tx_rest=nyx_tx_rest,
                query=q,
                page_limit=100,
                order_by="ORDER_BY_ASC",
                logger=logger,
                progress_desc=f"Txs {w.address[:8]}",
            ):
                ts_raw = str(resp.get("timestamp") or "")
                if not ts_raw:
                    continue
                ts_dt = parse_rfc3339_to_utc(ts_raw)

                if start_dt and ts_dt < start_dt:
                    continue
                if end_dt and ts_dt >= end_dt:
                    continue

                rows.extend(
                    build_reward_rows_for_tx(
                        wallet=w,
                        tx=tx,
                        tx_resp=resp,
                        mixnet_contract=mixnet_addr,
                        explorer_base=explorer,
                        tx_api_base=tx_api,
                        tx_rpc_base=tx_rpc,
                        logger=logger,
                        session=session,
                    )
                )

            wbar.update(1)

    if not rows:
        logger.warning("No reward-related receipts found in the selected range.")
        logger.warning("Tip: If you expected incoming transfers, try --search-mode recipient")
        return 0

    logger.info("Collected %d reward rows; fetching prices (%s)", len(rows), currency)

    enrich_rows_with_prices(
        rows,
        session=session,
        currency=currency,
        coingecko_base=cg_base,
        coin_id=cg_coin,
        api_key=coingecko_api_key,
        logger=logger,
    )

    log_rows_table(rows, currency=currency, logger=logger)
    write_rows(rows, currency=currency, out_path=out_csv)

    logger.info("Wrote %d rows to: %s", len(rows), out_csv)
    return 0
```


```python
from tempfile import TemporaryDirectory

```


```python
with TemporaryDirectory() as td:
    p = Path(td) / "wallets.csv"
    p.write_text("address,tag\n", encoding="utf-8")
    rc = run_reward_transactions(wallets_csv=str(p), out_csv=str(Path(td) / "out.csv"))
    assert rc == 2

```

    2026-02-10T18:31:23 | ERROR | nym_tax_export | No wallets found in /tmp/tmpis26h299/wallets.csv


## Python live end-to-end demo


```python
#| eval: false
import os
from tempfile import TemporaryDirectory

```


```python
with TemporaryDirectory() as td:
    wallets = Path(td) / "wallets.csv"
    wallets.write_text("address,tag\nn127c69pasr35p76amfczemusnutr8mtw78s8xl7,operator\n", encoding="utf-8")
    out = Path(td) / "rewards.csv"

    rc = run_reward_transactions(
        wallets_csv=str(wallets),
        out_csv=str(out),
        currency="eur",
        start="2025-01-01",
        end="2025-12-31",
        search_mode="sender",
        tx_api_base="https://api.nymtech.net/cosmos/tx/v1beta1/txs",
        tx_rpc_base="https://rpc.nymtech.net",
        log_file=None,
        log_level="INFO",
    )
    print("rc=", rc)
    print("out exists:", out.exists(), out)

```

    Wallets:   0%|                                                                                                                                                                                                                  | 0/1 [00:00<?, ?wallet/s]

    2026-02-10T18:31:23 | INFO | nym_tax_export | Scanning wallet=n127c69pasr35p76amfczemusnutr8mtw78s8xl7 tag=operator query="message.sender='n127c69pasr35p76amfczemusnutr8mtw78s8xl7'"


    


    Txs n127c69p: 0tx [00:00, ?tx/s]

    [A

    Txs n127c69p: 14tx [00:00, 1017.05tx/s]

    
    Wallets: 100%|██████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████| 1/1 [00:00<00:00, 10.01wallet/s]

    
    2026-02-10T18:31:23 | INFO | nym_tax_export | Collected 1 reward rows; fetching prices (eur)


    2026-02-10T18:31:23 | INFO | nym_tax_export | CoinGecko price window unix=1764862311..1764869511 (eur)


    2026-02-10T18:31:23 | INFO | nym_tax_export | Loaded 2 price points


    2026-02-10T18:31:23 | INFO | nym_tax_export | 


    2026-02-10T18:31:23 | INFO | nym_tax_export | Reward transactions (table)


    2026-02-10T18:31:23 | INFO | nym_tax_export | 
    |             timestamp_utc |                                   wallet |                   action |   node_id |   amount_nym |     net_nym |   price_eur_per_nym |   value_eur |
    |---------------------------|------------------------------------------|--------------------------|-----------|--------------|-------------|---------------------|-------------|
    | 2025-12-04T16:31:51+00:00 | n127c69pasr35p76amfczemusnutr8mtw78s8xl7 | withdraw_operator_reward |      2196 |  3009.552561 | 3009.547398 |          0.04261800 |      128.26 |


    2026-02-10T18:31:23 | INFO | nym_tax_export | Wrote 1 rows to: /tmp/tmp1sy_823o/rewards.csv


    rc= 0
    out exists: True /tmp/tmp1sy_823o/rewards.csv



```python
#| hide
import nbdev; nbdev.nbdev_export()
```
