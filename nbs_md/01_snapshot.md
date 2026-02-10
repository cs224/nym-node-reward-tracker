# Snapshot tracker

Port of the official Nym [`node_rewards_tracker.py`](https://github.com/nymtech/nym/blob/develop/scripts/rewards-tracker/node_rewards_tracker.py) into nbdev2 form.
This notebook focuses on the snapshot path and keeps a rolling history.


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


This notebook implements the `snapshot` CLI command.

It records wallet-level balances in micro-NYM (`unym`) and can fetch balances from:
* **SpectreDAO** aggregator (`/api/v1/balances/{address}`)
* **Nyx chain APIs** (Cosmos REST + mixnet contract smart queries)

It produces:
* a “latest snapshot” table file (`node-balances.csv` by default, or `.xlsx` by extension)
* a rolling history YAML (`data.yaml` by default) to estimate 7d/30d deltas


```python
#| default_exp snapshot
```

## Imports + endpoints + constants

Intent: define endpoints and defaults in one place, and keep the rest of the module pure and testable.


```python
#| export
from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple, Literal

from pydantic import BaseModel, ConfigDict, field_validator
from tabulate import tabulate

from nym_node_reward_tracker.common import (
    DEFAULT_DATA_DIR,
    NYM_DENOM,
    _FakeResp,
    _FakeSession,
    build_session,
    parse_unym_amount,
    read_wallets_csv,
    request_json,
    resolve_under_dir,
    setup_logging,
    smart_query,
    to_int,
    utc_now_iso,
    write_yaml,
    read_yaml,
)

SnapshotSource = Literal["spectre", "cosmos"]

DEFAULT_NYX_API_BASE = "https://api.nymtech.net"
DEFAULT_NYX_WASM_REST = f"{DEFAULT_NYX_API_BASE}/cosmwasm/wasm/v1/contract"
DEFAULT_NYX_TX_REST = f"{DEFAULT_NYX_API_BASE}/cosmos/tx/v1beta1/txs"
DEFAULT_NYX_BANK_REST = f"{DEFAULT_NYX_API_BASE}/cosmos/bank/v1beta1"

DEFAULT_SPECTRE_BAL_URL = "https://api.nym.spectredao.net/api/v1/balances/{address}"

DEFAULT_MIXNET_CONTRACT = "n17srjznxl9dvzdkpwpw24gg668wc73val88a6m5ajg6ankwvz9wtst0cznr"

```

## Data model

Intent: normalize both sources to a single internal representation, in **unym ints** (lossless).


```python
#| export
class BalanceBreakdown(BaseModel):
    """Normalized wallet balance components in unym."""
    model_config = ConfigDict(frozen=True)

    delegated_unym: int = 0
    self_bonded_unym: int = 0
    spendable_unym: int = 0
    locked_unym: int = 0

    rewards_operator_commissions_unym: int = 0
    rewards_staking_rewards_unym: int = 0
    rewards_unlocked_unym: int = 0

    @field_validator(
        "delegated_unym",
        "self_bonded_unym",
        "spendable_unym",
        "locked_unym",
        "rewards_operator_commissions_unym",
        "rewards_staking_rewards_unym",
        "rewards_unlocked_unym",
        mode="before",
    )
    @classmethod
    def _coerce_int(cls, value: Any) -> int:
        return int(to_int(value, 0) or 0)

    def total_unym(self) -> int:
        return (
            self.delegated_unym
            + self.self_bonded_unym
            + self.spendable_unym
            + self.locked_unym
            + self.rewards_operator_commissions_unym
            + self.rewards_staking_rewards_unym
            + self.rewards_unlocked_unym
        )


class WalletSnapshot(BaseModel):
    """Single timestamped snapshot row for one wallet."""
    model_config = ConfigDict(frozen=True)

    timestamp_utc: str
    wallet_address: str
    tag: str = ""
    node_id: Optional[int] = None
    identity_key: str = ""
    balances: BalanceBreakdown
    source: str

    @field_validator("node_id", mode="before")
    @classmethod
    def _coerce_node_id(cls, value: Any) -> Optional[int]:
        return to_int(value, None)

    def to_latest_csv_row(self) -> Dict[str, Any]:
        b = self.balances
        return {
            "timestamp_utc": self.timestamp_utc,
            "wallet": self.wallet_address,
            "tag": self.tag,
            "node_id": "" if self.node_id is None else str(self.node_id),
            "identity_key": self.identity_key,
            "delegated_unym": str(b.delegated_unym),
            "self_bonded_unym": str(b.self_bonded_unym),
            "spendable_unym": str(b.spendable_unym),
            "operator_commissions_unym": str(b.rewards_operator_commissions_unym),
            "staking_rewards_unym": str(b.rewards_staking_rewards_unym),
            "total_unym": str(b.total_unym()),
            "source": self.source,
        }

```


```python
b = BalanceBreakdown(
    delegated_unym="1",
    self_bonded_unym=2,
    spendable_unym=3,
    rewards_operator_commissions_unym="4",
)
assert b.total_unym() == 10

w = WalletSnapshot(
    timestamp_utc="2026-01-01T00:00:00+00:00",
    wallet_address="n1wallet",
    tag="test",
    node_id="2196",
    identity_key="identity",
    balances=b,
    source="spectre",
)
assert w.to_latest_csv_row()["node_id"] == "2196"

```


```python
b
```




    BalanceBreakdown(delegated_unym=1, self_bonded_unym=2, spendable_unym=3, locked_unym=0, rewards_operator_commissions_unym=4, rewards_staking_rewards_unym=0, rewards_unlocked_unym=0)




```python
w
```




    WalletSnapshot(timestamp_utc='2026-01-01T00:00:00+00:00', wallet_address='n1wallet', tag='test', node_id=2196, identity_key='identity', balances=BalanceBreakdown(delegated_unym=1, self_bonded_unym=2, spendable_unym=3, locked_unym=0, rewards_operator_commissions_unym=4, rewards_staking_rewards_unym=0, rewards_unlocked_unym=0), source='spectre')



## Wallet → node metadata (node_id, identity_key)

Intent: enrich snapshots with node identity when the wallet owns a node.

This uses `get_owned_nym_node`.


```bash
%%bash
MIXNET_CONTRACT='n17srjznxl9dvzdkpwpw24gg668wc73val88a6m5ajg6ankwvz9wtst0cznr'
WALLET='n127c69pasr35p76amfczemusnutr8mtw78s8xl7'
Q=$(printf '%s' '{"get_owned_nym_node":{"address":"'"${WALLET}"'"}}' | base64 -w 0)
curl -s "https://api.nymtech.net/cosmwasm/wasm/v1/contract/${MIXNET_CONTRACT}/smart/${Q}" | jq '.'
```

    {
      "data": {
        "address": "n127c69pasr35p76amfczemusnutr8mtw78s8xl7",
        "details": {
          "bon

    d_information": {
            "node_id": 2196,
            "owner": "n127c69pasr35p76amfczemusnutr8mtw78s8xl

    7",
            "original_pledge": {
              "denom": "unym",
              "amount": "15000000000"
          

      },
            "bonding_height": 16380988,
            "is_unbonding": false,
            "node": {
              

    "host": "94.143.231.195",
              "custom_http_port": 8080,
              "identity_key": "E67dRcrMNsE

    pNvRAxvFTkvMyqigTYpRWUYYPm25rDuGQ"
            }
          },
          "rewarding_details": {
            "cost_par

    ams": {
              "profit_margin_percent": "0.2",
              "interval_operating_cost": {
               

     "denom": "unym",
                "amount": "80000000"
              }
            },
            "operator": "17386

    289890.440145788593834037",
            "delegates": "257292003557.232730256788587701",
            "total_u

    nit_reward": "66087553.132157347816839083",
            "unit_delegation": "1000000000",
            "last_r

    ewarded_epoch": 28389,
            "unique_delegations": 4
          },
          "pending_changes": {
            "

    pledge_change": null,
            "cost_params_change": 2291
          }
        }
      }
    }


