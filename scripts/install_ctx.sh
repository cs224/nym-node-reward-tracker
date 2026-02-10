#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${CTX_BIN_DIR:-$ROOT/.bin}"
mkdir -p "$DEST"
echo "Installing ctx to $DEST ..."
curl -sSL https://raw.githubusercontent.com/context-hub/generator/main/download-latest.sh | bash -s "$DEST"
echo "ctx installed at $DEST/ctx"
