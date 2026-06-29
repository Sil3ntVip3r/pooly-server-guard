#!/usr/bin/env bash
set -uo pipefail

VERSION="0.5.0-alpha4.0"
REPORT_OWNER="${REPORT_OWNER:-pooly-sil3ntvip3r-admin}"
REPORT_HOME="$(getent passwd "$REPORT_OWNER" 2>/dev/null | cut -d: -f6 || true)"
POOLY_REPO_DIR="${POOLY_REPO_DIR:-${REPORT_HOME:-$HOME}/GPTrepos/pooly-server-guard}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${POOLY_LIB_DIR:-$POOLY_REPO_DIR/lib}"
[[ -d "$LIB_DIR" ]] || LIB_DIR="$SCRIPT_DIR/lib"

for lib in core health drift discord update systemd main; do
  file="$LIB_DIR/$lib.sh"
  if [[ ! -r "$file" ]]; then
    echo "FAIL: required library missing: $file"
    exit 1
  fi
  # shellcheck source=/dev/null
  source "$file" || { echo "FAIL: could not source library: $file"; exit 1; }
done

main "$@"
