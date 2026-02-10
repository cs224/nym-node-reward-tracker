# Common utilities

Shared helpers for logging, sessions, and input CSVs.


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


# Common utilities

This notebook defines shared helpers used by all commands and notebooks:

* consistent logging
* stable filesystem handling under `data/`
* small input parsers
* HTTP JSON fetchers with retry/backoff
* base64-encoded contract smart-query support

The rule: *anything used by ≥2 modules belongs here.*


```python
#| default_exp common
```

Intent: import only what we need and define stable constants used everywhere.


```python
#| export
from __future__ import annotations

import base64
import csv
import json
import logging
import time
from datetime import datetime, timedelta, timezone
from decimal import Decimal, InvalidOperation
from pathlib import Path
from typing import Any, Dict, Iterator, List, Optional, Sequence, Tuple

import requests
from tqdm import tqdm

DEFAULT_DATA_DIR = Path("data")
DEFAULT_TIMEOUT_S = 60
DEFAULT_LOG_FORMAT = "%(asctime)s | %(levelname)s | %(name)s | %(message)s"
NYM_DENOM = "unym"
MICRO = Decimal("1000000")


```

## Path helpers

Intent: resolve “inputs/outputs under data/” consistently.

Rule:

* if the user passes an absolute path → use it
* if the user passes a bare filename → place under `data_dir`
* if the user passes a relative path *with a parent* (e.g. `data/foo.csv` or `tmp/foo.csv`) → keep as-is


```python
#| export
def resolve_under_dir(base_dir: str | Path, path: str | Path) -> Path:
    """
    Resolve `path` relative to `base_dir` only if it is a bare filename.

    Examples:
      resolve_under_dir("data", "wallet-addresses.csv") -> data/wallet-addresses.csv
      resolve_under_dir("data", "data/wallet-addresses.csv") -> data/wallet-addresses.csv
      resolve_under_dir("data", "/abs/x.csv") -> /abs/x.csv
    """
    base = Path(base_dir)
    p = Path(path)
    if p.is_absolute():
        return p
    # Bare filename: parent is "."
    if p.parent == Path("."):
        return base / p
    return p


def ensure_parent_dir(path: str | Path) -> Path:
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    return p

```


```python
from tempfile import TemporaryDirectory

```


```python
with TemporaryDirectory() as td:
    base = Path(td) / "data"
    assert resolve_under_dir(base, "x.csv") == base / "x.csv"
    assert resolve_under_dir(base, "data/x.csv") == Path("data/x.csv")
    assert resolve_under_dir(base, base / "x.csv") == base / "x.csv"

with TemporaryDirectory() as td:
    out = ensure_parent_dir(Path(td) / "a" / "b" / "c.txt")
    assert out.parent.exists()

```

## Logging

Intent: create a logger that does **not** accumulate duplicate handlers when cells re-run.

Design:

* `setup_logging(name, ...)` returns a configured logger
* safe to call multiple times
* optional file handler + console handler
* `propagate=False` to avoid double logs



```python
#| export
def setup_logging(
    name: str,
    *,
    log_file: str | Path | None = None,
    level: str = "INFO",
) -> logging.Logger:
    logger = logging.getLogger(name)

    # If already configured, just update level and return.
    log_level = getattr(logging, level.upper(), logging.INFO)
    logger.setLevel(log_level)
    logger.propagate = False

    if logger.handlers:
        return logger

    fmt = logging.Formatter(DEFAULT_LOG_FORMAT, datefmt="%Y-%m-%dT%H:%M:%S")

    sh = logging.StreamHandler()
    sh.setFormatter(fmt)
    logger.addHandler(sh)

    if log_file:
        fh = logging.FileHandler(str(log_file), encoding="utf-8")
        fh.setFormatter(fmt)
        logger.addHandler(fh)

    logger.debug("Logger initialized")
    return logger

```


```python
log1 = setup_logging("test_common_logger", level="DEBUG")
log2 = setup_logging("test_common_logger", level="INFO")
assert log1 is log2
assert len(log1.handlers) >= 1
```

    2026-02-10T18:31:10 | DEBUG | test_common_logger | Logger initialized


## Wallet CSV

Intent: parse `wallet-addresses.csv` with columns `address,tag` into a stable list.

Rules:
* skip empty addresses
* tag is optional
* preserve file order (helps stable output)



