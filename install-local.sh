#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-$HOME/GPTlogs}"
INSTALL_PATH="${POOLY_INSTALL_PATH:-$INSTALL_DIR/pooly-server-guard.sh}"

mkdir -p "$INSTALL_DIR"
install -m 755 pooly-server-guard.sh "$INSTALL_PATH"

echo "Installed: $INSTALL_PATH"
echo
"$INSTALL_PATH" --help
