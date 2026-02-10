# nym-node-reward-tracker

Track Nym node rewards or reward withdrawal transactions over time and export for accounting or tax reporting.

Dual-use project:
- CLI tool for day-to-day runs (`uv run nym-node-reward-tracker ...`)
- Notebook-first [nbdev2](https://nbdev.fast.ai/) repo where notebooks in `nbs/` are the source of truth and exported code is generated in `nym_node_reward_tracker/`

## What this project does

- Snapshot operator rewards and uptime for bonded nodes, with rolling 7-day and 30-day comparisons from stored history.
- Export reward withdrawal transactions and attach fiat prices.
- Build/update a local SQLite cache of chain events for faster reruns.
- Reconstruct epoch-by-epoch reward earnings from cached events.

## Entry points

- CLI (recommended for routine use):
  ```bash
  uv run nym-node-reward-tracker --help
  ```
  Subcommands: `snapshot`, `reward-transactions`, `cache`, `epoch-by-epoch`.
- Notebook landing page: `nbs/index.ipynb`
- CLI notebook: `nbs/10_cli.ipynb` (also used by `make render-one` by default)
- Core pipeline notebooks:
  - `nbs/00_common.ipynb`
  - `nbs/00_cosmos_tx_parsing.ipynb`
  - `nbs/01_snapshot.ipynb`
  - `nbs/02_cache.ipynb`
  - `nbs/03_reward_transactions.ipynb`
  - `nbs/03_epoch_by_epoch.ipynb`
## Quickstart (CLI)

```bash
cd nym-node-reward-tracker
make sync

# Discover commands and options
uv run nym-node-reward-tracker --help

# 1) Snapshot operator rewards (writes to data/ by default)
uv run nym-node-reward-tracker snapshot

# 2) Export reward withdrawal transactions
uv run nym-node-reward-tracker reward-transactions \
  --wallets data/wallet-addresses.csv \
  --currency eur \
  --start 2025-01-01 \
  --end 2025-12-31 \
  --out data/nym_rewards_2025_eur.csv

# 3) Epoch-by-epoch replay to Excel (refreshes cache first)
uv run nym-node-reward-tracker epoch-by-epoch \
  --wallets data/wallet-addresses.csv \
  --out data/epoch_by_epoch_rewards.xlsx
```

Default outputs summary:
- Snapshot: `data/node-balances.csv` (or `.xlsx`) and `data/data.yaml`
- Cache DB: `data/nym_cache.sqlite`
- Epoch-by-epoch: `data/epoch_by_epoch_rewards.xlsx` (when using default `--data-dir data`)
- Reward transactions: output path comes from `--out` (default filename: `nym_rewards_tax_export.csv`)

## Inputs and outputs

### Wallet list (`data/wallet-addresses.csv`)

CSV columns:
- `address`: Nyx bech32 address
- `tag`: free-form label (for example `operator`, `delegator`)

Example:

```csv
address,tag
n127c69pasr35p76amfczemusnutr8mtw78s8xl7,operator
```

### Output formats

Commands that accept `--out` use filename suffixes:
- `.csv` writes CSV
- `.xlsx` writes Excel workbook

This suffix-based behavior is used by `snapshot` and `reward-transactions`.

## CLI reference

### Snapshot

```bash
uv run nym-node-reward-tracker snapshot \
  --data-dir data \
  --wallets wallet-addresses.csv \
  --out node-balances.csv \
  --history data.yaml
```

Behavior:
- Reads wallets from `data/wallet-addresses.csv` by default.
- Writes snapshot output to `data/node-balances.csv` by default.
- Stores rolling history in `data/data.yaml`.

### Reward transactions

```bash
uv run nym-node-reward-tracker reward-transactions \
  --wallets data/wallet-addresses.csv \
  --currency eur \
  --start 2025-01-01 \
  --end 2025-12-31 \
  --out data/nym_rewards_2025_eur.csv
```

Behavior:
- Queries Nyx tx history, detects reward withdrawals, and enriches with CoinGecko pricing.
- `--out` controls CSV vs XLSX output by filename suffix.

Tx URL resolution fallback order:
1. `--explorer-base`
2. `--tx-api-base`
3. `--tx-rpc-base` (default fallback host is `https://rpc.nymtech.net`)

### Cache

```bash
uv run nym-node-reward-tracker cache \
  --data-dir data \
  --wallets wallet-addresses.csv \
  --db-path data/nym_cache.sqlite
```

Behavior:
- Builds/updates local SQLite cache for reward, delegation, and withdrawal event scans.
- Tracks scanned height windows for incremental/idempotent reruns.

### Epoch-by-epoch replay

```bash
uv run nym-node-reward-tracker epoch-by-epoch \
  --data-dir data \
  --wallets wallet-addresses.csv \
  --out epoch_by_epoch_rewards.xlsx \
  --db-path data/nym_cache.sqlite
```

Behavior:
- Refreshes cache first.
- Replays canonical reward events per `(node_id, epoch)`.
- Writes three Excel sheets:
  - `wallet_seed_epoch_earnings`
  - `wallet_all_epoch_earnings`
  - `node_epoch_totals`

## Notebooks

Core notebooks:
- `nbs/00_common.ipynb`
- `nbs/00_cosmos_tx_parsing.ipynb`
- `nbs/01_snapshot.ipynb`
- `nbs/02_cache.ipynb`
- `nbs/03_reward_transactions.ipynb`
- `nbs/03_epoch_by_epoch.ipynb`
- `nbs/10_cli.ipynb`
- `nbs/99_tests.ipynb`

Notebook markdown mirror:
- `nbs_md/` contains markdown exports of tracked `nbs/*.ipynb` notebooks.
- Regenerate with:
  ```bash
  make nbs_md
  ```

## Docs

Docs are rendered with Quarto from preprocessed notebooks in `_proc/`.

- `make docs` renders docs without executing notebooks (uses last-saved outputs).
- `make docs-refresh-live` executes notebooks to refresh outputs, then renders docs.
- `make preview` starts local Quarto preview from `_proc/`.
- `make render-one RENDER_ONE=10_cli.ipynb` renders a single page inside `_proc/`.

## Publishing docs (local to GitHub Pages)

```bash
cd nym-node-reward-tracker
make publish
```

`make publish` runs:
- `make test`
- `make docs-refresh-live`
- `make nbs_md`

Then publishes `_proc/_docs` to `gh-pages` using `ghp-import`.

## Tests

Two complementary test systems are kept separate:

```bash
make nbdev_test   # notebook-based tests
make pytest       # standard Python tests
make test         # quality gate: nbdev_test + pytest
```

Convenience aliases:
- `make test-nb` (nbdev only)
- `make test-fast` (pytest only)

## Developer workflow

Use this section when you are changing notebooks, exported modules, docs, or tests.

### 1) Bootstrap dev tools

`make sync` installs runtime deps. nbdev/Jupyter/docs/test tooling lives in the `dev` group, so install it first:

```bash
cd nym-node-reward-tracker
uv sync --group dev
```

### 2) Run the full nbdev workflow

After each change, run:

```bash
cd nym-node-reward-tracker
make sync
make export
uv run nym-node-reward-tracker snapshot
uv run nym-node-reward-tracker reward-transactions --wallets data/wallet-addresses.csv
uv run nym-node-reward-tracker cache
make test
make docs
make nbs_md
```

### 3) Notebook (nbdev + nbclassic)

- Notebook landing page: `nbs/index.ipynb`
- Ways to launch nbclassic with the right deps:
  1) One-off via `uvx` (no project install changes):
     ```bash
     uvx --with notebook --with nbclassic jupyter nbclassic nbs/index.ipynb
     ```
  2) Using project dev dependencies:
     ```bash
     cd nym-node-reward-tracker
     uv sync --group dev
     uv run jupyter nbclassic nbs/index.ipynb
     ```