```python
#| export
def read_wallets_csv(path: str | Path) -> List[Tuple[str, str]]:
    p = Path(path)
    rows: List[Tuple[str, str]] = []
    with p.open(newline="", encoding="utf-8") as f:
        rdr = csv.DictReader(f)
        for row in rdr:
            addr = (row.get("address") or "").strip()
            tag = (row.get("tag") or "").strip()
            if addr:
                rows.append((addr, tag))
    return rows
```


```python
from tempfile import TemporaryDirectory

```


```python
with TemporaryDirectory() as td:
    p = Path(td) / "wallets.csv"
    p.write_text("address,tag\nn1abc,test\n,\n n1def ,  \n", encoding="utf-8")
    out = read_wallets_csv(p)
assert out == [("n1abc", "test"), ("n1def", "")]

```

## YAML + JSON I/O

Intent: read/write YAML and JSON safely for history files and cached metadata.


```python
#| export
def read_json(path: str | Path, *, default: Any = None) -> Any:
    p = Path(path)
    if not p.exists():
        return default
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except Exception:
        return default


def write_json(path: str | Path, obj: Any) -> None:
    p = ensure_parent_dir(path)
    p.write_text(json.dumps(obj, indent=2, sort_keys=True), encoding="utf-8")


def read_yaml(path: str | Path, *, default: Any = None) -> Any:
    # Avoid importing yaml globally for minimal import cost.
    p = Path(path)
    if not p.exists():
        return default
    try:
        import yaml
        return yaml.safe_load(p.read_text(encoding="utf-8")) or default
    except Exception:
        return default

def write_yaml(path: str | Path, obj: Any) -> None:
    p = ensure_parent_dir(path)
    import yaml
    p.write_text(yaml.safe_dump(obj, sort_keys=True), encoding="utf-8")

```


```python
from tempfile import TemporaryDirectory

```


```python
with TemporaryDirectory() as td:
    jp = Path(td) / "x.json"
    write_json(jp, {"a": 1})
    assert read_json(jp) == {"a": 1}

with TemporaryDirectory() as td:
    yp = Path(td) / "x.yaml"
    write_yaml(yp, {"a": 1})
    assert read_yaml(yp) == {"a": 1}

```

## HTTP session + JSON request

Intent: create a `requests.Session` with stable headers and a robust JSON fetcher with retry/backoff.

Important: keep it testable with “fake session” objects (so no reliance on urllib3 Retry internals).

Semantic note: some `429` responses are non-transient (for example: upstream grpc payload-size limits like "message larger than max").
In those cases retrying does not help and should fail fast; scanner window size/logs should be used to correct query shape.


```python
#| export
def build_session(user_agent: str = "nym-node-reward-tracker/1.0") -> requests.Session:
    s = requests.Session()
    s.headers.update(
        {
            "User-Agent": user_agent,
            "Accept": "application/json",
            "Accept-Encoding": "gzip, deflate",
        }
    )
    return s

def request_json(
    session: Any,
    url: str,
    *,
    params: Dict[str, Any] | Sequence[Tuple[str, str]] | None = None,
    headers: Dict[str, str] | None = None,
    timeout: int = DEFAULT_TIMEOUT_S,
    retries: int = 5,
    logger: Optional[logging.Logger] = None,
) -> Any:
    """
    GET JSON with exponential backoff retry for retryable transport/server errors.

    Notes:
    - retries 429/5xx by default,
    - fails fast for known non-transient 429 payload-size errors,
    - raises RuntimeError after retries,
    - logs retry/success timing for diagnostics.
    """
    log = logger or logging.getLogger("nym_node_reward_tracker.http")
    last_err: Optional[Exception] = None
    shown_url = url if len(url) <= 200 else (url[:120] + "..." + url[-40:])

    for attempt in range(1, retries + 1):
        t0 = time.perf_counter()
        try:
            req_kwargs = {"params": params, "timeout": timeout}
            if headers is not None:
                req_kwargs["headers"] = headers
            resp = session.get(url, **req_kwargs)
            status = int(getattr(resp, "status_code", 0) or 0)
            txt = str(getattr(resp, "text", "") or "")

            if status in (429, 500, 502, 503, 504):
                if status == 429 and "message larger than max" in txt:
                    raise RuntimeError(f"HTTP {status} non-retryable payload-too-large: {txt[:200]}")
                raise RuntimeError(f"HTTP {status}: {txt[:200]}")

            resp.raise_for_status()
            out = resp.json()
            elapsed_s = time.perf_counter() - t0
            if attempt > 1:
                log.info(
                    "request_json recovered attempt=%s/%s timeout=%ss elapsed=%.3fs url=%s",
                    attempt, retries, timeout, elapsed_s, shown_url,
                )
            elif elapsed_s >= 1.0:
                log.info(
                    "request_json slow elapsed=%.3fs timeout=%ss url=%s",
                    elapsed_s, timeout, shown_url,
                )
            return out
        except Exception as exc:
            last_err = exc
            elapsed_s = time.perf_counter() - t0
            if "non-retryable payload-too-large" in str(exc):
                log.error(
                    "request_json failed non_retryable timeout=%ss elapsed=%.3fs url=%s err=%s",
                    timeout, elapsed_s, shown_url, exc,
                )
                break
            if attempt < retries:
                sleep_s = min(2 ** attempt, 15)
                log.warning(
                    "request_json retry attempt=%s/%s timeout=%ss elapsed=%.3fs sleep=%.1fs url=%s err=%s",
                    attempt, retries, timeout, elapsed_s, sleep_s, shown_url, exc,
                )
                time.sleep(sleep_s)

    log.error(
        "request_json failed retries_exhausted=%s timeout=%ss url=%s err=%s",
        retries, timeout, shown_url, last_err,
    )
    raise RuntimeError(f"Failed GET {url}: {last_err}") from last_err



```


