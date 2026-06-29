#!/usr/bin/env bash
set -uo pipefail

VERSION="0.5.0-alpha4.0.1"
REPORT_OWNER="${REPORT_OWNER:-pooly-sil3ntvip3r-admin}"
REPORT_HOME="$(getent passwd "$REPORT_OWNER" 2>/dev/null | cut -d: -f6 || true)"
POOLY_REPO_DIR="${POOLY_REPO_DIR:-${REPORT_HOME:-$HOME}/GPTrepos/pooly-server-guard}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${POOLY_LIB_DIR:-$POOLY_REPO_DIR/lib}"
[[ -d "$LIB_DIR" ]] || LIB_DIR="$SCRIPT_DIR/lib"

REQUIRED_LIBS=(core health drift discord update systemd main)
missing_lib=0
for lib in "${REQUIRED_LIBS[@]}"; do
  [[ -r "$LIB_DIR/$lib.sh" ]] || missing_lib=1
done

if [[ "$missing_lib" == "1" && -d "$POOLY_REPO_DIR/.git" ]]; then
  echo "WARN: one or more alpha4 libraries are missing; attempting repo refresh before startup"
  if [[ ${EUID:-$(id -u)} -eq 0 && -n "${REPORT_OWNER:-}" && "$REPORT_OWNER" != "root" ]]; then
    sudo -H -u "$REPORT_OWNER" git -C "$POOLY_REPO_DIR" fetch --quiet --all --prune || true
    sudo -H -u "$REPORT_OWNER" git -C "$POOLY_REPO_DIR" reset --hard origin/main >/dev/null 2>&1 || true
  else
    git -C "$POOLY_REPO_DIR" fetch --quiet --all --prune || true
    git -C "$POOLY_REPO_DIR" reset --hard origin/main >/dev/null 2>&1 || true
  fi
fi

for lib in "${REQUIRED_LIBS[@]}"; do
  file="$LIB_DIR/$lib.sh"
  if [[ ! -r "$file" ]]; then
    echo "FAIL: required library missing: $file"
    exit 1
  fi
  # shellcheck source=/dev/null
  source "$file" || { echo "FAIL: could not source library: $file"; exit 1; }
done

main "$@"
