#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

section(){ printf '\n== %s ==\n' "$*"; }
# shellcheck source=../lib/main.sh
source "$ROOT/lib/main.sh"

fail(){ echo "FAIL: $*" >&2; exit 1; }
assert_contains(){ [[ "$1" == *"$2"* ]] || fail "expected output to contain: $2"; }

balloon_status(){ echo "BALLOON SUPPORTED: yes"; echo "$UNBOUND_BALLOON_TEST"; }
out="$(balloon_watch_section)"
assert_contains "$out" "BALLOON STATE: ERROR"
assert_contains "$out" "BALLOON RESULT: WARN"
echo parent-still-running > "$TMP/parent-marker"
[[ -f "$TMP/parent-marker" ]] || fail "parent shell did not continue after optional module failure"

balloon_status(){ section "POOLY MEMORY BALLOON"; echo "BALLOON STATE: ACTIVE"; echo "BALLOON RESULT: WARN"; return 2; }
out="$(balloon_watch_section)"
assert_contains "$out" "BALLOON STATE: ACTIVE"
[[ "$(grep -c '^BALLOON RESULT:' <<< "$out")" == "1" ]] || fail "valid WARN result was duplicated"

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
balloon_status(){ section "POOLY MEMORY BALLOON"; echo "BALLOON STATE: ACTIVE"; echo "BALLOON RESULT: WARN"; return 2; }

out="$(guard_watch)"
assert_contains "$out" "SERVICE-CHECK-RAN"
assert_contains "$out" "WATCH RESULT: WARN"
report="$(find "$REPORT_DIR" -type f -name 'pooly-server-guard-watch-*.txt' -print -quit)"
[[ -n "$report" ]] || fail "guard_watch did not write report"
grep -q '^BALLOON RESULT: WARN$' "$report" || fail "report omitted balloon result"
grep -q '^SERVICE HEALTH RESULT: PASS$' "$report" || fail "report omitted later service checks"

echo 'PASS: watch balloon integration tests'