## nbdev workflow (cheat sheet)

```bash
cd nym-node-reward-tracker
make sync
make export
uv run nym-node-reward-tracker snapshot
uv run nym-node-reward-tracker reward-transactions --wallets data/wallet-addresses.csv
uv run nym-node-reward-tracker cache
make test
make docs
make nbs_md
```

Useful extras:

```bash
uv run nbdev_install_hooks   # optional: install nbdev git hooks
```

## Project structure (high level)

- `nbs/index.ipynb` - notebook landing page
- `nbs/10_cli.ipynb` - CLI usage in notebook form
- `nym_node_reward_tracker/` - generated Python package (do not edit directly)
- `tests/` - pytest suite
- `data/` - default input/output directory
- `nbs_md/` - markdown mirror for notebook-flow review
- `_proc/` - preprocessed notebooks and rendered docs output (`_proc/_docs`)

## UV cache and environment

This repo uses a project-local uv cache:

```toml
[tool.uv]
cache-dir = "./.uv-cache"
```

- Run `uv` and `make` from `nym-node-reward-tracker/` so this config is applied.
- Do not set `UV_CACHE_DIR` to external locations (for example `/tmp/...`) for normal development.
- If you prefer working in an activated virtualenv shell, run:
  ```bash
  make sync   # or: uv sync
  source .venv/bin/activate
  ```
  You can then run commands directly in that environment (for example `python`, `pytest`, `nbdev_test`).

## Notes / FAQ

### Why are docs non-executing by default?

Some notebooks use live Nyx/REST API calls. To keep regular docs builds deterministic, `make docs` renders saved outputs without re-executing notebooks. Use `make docs-refresh-live` when you intentionally want fresh outputs.

### Can I edit files under `nym_node_reward_tracker/`?

Prefer editing notebooks in `nbs/`; exported files under `nym_node_reward_tracker/` are generated by `make export` (`nbdev_export`).

Advanced exception: nbdev2 provides `nbdev_update`, which can propagate module changes back to the source notebook:

```bash
uv run nbdev_update --fname nym_node_reward_tracker/<module>.py
```

Use this sparingly and verify the notebook narrative/flow afterward. Notebook-first edits remain the default and safest workflow.

### Should I run `uv run nbdev_prepare`?

Usually no. `nbdev_prepare` can overwrite `README.md` and may strip notebook outputs. Prefer the Makefile workflow above.

### I see `Found cells containing imports and other code. See FAQ.` during nbdev processing. What does it mean?

This warning is emitted by nbdev when a notebook code cell mixes import statements with executable logic in the same cell (for example `import ...` plus `assert`, `with ...`, or function calls).

How to notice it:
- It appears in `uv run nbdev_proc_nbs`, `make docs`, or `make docs-refresh-live` output.
- The warning prints the exact offending cell body.

What to do:
1. Split the offending cell into two adjacent cells.
2. Keep imports in an import-only cell.
3. Move runtime/use/verify code (`assert`, calls, temp-file setup, etc.) into the next cell.
4. Re-run:
   ```bash
   uv run nbdev_proc_nbs
   ```
   and confirm the warning is gone.

Reference:
- nbdev FAQ: https://nbdev.fast.ai/faq.html#why-is-there-a-warning-about-found-cells-containing-imports-and-other-code

Related rule for model docs:
- Give each public `pydantic.BaseModel` in exported notebooks an explicit class docstring.
- Without an explicit docstring, generated docs can inherit upstream Pydantic text/links (for example `../concepts/models.md`) that do not exist in this repo and create Quarto unresolved-link warnings.