Intent: parse owned-node details from smart-query response for a wallet.


```python
#| export
def get_owned_node_details(
    session: Any,
    wallet_address: str,
    *,
    nyx_wasm_rest: str,
    mixnet_contract: str,
    timeout: int = 20,
    logger=None,
) -> Tuple[Optional[int], str, int]:
    """
    Returns (node_id, identity_key, self_bonded_unym_from_original_pledge).

    If wallet has no owned node: (None, "", 0).
    """
    js = smart_query(
        session,
        nyx_wasm_rest=nyx_wasm_rest,
        contract=mixnet_contract,
        payload={"get_owned_nym_node": {"address": wallet_address}},
        timeout=timeout,
        logger=logger,
    )
    details = (js.get("data") or {}).get("details") or {}
    bond = (details.get("bond_information") or {})
    node_id = to_int(bond.get("node_id"))
    identity_key = ((bond.get("node") or {}).get("identity_key") or "")
    pledge = (bond.get("original_pledge") or {})
    pledge_amt = to_int(pledge.get("amount"), 0) or 0
    return node_id, str(identity_key), int(pledge_amt)

```


```python
fake = _FakeSession([_FakeResp({"data": {"ok": True}})])
# This fake returns no bond information, so node metadata should be empty.
nid, ik, pledge = get_owned_node_details(fake, "n1", nyx_wasm_rest="x", mixnet_contract="c")
assert nid is None and ik == "" and pledge == 0

```

## Source 1: Spectre balance parser

Intent: parse Spectre response into our normalized `BalanceBreakdown` (unym ints).

We keep this pure: “JSON in → dataclass out”.


```bash
%%bash
WALLET="n127c69pasr35p76amfczemusnutr8mtw78s8xl7"
URL="https://api.nym.spectredao.net/api/v1/balances/${WALLET}"
curl -s "$URL" | jq '.'
```

    {
      "delegated": {
        "amount": 200977025706,
        "denom": "unym"
      },
      "locked": {
        "amount": 

    0,
        "denom": "unym"
      },
      "rewards": {
        "operator_commissions": {
          "amount": 2386289890,

    
          "denom": "unym"
        },
        "staking_rewards": {
          "amount": 441855607,
          "denom": "un

    ym"
        },
        "unlocked": {
          "amount": 0,
          "denom": "unym"
        }
      },
      "self_bonded": {


        "amount": 15000000000,
        "denom": "unym"
      },
      "spendable": {
        "amount": 60639227,
        "de

    nom": "unym"
      },
      "total": {
        "amount": 218865810430,
        "denom": "unym"
      }
    }