```python
# verify_request_json_semantics
class _HdrResp:
    status_code = 200
    text = "{}"
    def raise_for_status(self):
        return None
    def json(self):
        return {"ok": True}

class _HdrSession:
    def __init__(self):
        self.headers_seen = None
    def get(self, url, params=None, headers=None, timeout=0):
        self.headers_seen = headers
        return _HdrResp()

hs = _HdrSession()
out = request_json(hs, "https://example", headers={"X-Test": "1"}, retries=1)
assert out["ok"] is True
assert hs.headers_seen == {"X-Test": "1"}

class _TooBigResp:
    status_code = 429
    text = 'grpc: received message larger than max (16281606 vs. 10485760)'
    def raise_for_status(self):
        raise RuntimeError("HTTP 429")
    def json(self):
        return {}

class _TooBigSession:
    def __init__(self):
        self.calls = 0
    def get(self, url, params=None, headers=None, timeout=0):
        self.calls += 1
        return _TooBigResp()

ts = _TooBigSession()
try:
    request_json(ts, "https://example", retries=5)
    raise AssertionError("expected failure")
except RuntimeError:
    pass
assert ts.calls == 1

```

    request_json failed non_retryable timeout=60s elapsed=0.000s url=https://example err=HTTP 429 non-retryable payload-too-large: grpc: received message larger than max (16281606 vs. 10485760)


    request_json failed retries_exhausted=5 timeout=60s url=https://example err=HTTP 429 non-retryable payload-too-large: grpc: received message larger than max (16281606 vs. 10485760)


Intent: provide tiny fake HTTP helpers for deterministic notebook tests of retry/pagination logic without real network calls.\n


```python
#| export
class _FakeResp:
    """Tiny fake response object for notebook-level unit tests."""

    def __init__(self, payload: Any, status_code: int = 200):
        self._payload = payload
        self.status_code = status_code
        self.text = json.dumps(payload)

    def raise_for_status(self) -> None:
        if self.status_code >= 400:
            raise RuntimeError(f"HTTP {self.status_code}")

    def json(self) -> Any:
        return self._payload


class _FakeSession:
    """Tiny fake requests session that replays prepared responses."""

    def __init__(self, responses: List[_FakeResp]):
        self._resps = responses
        self._i = 0

    def get(self, url: str, params: Any = None, headers: Any = None, timeout: int = 0):
        r = self._resps[min(self._i, len(self._resps) - 1)]
        self._i += 1
        return r
```


```python
f = _FakeSession([_FakeResp({"ok": True}), _FakeResp({"ok": False}, status_code=500)])
assert f.get("https://example").json() == {"ok": True}
try:
    f.get("https://example").raise_for_status()
    raise AssertionError("expected HTTP error")
except RuntimeError:
    pass

```

## Smart query helper

Intent: perform CosmWasm smart queries via Nyx REST (`/smart/{b64}`).

We keep it small and let `request_json` handle retries.


