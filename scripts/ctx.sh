#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CTX_BIN="${CTX_BIN:-$ROOT/.bin/ctx}"
if [ ! -x "$CTX_BIN" ]; then
  if command -v ctx >/dev/null 2>&1; then
    CTX_BIN="$(command -v ctx)"
  else
    echo "ctx binary not found. Run ./scripts/install_ctx.sh (network required) or set CTX_BIN to an existing ctx." >&2
    exit 1
  fi
fi
cd "$ROOT"
"$CTX_BIN" build --config-file ctx.yaml "$@"