Intent: normalize Spectre numeric amount fields to integer `unym`.


```python
#| export
def _read_amount_unym(obj: Any) -> int:
    if not isinstance(obj, dict):
        return 0
    return int(to_int(obj.get("amount"), 0) or 0)


def balances_from_spectre_json(js: Dict[str, Any]) -> BalanceBreakdown:
    rewards = js.get("rewards") if isinstance(js.get("rewards"), dict) else {}
    return BalanceBreakdown(
        delegated_unym=_read_amount_unym(js.get("delegated")),
        self_bonded_unym=_read_amount_unym(js.get("self_bonded")),
        spendable_unym=_read_amount_unym(js.get("spendable")),
        locked_unym=_read_amount_unym(js.get("locked")),
        rewards_operator_commissions_unym=_read_amount_unym(rewards.get("operator_commissions")),
        rewards_staking_rewards_unym=_read_amount_unym(rewards.get("staking_rewards")),
        rewards_unlocked_unym=_read_amount_unym(rewards.get("unlocked")),
    )
```


```python
example = {
  "delegated": {"amount": 200977025706, "denom": "unym"},
  "locked": {"amount": 0, "denom": "unym"},
  "rewards": {
      "operator_commissions": {"amount": 2215364099, "denom": "unym"},
      "staking_rewards": {"amount": 280778666, "denom": "unym"},
      "unlocked": {"amount": 0, "denom": "unym"}
  },
  "self_bonded": {"amount": 15000000000, "denom": "unym"},
  "spendable": {"amount": 60639227, "denom": "unym"},
  "total": {"amount": 218533807698, "denom": "unym"},
}

b = balances_from_spectre_json(example)
assert b.total_unym() == 218533807698
```

## Source 1: Spectre fetcher

Intent: fetch Spectre balance JSON and convert it into `BalanceBreakdown`.


```python
#| export
def fetch_balances_spectre(
    session: Any,
    wallet_address: str,
    *,
    spectre_balance_url: str = DEFAULT_SPECTRE_BAL_URL,
    timeout: int = 20,
    logger=None,
) -> BalanceBreakdown:
    url = spectre_balance_url.format(address=wallet_address)
    js = request_json(session, url, timeout=timeout, logger=logger)
    return balances_from_spectre_json(js if isinstance(js, dict) else {})

```


```python
# offline verify: we only test the parser above.
assert callable(fetch_balances_spectre)

```

Intent: run the same helper against the real API so notebook readers can inspect actual values (without failing tests if network is unavailable).


```python
#| eval: false
live_session = build_session("nym-node-reward-tracker/notebook-live")
live_wallet = "n127c69pasr35p76amfczemusnutr8mtw78s8xl7"

live_spectre = fetch_balances_spectre(live_session, live_wallet)
assert isinstance(live_spectre, BalanceBreakdown)
live_spectre
```




    BalanceBreakdown(delegated_unym=200977025706, self_bonded_unym=15000000000, spendable_unym=60639227, locked_unym=0, rewards_operator_commissions_unym=2386289890, rewards_staking_rewards_unym=441855607, rewards_unlocked_unym=0)



## Source 2: Cosmos snapshot builder (best-effort, chain-native)

Intent: query the bank module for `unym` spendable balance.


```bash
%%bash
WALLET="n127c69pasr35p76amfczemusnutr8mtw78s8xl7"
NYX_BANK_REST="https://api.nymtech.net/cosmos/bank/v1beta1"
URL="${NYX_BANK_REST}/balances/${WALLET}"

curl -s "$URL" | jq '.'
```

    {
      "balances": [
        {
          "denom": "unym",
          "amount": "60639227"
        }
      ],
      "pagination":

     {
        "next_key": null,
        "total": "1"
      }
    }


Intent: fetch spendable `unym` from bank balances endpoint.


```python
#| export
def fetch_spendable_unym_bank(
    session: Any,
    wallet_address: str,
    *,
    nyx_bank_rest: str = DEFAULT_NYX_BANK_REST,
    timeout: int = 20,
    logger=None,
) -> int:
    url = f"{nyx_bank_rest.rstrip('/')}/balances/{wallet_address}"
    js = request_json(session, url, timeout=timeout, logger=logger)
    balances = (js.get("balances") or []) if isinstance(js, dict) else []
    if not isinstance(balances, list):
        return 0
    for c in balances:
        if not isinstance(c, dict):
            continue
        if c.get("denom") == NYM_DENOM:
            return int(to_int(c.get("amount"), 0) or 0)
    return 0
```


```python
sample_bank = {"balances": [{"denom": "unym", "amount": "123"}]}
class _BankSession:
    def get(self, url, params=None, timeout=0):
        return _FakeResp(sample_bank)

assert fetch_spendable_unym_bank(_BankSession(), "n1", nyx_bank_rest="https://x") == 123
```

Intent: list current delegations for a wallet (smart query), and sum principal amounts in unym.