```python
#| export
def smart_query(
    session: Any,
    *,
    nyx_wasm_rest: str,
    contract: str,
    payload: Dict[str, Any],
    timeout: int = DEFAULT_TIMEOUT_S,
    logger: Optional[logging.Logger] = None,
) -> Dict[str, Any]:
    """Execute a CosmWasm smart query against the Nyx REST endpoint."""
    raw = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    query_b64 = base64.b64encode(raw).decode("ascii")
    url = f"{nyx_wasm_rest.rstrip('/')}/{contract}/smart/{query_b64}"
    out = request_json(session, url, timeout=timeout, logger=logger)
    return out if isinstance(out, dict) else {}
```


```python
fake = _FakeSession([_FakeResp({"ok": True})])
assert request_json(fake, "http://example") == {"ok": True}

smart = _FakeSession([_FakeResp({"data": {"node_id": 2196}})])
out = smart_query(
    smart,
    nyx_wasm_rest="https://api.nymtech.net/cosmwasm/wasm/v1/contract",
    contract="n1contract",
    payload={"get_node_rewarding_details": {"node_id": 2196}},
)
assert out["data"]["node_id"] == 2196
```

## Parsing helpers

Intent: normalize common “stringly typed” values from APIs and events:
* `to_int`
* `to_decimal`
* `parse_unym_amount` strips trailing denom and leading `+`


```python
#| export
def utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def to_int(value: Any, default: Optional[int] = None) -> Optional[int]:
    try:
        return int(str(value))
    except Exception:
        return default


def to_decimal(value: Any, default: Optional[Decimal] = None) -> Optional[Decimal]:
    if value is None:
        return default
    try:
        return Decimal(str(value))
    except (InvalidOperation, ValueError):
        return default


def parse_unym_amount(value: Optional[str]) -> Optional[str]:
    """
    Parse strings like '123unym' or '+123unym' -> '123'
    Returns None if empty or invalid.
    """
    if not value:
        return None
    s = str(value).strip()
    if s.startswith("+"):
        s = s[1:]
    if s.endswith(NYM_DENOM):
        s = s[: -len(NYM_DENOM)]
    s = s.strip()
    return s if s else None


def b64_json(payload: Dict[str, Any]) -> str:
    raw = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    return base64.b64encode(raw).decode("ascii")

```


```python
assert to_int("42") == 42
assert to_int("x", None) is None
assert to_decimal("1.25") == Decimal("1.25")
assert parse_unym_amount("+123unym") == "123"
assert b64_json({"a": 1}) == "eyJhIjoxfQ=="
```

## Date + wallet tx-query helpers


Intent: keep date parsing and wallet tx query pagination in one shared place so reward/caching notebooks can reuse the exact same behavior.



```python
#| export
def parse_rfc3339_to_utc(ts: str) -> datetime:
    s = (ts or "").strip()
    if not s:
        raise ValueError("empty timestamp")
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    d = datetime.fromisoformat(s)
    if d.tzinfo is None:
        d = d.replace(tzinfo=timezone.utc)
    return d.astimezone(timezone.utc)


def parse_date_filters(
    start: Optional[str],
    end: Optional[str],
) -> tuple[Optional[datetime], Optional[datetime]]:
    start_dt = datetime.fromisoformat(start).replace(tzinfo=timezone.utc) if start else None
    end_dt = (datetime.fromisoformat(end).replace(tzinfo=timezone.utc) + timedelta(days=1)) if end else None
    return start_dt, end_dt


def build_tx_query(address: str, search_mode: str) -> str:
    if search_mode == "sender":
        return f"message.sender='{address}'"
    if search_mode == "recipient":
        return f"transfer.recipient='{address}'"
    raise ValueError(f"Unknown search_mode={search_mode!r} (expected 'sender' or 'recipient')")


def iter_txs_by_query(
    session: Any,
    *,
    nyx_tx_rest: str,
    query: str,
    page_limit: int = 100,
    order_by: str = "ORDER_BY_ASC",
    timeout: int = DEFAULT_TIMEOUT_S,
    retries: int = 5,
    logger: Optional[logging.Logger] = None,
    progress_desc: Optional[str] = None,
) -> Iterator[Tuple[Dict[str, Any], Dict[str, Any]]]:
    """
    Yield `(tx, tx_response)` tuples across all pages for a Cosmos tx search query.

    - Uses `pagination.next_key` to page.
    - De-duplicates by txhash defensively.
    - If `progress_desc` is provided, shows a tqdm progress bar (uses pagination.total if available).
    """
    log = logger or logging.getLogger("nym_node_reward_tracker.tx")
    seen: set[str] = set()
    next_key: Optional[str] = None
    first = True
    pbar = None

    while True:
        params: Dict[str, str] = {
            "query": query,
            "pagination.limit": str(page_limit),
            "pagination.count_total": "true",
            "order_by": order_by,
        }
        if next_key:
            params["pagination.key"] = next_key

        js = request_json(session, nyx_tx_rest, params=params, timeout=timeout, retries=retries, logger=log)
        if not isinstance(js, dict):
            break

        if first:
            total = to_int((js.get("pagination") or {}).get("total"))
            if progress_desc:
                pbar = tqdm(total=total or None, desc=progress_desc, unit="tx")
            first = False

        txs = js.get("txs") or []
        resps = js.get("tx_responses") or []

        for tx, resp in zip(txs, resps):
            txhash = str((resp or {}).get("txhash") or "")
            if txhash and txhash in seen:
                continue
            if txhash:
                seen.add(txhash)
            yield (tx if isinstance(tx, dict) else {}), (resp if isinstance(resp, dict) else {})
            if pbar is not None:
                pbar.update(1)

        next_key = (js.get("pagination") or {}).get("next_key")
        if not next_key:
            break

    if pbar is not None:
        pbar.close()



```


