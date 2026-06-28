#!/usr/bin/env bash
set -uo pipefail

VERSION="0.5.0-alpha3.6"
POOLY_CORE_REF="68ae1124c5a10d68662a853fdbb75e83cbcf2470"
SSH_PORT="${SSH_PORT:-6200}"
ADMIN_USERS=("poolyadmin" "pooly-sil3ntvip3r-admin")
POOLY_STATE_DIR="${POOLY_STATE_DIR:-/etc/pooly/server-guard-state}"
POOLY_GUARD_ENV="${POOLY_GUARD_ENV:-/etc/pooly/server-guard.env}"
REPORT_OWNER="${REPORT_OWNER:-pooly-sil3ntvip3r-admin}"
REPORT_HOME="$(getent passwd "$REPORT_OWNER" 2>/dev/null | cut -d: -f6 || true)"
REPORT_DIR="${REPORT_DIR:-${REPORT_HOME:-$HOME}/GPTlogs}"
POOLY_REPO_DIR="${POOLY_REPO_DIR:-${REPORT_HOME:-$HOME}/GPTrepos/pooly-server-guard}"
POOLY_INSTALL_PATH="${POOLY_INSTALL_PATH:-${REPORT_HOME:-$HOME}/GPTlogs/pooly-server-guard.sh}"
POOLY_WATCH_ONCALENDAR="${POOLY_WATCH_ONCALENDAR:-*:0/10}"
SUDO=""
[[ ${EUID:-$(id -u)} -eq 0 ]] || SUDO="sudo"

ORIG_ARGS=("$@")
CORE_TMP="$(mktemp)"
cleanup_core(){ rm -f "$CORE_TMP"; }
trap cleanup_core EXIT
if ! git -C "$POOLY_REPO_DIR" show "$POOLY_CORE_REF:pooly-server-guard.sh" > "$CORE_TMP" 2>/dev/null; then
  echo "FAIL: could not load Pooly Server Guard core from repo ref $POOLY_CORE_REF"
  echo "Check repo path: $POOLY_REPO_DIR"
  exit 1
fi
set -- __pooly_source_only
# shellcheck source=/dev/null
source "$CORE_TMP" >/dev/null 2>&1 || true
set -- "${ORIG_ARGS[@]}"
VERSION="0.5.0-alpha3.6"

eval "$(declare -f health_defaults | sed '1s/health_defaults/pooly_core_health_defaults/')"
health_defaults(){
  pooly_core_health_defaults
  : "${POOLY_JOURNAL_GROWTH_WARN_MB:=256}"
  : "${POOLY_JOURNAL_GROWTH_FAIL_MB:=512}"
  : "${POOLY_PRODUCTION_ONCALENDAR:=*:0/10}"
}

timer_status(){
  section "POOLY TIMER STATUS"
  load_env; health_defaults
  local mode="CUSTOM"
  [[ "$POOLY_WATCH_ONCALENDAR" == "*:0/2" ]] && mode="TEST"
  [[ "$POOLY_WATCH_ONCALENDAR" == "$POOLY_PRODUCTION_ONCALENDAR" ]] && mode="PRODUCTION"
  echo "Active timer: $POOLY_WATCH_ONCALENDAR"
  echo "Recommended production timer: $POOLY_PRODUCTION_ONCALENDAR"
  echo "Timer mode: $mode"
  echo "TIMER RESULT: PASS"
}