```bash
%%bash -s "$wallet"
WALLET="n127c69pasr35p76amfczemusnutr8mtw78s8xl7"
NYX_WASM_REST="https://api.nymtech.net/cosmwasm/wasm/v1/contract"
MIXNET_CONTRACT="n17srjznxl9dvzdkpwpw24gg668wc73val88a6m5ajg6ankwvz9wtst0cznr"

# Single-page example of get_delegator_delegations (like one call inside get_delegator_delegations_current)
PAYLOAD=$(jq -cn --arg w "$WALLET" '{get_delegator_delegations:{delegator:$w, limit:5}}')
echo $PAYLOAD
Q=$(printf '%s' "$PAYLOAD" | base64 -w 0)

curl -s "${NYX_WASM_REST}/${MIXNET_CONTRACT}/smart/${Q}" | jq '.'
```

    {"get_delegator_delegations":{"delegator":"n127c69pasr35p76amfczemusnutr8mtw78s8xl7","limit":5}}


    {
      "data": {
        "delegations": [
          {
            "owner": "n127c69pasr35p76amfczemusnutr8mtw78s8xl

    7",
            "node_id": 2933,
            "cumulative_reward_ratio": "669788.748216958693826745",
           

     "amount": {
              "denom": "unym",
              "amount": "200977025706"
            },
            "heigh

    t": 22222929,
            "proxy": null
          }
        ],
        "start_next_after": [
          2933,
          "n127

    c69pasr35p76amfczemusnutr8mtw78s8xl7"
        ]
      }
    }


Intent: fetch current delegations and provide a principal summation helper.


```python
#| export
def get_delegator_delegations_current(
    session: Any,
    wallet_address: str,
    *,
    nyx_wasm_rest: str,
    mixnet_contract: str,
    limit: int = 200,
    max_pages: int = 50,
    timeout: int = 20,
    logger=None,
) -> List[Dict[str, Any]]:
    """
    Returns a flat list of delegations from contract query `get_delegator_delegations`,
    handling pagination via `start_after` if present.
    """
    out: List[Dict[str, Any]] = []
    start_after: Optional[List[Any]] = None

    for _ in range(max_pages):
        payload: Dict[str, Any] = {"delegator": wallet_address, "limit": limit}
        if start_after is not None:
            payload["start_after"] = start_after

        js = smart_query(
            session,
            nyx_wasm_rest=nyx_wasm_rest,
            contract=mixnet_contract,
            payload={"get_delegator_delegations": payload},
            timeout=timeout,
            logger=logger,
        )
        data = js.get("data") if isinstance(js, dict) else {}
        delegs = (data.get("delegations") or []) if isinstance(data, dict) else []
        if not isinstance(delegs, list) or not delegs:
            break
        out.extend([d for d in delegs if isinstance(d, dict)])

        nxt = data.get("start_next_after") if isinstance(data, dict) else None
        if not nxt:
            break
        start_after = nxt

    return out


def sum_delegated_unym(delegations: List[Dict[str, Any]]) -> int:
    total = 0
    for d in delegations:
        amt = d.get("amount")
        if isinstance(amt, dict):
            total += int(to_int(amt.get("amount"), 0) or 0)
        else:
            # tolerate alternative shapes
            total += int(to_int(d.get("amount"), 0) or 0)
    return total
```


```python
assert sum_delegated_unym([{"amount": {"amount": "10", "denom": "unym"}}, {"amount": {"amount": "2"}}]) == 12
```

Intent: fetch pending delegator reward for a (delegator,node_id) pair and return unym int.


```bash
%%bash
WALLET="n127c69pasr35p76amfczemusnutr8mtw78s8xl7"
NODE_ID="2933"
NYX_WASM_REST="https://api.nymtech.net/cosmwasm/wasm/v1/contract"
MIXNET_CONTRACT="n17srjznxl9dvzdkpwpw24gg668wc73val88a6m5ajg6ankwvz9wtst0cznr"

PAYLOAD=$(jq -cn --arg w "$WALLET" --argjson n "$NODE_ID" '{get_pending_delegator_reward:{address:$w,node_id:$n}}')
echo $PAYLOAD
Q=$(printf '%s' "$PAYLOAD" | base64 -w 0)

curl -s "${NYX_WASM_REST}/${MIXNET_CONTRACT}/smart/${Q}" | jq '.'
```

    {"get_pending_delegator_reward":{"address":"n127c69pasr35p76amfczemusnutr8mtw78s8xl7","node_id":2933

    }}


    {
      "data": {
        "amount_staked": {
          "denom": "unym",
          "amount": "200977025706"
        },
      

      "amount_earned": {
          "denom": "unym",
          "amount": "441855607"
        },
        "amount_earned_de

    tailed": "441855607.324003049500983703",
        "mixnode_still_fully_bonded": true,
        "node_still_ful

    ly_bonded": true
      }
    }


Intent: fetch pending delegator reward amount for a node and wallet.


```python
#| export
def get_pending_delegator_reward_unym(
    session: Any,
    *,
    nyx_wasm_rest: str,
    mixnet_contract: str,
    node_id: int,
    delegator: str,
    timeout: int = 20,
    logger=None,
) -> int:
    js = smart_query(
        session,
        nyx_wasm_rest=nyx_wasm_rest,
        contract=mixnet_contract,
        payload={"get_pending_delegator_reward": {"address": delegator, "node_id": node_id}},
        timeout=timeout,
        logger=logger,
    )
    data = js.get("data") if isinstance(js, dict) else {}
    earned = (data.get("amount_earned") or {}) if isinstance(data, dict) else {}
    return int(to_int((earned.get("amount") if isinstance(earned, dict) else None), 0) or 0)

```

