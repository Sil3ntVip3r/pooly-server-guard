#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-$HOME/GPTlogs}"
INSTALL_PATH="${POOLY_INSTALL_PATH:-$INSTALL_DIR/pooly-server-guard.sh}"
SOURCE_PATH="${SOURCE_PATH:-pooly-server-guard.sh}"

if [[ ! -f "$SOURCE_PATH" ]]; then
  echo "FAIL: source script missing: $SOURCE_PATH"
  exit 1
fi

bash -n "$SOURCE_PATH"
for f in lib/*.sh; do
  bash -n "$f"
done

mkdir -p "$INSTALL_DIR"
tmp="$(mktemp)"
install -m 755 "$SOURCE_PATH" "$tmp"
mv "$tmp" "$INSTALL_PATH"

echo "Installed: $INSTALL_PATH"
echo
"$INSTALL_PATH" --help
