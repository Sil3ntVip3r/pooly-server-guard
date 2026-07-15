#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

section(){ printf '\n== %s ==\n' "$*"; }
# shellcheck source=../lib/main.sh
source "$ROOT/lib/main.sh"

fail(){ echo "FAIL: $*" >&2; exit 1; }
assert_contains(){ [[ "$1" == *"$2"* ]] || fail "expected output to contain: $2
$out"; }
assert_not_contains(){ [[ "$1" != *"$2"* ]] || fail "expected output not to contain: $2"; }
assert_eq(){ [[ "$1" == "$2" ]] || fail "expected '$2', got '$1'"; }

# A nounset or explicit exit inside the optional module must not terminate the parent watch shell.
balloon_status(){ echo "BALLOON SUPPORTED: yes"; echo "$UNBOUND_BALLOON_TEST"; }
out="$(balloon_watch_section --persist)"
assert_contains "$out" "BALLOON STATE: ERROR"
assert_contains "$out" "BALLOON RESULT: WARN"
echo parent-still-running > "$TMP/parent-marker"
[[ -f "$TMP/parent-marker" ]] || fail "parent shell did not continue after optional module failure"

# The wrapper forwards read-only mode for manual health/status paths.
balloon_status(){ printf '%s\n' "$1" > "$TMP/mode"; section "POOLY MEMORY BALLOON"; echo "BALLOON STATE: IDLE"; echo "BALLOON RESULT: PASS"; return 0; }
out="$(balloon_watch_section --no-persist)"
assert_contains "$out" "BALLOON STATE: IDLE"
assert_eq "$(cat "$TMP/mode")" "--no-persist"
out="$(balloon_watch_section)"
assert_contains "$out" "BALLOON STATE: IDLE"
assert_eq "$(cat "$TMP/mode")" "--no-persist"

# A valid WARN result with exit code 2 is accepted without fallback duplication.
balloon_status(){ section "POOLY MEMORY BALLOON"; echo "BALLOON STATE: ACTIVE"; echo "BALLOON RESULT: WARN"; return 2; }
out="$(balloon_watch_section --persist)"
assert_contains "$out" "BALLOON STATE: ACTIVE"
[[ "$(grep -c '^BALLOON RESULT:' <<< "$out")" == "1" ]] || fail "valid WARN result was duplicated"

# A result/exit mismatch must fail open as WARN and preserve the parent shell.
balloon_status(){ section "POOLY MEMORY BALLOON"; echo "BALLOON STATE: IDLE"; echo "BALLOON RESULT: PASS"; return 1; }
out="$(balloon_watch_section --persist)"
assert_contains "$out" "result/exit mismatch (PASS/1)"
assert_contains "$out" "BALLOON STATE: ERROR"
assert_contains "$out" "BALLOON RESULT: WARN"

# The health command must request a read-only balloon sample.
version_info(){ :; }
node_id(){ echo 003; }
timer_status(){ :; }
server_health(){ :; }
journal_growth(){ :; }
report_prune(){ :; }
memory_diagnostics(){ :; }
load_diagnostics(){ :; }
failed_services_check(){ :; }
balloon_watch_section(){ printf '%s\n' "$1" > "$TMP/health-mode"; }
health >/dev/null 2>&1 || true
assert_eq "$(cat "$TMP/health-mode")" "--no-persist"
unset -f balloon_watch_section
# shellcheck source=../lib/main.sh
source "$ROOT/lib/main.sh"

# Run the real guard_watch orchestrator with all non-balloon checks stubbed.
REPORT_DIR="$TMP/reports"
REPORT_OWNER="$(id -un)"
POOLY_ALERT_ON_WARN=0
POOLY_ALERT_ON_PASS=0
POOLY_WATCH_WARN_UFW_DRIFT=1
mkdir -p "$REPORT_DIR"
clear_self_failed_state(){ :; }
mkdirs(){ mkdir -p "$REPORT_DIR"; }
load_env(){ :; }
health_defaults(){ :; }
acquire_watch_lock(){ return 0; }
self_update(){ echo "UPDATE RESULT: PASS"; }
report_prune(){ echo "REPORT PRUNE RESULT: PASS"; }
timer_status(){ echo "TIMER RESULT: PASS"; }
verify(){ echo "RESULT: PASS"; }
baseline_verify(){ echo "BASELINE RESULT: PASS"; }
server_health(){ echo "RAM: 20% pressure — PASS"; echo "SWAP: 1% used — PASS"; echo "SERVER HEALTH RESULT: PASS"; }
journal_growth(){ echo "JOURNAL GROWTH RESULT: PASS"; }
memory_pressure_active(){ return 1; }
load_pressure_active(){ return 1; }
port_audit(){ echo "PORT RESULT: PASS"; }
keys_drift(){ echo "KEYS RESULT: PASS"; }
sshd_drift(){ echo "SSHD DRIFT RESULT: PASS"; }
ufw_drift(){ echo "UFW DRIFT RESULT: PASS"; }
services_drift(){ echo "SERVICE RESULT: PASS"; }
service_health(){ echo "SERVICE-CHECK-RAN"; echo "SERVICE HEALTH RESULT: PASS"; }
failed_services_check(){ echo "FAILED SERVICES RESULT: PASS"; }
discord_send_watch(){ echo "DISCORD RESULT: PASS"; }
node_id(){ echo 003; }
balloon_status(){ printf '%s\n' "$1" > "$TMP/watch-mode"; section "POOLY MEMORY BALLOON"; echo "BALLOON STATE: ACTIVE"; echo "BALLOON RESULT: WARN"; return 2; }

out="$(guard_watch)"
assert_contains "$out" "SERVICE-CHECK-RAN"
assert_contains "$out" "WATCH RESULT: WARN"
assert_eq "$(cat "$TMP/watch-mode")" "--persist"
report="$(find "$REPORT_DIR" -type f -name 'pooly-server-guard-watch-*.txt' -print -quit)"
[[ -n "$report" ]] || fail "guard_watch did not write report"
grep -q '^BALLOON RESULT: WARN$' "$report" || fail "report omitted balloon result"
grep -q '^SERVICE HEALTH RESULT: PASS$' "$report" || fail "report omitted later service checks"

# A security failure must keep action priority over a simultaneous balloon warning.
cat > "$TMP/fail-priority.txt" <<'FAIL_PRIORITY'
RESULT: FAIL
BALLOON STATE: ACTIVE
BALLOON RESULT: WARN
SERVICE HEALTH RESULT: PASS
FAILED SERVICES RESULT: PASS
FAIL_PRIORITY
out="$(watch_issue_action "$TMP/fail-priority.txt")"
assert_contains "$out" "security or access-control"
assert_not_contains "$out" "Host-side memory balloon"

printf 'PASS: watch balloon integration tests\n'