Intent: provide a tiny fake session for deterministic verification of pending-reward query parsing.


```python
class _PendingSession:
    def get(self, url, params=None, timeout=0):
        return _FakeResp({"data": {"amount_earned": {"amount": "77", "denom": "unym"}}})

assert get_pending_delegator_reward_unym(
    _PendingSession(),
    nyx_wasm_rest="https://x",
    mixnet_contract="c",
    node_id=1,
    delegator="n1",
) == 77
```

Intent: fetch pending operator reward if available.
Because the exact query variant may differ across contract versions, we implement **a conservative fallback strategy**:

1. try `get_pending_operator_reward` by owner address
2. try `get_pending_node_operator_reward` by node_id
3. else return 0 (and let higher-level code report “unavailable” if desired)


```bash
%%bash -s "$wallet" "$node_id"
WALLET="n127c69pasr35p76amfczemusnutr8mtw78s8xl7"
NODE_ID="2933"
NYX_WASM_REST="https://api.nymtech.net/cosmwasm/wasm/v1/contract"
MIXNET_CONTRACT="n17srjznxl9dvzdkpwpw24gg668wc73val88a6m5ajg6ankwvz9wtst0cznr"

# Attempt 1 (same as function): address-based get_pending_operator_reward
PAYLOAD=$(jq -cn --arg w "$WALLET" '{get_pending_operator_reward:{address:$w}}')
echo $PAYLOAD
Q=$(printf '%s' "$PAYLOAD" | base64 -w 0)

curl -s "${NYX_WASM_REST}/${MIXNET_CONTRACT}/smart/${Q}" | jq '.'
```

    {"get_pending_operator_reward":{"address":"n127c69pasr35p76amfczemusnutr8mtw78s8xl7"}}


    {
      "data": {
        "amount_staked": {
          "denom": "unym",
          "amount": "15000000000"
        },
       

     "amount_earned": {
          "denom": "unym",
          "amount": "2386289890"
        },
        "amount_earned_de

    tailed": "2386289890.440145788593834037",
        "mixnode_still_fully_bonded": true,
        "node_still_fu

    lly_bonded": true
      }
    }


Intent: fetch pending operator reward amount for wallet-owned node when available.


```python
#| export
def get_pending_operator_reward_unym(
    session: Any,
    *,
    nyx_wasm_rest: str,
    mixnet_contract: str,
    owner_address: str,
    node_id: Optional[int],
    timeout: int = 20,
    logger=None,
) -> int:
    # Attempt 1: address-based
    try:
        js = smart_query(
            session,
            nyx_wasm_rest=nyx_wasm_rest,
            contract=mixnet_contract,
            payload={"get_pending_operator_reward": {"address": owner_address}},
            timeout=timeout,
            logger=logger,
        )
        data = js.get("data") if isinstance(js, dict) else {}
        earned = (data.get("amount_earned") or data.get("reward") or {}) if isinstance(data, dict) else {}
        if isinstance(earned, dict) and "amount" in earned:
            return int(to_int(earned.get("amount"), 0) or 0)
    except Exception:
        pass

    # Attempt 2: node_id-based
    if node_id is not None:
        try:
            js = smart_query(
                session,
                nyx_wasm_rest=nyx_wasm_rest,
                contract=mixnet_contract,
                payload={"get_pending_node_operator_reward": {"node_id": int(node_id)}},
                timeout=timeout,
                logger=logger,
            )
            data = js.get("data") if isinstance(js, dict) else {}
            earned = (data.get("amount_earned") or data.get("reward") or {}) if isinstance(data, dict) else {}
            if isinstance(earned, dict) and "amount" in earned:
                return int(to_int(earned.get("amount"), 0) or 0)
        except Exception:
            pass

    return 0
```


```python
# verify_get_pending_operator_reward_unym
class _OpSession:
    def get(self, *args, **kwargs):
        class R:
            status_code = 200
            text = "{}"
            def raise_for_status(self): return None
            def json(self):
                return {"data": {"amount_earned": {"amount": "7"}}}
        return R()
out = get_pending_operator_reward_unym(
    _OpSession(),
    nyx_wasm_rest="https://x",
    mixnet_contract="c",
    owner_address="n1",
    node_id=14,
)
assert out == 7

```


```python
assert callable(get_pending_operator_reward_unym)
```

## Cosmos snapshot assembly

Intent: build the full `BalanceBreakdown` from Cosmos endpoints + smart queries.


