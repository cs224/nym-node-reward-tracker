# Makefile for an nbdev2 + uv project

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.NOTPARALLEL:
.DEFAULT_GOAL := help

UV      ?= uv
QUARTO  ?= quarto
UVRUN    = $(UV) run

NBS_DIR     ?= nbs
NBS_MD_DIR  ?= nbs_md
PROC_DIR    ?= _proc

# Single-file render inside _proc (proc-relative)
RENDER_ONE ?= 10_cli.ipynb

NB_TIMEOUT ?= 600

CTX_CONFIG  ?= ctx.yaml
CTX_LOCAL   ?= ./.bin/ctx
CTX_INSTALL ?= ./scripts/install_ctx.sh

.PHONY: help \
  sync export nbs_md \
  nbdev_test pytest test test-fast test-nb \
  clean strip-outputs clean-nbs \
  proc exec-nbs proc-live \
  render render-live docs docs-refresh-live preview render-one render-core \
  clean-proc clean-docs clean-all \
  publish \
  test_reward_transactions \
  ctx ctx-check ctx-install quarto-inspect

help:
	@echo "Targets:"
	@echo ""
	@echo "  Environment:"
	@echo "    make sync         - Create/update .venv from pyproject.toml"
	@echo ""
	@echo "  Build / export:"
	@echo "    make export       - nbdev_export (generate package modules)"
	@echo "    make nbs_md       - export tracked nbdev notebooks as markdown into $(NBS_MD_DIR)/"
	@echo ""
	@echo "  Tests (two runners):"
	@echo "    make nbdev_test   - notebook-based tests via nbdev_test"
	@echo "    make pytest       - standard Python tests via pytest"
	@echo "    make test         - quality gate: runs nbdev_test then pytest"
	@echo "    make test-fast    - convenience: pytest only"
	@echo "    make test-nb      - convenience: nbdev_test only"
	@echo ""
	@echo "  Docs:"
	@echo "    make docs               - non-executing docs build (uses saved notebook outputs)"
	@echo "    make docs-refresh-live  - execute notebooks (refresh outputs) then render docs"
	@echo "    make preview            - quarto preview from within $(PROC_DIR)"
	@echo "    make render-one         - render a single page inside $(PROC_DIR) (RENDER_ONE=$(RENDER_ONE))"
	@echo ""
	@echo "  Cleanup:"
	@echo "    make clean         - nbdev_clean"
	@echo "    make strip-outputs - nbdev_clean --clear_all (DESTRUCTIVE: strips notebook outputs)"
	@echo "    make clean-proc    - remove $(PROC_DIR)"
	@echo "    make clean-docs    - remove rendered docs output under $(PROC_DIR)"
	@echo "    make clean-all     - clean + clean-proc + clean-docs (non-destructive to notebook outputs)"
	@echo ""
	@echo "  Publish:"
	@echo "    make publish       - run tests, refresh live outputs, build docs, refresh nbs_md, then publish $(PROC_DIR)/_docs to gh-pages"

## Ensure environment is ready
sync:
	@echo "==> uv sync"
	$(UV) sync --group dev

## Step 1: export library code from notebooks
export:
	@echo "==> nbdev_export"
	$(UVRUN) nbdev_export

