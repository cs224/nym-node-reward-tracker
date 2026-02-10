# Cosmos Tx Parsing Helpers

Shared helpers for Nyx/Cosmos transaction structures. This notebook centralizes tx event/message parsing so multiple notebooks can reuse one implementation.


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



```python
#| default_exp cosmos_tx_parsing
```

## Imports

Intent: keep parsing dependencies explicit and lightweight for reuse across cache and reward notebooks.


```python
#| export
from __future__ import annotations

import logging
import re
from decimal import Decimal
from typing import Any, Dict, List, Optional, Tuple

from nym_node_reward_tracker.common import MICRO, NYM_DENOM, to_int
```

## Event Normalization

Intent: normalize raw Cosmos event attributes into stable dictionaries.


```python
#| export
def attr_map(attrs: Any) -> Dict[str, str]:
    out: Dict[str, str] = {}
    if not isinstance(attrs, list):
        return out
    for a in attrs:
        if not isinstance(a, dict):
            continue
        k = str(a.get("key") or "")
        if not k:
            continue
        out[k] = str(a.get("value") or "")
    return out


def extract_events(tx_response_or_like: Dict[str, Any]) -> List[Dict[str, Any]]:
    rows: List[Dict[str, Any]] = []
    for ev in (tx_response_or_like.get("events") or []):
        if not isinstance(ev, dict):
            continue
        rows.append({"type": str(ev.get("type") or ""), "attributes": attr_map(ev.get("attributes"))})
    return rows
```


```python
sample = extract_events({"events": [{"type": "x", "attributes": [{"key": "a", "value": "1"}]}]})
assert sample == [{"type": "x", "attributes": {"a": "1"}}]
```

## Node Id Extraction

Intent: normalize node id extraction across event/message payload variants.


```python
#| export
def node_id_from_attrs(attrs: Dict[str, str]) -> Optional[int]:
    for key in ("node_id", "delegation_target", "mix_id"):
        v = to_int(attrs.get(key))
        if v is not None:
            return v
    return None
```


```python
assert node_id_from_attrs({"node_id": "14"}) == 14
assert node_id_from_attrs({"delegation_target": "2933"}) == 2933
assert node_id_from_attrs({"mix_id": "7"}) == 7
assert node_id_from_attrs({}) is None
```

## Coin Parsing

Intent: parse Cosmos coin lists like `100unym,5ufoo` into structured tuples.


```python
#| export
COIN_RE = re.compile(r"^(\d+)([a-zA-Z][a-zA-Z0-9/]*)$")


def parse_coins(amount_str: str) -> List[Tuple[int, str]]:
    out: List[Tuple[int, str]] = []
    for part in (amount_str or "").split(","):
        part = part.strip()
        if not part:
            continue
        m = COIN_RE.match(part)
        if not m:
            continue
        out.append((int(m.group(1)), m.group(2)))
    return out
```


```python
assert parse_coins("100unym,5ufoo") == [(100, "unym"), (5, "ufoo")]
assert parse_coins("") == []
```

## Message-Indexed Events

Intent: group tx events by `msg_index`, preferring `logs` and falling back to top-level `events` where possible.


```python
#| export
def events_by_msg_index(
    tx_resp: Dict[str, Any],
    *,
    prefer_logs: bool = True,
    logger: Optional[logging.Logger] = None,
    txhash: str = "",
) -> Dict[int, List[Dict[str, Any]]]:
    out: Dict[int, List[Dict[str, Any]]] = {}

    if prefer_logs:
        for lg in (tx_resp.get("logs") or []):
            mi = to_int((lg or {}).get("msg_index"))
            if mi is None:
                continue
            evs = (lg or {}).get("events") or []
            if isinstance(evs, list):
                out[int(mi)] = [e for e in evs if isinstance(e, dict)]

    if out:
        return out

    raw_events = [e for e in (tx_resp.get("events") or []) if isinstance(e, dict)]
    normalized = extract_events({"events": raw_events})
    for raw_ev, norm_ev in zip(raw_events, normalized):
        mi = to_int((norm_ev.get("attributes") or {}).get("msg_index"))
        if mi is None:
            continue
        out.setdefault(int(mi), []).append(raw_ev)

    if out and logger:
        logger.debug("Reconstructed events by msg_index tx=%s indexes=%s", txhash, sorted(out.keys()))

    return out
```


```python
tx_logs = {"logs": [{"msg_index": "0", "events": [{"type": "transfer", "attributes": []}]}]}
by_idx = events_by_msg_index(tx_logs)
assert 0 in by_idx and by_idx[0][0]["type"] == "transfer"

tx_fallback = {"events": [{"type": "transfer", "attributes": [{"key": "msg_index", "value": "2"}]}]}
by_idx_fb = events_by_msg_index(tx_fallback)
assert 2 in by_idx_fb and by_idx_fb[2][0]["type"] == "transfer"
```

## Incoming Amount Helpers

Intent: compute incoming NYM for a specific recipient from transfer/coin_received events while avoiding double-counting mirrored events.


```python
#| export
def sum_incoming_unym_from_events(events: List[Dict[str, Any]], recipient: str) -> int:
    transfer_unym = 0
    coin_received_unym = 0

    for ev in events:
        ev_type = str(ev.get("type") or ev.get("kind") or "")
        if ev_type not in ("transfer", "coin_received"):
            continue

        recv_key = "recipient" if ev_type == "transfer" else "receiver"
        attrs = ev.get("attributes") or []
        if not isinstance(attrs, list):
            continue

        receivers = {
            str((a.get("value") or "")).strip()
            for a in attrs
            if (a.get("key") or a.get("name") or "") == recv_key
        }
        if recipient not in receivers:
            continue

        for a in attrs:
            if (a.get("key") or a.get("name") or "") != "amount":
                continue
            for amt, denom in parse_coins(str(a.get("value") or "")):
                if denom != NYM_DENOM:
                    continue
                if ev_type == "transfer":
                    transfer_unym += int(amt)
                else:
                    coin_received_unym += int(amt)

    return transfer_unym if transfer_unym > 0 else coin_received_unym


def sum_incoming_nym_from_events(events: List[Dict[str, Any]], recipient: str) -> Decimal:
    return Decimal(sum_incoming_unym_from_events(events, recipient)) / MICRO
```


```python
addr = "n1abc"
mirror = [
    {"type": "transfer", "attributes": [{"key": "recipient", "value": addr}, {"key": "amount", "value": "2000000unym"}]},
    {"type": "coin_received", "attributes": [{"key": "receiver", "value": addr}, {"key": "amount", "value": "2000000unym"}]},
]
assert sum_incoming_unym_from_events(mirror, addr) == 2_000_000
assert sum_incoming_nym_from_events(mirror, addr) == Decimal("2")
```


```python
#| hide
import nbdev; nbdev.nbdev_export()
```