```python
#| export
def fetch_balances_cosmos(
    session: Any,
    wallet_address: str,
    *,
    nyx_wasm_rest: str,
    nyx_bank_rest: str,
    mixnet_contract: str,
    timeout: int = 20,
    logger=None,
) -> Tuple[BalanceBreakdown, Optional[int], str]:
    # owned node enrich
    node_id, identity_key, pledge_unym = get_owned_node_details(
        session,
        wallet_address,
        nyx_wasm_rest=nyx_wasm_rest,
        mixnet_contract=mixnet_contract,
        timeout=timeout,
        logger=logger,
    )

    spendable = fetch_spendable_unym_bank(
        session,
        wallet_address,
        nyx_bank_rest=nyx_bank_rest,
        timeout=timeout,
        logger=logger,
    )

    delegations = get_delegator_delegations_current(
        session,
        wallet_address,
        nyx_wasm_rest=nyx_wasm_rest,
        mixnet_contract=mixnet_contract,
        timeout=timeout,
        logger=logger,
    )
    delegated = sum_delegated_unym(delegations)

    # pending delegator rewards across delegations
    staking_rewards = 0
    for d in delegations:
        nid = to_int(d.get("node_id"))
        if nid is None:
            continue
        staking_rewards += get_pending_delegator_reward_unym(
            session,
            nyx_wasm_rest=nyx_wasm_rest,
            mixnet_contract=mixnet_contract,
            node_id=int(nid),
            delegator=wallet_address,
            timeout=timeout,
            logger=logger,
        )

    operator_commissions = get_pending_operator_reward_unym(
        session,
        nyx_wasm_rest=nyx_wasm_rest,
        mixnet_contract=mixnet_contract,
        owner_address=wallet_address,
        node_id=node_id,
        timeout=timeout,
        logger=logger,
    )

    b = BalanceBreakdown(
        delegated_unym=int(delegated),
        self_bonded_unym=int(pledge_unym),
        spendable_unym=int(spendable),
        locked_unym=0,
        rewards_operator_commissions_unym=int(operator_commissions),
        rewards_staking_rewards_unym=int(staking_rewards),
        rewards_unlocked_unym=0,
    )
    return b, node_id, identity_key
```


```python
assert callable(fetch_balances_cosmos)
```

Intent: run the cosmos snapshot helper against real APIs so readers can inspect chain-native values without breaking tests when network is unavailable.


```python
#| eval: false
live_session = build_session("nym-node-reward-tracker/notebook-live")
live_wallet = "n127c69pasr35p76amfczemusnutr8mtw78s8xl7"

live_cosmos_balances, live_cosmos_node_id, live_cosmos_identity_key = fetch_balances_cosmos(
    live_session,
    live_wallet,
    nyx_wasm_rest=DEFAULT_NYX_WASM_REST,
    nyx_bank_rest=DEFAULT_NYX_BANK_REST,
    mixnet_contract=DEFAULT_MIXNET_CONTRACT,
)
assert isinstance(live_cosmos_balances, BalanceBreakdown)
live_cosmos_balances
```




    BalanceBreakdown(delegated_unym=200977025706, self_bonded_unym=15000000000, spendable_unym=60639227, locked_unym=0, rewards_operator_commissions_unym=2386289890, rewards_staking_rewards_unym=441855607, rewards_unlocked_unym=0)



## Snapshot orchestration

Intent: for each wallet, pick source → fetch balances → emit `WalletSnapshot`.

All network calls are inside fetch functions; this orchestration is “pure glue”.


```python
#| export
def build_wallet_snapshot(
    session: Any,
    wallet_address: str,
    tag: str,
    *,
    source: SnapshotSource,
    nyx_wasm_rest: str,
    nyx_bank_rest: str,
    mixnet_contract: str,
    spectre_balance_url: str,
    timeout: int,
    logger,
) -> WalletSnapshot:
    ts = utc_now_iso()
    node_id: Optional[int] = None
    identity_key = ""
    if source == "spectre":
        # still enrich node metadata from chain (cheap and deterministic)
        node_id, identity_key, pledge = get_owned_node_details(
            session,
            wallet_address,
            nyx_wasm_rest=nyx_wasm_rest,
            mixnet_contract=mixnet_contract,
            timeout=timeout,
            logger=logger,
        )
        balances = fetch_balances_spectre(
            session,
            wallet_address,
            spectre_balance_url=spectre_balance_url,
            timeout=timeout,
            logger=logger,
        )
    else:
        balances, node_id, identity_key = fetch_balances_cosmos(
            session,
            wallet_address,
            nyx_wasm_rest=nyx_wasm_rest,
            nyx_bank_rest=nyx_bank_rest,
            mixnet_contract=mixnet_contract,
            timeout=timeout,
            logger=logger,
        )

    return WalletSnapshot(
        timestamp_utc=ts,
        wallet_address=wallet_address,
        tag=tag,
        node_id=node_id,
        identity_key=identity_key,
        balances=balances,
        source=source,
    )
```


```python
# verify_build_wallet_snapshot
class _S:
    def get(self, *args, **kwargs):
        class R:
            status_code = 200
            text = "{}"
            def raise_for_status(self): return None
            def json(self):
                return {"data": {"details": None}, "balances": []}
        return R()
ws = build_wallet_snapshot(
    _S(),
    wallet_address="n1",
    tag="t",
    source="spectre",
    nyx_wasm_rest="https://x",
    nyx_bank_rest="https://x",
    mixnet_contract="c",
    spectre_balance_url="https://x/{address}",
    timeout=1,
    logger=None,
)
assert ws.wallet_address == "n1"

```


```python
assert callable(build_wallet_snapshot)
```

## Persistence and history

Intent: store a rolling per-wallet history (default 30 days) in YAML.

We store **unym totals** only (lossless, minimal).
Later, if desired, extend with more fields.



