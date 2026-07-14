#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail(){ echo "FAIL: $*" >&2; exit 1; }
assert_contains(){ [[ "$1" == *"$2"* ]] || fail "expected output to contain: $2"; }

make_runtime(){
  local dir="$1" include_balloon="$2"
  mkdir -p "$dir/lib"
  cp "$ROOT/pooly-server-guard.sh" "$dir/pooly-server-guard.sh"
  cp "$ROOT/lib/main.sh" "$dir/lib/main.sh"
  cp "$ROOT/lib/discord.sh" "$dir/lib/discord.sh"
  cp "$ROOT/lib/update.sh" "$dir/lib/update.sh"
  for f in health drift systemd; do printf '#!/usr/bin/env bash\n' > "$dir/lib/$f.sh"; done
  cat > "$dir/lib/core.sh" <<'CORE'
#!/usr/bin/env bash
POOLY_STATE_DIR="${POOLY_STATE_DIR:-/tmp/pooly-test-state}"
POOLY_GUARD_ENV="${POOLY_GUARD_ENV:-/nonexistent}"
POOLY_INSTALL_PATH="${POOLY_INSTALL_PATH:-/tmp/pooly-server-guard.sh}"
POOLY_REPO_DIR="${POOLY_REPO_DIR:-/tmp/pooly-server-guard-repo}"
POOLY_WATCH_ONCALENDAR="${POOLY_WATCH_ONCALENDAR:-*:0/10}"
POOLY_PRODUCTION_ONCALENDAR="${POOLY_PRODUCTION_ONCALENDAR:-*:0/10}"
POOLY_LOCK_FILE="${POOLY_LOCK_FILE:-/tmp/pooly-server-guard.lock}"
POOLY_ALERT_ON_WARN="${POOLY_ALERT_ON_WARN:-1}"
POOLY_DISCORD_SUPPRESS_PASS="${POOLY_DISCORD_SUPPRESS_PASS:-1}"
SUDO=""
section(){ printf '\n== %s ==\n' "$*"; }
load_env(){ return 0; }
health_defaults(){ :; }
status_return(){ case "$1" in PASS) return 0 ;; WARN) return 2 ;; FAIL) return 1 ;; *) return 1 ;; esac; }
json_escape(){ python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'; }
CORE
  if [[ "$include_balloon" == "1" ]]; then cp "$ROOT/lib/balloon.sh" "$dir/lib/balloon.sh"; fi
  printf '0.5.0-alpha4.1.0\n' > "$dir/VERSION"
  chmod +x "$dir/pooly-server-guard.sh"
}

feature="$TMP/feature"
make_runtime "$feature" 1
out="$(POOLY_LIB_DIR="$feature/lib" "$feature/pooly-server-guard.sh" --help)"
assert_contains "$out" "Pooly Server Guard v0.5.0-alpha4.1.0"
assert_contains "$out" "balloon-status"

rm -f "$feature/lib/balloon.sh"
out="$(POOLY_LIB_DIR="$feature/lib" "$feature/pooly-server-guard.sh" --help)"
assert_contains "$out" "Pooly Server Guard v0.5.0-alpha4.1.0"

set +e
out="$(POOLY_LIB_DIR="$feature/lib" "$feature/pooly-server-guard.sh" balloon-status 2>&1)"
rc=$?
set -e
[[ "$rc" == "2" ]] || fail "missing optional module returned $rc, want 2"
assert_contains "$out" "BALLOON STATE: MODULE_MISSING"
assert_contains "$out" "BALLOON RESULT: WARN"

rollback="$TMP/rollback"
make_runtime "$rollback" 0
POOLY_REPO_DIR="$rollback"
# shellcheck source=../lib/update.sh
source "$ROOT/lib/update.sh"
validate_repo_release || fail "validator rejected rollback tree without optional balloon module"

if grep -E 'REQUIRED_LIBS=.*balloon' "$ROOT/pooly-server-guard.sh"; then
  fail "balloon library was added to required startup dependencies"
fi

printf 'PASS: optional module rollback tests\n'
