#!/usr/bin/env bash
[[ "${BASH_SOURCE[0]}" == "$0" ]] && { echo "This library must be sourced by pooly-server-guard.sh"; exit 1; }

SSH_PORT="${SSH_PORT:-6200}"
ADMIN_USERS=("poolyadmin" "pooly-sil3ntvip3r-admin")
POOLY_STATE_DIR="${POOLY_STATE_DIR:-/etc/pooly/server-guard-state}"
POOLY_GUARD_ENV="${POOLY_GUARD_ENV:-/etc/pooly/server-guard.env}"
REPORT_OWNER="${REPORT_OWNER:-pooly-sil3ntvip3r-admin}"
REPORT_HOME="$(getent passwd "$REPORT_OWNER" 2>/dev/null | cut -d: -f6 || true)"
REPORT_DIR="${REPORT_DIR:-${REPORT_HOME:-$HOME}/GPTlogs}"
POOLY_REPO_DIR="${POOLY_REPO_DIR:-${REPORT_HOME:-$HOME}/GPTrepos/pooly-server-guard}"
POOLY_INSTALL_PATH="${POOLY_INSTALL_PATH:-${REPORT_HOME:-$HOME}/GPTlogs/pooly-server-guard.sh}"
POOLY_GUARD_AUTO_UPDATE="${POOLY_GUARD_AUTO_UPDATE:-1}"
POOLY_GUARD_AUTO_UPDATE_BRANCH="${POOLY_GUARD_AUTO_UPDATE_BRANCH:-main}"
POOLY_PORT_STRICT_BASELINE="${POOLY_PORT_STRICT_BASELINE:-0}"
POOLY_WATCH_ONCALENDAR="${POOLY_WATCH_ONCALENDAR:-*:0/10}"
POOLY_LOCK_FILE="${POOLY_LOCK_FILE:-/run/pooly-server-guard.lock}"
POOLY_LOCK_WAIT_SECONDS="${POOLY_LOCK_WAIT_SECONDS:-0}"
SUDO=""
[[ ${EUID:-$(id -u)} -eq 0 ]] || SUDO="sudo"