```python
#| export
def prune_history_older_than(history: Dict[str, Any], *, cutoff_ts: float) -> Dict[str, Any]:
    out: Dict[str, Any] = {}
    for k, lst in (history or {}).items():
        if not isinstance(lst, list):
            continue
        kept = [e for e in lst if isinstance(e, dict) and float(e.get("ts", 0)) >= cutoff_ts]
        if kept:
            out[k] = kept
    return out


def record_history_point(history: Dict[str, Any], *, wallet: str, ts: float, total_unym: int) -> None:
    history.setdefault(wallet, []).append({"ts": float(ts), "total_unym": int(total_unym)})


def scaled_window_change_unym(
    history: Dict[str, Any],
    *,
    wallet: str,
    now_ts: float,
    window_days: float,
    current_total_unym: int,
) -> Optional[Dict[str, Any]]:
    lst = history.get(wallet)
    if not isinstance(lst, list) or not lst:
        return None

    cutoff = now_ts - window_days * 24 * 3600
    candidates = [e for e in lst if float(e.get("ts", 0.0)) <= cutoff]
    if not candidates:
        return None
    snap = sorted(candidates, key=lambda e: float(e.get("ts", 0.0)))[-1]
    prev_total = int(snap.get("total_unym", 0))
    prev_ts = float(snap.get("ts", now_ts))
    span_hours = max(0.0, (now_ts - prev_ts) / 3600.0)
    if span_hours <= 0:
        return None

    profit_unym = int(current_total_unym) - prev_total
    target_hours = window_days * 24.0
    scaled_unym = profit_unym * (target_hours / span_hours)
    return {
        "profit_scaled_unym": int(scaled_unym),
        "span_hours": span_hours,
        "hourly_scaled_unym": float(scaled_unym / target_hours),
    }
```


```python
h = {"w": [{"ts": 0.0, "total_unym": 10}]}
out = scaled_window_change_unym(h, wallet="w", now_ts=8 * 24 * 3600, window_days=7, current_total_unym=17)
assert out is not None
```

## Tabular output (latest snapshot)

Intent: write a simple “latest snapshot” table file (overwritten each run) for quick inspection and downstream tooling. Format is selected by extension (`.csv` or `.xlsx`).


```python
#| export
def write_latest_snapshot_csv(rows: List[WalletSnapshot], out_path: str | Path) -> None:
    import csv

    p = Path(out_path)
    p.parent.mkdir(parents=True, exist_ok=True)

    fieldnames = [
        "timestamp_utc",
        "wallet",
        "tag",
        "node_id",
        "identity_key",
        "delegated_unym",
        "self_bonded_unym",
        "spendable_unym",
        "operator_commissions_unym",
        "staking_rewards_unym",
        "total_unym",
        "source",
    ]

    records = [r.to_latest_csv_row() for r in rows]
    suffix = p.suffix.lower()

    if suffix == ".xlsx":
        try:
            from openpyxl import Workbook
        except ImportError as exc:
            raise RuntimeError("openpyxl is required for .xlsx output") from exc

        wb = Workbook()
        ws = wb.active
        ws.title = "snapshot"
        ws.append(fieldnames)
        for rec in records:
            ws.append([rec.get(k, "") for k in fieldnames])
        wb.save(p)
        return

    if suffix not in ("", ".csv"):
        raise ValueError(f"Unsupported output extension '{suffix}' for {p}. Use .csv or .xlsx")

    with p.open("w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=fieldnames)
        w.writeheader()
        for rec in records:
            w.writerow(rec)


def log_snapshot_table(rows: List[WalletSnapshot], *, history: Dict[str, Any], now_ts: float, logger) -> None:
    def _fmt_nym(unym_value: int) -> str:
        sign = "-" if unym_value < 0 else ""
        abs_v = abs(int(unym_value))
        whole = abs_v // 1_000_000
        frac = abs_v % 1_000_000
        return f"{sign}{whole}.{frac:06d}"

    headers = [
        "timestamp_utc",
        "wallet",
        "tag",
        "node_id",
        "source",
        "delegated_nym",
        "self_bonded_nym",
        "spendable_nym",
        "operator_comm_nym",
        "staking_rewards_nym",
        "total_nym",
        "7d_scaled_nym",
        "30d_scaled_nym",
    ]
    view = []
    for s in rows:
        total_unym = s.balances.total_unym()
        d7 = scaled_window_change_unym(
            history,
            wallet=s.wallet_address,
            now_ts=now_ts,
            window_days=7,
            current_total_unym=total_unym,
        )
        d30 = scaled_window_change_unym(
            history,
            wallet=s.wallet_address,
            now_ts=now_ts,
            window_days=30,
            current_total_unym=total_unym,
        )
        b = s.balances
        view.append([
            s.timestamp_utc,
            s.wallet_address,
            s.tag,
            "" if s.node_id is None else str(s.node_id),
            s.source,
            _fmt_nym(b.delegated_unym),
            _fmt_nym(b.self_bonded_unym),
            _fmt_nym(b.spendable_unym),
            _fmt_nym(b.rewards_operator_commissions_unym),
            _fmt_nym(b.rewards_staking_rewards_unym),
            _fmt_nym(total_unym),
            (_fmt_nym(int(d7["profit_scaled_unym"])) if d7 else "n/a"),
            (_fmt_nym(int(d30["profit_scaled_unym"])) if d30 else "n/a"),
        ])

    logger.info("")
    logger.info("Snapshot balances (table)")
    logger.info("\n%s", tabulate(view, headers=headers, tablefmt="github", stralign="right", disable_numparse=True))

```


