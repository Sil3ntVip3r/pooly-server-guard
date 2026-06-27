#!/usr/bin/env bash
set -euo pipefail
mkdir -p "$HOME/GPTlogs"
install -m 700 pooly-server-guard.sh "$HOME/GPTlogs/pooly-server-guard.sh"
echo "Installed: $HOME/GPTlogs/pooly-server-guard.sh"
echo
"$HOME/GPTlogs/pooly-server-guard.sh" --help