## Export notebooks to markdown for notebook-flow review and version control
nbs_md:
	@echo "==> export notebooks to $(NBS_MD_DIR)/"
	mkdir -p $(NBS_MD_DIR)
	rm -f $(NBS_MD_DIR)/*.md
	rm -rf $(NBS_MD_DIR)/*_files
	$(UVRUN) python -m jupyter nbconvert --to markdown --output-dir $(NBS_MD_DIR) $$(git ls-files '$(NBS_DIR)/*.ipynb')

## Tests: nbdev (notebooks)
nbdev_test:
	@echo "==> nbdev_test"
	$(UVRUN) nbdev_test --n_workers 0

## Tests: pytest (standard)
pytest:
	@echo "==> pytest"
	$(UVRUN) pytest

## Quality gate: both test systems
test: nbdev_test pytest
	@echo "Done: nbdev_test + pytest"

## Convenience aliases (do not replace canonical targets)
test-fast: pytest
	@echo "Done: pytest (fast)"

test-nb: nbdev_test
	@echo "Done: nbdev_test (notebook suite)"

## nbdev clean
clean:
	@echo "==> nbdev_clean"
	$(UVRUN) nbdev_clean

## Destructive: strip notebook outputs
strip-outputs:
	@echo "==> nbdev_clean --clear_all"
	$(UVRUN) nbdev_clean --clear_all

## Back-compat alias (old name)
clean-nbs: strip-outputs
	@echo "Done: clean-nbs (alias for strip-outputs)"

## Preprocess notebooks for docs (generates/updates _proc) without execution
proc:
	@echo "==> nbdev_proc_nbs"
	$(UVRUN) nbdev_proc_nbs

## Execute notebooks to refresh outputs (explicit, on-demand)
exec-nbs:
	@echo "==> execute notebooks inside $(NBS_DIR) (refresh saved outputs)"
	$(UVRUN) python -m jupyter nbconvert --to notebook --inplace --execute --ExecutePreprocessor.timeout=$(NB_TIMEOUT) $(NBS_DIR)/*.ipynb

## On-demand live refresh: execute notebooks then preprocess
proc-live: exec-nbs
	@echo "==> nbdev_proc_nbs"
	$(UVRUN) nbdev_proc_nbs

## Render documentation (FULL SITE, non-executing by default)
render: proc
	@echo "==> quarto render (full site) inside $(PROC_DIR)"
	cd $(PROC_DIR) && $(QUARTO) render

## Render docs after live notebook execution
render-live: proc-live
	@echo "==> quarto render (full site) inside $(PROC_DIR)"
	cd $(PROC_DIR) && $(QUARTO) render

## High-level docs target (non-executing, preserves last saved outputs)
docs:
	@echo "==> uv sync --group dev"
	$(UV) sync --group dev
	$(MAKE) render
	@echo "Done: docs"

## On-demand live refresh path for API examples
docs-refresh-live:
	@echo "==> uv sync --group dev"
	$(UV) sync --group dev
	$(MAKE) render-live
	@echo "Done: docs-refresh-live"

## Live preview server
preview: proc
	@echo "==> quarto preview inside $(PROC_DIR)"
	cd $(PROC_DIR) && $(QUARTO) preview

## Single-file render for faster iteration (proc-relative)
render-one: proc
	@echo "==> quarto render (single file): $(RENDER_ONE)"
	cd $(PROC_DIR) && $(QUARTO) render $(RENDER_ONE)

## Back-compat alias (old name)
render-core: render-one

## Cleanup helpers
clean-proc:
	@echo "==> rm -rf $(PROC_DIR)"
	rm -rf $(PROC_DIR)

clean-docs:
	@echo "==> rm -rf $(PROC_DIR)/_docs $(PROC_DIR)/_site (if present)"
	rm -rf $(PROC_DIR)/_docs $(PROC_DIR)/_site

## Non-destructive artifact clean
clean-all: clean clean-proc clean-docs
	@echo "Done: clean-all"

quarto-inspect:
	@echo "Quarto Inspect:"
	cd $(PROC_DIR) && quarto inspect . | jq .

## Publish docs in _proc/_docs to gh-pages (GitHub Pages)
publish: test docs-refresh-live nbs_md
	@echo "==> ghp-import (publish $(PROC_DIR)/_docs to gh-pages)"
	$(UVRUN) ghp-import -n -p -f $(PROC_DIR)/_docs
	@echo "Done: publish (gh-pages updated from $(PROC_DIR)/_docs)"

test_reward_transactions:
	$(UVRUN) nym-node-reward-tracker reward-transactions --wallets ./data/wallet-addresses.csv --currency eur --start 2025-01-01 --end 2025-12-31 --out nym_rewards_2025_eur.csv

## CTX integration (optional)
ctx-check:
	@set -e; \
	CTX_BIN="$(CTX_LOCAL)"; \
	if [ ! -x "$$CTX_BIN" ]; then \
	  if command -v ctx >/dev/null 2>&1; then \
	    CTX_BIN="$$(command -v ctx)"; \
	  else \
	    echo "ERROR: CTX binary not found at '$(CTX_LOCAL)' and 'ctx' is not in PATH."; \
	    if [ -f "$(CTX_INSTALL)" ]; then \
	      echo "Fix: run 'make ctx-install' (network required)"; \
	    fi; \
	    exit 1; \
	  fi; \
	fi

ctx: ctx-check
	@set -e; \
	CTX_BIN="$(CTX_LOCAL)"; \
	if [ ! -x "$$CTX_BIN" ]; then \
	  CTX_BIN="$$(command -v ctx)"; \
	fi; \
	"$$CTX_BIN" tool:run nb-export --no-interaction --config-file "$(CTX_CONFIG)"; \
	"$$CTX_BIN" build --config-file "$(CTX_CONFIG)"

ctx-install:
	@set -e; \
	if [ ! -f "$(CTX_INSTALL)" ]; then \
	  echo "ERROR: install script not found at '$(CTX_INSTALL)'"; \
	  exit 1; \
	fi; \
	sh "$(CTX_INSTALL)"