journal_growth(){
  section "JOURNAL GROWTH"
  load_env; health_defaults
  local state_file="$POOLY_STATE_DIR/journal-size-mb.txt" current previous delta abs status sign
  current="$(du -sm /var/log/journal /run/log/journal 2>/dev/null | awk '{sum+=$1} END{print sum+0}')"
  current="${current:-0}"
  echo "Current journal size: ${current}M"
  if $SUDO test -f "$state_file" 2>/dev/null; then
    previous="$($SUDO cat "$state_file" 2>/dev/null | tail -1 | awk '{print $1+0}')"
  else
    previous=""
  fi
  if [[ -z "${previous:-}" ]]; then
    echo "Previous journal size: none"
    echo "JOURNAL GROWTH: baseline saved — PASS"
    status="PASS"
  else
    delta=$((current-previous)); abs=${delta#-}; sign="+"; [[ $delta -lt 0 ]] && sign="-"
    status="$(num_status "$abs" "$POOLY_JOURNAL_GROWTH_WARN_MB" "$POOLY_JOURNAL_GROWTH_FAIL_MB")"
    echo "Previous journal size: ${previous}M"
    echo "JOURNAL GROWTH: ${sign}${abs}M since last watch — $status"
  fi
  $SUDO install -d -m 700 "$POOLY_STATE_DIR" 2>/dev/null || true
  printf '%s\n' "$current" | $SUDO tee "$state_file" >/dev/null 2>&1 || echo "WARN: unable to save journal growth state"
  echo "JOURNAL GROWTH RESULT: $status"
  status_return "$status"
}

version_info(){
  load_env; health_defaults
  section "POOLY SERVER GUARD VERSION"
  echo "Installed script version: $VERSION"
  echo "Core script ref:          $POOLY_CORE_REF"
  echo "Configured install path:  $POOLY_INSTALL_PATH"
  echo "Configured repo path:     $POOLY_REPO_DIR"
  echo "Configured timer:         $POOLY_WATCH_ONCALENDAR"
  echo "Recommended production timer: $POOLY_PRODUCTION_ONCALENDAR"
  echo "Configured lock file:     $POOLY_LOCK_FILE"
  echo "Journal growth warn/fail: ${POOLY_JOURNAL_GROWTH_WARN_MB}/${POOLY_JOURNAL_GROWTH_FAIL_MB}M since last watch"
  echo "Report pruning:          ${POOLY_REPORT_PRUNE_ENABLED:-1}, ${POOLY_REPORT_RETENTION_DAYS:-14} day(s), max ${POOLY_REPORT_MAX_FILES:-1000} file(s)"
  echo "Memory diagnostics:      RAM >= ${POOLY_RAM_WARN_PCT:-85}% or swap >= ${POOLY_SWAP_WARN_PCT:-20}%"
  echo "Load diagnostics:        load/CPU >= ${POOLY_LOAD_WARN_PER_CPU:-2}"
  echo "Discord embeds:          enabled for watch alerts; suppress PASS=${POOLY_DISCORD_SUPPRESS_PASS:-1}"
  if [[ -d "$POOLY_REPO_DIR/.git" ]]; then
    run_as_report_owner git -C "$POOLY_REPO_DIR" rev-parse --short HEAD 2>/dev/null | awk '{print "Repo HEAD:              "$0}' || true
    [[ -f "$POOLY_REPO_DIR/VERSION" ]] && awk '{print "Repo VERSION:           "$0}' "$POOLY_REPO_DIR/VERSION" || true
  else
    echo "Repo state:             missing"
  fi
}

discord_watch_payload_file(){
  local status="${1:?missing status}" host="${2:?missing host}" node="${3:?missing node}" report="${4:?missing report}" tmp="${5:?missing tmp}" payload_file="${6:?missing payload file}"
  local iso_now; iso_now="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  STATUS="$status" HOST="$host" NODE="$node" REPORT="$report" TIMER="$POOLY_WATCH_ONCALENDAR" VERSION="$VERSION" ISO_NOW="$iso_now" SUPPRESS_PASS="${POOLY_DISCORD_SUPPRESS_PASS:-1}" python3 - "$tmp" > "$payload_file" <<'PY'
import json, os, re, sys, pathlib
lines = pathlib.Path(sys.argv[1]).read_text(errors='replace').splitlines()
status=os.environ.get('STATUS','PASS'); host=os.environ.get('HOST','unknown'); node=os.environ.get('NODE','unknown')
report=os.environ.get('REPORT',''); timer=os.environ.get('TIMER',''); version=os.environ.get('VERSION',''); iso_now=os.environ.get('ISO_NOW','')
suppress_pass=os.environ.get('SUPPRESS_PASS','1')=='1'
city={'001':'Toronto','002':'Mumbai','003':'Tokyo2','004':'Frankfurt'}.get(node,'')
def first(prefix): return next((x.strip() for x in lines if x.startswith(prefix)), '')
def result(label):
    s=first(label+':'); return s.split(':',1)[1].strip().split()[0] if s and ':' in s else '?'
def metric(prefix, kind):
    s=first(prefix); stat=s.rsplit('—',1)[1].strip() if '—' in s else '?'
    if kind in ('disk','ram','swap'):
        m=re.search(r':\s*([0-9]+%)',s); return f"{m.group(1) if m else '?'} {stat}"
    if kind=='load':
        m=re.search(r'=\s*([0-9.]+)\s+per CPU',s); return f"{m.group(1) if m else '?'} {stat}"
    if kind=='mb':
        m=re.search(r':\s*([0-9]+M)',s); return f"{m.group(1) if m else '?'} {stat}"
    return s
def metric_value(prefix, kind):
    s=first(prefix)
    if kind in ('disk','ram','swap'):
        m=re.search(r':\s*([0-9]+%)',s); return m.group(1) if m else '?'
    if kind=='load':
        m=re.search(r'=\s*([0-9.]+)\s+per CPU',s); return m.group(1) if m else '?'
    if kind=='mb':
        m=re.search(r':\s*([0-9]+M)',s); return m.group(1) if m else '?'
    return '?'
def jdelta_value():
    s=first('JOURNAL GROWTH:')
    m=re.search(r':\s*(.*?)(?:\s+since last watch)?\s+—',s)
    return (m.group(1).strip().replace('baseline saved','baseline') if m else '?')
def jdelta_full():
    s=first('JOURNAL GROWTH:')
    m=re.search(r':\s*(.*?)(?:\s+since last watch)?\s+—\s*(\w+)',s)
    return f"{m.group(1).strip().replace('baseline saved','baseline')} {m.group(2)}" if m else '?'
def health():
    return f"Disk {metric('DISK /:','disk')} | RAM {metric('RAM:','ram')} | Swap {metric('SWAP:','swap')} | Load/CPU {metric('LOAD:','load')}\nJournal {metric('JOURNAL SIZE:','mb')} | Δ {jdelta_full()} | Reports {metric('GPTLOGS SIZE:','mb')}"
def pass_health(): return f"Disk {metric_value('DISK /:','disk')} | RAM {metric_value('RAM:','ram')} | Load {metric_value('LOAD:','load')} | Logs {metric_value('JOURNAL SIZE:','mb')} | Δ {jdelta_value()}"
def checks(): return f"Security {result('RESULT')} | Baseline {result('BASELINE RESULT')} | Server {result('SERVER HEALTH RESULT')} | Services {result('SERVICE HEALTH RESULT')}\nTimer {result('TIMER RESULT')} | Journal Δ {result('JOURNAL GROWTH RESULT')} | Failed units {result('FAILED SERVICES RESULT')}"
def pass_checks():
    sv=result('SERVICE HEALTH RESULT'); failed=result('FAILED SERVICES RESULT'); jg=result('JOURNAL GROWTH RESULT')
    failed_units='0' if failed=='PASS' else failed
    overall='OK' if result('RESULT')=='PASS' and result('BASELINE RESULT')=='PASS' and result('SERVER HEALTH RESULT')=='PASS' and sv=='PASS' and failed=='PASS' and jg in ('PASS','?') else 'Review'
    return f"Checks {overall} | Services {'OK' if sv=='PASS' else sv} | Failed units {failed_units}"
def causes():
    out=[]
    for x in lines:
        if re.match(r'^(DISK /|DISK WORST|INODES /|RAM:|SWAP:|LOAD:|REBOOT REQUIRED:|JOURNAL SIZE:|JOURNAL GROWTH:|GPTLOGS SIZE:)',x) and ('— WARN' in x or '— FAIL' in x): out.append(x)
    for x in lines:
        if re.match(r'^(UPDATE RESULT|RESULT|BASELINE RESULT|SERVER HEALTH RESULT|TIMER RESULT|JOURNAL GROWTH RESULT|REPORT PRUNE RESULT|PORT RESULT|KEYS RESULT|SSHD DRIFT RESULT|UFW DRIFT RESULT|SERVICE RESULT|SERVICE HEALTH RESULT|FAILED SERVICES RESULT|WATCH RESULT):',x) and re.search(r':\s*(WARN|FAIL|SKIP|SKIP_LOCKED)',x): out.append(x)
    clean=[]
    for x in out:
        if x not in clean: clean.append(x)
    return '\n'.join(clean[:6]) or 'Open the full report for details.'
def first_after(marker):
    for i,x in enumerate(lines):
        if x.strip()==marker and i+2 < len(lines): return lines[i+2].strip()
    return ''
def gb(kb):
    try: return f"{float(kb)/1048576:.2f} GB"
    except Exception: return '? GB'
def proc(line,label):
    if not line: return ''
    p=line.split(None,9)
    if len(p)<9: return f"{label}: {line[:160]}"
    pid,ppid,user,comm,cpu,mem,rss,vsz,elapsed=p[:9]; args=p[9] if len(p)>9 else ''
    name=comm
    if args:
        a=args.split()[0]; name=a.rsplit('/',1)[-1] if '/' in a else a
    hint='\nHint: running with -reindex' if '-reindex' in args else ('\nHint: Miningcore/dotnet process' if ('Miningcore' in args or 'miningcore' in args or 'dotnet' in name) else '')
    return f"{label}: {name}\nCPU {cpu}% | MEM {mem}% | RSS {gb(rss)}{hint}"
def evidence():
    out=[]
    if any((x.startswith('RAM:') or x.startswith('SWAP:')) and ('— WARN' in x or '— FAIL' in x) for x in lines): out.append(proc(first_after('TOP MEMORY PROCESSES BY RSS'),'Top memory'))
    if any(x.startswith('LOAD:') and ('— WARN' in x or '— FAIL' in x) for x in lines): out.append(proc(first_after('TOP CPU PROCESSES'),'Top CPU'))
    return '\n\n'.join([x for x in out if x])
def action():
    c=causes()
    if re.search(r'^(DISK /|DISK WORST|JOURNAL SIZE:|JOURNAL GROWTH:|GPTLOGS SIZE:)',c,re.M): return 'Storage/logs crossed a threshold. Full details are in the report.'
    if re.search(r'^(RAM:|SWAP:)',c,re.M): return 'Memory pressure crossed a threshold. Full process details are in the report.'
    if re.search(r'^LOAD:',c,re.M): return 'CPU/load pressure crossed a threshold. Full process details are in the report.'
    if 'SERVICE HEALTH RESULT: FAIL' in c or 'FAILED SERVICES RESULT: FAIL' in c or 'SERVICE RESULT: FAIL' in c: return 'A Pooly/system service check failed. Review service health and failed units immediately.'
    if 'SSHD DRIFT RESULT: FAIL' in c or 'KEYS RESULT: FAIL' in c or 'UFW DRIFT RESULT: FAIL' in c or 'RESULT: FAIL' in c: return 'A security or access-control check failed. Review SSH, keys, sudo, and firewall drift immediately.'
    return 'Review the full report on the affected server.'
colors={'PASS':0x2ECC71,'WARN':0xF1C40F,'FAIL':0xE74C3C}; emoji={'PASS':'✅','WARN':'⚠️','FAIL':'🚨'}.get(status,'ℹ️')
title=f"{emoji} Node {node} {status}" + (f" — {city}" if city else '')
embed={'title':title,'description':f"Host: `{host}`\nVersion: `v{version}` | Timer: `{timer}`",'color':colors.get(status,0x95A5A6),'timestamp':iso_now,'fields':[],'footer':{'text':'Pooly Server Guard'}}
if status=='PASS': embed['fields'] += [{'name':'Health','value':pass_health(),'inline':False},{'name':'Checks','value':pass_checks(),'inline':False}]
else:
    embed['fields'] += [{'name':'Cause','value':causes()[:1024],'inline':False},{'name':'Health','value':health(),'inline':False}]
    ev=evidence()
    if ev: embed['fields'].append({'name':'Evidence','value':ev[:1024],'inline':False})
    embed['fields'].append({'name':'Action','value':action()[:1024],'inline':False})
    if report: embed['fields'].append({'name':'Report','value':report[-1024:],'inline':False})
payload={'embeds':[embed],'allowed_mentions':{'parse':[]}}
if status=='PASS' and suppress_pass: payload['flags']=4096
print(json.dumps(payload, ensure_ascii=False))
PY
}

guard_watch(){
  clear_self_failed_state; mkdirs; load_env; health_defaults
  local lock_rc=0
  acquire_watch_lock || lock_rc=$?
  if [[ "$lock_rc" == "75" ]]; then return 0; elif [[ "$lock_rc" != "0" ]]; then return "$lock_rc"; fi
  local tmp failed=0 warned=0 host node report update_rc=0 outcome="PASS"
  host="$(hostname)"; node="$(node_id)"; tmp="$(mktemp)"
  { echo "LOCK RESULT: PASS"; self_update || update_rc=$?; report_prune || true; timer_status || true; verify || true; baseline_verify || true; server_health || true; journal_growth || true; if memory_pressure_active; then memory_diagnostics || true; fi; if load_pressure_active; then load_diagnostics || true; fi; port_audit || true; keys_drift || true; sshd_drift || true; [[ "${POOLY_WATCH_WARN_UFW_DRIFT:-1}" == "1" ]] && ufw_drift || true; services_drift || true; service_health || true; failed_services_check || true; } | tee "$tmp"
  if [[ "$update_rc" != "0" ]] || grep -Eq 'UPDATE RESULT: FAIL|RESULT: FAIL|DRIFT RESULT: FAIL|PORT RESULT: FAIL|KEYS RESULT: FAIL|SERVICE RESULT: FAIL|SERVICE HEALTH RESULT: FAIL|FAILED SERVICES RESULT: FAIL|SERVER HEALTH RESULT: FAIL|JOURNAL GROWTH RESULT: FAIL|REPORT PRUNE RESULT: FAIL' "$tmp"; then failed=1; outcome="FAIL"; elif grep -Eq 'SERVER HEALTH RESULT: WARN|JOURNAL GROWTH RESULT: WARN|REPORT PRUNE RESULT: WARN|WARN:' "$tmp"; then warned=1; outcome="WARN"; fi
  echo "WATCH RESULT: $outcome" | tee -a "$tmp"
  report="$REPORT_DIR/pooly-server-guard-watch-$host-$(date -u +%Y%m%d-%H%M%S).txt"
  cp "$tmp" "$report"
  [[ ${EUID:-$(id -u)} -eq 0 ]] && chown "$REPORT_OWNER:$REPORT_OWNER" "$report" 2>/dev/null || true
  if [[ $failed -ne 0 ]]; then discord_send_watch FAIL "$host" "$node" "$report" "$tmp" | tee -a "$tmp" "$report" >/dev/null || true; rm -f "$tmp"; return 1; fi
  if [[ $warned -ne 0 ]]; then [[ "${POOLY_ALERT_ON_WARN:-1}" == "1" ]] && discord_send_watch WARN "$host" "$node" "$report" "$tmp" | tee -a "$tmp" "$report" >/dev/null || true; rm -f "$tmp"; return 0; fi
  [[ "${POOLY_ALERT_ON_PASS:-0}" == "1" ]] && discord_send_watch PASS "$host" "$node" "$report" "$tmp" | tee -a "$tmp" "$report" >/dev/null || true
  rm -f "$tmp"; return 0
}

health(){ version_info; section "POOLY HEALTH AUDIT"; echo "Host: $(hostname)"; echo "Node: $(node_id)"; echo "UTC:  $(date -u)"; timer_status || true; section "OS / KERNEL / UPTIME"; lsb_release -a 2>/dev/null || true; uname -a; uptime; section "DISK / INODES"; df -hT; echo; df -ih; section "MEMORY / SWAP"; free -h; swapon --show || true; server_health || true; journal_growth || true; report_prune || true; memory_diagnostics || true; load_diagnostics || true; failed_services_check || true; section "RUNNING POOLY SERVICES"; systemctl list-units --type=service --state=running --no-pager | egrep 'coin-|miningcore|nginx|redis|fail2ban|chrony|netdata|push-agent|pm2' || true; section "ALL POOLY SERVICES"; systemctl list-units --type=service --all --no-pager | egrep 'coin-|miningcore|nginx|redis|fail2ban|chrony|netdata|push-agent|pm2' || true; section "LISTENING PORTS"; ss -lntu || true; }
usage(){ cat <<HELP
Pooly Server Guard v$VERSION
Commands:
  verify | baseline-verify | health | save-report
  init-state | watch | self-update | server-health | report-prune | memory-diagnostics | load-diagnostics
  timer-status | journal-growth
  port-audit | keys-drift | sshd-drift | ufw-drift | services-drift | service-health | failed-services
  discord-test | install-watch-timer | uninstall-watch-timer
HELP
}
cmd="${1:-help}"
case "$cmd" in verify) verify ;; baseline-verify) baseline_verify ;; health) health ;; save-report) save_report ;; init-state) init_state ;; watch) guard_watch ;; self-update) self_update ;; server-health) server_health ;; report-prune) report_prune ;; memory-diagnostics) memory_diagnostics ;; load-diagnostics) load_diagnostics ;; timer-status) timer_status ;; journal-growth) journal_growth ;; port-audit) port_audit ;; keys-drift) keys_drift ;; sshd-drift) sshd_drift ;; ufw-drift) ufw_drift ;; services-drift) services_drift ;; service-health) service_health ;; failed-services) failed_services_check ;; discord-test) discord_test ;; install-watch-timer) install_timer ;; uninstall-watch-timer) uninstall_timer ;; help|-h|--help|*) usage ;; esac