section(){ printf '\n============================================================\n %s\n============================================================\n' "$*"; }
need_sudo(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || sudo -v; }
json_escape(){ python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'; }

load_env(){
  [[ -f "$POOLY_GUARD_ENV" ]] || return 0
  local owner mode group_w other_w
  owner="$(stat -c '%U' "$POOLY_GUARD_ENV" 2>/dev/null || echo unknown)"
  mode="$(stat -c '%a' "$POOLY_GUARD_ENV" 2>/dev/null || echo unknown)"
  if [[ "$owner" != "root" && "$owner" != "$REPORT_OWNER" ]]; then
    echo "FAIL: unsafe env owner for $POOLY_GUARD_ENV: $owner"
    return 1
  fi
  if [[ "$mode" =~ ^[0-7]+$ ]]; then
    group_w=$(( (8#$mode / 10) % 10 & 2 ))
    other_w=$(( 8#$mode % 10 & 2 ))
    if (( group_w || other_w )); then
      echo "FAIL: unsafe env permissions for $POOLY_GUARD_ENV: $mode"
      return 1
    fi
  fi
  # shellcheck source=/dev/null
  source "$POOLY_GUARD_ENV"
}

health_defaults(){
  : "${POOLY_ALERT_ON_WARN:=1}"
  : "${POOLY_DISK_WARN_PCT:=80}"
  : "${POOLY_DISK_FAIL_PCT:=90}"
  : "${POOLY_INODE_WARN_PCT:=80}"
  : "${POOLY_INODE_FAIL_PCT:=90}"
  : "${POOLY_RAM_WARN_PCT:=85}"
  : "${POOLY_RAM_FAIL_PCT:=95}"
  : "${POOLY_SWAP_WARN_PCT:=20}"
  : "${POOLY_SWAP_FAIL_PCT:=50}"
  : "${POOLY_LOAD_WARN_PER_CPU:=2}"
  : "${POOLY_LOAD_FAIL_PER_CPU:=4}"
  : "${POOLY_JOURNAL_WARN_MB:=5120}"
  : "${POOLY_JOURNAL_FAIL_MB:=10240}"
  : "${POOLY_JOURNAL_GROWTH_WARN_MB:=256}"
  : "${POOLY_JOURNAL_GROWTH_FAIL_MB:=512}"
  : "${POOLY_GPTLOGS_WARN_MB:=1024}"
  : "${POOLY_GPTLOGS_FAIL_MB:=2048}"
  : "${POOLY_LOCK_FILE:=/run/pooly-server-guard.lock}"
  : "${POOLY_LOCK_WAIT_SECONDS:=0}"
  : "${POOLY_REPORT_PRUNE_ENABLED:=1}"
  : "${POOLY_REPORT_RETENTION_DAYS:=14}"
  : "${POOLY_REPORT_MAX_FILES:=1000}"
  : "${POOLY_DISCORD_SUPPRESS_PASS:=1}"
  : "${POOLY_PRODUCTION_ONCALENDAR:=*:0/10}"
}

run_as_report_owner(){
  if [[ ${EUID:-$(id -u)} -eq 0 && -n "${REPORT_OWNER:-}" && "$REPORT_OWNER" != "root" ]]; then
    sudo -H -u "$REPORT_OWNER" "$@"
  else
    "$@"
  fi
}

mkdirs(){
  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    install -d -m 755 -o "$REPORT_OWNER" -g "$REPORT_OWNER" "$REPORT_DIR" 2>/dev/null || mkdir -p "$REPORT_DIR"
  else
    mkdir -p "$REPORT_DIR" 2>/dev/null || true
  fi
}

clear_self_failed_state(){
  if [[ ${EUID:-$(id -u)} -eq 0 ]] && command -v systemctl >/dev/null 2>&1; then
    systemctl reset-failed pooly-server-guard-watch.service 2>/dev/null || true
  fi
}

num_status(){ local value="$1" warn="$2" fail="$3"; awk -v v="$value" -v w="$warn" -v f="$fail" 'BEGIN{if(v>=f)print "FAIL"; else if(v>=w)print "WARN"; else print "PASS"}'; }
worst_mark(){ local new="$1"; case "$new" in FAIL) POOLY_WORST_STATUS="FAIL" ;; WARN) [[ "$POOLY_WORST_STATUS" != "FAIL" ]] && POOLY_WORST_STATUS="WARN" ;; esac; }
status_return(){ case "$1" in PASS) return 0 ;; WARN) return 2 ;; FAIL) return 1 ;; *) return 1 ;; esac; }

acquire_watch_lock(){
  section "POOLY SERVER GUARD LOCK"
  if ! command -v flock >/dev/null 2>&1; then echo "WARN: flock not found; overlap protection disabled"; echo "LOCK RESULT: WARN"; return 0; fi
  exec 9>"$POOLY_LOCK_FILE" || { echo "WARN: could not open lock file $POOLY_LOCK_FILE"; echo "LOCK RESULT: WARN"; return 0; }
  if [[ "${POOLY_LOCK_WAIT_SECONDS:-0}" =~ ^[0-9]+$ && "${POOLY_LOCK_WAIT_SECONDS:-0}" -gt 0 ]]; then
    if ! flock -w "$POOLY_LOCK_WAIT_SECONDS" 9; then echo "SKIP: another Pooly Server Guard watch run is still active after waiting ${POOLY_LOCK_WAIT_SECONDS}s"; echo "LOCK RESULT: SKIP"; echo "WATCH RESULT: SKIP_LOCKED"; return 75; fi
  else
    if ! flock -n 9; then echo "SKIP: another Pooly Server Guard watch run is already active"; echo "LOCK RESULT: SKIP"; echo "WATCH RESULT: SKIP_LOCKED"; return 75; fi
  fi
  echo "PASS: lock acquired at $POOLY_LOCK_FILE"
  return 0
}