```python
assert parse_rfc3339_to_utc("2025-12-04T16:31:51Z").tzinfo == timezone.utc

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

## Cosmos tx search + pagination and window iteration

Intent: provide a single, reusable Cosmos /cosmos/tx/v1beta1/txs search helper with safe pagination and deduplication. This is needed by both cache building and later epoch-by-epoch reward tooling.


```python
#| export
def tx_search(
    session: Any,
    *,
    nyx_tx_rest: str,
    query: str,
    limit: int = 100,
    offset: int = 0,
    timeout: int = DEFAULT_TIMEOUT_S,
    logger: Optional[logging.Logger] = None,
    strict: bool = False,
    retries: int = 5,
) -> Dict[str, Any]:
    """
    Thin wrapper around Cosmos tx search endpoint.

    Returns a dict that (on success) contains:
      - tx_responses: list
      - pagination: { total: "..." }

    On error (strict=False) it returns:
      - tx_responses: []
      - pagination: { total: "0" }
      - error: <original payload or exception string>

    With strict=True, it raises RuntimeError on HTTP/shape errors.
    """
    params = {
        "query": query,
        "pagination.limit": str(limit),
        "pagination.offset": str(offset),
        "order_by": "ORDER_BY_DESC",
    }
    try:
        out = request_json(
            session,
            nyx_tx_rest,
            params=params,
            timeout=timeout,
            logger=logger,
            retries=retries,
        )
    except Exception as exc:
        if strict:
            raise
        return {"tx_responses": [], "pagination": {"total": "0"}, "error": str(exc)}

    if not isinstance(out, dict) or "tx_responses" not in out:
        msg = f"Malformed tx_search response for query={query!r}: {out!r}"
        if strict:
            raise RuntimeError(msg)
        return {"tx_responses": [], "pagination": {"total": "0"}, "error": out}
    return out