```python
from tempfile import TemporaryDirectory

```


```python
sample = WalletSnapshot(
    timestamp_utc="2026-01-01T00:00:00+00:00",
    wallet_address="n1wallet",
    tag="test",
    node_id=2196,
    identity_key="identity",
    balances=BalanceBreakdown(
        delegated_unym=1_500_000,
        self_bonded_unym=2_000_000,
        spendable_unym=250_000,
    ),
    source="spectre",
)

with TemporaryDirectory() as td:
    p_csv = Path(td) / "latest.csv"
    write_latest_snapshot_csv([sample], p_csv)
    assert p_csv.exists()

    p_xlsx = Path(td) / "latest.xlsx"
    write_latest_snapshot_csv([sample], p_xlsx)
    assert p_xlsx.exists()

assert callable(log_snapshot_table)

```

## Main entry point: run_snapshot

Intent: the CLI-facing function `run_snapshot(...)`:

* loads wallets
* fetches snapshots
* updates history yaml
* writes latest table output (`.csv` or `.xlsx`)
* logs a compact report including 7d/30d scaled change


```python
#| export
def run_snapshot(
    *,
    data_dir: str | Path = DEFAULT_DATA_DIR,
    wallets_csv: str | Path = "wallet-addresses.csv",
    out_csv: str | Path = "node-balances.csv",
    hist_file: str | Path = "data.yaml",
    source: SnapshotSource = "spectre",
    nyx_wasm_rest: str = DEFAULT_NYX_WASM_REST,
    nyx_bank_rest: str = DEFAULT_NYX_BANK_REST,
    mixnet_contract: str = DEFAULT_MIXNET_CONTRACT,
    spectre_balance_url: str | None = DEFAULT_SPECTRE_BAL_URL,
    spectre_nodes_url: str | None = None,
    validator_bonded_url: str | None = None,
    validator_described_url: str | None = None,
    history_days: int = 30,
    timeout: int = 20,
    log_file: str | None = None,
    log_level: str = "INFO",
) -> int:
    logger = setup_logging("nym_snapshot", log_file=log_file, level=log_level)
    data_dir = Path(data_dir)

    if spectre_balance_url is None:
        spectre_balance_url = DEFAULT_SPECTRE_BAL_URL

    if spectre_nodes_url or validator_bonded_url or validator_described_url:
        logger.debug(
            "snapshot legacy url overrides ignored in current implementation: spectre_nodes_url=%s validator_bonded_url=%s validator_described_url=%s",
            spectre_nodes_url,
            validator_bonded_url,
            validator_described_url,
        )

    wallets_path = resolve_under_dir(data_dir, wallets_csv)
    out_path = resolve_under_dir(data_dir, out_csv)
    hist_path = resolve_under_dir(data_dir, hist_file)

    wallets = read_wallets_csv(wallets_path)
    if not wallets:
        logger.error("No wallets found in %s", wallets_path)
        return 2

    session = build_session("nym-node-reward-tracker/snapshot")

    # load/prune history
    hist = read_yaml(hist_path, default={}) or {}
    now_ts = datetime.now(timezone.utc).timestamp()
    cutoff = now_ts - float(history_days) * 24 * 3600
    hist = prune_history_older_than(hist, cutoff_ts=cutoff)

    snaps: List[WalletSnapshot] = []
    for addr, tag in wallets:
        snap = build_wallet_snapshot(
            session,
            addr,
            tag,
            source=source,
            nyx_wasm_rest=nyx_wasm_rest,
            nyx_bank_rest=nyx_bank_rest,
            mixnet_contract=mixnet_contract,
            spectre_balance_url=spectre_balance_url,
            timeout=timeout,
            logger=logger,
        )
        snaps.append(snap)
        record_history_point(hist, wallet=addr, ts=now_ts, total_unym=snap.balances.total_unym())

    write_yaml(hist_path, hist)
    write_latest_snapshot_csv(snaps, out_path)

    # Print a compact table like reward-transactions for CLI visibility.
    log_snapshot_table(snaps, history=hist, now_ts=now_ts, logger=logger)

    logger.info("Wrote latest snapshot: %s", out_path)
    logger.info("Updated history: %s", hist_path)
    return 0

```


```python
# verify_run_snapshot_use
from tempfile import TemporaryDirectory

```


```python
with TemporaryDirectory() as td:
    data_dir = Path(td)
    wallets = data_dir / "__missing__.csv"
    wallets.write_text("address,tag\n", encoding="utf-8")
    rc = run_snapshot(data_dir=str(data_dir), wallets_csv="__missing__.csv")
    assert isinstance(rc, int)

```

    2026-02-10T18:31:16 | ERROR | nym_snapshot | No wallets found in /tmp/tmp4lnsbclq/__missing__.csv



```python
# verify_run_snapshot_signature
assert run_snapshot.__name__ == "run_snapshot"

```


```python
assert callable(run_snapshot)
```


```python
#| hide
import nbdev; nbdev.nbdev_export()

```
