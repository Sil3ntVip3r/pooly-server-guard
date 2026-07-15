#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/balloon.sh
source "$ROOT/lib/balloon.sh"

section(){ :; }
load_env(){ return 0; }
status_return(){ case "$1" in PASS) return 0 ;; WARN) return 2 ;; FAIL) return 1 ;; *) return 1 ;; esac; }

fail(){ echo "FAIL: $*" >&2; exit 1; }
assert_contains(){ [[ "$1" == *"$2"* ]] || fail "expected output to contain: $2
--- output ---
$1"; }
assert_not_contains(){ [[ "$1" != *"$2"* ]] || fail "expected output not to contain: $2"; }
assert_eq(){ [[ "$1" == "$2" ]] || fail "expected '$2', got '$1'"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export POOLY_BALLOON_VMSTAT_PATH="$TMP/vmstat"
export POOLY_BALLOON_MEMINFO_PATH="$TMP/meminfo"
export POOLY_BALLOON_PSI_PATH="$TMP/psi"
export POOLY_BALLOON_BOOT_ID_PATH="$TMP/boot_id"
export POOLY_BALLOON_SYSFS_ROOT="$TMP/sys"
export POOLY_BALLOON_STATE_DIR="$TMP/state/balloon"
export POOLY_BALLOON_WARN_MIB=1024
export POOLY_BALLOON_HISTORY_MAX_LINES=10000
export POOLY_BALLOON_LOCK_WAIT_SECONDS=2
export POOLY_BALLOON_ASSUME_SUPPORTED=1

PAGE_SIZE="$(getconf PAGESIZE)"
THRESHOLD_PAGES=$((1024*1024*1024/PAGE_SIZE))
BASE=1000000

write_vmstat(){
  local inflate="$1" deflate="$2" migrate="${3:-0}" psin="${4:-100}" psout="${5:-200}" maj="${6:-300}" oom="${7:-0}"
  cat > "$POOLY_BALLOON_VMSTAT_PATH" <<DATA
balloon_inflate $inflate
balloon_deflate $deflate
balloon_migrate $migrate
pswpin $psin
pswpout $psout
pgmajfault $maj
oom_kill $oom
DATA
}

write_meminfo(){
  local available="${1:-83886080}" swap_free="${2:-15728640}"
  cat > "$POOLY_BALLOON_MEMINFO_PATH" <<DATA
MemTotal:       100663296 kB
MemAvailable:   $available kB
SwapTotal:      20971520 kB
SwapFree:       $swap_free kB
DATA
}

write_psi(){
  cat > "$POOLY_BALLOON_PSI_PATH" <<'DATA'
some avg10=0.12 avg60=0.01 avg300=0.00 total=1
full avg10=0.03 avg60=0.00 avg300=0.00 total=1
DATA
}

run_status(){
  local output rc
  set +e
  output="$(balloon_status --persist 2>&1)"
  rc=$?
  set -e
  printf '%s\n%s' "$rc" "$output"
}

run_readonly(){
  local output rc
  set +e
  output="$(balloon_status --no-persist 2>&1)"
  rc=$?
  set -e
  printf '%s\n%s' "$rc" "$output"
}

status_rc(){ printf '%s\n' "$1" | head -1; }
status_output(){ printf '%s\n' "$1" | tail -n +2; }

reset_fixture(){
  rm -rf "$TMP/state" "$TMP/sys"
  mkdir -p "$TMP/state" "$TMP/sys"
  printf 'boot-a\n' > "$POOLY_BALLOON_BOOT_ID_PATH"
  write_meminfo
  write_psi
}

# Disabled monitoring must not create state.
reset_fixture
write_vmstat "$BASE" "$BASE"
export POOLY_BALLOON_MONITOR_ENABLED=0
res="$(run_status)"
assert_eq "$(status_rc "$res")" "0"
assert_contains "$(status_output "$res")" "BALLOON SAMPLE MODE: PERSIST"
assert_contains "$(status_output "$res")" "BALLOON STATE: DISABLED"
assert_contains "$(status_output "$res")" "BALLOON RESULT: PASS"
[[ ! -e "$POOLY_BALLOON_STATE_DIR/state.tsv" ]] || fail "disabled monitor wrote state"

# Read-only status must not create initial state.
reset_fixture
export POOLY_BALLOON_MONITOR_ENABLED=1
export POOLY_BALLOON_ASSUME_SUPPORTED=1
write_vmstat "$BASE" "$BASE"
res="$(run_readonly)"
assert_eq "$(status_rc "$res")" "0"
assert_contains "$(status_output "$res")" "BALLOON SAMPLE MODE: READ_ONLY"
assert_contains "$(status_output "$res")" "BALLOON STATE: BASELINE"
assert_contains "$(status_output "$res")" "read-only sample did not advance balloon alert state"
[[ ! -e "$POOLY_BALLOON_STATE_DIR/state.tsv" ]] || fail "read-only status created state"

# Unsupported hosts do not create state.
reset_fixture
export POOLY_BALLOON_ASSUME_SUPPORTED=0
write_vmstat 0 0 0
res="$(run_status)"
assert_eq "$(status_rc "$res")" "0"
assert_contains "$(status_output "$res")" "BALLOON STATE: UNSUPPORTED"
assert_contains "$(status_output "$res")" "BALLOON RESULT: PASS"
[[ ! -e "$POOLY_BALLOON_STATE_DIR/state.tsv" ]] || fail "unsupported monitor wrote state"

reset_fixture
export POOLY_BALLOON_ASSUME_SUPPORTED=1
: > "$POOLY_BALLOON_VMSTAT_PATH"
res="$(run_status)"
assert_eq "$(status_rc "$res")" "0"
assert_contains "$(status_output "$res")" "BALLOON STATE: UNSUPPORTED"

# Malformed counters fail open as WARN.
reset_fixture
printf 'balloon_inflate not-a-number\nballoon_deflate 0\n' > "$POOLY_BALLOON_VMSTAT_PATH"
res="$(run_status)"
assert_eq "$(status_rc "$res")" "2"
assert_contains "$(status_output "$res")" "BALLOON STATE: ERROR"

# First persisted sample creates protected baseline files.
reset_fixture
write_vmstat "$BASE" "$BASE"
res="$(run_status)"
assert_eq "$(status_rc "$res")" "0"
assert_contains "$(status_output "$res")" "BALLOON STATE: BASELINE"
assert_contains "$(status_output "$res")" "BALLOON RESULT: PASS"
assert_eq "$(stat -c '%a' "$POOLY_BALLOON_STATE_DIR")" "700"
assert_eq "$(stat -c '%a' "$POOLY_BALLOON_STATE_DIR/state.tsv")" "600"
assert_eq "$(stat -c '%a' "$POOLY_BALLOON_STATE_DIR/history.tsv")" "600"

# A manual read-only sample cannot consume a new transition before watch persists it.
inflate_active=$((BASE + THRESHOLD_PAGES*2))
write_vmstat "$inflate_active" "$BASE" 10 100 250 350 0
write_meminfo 16777216 15000000
state_before="$(cat "$POOLY_BALLOON_STATE_DIR/state.tsv")"
history_before="$(wc -l < "$POOLY_BALLOON_STATE_DIR/history.tsv" | tr -d ' ')"
res="$(run_readonly)"
assert_eq "$(status_rc "$res")" "2"
assert_contains "$(status_output "$res")" "BALLOON STATE: ACTIVE"
assert_contains "$(status_output "$res")" "BALLOON RESULT: WARN"
assert_eq "$(cat "$POOLY_BALLOON_STATE_DIR/state.tsv")" "$state_before"
assert_eq "$(wc -l < "$POOLY_BALLOON_STATE_DIR/history.tsv" | tr -d ' ')" "$history_before"
res="$(run_status)"
assert_eq "$(status_rc "$res")" "2"
assert_contains "$(status_output "$res")" "BALLOON STATE: ACTIVE"
assert_contains "$(status_output "$res")" "new significant host balloon inflation detected"

# Continuing inflation does not repeat a transition warning.
inflate_cont=$((inflate_active + THRESHOLD_PAGES))
write_vmstat "$inflate_cont" "$BASE" 20 110 300 400 0
write_meminfo 8388608 14800000
res="$(run_status)"
assert_eq "$(status_rc "$res")" "0"
assert_contains "$(status_output "$res")" "BALLOON STATE: ACTIVE_CONTINUING"
assert_contains "$(status_output "$res")" "BALLOON RESULT: PASS"

# Deflation and recovery remain visible without duplicate warning.
deflate_partial=$((BASE + THRESHOLD_PAGES))
write_vmstat "$inflate_cont" "$deflate_partial" 30 120 310 410 0
write_meminfo 33554432 14800000
res="$(run_status)"
assert_eq "$(status_rc "$res")" "0"
assert_contains "$(status_output "$res")" "BALLOON STATE: DEFLATING"

write_vmstat "$inflate_cont" "$inflate_cont" 40 130 320 420 0
write_meminfo 83886080 14800000
res="$(run_status)"
assert_eq "$(status_rc "$res")" "0"
assert_contains "$(status_output "$res")" "BALLOON STATE: RECOVERED"

# A full cycle between samples warns once without claiming an exact event count.
cycle=$((THRESHOLD_PAGES*2))
write_vmstat $((inflate_cont+cycle)) $((inflate_cont+cycle)) 50 140 400 500 0
res="$(run_status)"
assert_eq "$(status_rc "$res")" "2"
assert_contains "$(status_output "$res")" "BALLOON STATE: CYCLE_COMPLETED"
assert_contains "$(status_output "$res")" "one or more complete balloon cycles occurred between checks"

# Next unchanged sample is idle and does not repeat the warning.
res="$(run_status)"
assert_eq "$(status_rc "$res")" "0"
assert_contains "$(status_output "$res")" "BALLOON STATE: IDLE"
assert_contains "$(status_output "$res")" "BALLOON RESULT: PASS"
history_before_idle="$(wc -l < "$POOLY_BALLOON_STATE_DIR/history.tsv" | tr -d ' ')"
res="$(run_status)"
history_after_idle="$(wc -l < "$POOLY_BALLOON_STATE_DIR/history.tsv" | tr -d ' ')"
assert_eq "$history_after_idle" "$history_before_idle"

# Ordinary idle swap-in/page-fault movement updates baseline counters but not balloon history.
write_vmstat $((inflate_cont+cycle)) $((inflate_cont+cycle)) 50 155 400 575 0
res="$(run_status)"
assert_eq "$(status_rc "$res")" "0"
assert_contains "$(status_output "$res")" "BALLOON STATE: IDLE"
assert_eq "$(wc -l < "$POOLY_BALLOON_STATE_DIR/history.tsv" | tr -d ' ')" "$history_before_idle"

# Partial deflation during a newly active event must not be misclassified as a complete cycle.
reset_fixture
write_vmstat "$BASE" "$BASE"
run_status >/dev/null
write_vmstat $((BASE+THRESHOLD_PAGES*10)) $((BASE+THRESHOLD_PAGES*2))
res="$(run_status)"
assert_eq "$(status_rc "$res")" "2"
assert_contains "$(status_output "$res")" "BALLOON STATE: ACTIVE"
assert_not_contains "$(status_output "$res")" "BALLOON STATE: CYCLE_ACTIVE"

# A complete cycle followed by renewed inflation before the next sample must still warn.
reset_fixture
write_vmstat "$BASE" "$BASE"
run_status >/dev/null
active_outstanding=$((THRESHOLD_PAGES*2))
write_vmstat $((BASE+active_outstanding)) "$BASE"
res="$(run_status)"
assert_eq "$(status_rc "$res")" "2"
assert_contains "$(status_output "$res")" "BALLOON STATE: ACTIVE"
write_vmstat $((BASE+active_outstanding+cycle)) $((BASE+cycle))
res="$(run_status)"
assert_eq "$(status_rc "$res")" "2"
assert_contains "$(status_output "$res")" "BALLOON STATE: CYCLE_ACTIVE"
assert_contains "$(status_output "$res")" "cycle-scale inflate and deflate activity occurred between checks and significant ballooning remains active"
res="$(run_status)"
assert_eq "$(status_rc "$res")" "0"
assert_contains "$(status_output "$res")" "BALLOON STATE: ACTIVE_CONTINUING"

# OOM counter changes warn without being misattributed when no balloon activity is present.
reset_fixture
write_vmstat "$BASE" "$BASE" 0 100 200 300 0
run_status >/dev/null
write_vmstat "$BASE" "$BASE" 0 100 200 300 1
res="$(run_status)"
assert_eq "$(status_rc "$res")" "2"
assert_contains "$(status_output "$res")" "BALLOON STATE: OOM_OBSERVED"
assert_contains "$(status_output "$res")" "OOM KILL DELTA: 1"
assert_contains "$(status_output "$res")" "without significant balloon activity"

# Missing PSI is supported and yields zero values.
rm -f "$POOLY_BALLOON_PSI_PATH"
res="$(run_status)"
assert_eq "$(status_rc "$res")" "0"
assert_contains "$(status_output "$res")" "MEMORY PSI SOME/FULL: 0 / 0"
write_psi

# Boot/counter reset must not produce negative deltas.
printf 'boot-b\n' > "$POOLY_BALLOON_BOOT_ID_PATH"
write_vmstat 10 10 0 1 1 1 0
res="$(run_status)"
assert_eq "$(status_rc "$res")" "0"
assert_contains "$(status_output "$res")" "BALLOON STATE: COUNTER_RESET"
assert_not_contains "$(status_output "$res")" "SINCE LAST CHECK: -"

# A reset still warns if significant ballooning is already active.
printf 'boot-c\n' > "$POOLY_BALLOON_BOOT_ID_PATH"
write_vmstat $((THRESHOLD_PAGES*2)) 0 0 1 1 1 0
res="$(run_status)"
assert_eq "$(status_rc "$res")" "2"
assert_contains "$(status_output "$res")" "BALLOON STATE: ACTIVE"
assert_contains "$(status_output "$res")" "counters changed while significant host ballooning is active"
res="$(run_status)"
assert_eq "$(status_rc "$res")" "0"
assert_contains "$(status_output "$res")" "BALLOON STATE: ACTIVE_CONTINUING"

# Corrupt state is data, never sourced or executed.
pwned="$TMP/pwned"
printf '$(touch %s)\n' "$pwned" > "$POOLY_BALLOON_STATE_DIR/state.tsv"
write_vmstat 20 20 0 2 2 2 0
res="$(run_status)"
assert_eq "$(status_rc "$res")" "2"
assert_contains "$(status_output "$res")" "BALLOON STATE: STATE_RESET"
[[ ! -e "$pwned" ]] || fail "corrupt state executed shell content"

# Real Node003 counters captured during the July 13 balloon event.
reset_fixture
write_vmstat 1452704256 1452704256 109267 21392 1393809 114584 0
write_meminfo 83733604 15402804
res="$(run_status)"
assert_contains "$(status_output "$res")" "BALLOON STATE: BASELINE"
write_vmstat 1473015808 1452704256 109267 21565 1393809 114841 0
write_meminfo 2454724 15403060
res="$(run_status)"
assert_eq "$(status_rc "$res")" "2"
assert_contains "$(status_output "$res")" "BALLOON STATE: ACTIVE"
assert_contains "$(status_output "$res")" "BALLOON OUTSTANDING: 77.48 GiB"
write_vmstat 1473417216 1470982656 109267 21572 1443257 114964 0
write_meminfo 74156872 15205420
res="$(run_status)"
assert_eq "$(status_rc "$res")" "0"
assert_contains "$(status_output "$res")" "BALLOON STATE: DEFLATING"
write_vmstat 1473417216 1473417216 109267 21600 1443257 115000 0
write_meminfo 83800000 15205420
res="$(run_status)"
assert_contains "$(status_output "$res")" "BALLOON STATE: RECOVERED"

# History is bounded exactly to the configured line limit.
export POOLY_BALLOON_HISTORY_MAX_LINES=3
for n in 1 2 3 4 5; do
  write_vmstat $((1473417216+n)) $((1473417216+n)) 0 $((21600+n)) $((1443257+n)) $((115000+n)) 0
  run_status >/dev/null
done
assert_eq "$(wc -l < "$POOLY_BALLOON_STATE_DIR/history.tsv" | tr -d ' ')" "3"

# History command is read-only and emits the expected header.
out="$(balloon_history 2)"
assert_contains "$out" $'UTC\tSTATE\tRESULT'

# Dangerous state directory targets are refused before any write.
old_state_dir="$POOLY_BALLOON_STATE_DIR"
export POOLY_BALLOON_STATE_DIR="/"
write_vmstat 100 100
res="$(run_status)"
assert_eq "$(status_rc "$res")" "2"
assert_contains "$(status_output "$res")" "refusing unsafe balloon state directory"
export POOLY_BALLOON_STATE_DIR="$old_state_dir"

# Symlinked state targets are refused.
rm -rf "$TMP/state"
mkdir -p "$TMP/state" "$TMP/elsewhere"
ln -s "$TMP/elsewhere" "$POOLY_BALLOON_STATE_DIR"
write_vmstat 100 100
res="$(run_status)"
assert_eq "$(status_rc "$res")" "2"
assert_contains "$(status_output "$res")" "refusing symlinked balloon state path"

# Invalid mode is rejected.
set +e
invalid_out="$(balloon_status --invalid 2>&1)"
invalid_rc=$?
set -e
assert_eq "$invalid_rc" "1"
assert_contains "$invalid_out" "BALLOON RESULT: FAIL"

# Static safety boundary: Phase 1 may not contain remediation or service-control actions.
if grep -En '\b(swapoff|swapon|reboot|shutdown|pkill|killall)\b|systemctl[[:space:]]+(stop|restart|disable)|/proc/sys/.+>' "$ROOT/lib/balloon.sh"; then
  fail "prohibited remediation action found in balloon module"
fi

# Repeated persistent sampling must not leak its lock descriptor.
reset_fixture
export POOLY_BALLOON_HISTORY_MAX_LINES=10000
write_vmstat 100 100
for n in $(seq 1 25); do
  write_vmstat $((100+n)) $((100+n))
  run_status >/dev/null
done
fd_count="$(find "/proc/$$/fd" -maxdepth 1 -type l 2>/dev/null | wc -l | tr -d ' ')"
(( fd_count < 64 )) || fail "unexpected file descriptor growth: $fd_count"

# Concurrent persistent samples leave one valid state line.
write_vmstat 1000 1000
(run_status >/dev/null) & p1=$!
(run_status >/dev/null) & p2=$!
wait "$p1"
wait "$p2"
assert_eq "$(wc -l < "$POOLY_BALLOON_STATE_DIR/state.tsv" | tr -d ' ')" "1"
balloon_read_state "$POOLY_BALLOON_STATE_DIR/state.tsv" >/dev/null || fail "concurrent state became invalid"

printf 'PASS: balloon observe tests\n'