def tx_search_all_pages(
    session: Any,
    *,
    nyx_tx_rest: str,
    query: str,
    page_size: int = 100,
    max_pages: int = 200,
    timeout: int = DEFAULT_TIMEOUT_S,
    logger: Optional[logging.Logger] = None,
    strict: bool = False,
    retries: int = 5,
) -> List[Dict[str, Any]]:
    """
    Fetch all pages using offset pagination.

    Defensive features:
    - de-duplicates by txhash
    - stops on repeated page fingerprint (guards against buggy pagination)
    - with strict=True, raises on transport/shape errors and max_pages truncation
    """
    log = logger or logging.getLogger("nym_node_reward_tracker.tx")
    t_all = time.perf_counter()
    rows: List[Dict[str, Any]] = []
    seen_hashes: set[str] = set()
    prev_fingerprint: Optional[Tuple[str, str, int]] = None
    page_count = 0

    for page_idx in range(max_pages):
        offset = page_idx * page_size
        t_page = time.perf_counter()
        resp = tx_search(
            session,
            nyx_tx_rest=nyx_tx_rest,
            query=query,
            limit=page_size,
            offset=offset,
            timeout=timeout,
            logger=logger,
            strict=strict,
            retries=retries,
        )
        page_count += 1

        if strict and resp.get("error") is not None:
            raise RuntimeError(f"tx_search error query={query!r} offset={offset}: {resp.get('error')}")

        chunk = resp.get("tx_responses") or []
        page_elapsed_s = time.perf_counter() - t_page
        if page_elapsed_s >= 1.0:
            log.info(
                "tx_search_all_pages slow_page query=%r offset=%s page_size=%s elapsed=%.3fs",
                query,
                offset,
                page_size,
                page_elapsed_s,
            )

        if not isinstance(chunk, list) or not chunk:
            break

        first_h = str((chunk[0] or {}).get("txhash") or "")
        last_h = str((chunk[-1] or {}).get("txhash") or "")
        fingerprint = (first_h, last_h, len(chunk))
        if prev_fingerprint == fingerprint:
            break
        prev_fingerprint = fingerprint

        added = 0
        for txr in chunk:
            txhash = str((txr or {}).get("txhash") or "")
            if txhash and txhash in seen_hashes:
                continue
            if txhash:
                seen_hashes.add(txhash)
            rows.append(txr)
            added += 1

        total = to_int((resp.get("pagination") or {}).get("total"))
        if total is not None and len(seen_hashes) >= total:
            break
        if added == 0:
            break
        if len(chunk) < page_size:
            break
    else:
        msg = f"Reached max_pages={max_pages}; results may be truncated for query={query!r}"
        if strict:
            raise RuntimeError(msg)
        log.warning(msg)

    total_elapsed_s = time.perf_counter() - t_all
    if total_elapsed_s >= 1.0:
        log.info(
            "tx_search_all_pages summary query=%r pages=%s rows=%s unique_tx=%s elapsed=%.3fs",
            query,
            page_count,
            len(rows),
            len(seen_hashes),
            total_elapsed_s,
        )

    return rows

```


```python
# Define -> use -> verify: paging dedupe + strict error handling

# dedupe works
_fake_pages = [
    {"tx_responses": [{"txhash": "A"}, {"txhash": "B"}], "pagination": {"total": "2"}},
    {"tx_responses": [{"txhash": "A"}, {"txhash": "B"}], "pagination": {"total": "2"}},
]
fake = _FakeSession([_FakeResp(p) for p in _fake_pages])
out = tx_search_all_pages(fake, nyx_tx_rest="https://example", query="q", page_size=2, max_pages=5)
assert [r["txhash"] for r in out] == ["A", "B"]

# strict=True raises on transport errors
class BoomSession:
    def get(self, url: str, params=None, timeout: int = 0):
        raise RuntimeError("boom")

try:
    tx_search(BoomSession(), nyx_tx_rest="https://example", query="q", strict=True, retries=1)
    raise AssertionError("expected strict tx_search to raise")
except RuntimeError:
    pass

non_strict = tx_search(BoomSession(), nyx_tx_rest="https://example", query="q", strict=False, retries=1)
assert non_strict["tx_responses"] == []
assert "error" in non_strict

# strict=True raises when max_pages truncation is reached
class EndlessSession:
    def get(self, url: str, params=None, timeout: int = 0):
        lim = int((params or {}).get("pagination.limit", 2))
        off = int((params or {}).get("pagination.offset", 0))
        page = {
            "tx_responses": [{"txhash": f"T{off+n}"} for n in range(lim)],
            "pagination": {"total": "999999"},
        }
        return _FakeResp(page)

try:
    tx_search_all_pages(EndlessSession(), nyx_tx_rest="https://example", query="q", page_size=2, max_pages=2, strict=True, retries=1)
    raise AssertionError("expected strict max_pages truncation to raise")
except RuntimeError:
    pass

```

    request_json failed retries_exhausted=1 timeout=60s url=https://example err=boom


    request_json failed retries_exhausted=1 timeout=60s url=https://example err=boom


Intent: deterministic height slicing used across scanners.


```python
#| export
def iter_windows(start_height: int, end_height: int, window_size: int) -> List[Tuple[int, int]]:
    """
    Inclusive height windows: (start, end) with end <= end_height.
    """
    if start_height > end_height:
        return []
    out: List[Tuple[int, int]] = []
    s = start_height
    while s <= end_height:
        e = min(s + window_size - 1, end_height)
        out.append((s, e))
        s = e + 1
    return out
```


```python
assert iter_windows(1, 5, 2) == [(1, 2), (3, 4), (5, 5)]
```


```python
#| hide
import nbdev; nbdev.nbdev_export()

```


```python

```
