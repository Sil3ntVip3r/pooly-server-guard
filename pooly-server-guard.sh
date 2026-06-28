#!/usr/bin/env bash
set -uo pipefail

VERSION="0.5.0-alpha3.5.1"
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
load_env(){ [[ -f "$POOLY_GUARD_ENV" ]] && source "$POOLY_GUARD_ENV"; }
json_escape(){ python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'; }

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
  : "${POOLY_GPTLOGS_WARN_MB:=1024}"
  : "${POOLY_GPTLOGS_FAIL_MB:=2048}"
  : "${POOLY_LOCK_FILE:=/run/pooly-server-guard.lock}"
  : "${POOLY_LOCK_WAIT_SECONDS:=0}"
  : "${POOLY_REPORT_PRUNE_ENABLED:=1}"
  : "${POOLY_REPORT_RETENTION_DAYS:=14}"
  : "${POOLY_REPORT_MAX_FILES:=1000}"
  : "${POOLY_DISCORD_SUPPRESS_PASS:=1}"
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

acquire_watch_lock(){
  section "POOLY SERVER GUARD LOCK"
  if ! command -v flock >/dev/null 2>&1; then
    echo "WARN: flock not found; overlap protection disabled"
    echo "LOCK RESULT: WARN"
    return 0
  fi
  exec 9>"$POOLY_LOCK_FILE" || { echo "WARN: could not open lock file $POOLY_LOCK_FILE"; echo "LOCK RESULT: WARN"; return 0; }
  if [[ "${POOLY_LOCK_WAIT_SECONDS:-0}" =~ ^[0-9]+$ && "${POOLY_LOCK_WAIT_SECONDS:-0}" -gt 0 ]]; then
    if ! flock -w "$POOLY_LOCK_WAIT_SECONDS" 9; then
      echo "SKIP: another Pooly Server Guard watch run is still active after waiting ${POOLY_LOCK_WAIT_SECONDS}s"
      echo "LOCK RESULT: SKIP"
      echo "WATCH RESULT: SKIP_LOCKED"
      return 75
    fi
  else
    if ! flock -n 9; then
      echo "SKIP: another Pooly Server Guard watch run is already active"
      echo "LOCK RESULT: SKIP"
      echo "WATCH RESULT: SKIP_LOCKED"
      return 75
    fi
  fi
  echo "PASS: lock acquired at $POOLY_LOCK_FILE"
  return 0
}

report_file_find_expr(){
  find "$REPORT_DIR" -maxdepth 1 -xdev -type f \( -name 'pooly-server-guard-watch-*.txt' -o -name 'pooly-server-guard-*.txt' \)
}

report_prune_safe_dir(){
  [[ -n "${REPORT_DIR:-}" ]] || { echo "WARN: REPORT_DIR is empty"; return 1; }
  [[ "$REPORT_DIR" != "/" ]] || { echo "WARN: refusing to prune root directory"; return 1; }
  [[ "$REPORT_DIR" != "/home" ]] || { echo "WARN: refusing to prune /home"; return 1; }
  [[ "$REPORT_DIR" != "/root" ]] || { echo "WARN: refusing to prune /root"; return 1; }
  [[ -d "$REPORT_DIR" ]] || { echo "WARN: REPORT_DIR does not exist: $REPORT_DIR"; return 1; }
  [[ ! -L "$REPORT_DIR" ]] || { echo "WARN: refusing to prune symlink REPORT_DIR: $REPORT_DIR"; return 1; }
  return 0
}

report_prune(){
  section "POOLY REPORT PRUNE"
  load_env; health_defaults
  local before_count after_count before_mb after_mb deleted_age=0 deleted_count=0 excess count max retention entry f
  echo "Report dir: $REPORT_DIR"
  echo "Enabled: ${POOLY_REPORT_PRUNE_ENABLED:-1}"
  echo "Retention days: ${POOLY_REPORT_RETENTION_DAYS:-14}"
  echo "Max files: ${POOLY_REPORT_MAX_FILES:-1000}"
  if [[ "${POOLY_REPORT_PRUNE_ENABLED:-1}" != "1" ]]; then
    echo "SKIP: report pruning disabled"
    echo "REPORT PRUNE RESULT: PASS"
    return 0
  fi
  if ! report_prune_safe_dir; then
    echo "REPORT PRUNE RESULT: WARN"
    return 0
  fi
  before_count="$(report_file_find_expr 2>/dev/null | wc -l | awk '{print $1}')"
  before_mb="$(du -sm "$REPORT_DIR" 2>/dev/null | awk '{print $1+0}')"
  retention="${POOLY_REPORT_RETENTION_DAYS:-14}"
  if [[ "$retention" =~ ^[0-9]+$ && "$retention" -gt 0 ]]; then
    while IFS= read -r -d '' f; do
      if rm -f -- "$f"; then deleted_age=$((deleted_age+1)); fi
    done < <(find "$REPORT_DIR" -maxdepth 1 -xdev -type f \( -name 'pooly-server-guard-watch-*.txt' -o -name 'pooly-server-guard-*.txt' \) -mtime +"$retention" -print0 2>/dev/null)
  else
    echo "WARN: invalid POOLY_REPORT_RETENTION_DAYS=$retention; age pruning skipped"
  fi
  max="${POOLY_REPORT_MAX_FILES:-1000}"
  if [[ "$max" =~ ^[0-9]+$ && "$max" -gt 0 ]]; then
    count="$(report_file_find_expr 2>/dev/null | wc -l | awk '{print $1}')"
    if [[ "$count" -gt "$max" ]]; then
      excess=$((count-max))
      while IFS= read -r -d '' entry; do
        f="${entry#* }"
        if [[ -n "$f" && -f "$f" ]]; then
          if rm -f -- "$f"; then deleted_count=$((deleted_count+1)); fi
        fi
      done < <(find "$REPORT_DIR" -maxdepth 1 -xdev -type f \( -name 'pooly-server-guard-watch-*.txt' -o -name 'pooly-server-guard-*.txt' \) -printf '%T@ %p\0' 2>/dev/null | sort -z -n | head -z -n "$excess")
    fi
  else
    echo "WARN: invalid POOLY_REPORT_MAX_FILES=$max; count pruning skipped"
  fi
  after_count="$(report_file_find_expr 2>/dev/null | wc -l | awk '{print $1}')"
  after_mb="$(du -sm "$REPORT_DIR" 2>/dev/null | awk '{print $1+0}')"
  echo "Before: ${before_count} report file(s), ${before_mb}M GPTlogs"
  echo "Deleted by age: $deleted_age"
  echo "Deleted by count cap: $deleted_count"
  echo "After: ${after_count} report file(s), ${after_mb}M GPTlogs"
  echo "REPORT PRUNE RESULT: PASS"
  return 0
}

memory_pressure_active(){
  load_env; health_defaults
  local ram_pct swap_total swap_free swap_pct=0
  ram_pct="$(awk '/MemTotal:/{t=$2}/MemAvailable:/{a=$2} END{if(t>0) printf "%.0f", ((t-a)*100)/t; else print 0}' /proc/meminfo 2>/dev/null)"
  ram_pct="${ram_pct:-0}"
  if [[ "$ram_pct" =~ ^[0-9]+$ && "$ram_pct" -ge "${POOLY_RAM_WARN_PCT:-85}" ]]; then return 0; fi
  read -r swap_total swap_free < <(awk '/SwapTotal:/{t=$2}/SwapFree:/{f=$2} END{print t+0, f+0}' /proc/meminfo 2>/dev/null)
  if [[ "${swap_total:-0}" -gt 0 ]]; then
    swap_pct="$(awk -v t="$swap_total" -v f="$swap_free" 'BEGIN{printf "%.0f", ((t-f)*100)/t}')"
    if [[ "$swap_pct" =~ ^[0-9]+$ && "$swap_pct" -ge "${POOLY_SWAP_WARN_PCT:-20}" ]]; then return 0; fi
  fi
  return 1
}

load_pressure_active(){
  load_env; health_defaults
  local load1 cpus load_per_cpu
  load1="$(awk '{print $1}' /proc/loadavg 2>/dev/null)"
  cpus="$(nproc 2>/dev/null || echo 1)"
  load_per_cpu="$(awk -v l="${load1:-0}" -v c="${cpus:-1}" 'BEGIN{if(c>0) printf "%.2f", l/c; else print "0.00"}')"
  awk -v v="$load_per_cpu" -v w="${POOLY_LOAD_WARN_PER_CPU:-2}" 'BEGIN{exit (v>=w)?0:1}'
}

memory_diagnostics(){
  section "MEMORY PRESSURE DETAILS"
  echo "Reason: RAM or swap crossed a warning/fail threshold, so alpha3.5.1 captured process evidence."
  echo "Snapshot UTC: $(date -u)"
  echo; echo "FREE -H"; free -h || true
  echo; echo "MEMINFO SUMMARY"; awk '/MemTotal|MemFree|MemAvailable|Buffers|Cached|SwapCached|SwapTotal|SwapFree|Slab|SReclaimable|SUnreclaim|Committed_AS|CommitLimit/ {print}' /proc/meminfo 2>/dev/null || true
  echo; echo "TOP MEMORY PROCESSES BY RSS"; ps -eo pid,ppid,user,comm,%mem,%cpu,rss,vsz,etime,args --sort=-rss 2>/dev/null | head -25 || true
  echo; echo "TOP POOLY/COIN MEMORY PROCESSES"; ps -eo pid,ppid,user,comm,%mem,%cpu,rss,vsz,etime,args --sort=-rss 2>/dev/null | awk 'NR==1 || /\/opt\/pooly|Miningcore|coin-|buckd|ycashd|zerod|firod|ravend|bitcoinzd|neoxad|kerrigand|gemlink/ {print}' | head -30 || true
  echo; echo "KERNEL OOM CHECK - LAST 24 HOURS"; journalctl -k --since "24 hours ago" --no-pager 2>/dev/null | grep -Ei 'oom|out of memory|killed process|memory allocation|page allocation|segfault' | tail -40 || true
  echo; echo "MEMORY DIAGNOSTIC RESULT: PASS"
}

load_diagnostics(){
  section "LOAD PRESSURE DETAILS"
  local load1 load5 load15 cpus load_per_cpu
  read -r load1 load5 load15 _ < /proc/loadavg 2>/dev/null || true
  cpus="$(nproc 2>/dev/null || echo 1)"
  load_per_cpu="$(awk -v l="${load1:-0}" -v c="${cpus:-1}" 'BEGIN{if(c>0) printf "%.2f", l/c; else print "0.00"}')"
  echo "Reason: load per CPU crossed a warning/fail threshold, so alpha3.5.1 captured CPU/process evidence."
  echo "Snapshot UTC: $(date -u)"
  echo "Load averages: ${load1:-0} ${load5:-0} ${load15:-0}"
  echo "CPU cores: ${cpus:-1}"
  echo "Load per CPU: $load_per_cpu"
  echo; echo "UPTIME"; uptime || true
  echo; echo "TOP CPU PROCESSES"; ps -eo pid,ppid,user,comm,%cpu,%mem,rss,vsz,etime,args --sort=-%cpu 2>/dev/null | head -25 || true
  echo; echo "TOP POOLY/COIN CPU PROCESSES"; ps -eo pid,ppid,user,comm,%cpu,%mem,rss,vsz,etime,args --sort=-%cpu 2>/dev/null | awk 'NR==1 || /\/opt\/pooly|Miningcore|coin-|buckd|ycashd|zerod|firod|ravend|bitcoinzd|neoxad|kerrigand|gemlink|dotnet/ {print}' | head -30 || true
  echo; echo "LOAD DIAGNOSTIC RESULT: PASS"
}

discord_post(){
  load_env
  [[ "${POOLY_DISCORD_ENABLED:-0}" == "1" ]] || return 0
  [[ -n "${POOLY_DISCORD_WEBHOOK:-}" ]] || { echo "Missing POOLY_DISCORD_WEBHOOK in $POOLY_GUARD_ENV"; return 1; }
  local payload
  payload="{\"content\":$(printf '%s' "$1" | json_escape),\"allowed_mentions\":{\"parse\":[]}}"
  curl -fsS -H 'Content-Type: application/json' -d "$payload" "$POOLY_DISCORD_WEBHOOK" >/dev/null
}

discord_post_json_file(){
  local payload_file="${1:?missing payload file}"
  load_env
  [[ "${POOLY_DISCORD_ENABLED:-0}" == "1" ]] || { echo "DISCORD RESULT: SKIP_DISABLED"; return 0; }
  [[ -n "${POOLY_DISCORD_WEBHOOK:-}" ]] || { echo "DISCORD RESULT: FAIL_MISSING_WEBHOOK"; return 0; }
  command -v curl >/dev/null 2>&1 || { echo "DISCORD RESULT: FAIL_CURL_MISSING"; return 0; }
  local response_file http_code retry_after http_code2
  response_file="$(mktemp)"
  http_code="$(curl -sS -o "$response_file" -w '%{http_code}' -H 'Content-Type: application/json' -d @"$payload_file" "$POOLY_DISCORD_WEBHOOK" 2>/dev/null || echo curl_failed)"
  case "$http_code" in
    200|204) rm -f "$response_file"; echo "DISCORD RESULT: PASS"; return 0 ;;
    429)
      retry_after="$(python3 - "$response_file" <<'PY' 2>/dev/null || true
import json,sys
try:
    data=json.load(open(sys.argv[1])); val=float(data.get('retry_after',1)); print(max(0.1,min(val,10)))
except Exception:
    print(1)
PY
)"
      sleep "${retry_after:-1}"
      http_code2="$(curl -sS -o "$response_file" -w '%{http_code}' -H 'Content-Type: application/json' -d @"$payload_file" "$POOLY_DISCORD_WEBHOOK" 2>/dev/null || echo curl_failed)"
      rm -f "$response_file"
      case "$http_code2" in 200|204) echo "DISCORD RESULT: PASS_AFTER_429_RETRY" ;; *) echo "DISCORD RESULT: FAIL_HTTP_${http_code2}_AFTER_429" ;; esac
      return 0 ;;
    404) rm -f "$response_file"; echo "DISCORD RESULT: FAIL_INVALID_WEBHOOK_404"; return 0 ;;
    curl_failed) rm -f "$response_file"; echo "DISCORD RESULT: FAIL_CURL"; return 0 ;;
    *) rm -f "$response_file"; echo "DISCORD RESULT: FAIL_HTTP_${http_code}"; return 0 ;;
  esac
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

def first(prefix):
    return next((x.strip() for x in lines if x.startswith(prefix)), '')
def result(label):
    s=first(label+':')
    return s.split(':',1)[1].strip().split()[0] if s and ':' in s else '?'
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
def health():
    return f"Disk {metric('DISK /:','disk')} | RAM {metric('RAM:','ram')} | Swap {metric('SWAP:','swap')} | Load/CPU {metric('LOAD:','load')}\nJournal {metric('JOURNAL SIZE:','mb')} | Reports {metric('GPTLOGS SIZE:','mb')}"
def pass_health():
    return f"Disk {metric_value('DISK /:','disk')} | RAM {metric_value('RAM:','ram')} | Load {metric_value('LOAD:','load')} | Logs {metric_value('JOURNAL SIZE:','mb')}"
def checks():
    return f"Security {result('RESULT')} | Baseline {result('BASELINE RESULT')} | Server {result('SERVER HEALTH RESULT')} | Services {result('SERVICE HEALTH RESULT')}\nPort {result('PORT RESULT')} | Keys {result('KEYS RESULT')} | SSHD {result('SSHD DRIFT RESULT')} | UFW {result('UFW DRIFT RESULT')} | Failed units {result('FAILED SERVICES RESULT')}"
def pass_checks():
    sv=result('SERVICE HEALTH RESULT'); failed=result('FAILED SERVICES RESULT')
    failed_units='0' if failed=='PASS' else failed
    overall='OK' if result('RESULT')=='PASS' and result('BASELINE RESULT')=='PASS' and result('SERVER HEALTH RESULT')=='PASS' and sv=='PASS' and failed=='PASS' else 'Review'
    services='OK' if sv=='PASS' else sv
    return f"Checks {overall} | Services {services} | Failed units {failed_units}"
def causes():
    out=[]
    for x in lines:
        if re.match(r'^(DISK /|DISK WORST|INODES /|RAM:|SWAP:|LOAD:|REBOOT REQUIRED:|JOURNAL SIZE:|GPTLOGS SIZE:)',x) and ('— WARN' in x or '— FAIL' in x): out.append(x)
    for x in lines:
        if re.match(r'^(UPDATE RESULT|RESULT|BASELINE RESULT|SERVER HEALTH RESULT|REPORT PRUNE RESULT|PORT RESULT|KEYS RESULT|SSHD DRIFT RESULT|UFW DRIFT RESULT|SERVICE RESULT|SERVICE HEALTH RESULT|FAILED SERVICES RESULT|WATCH RESULT):',x) and re.search(r':\s*(WARN|FAIL|SKIP|SKIP_LOCKED)',x): out.append(x)
    clean=[]
    for x in out:
        if x not in clean: clean.append(x)
    return '\n'.join(clean[:5]) or 'Open the full report for details.'
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
    if re.search(r'^(DISK /|DISK WORST|JOURNAL SIZE:|GPTLOGS SIZE:)',c,re.M): return 'Storage/logs crossed a threshold. Full details are in the report.'
    if re.search(r'^(RAM:|SWAP:)',c,re.M): return 'Memory pressure crossed a threshold. Full process details are in the report.'
    if re.search(r'^LOAD:',c,re.M): return 'CPU/load pressure crossed a threshold. Full process details are in the report.'
    if 'SERVICE HEALTH RESULT: FAIL' in c or 'FAILED SERVICES RESULT: FAIL' in c or 'SERVICE RESULT: FAIL' in c: return 'A Pooly/system service check failed. Review service health and failed units immediately.'
    if 'SSHD DRIFT RESULT: FAIL' in c or 'KEYS RESULT: FAIL' in c or 'UFW DRIFT RESULT: FAIL' in c or 'RESULT: FAIL' in c: return 'A security or access-control check failed. Review SSH, keys, sudo, and firewall drift immediately.'
    return 'Review the full report on the affected server.'
colors={'PASS':0x2ECC71,'WARN':0xF1C40F,'FAIL':0xE74C3C}; emoji={'PASS':'✅','WARN':'⚠️','FAIL':'🚨'}.get(status,'ℹ️')
title=f"{emoji} Node {node} {status}" + (f" — {city}" if city else '')
embed={'title':title,'description':f"Host: `{host}`\nVersion: `v{version}` | Timer: `{timer}`",'color':colors.get(status,0x95A5A6),'timestamp':iso_now,'fields':[],'footer':{'text':'Pooly Server Guard'}}
if status=='PASS':
    embed['fields'] += [{'name':'Health','value':pass_health(),'inline':False},{'name':'Checks','value':pass_checks(),'inline':False}]
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

discord_send_watch(){
  local status="${1:?missing status}" host="${2:?missing host}" node="${3:?missing node}" report="${4:?missing report}" tmp="${5:?missing tmp}" payload_file
  payload_file="$(mktemp)"
  if discord_watch_payload_file "$status" "$host" "$node" "$report" "$tmp" "$payload_file"; then
    discord_post_json_file "$payload_file"
  else
    echo "DISCORD RESULT: FAIL_PAYLOAD"
  fi
  rm -f "$payload_file"
}

node_id(){
  local h ip
  h="$(hostname 2>/dev/null || true)"
  ip="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+\.' | head -1 || true)"
  case "$h $ip" in
    *001*toronto*|*104.225.219.167*) echo 001 ;;
    *002*mumbai*|*209.182.232.151*) echo 002 ;;
    *003*tokyo2*|*63.250.52.172*) echo 003 ;;
    *004*frankfurt*|*208.87.129.34*) echo 004 ;;
    *) echo unknown ;;
  esac
}

num_status(){ local value="$1" warn="$2" fail="$3"; awk -v v="$value" -v w="$warn" -v f="$fail" 'BEGIN{if(v>=f)print "FAIL"; else if(v>=w)print "WARN"; else print "PASS"}'; }
worst_mark(){ local new="$1"; case "$new" in FAIL) POOLY_WORST_STATUS="FAIL" ;; WARN) [[ "$POOLY_WORST_STATUS" != "FAIL" ]] && POOLY_WORST_STATUS="WARN" ;; esac; }
status_return(){ case "$1" in PASS) return 0 ;; WARN) return 2 ;; FAIL) return 1 ;; *) return 1 ;; esac; }
current_ports(){ ss -H -lntu 2>/dev/null | awk '{print $5}' | sed -E 's/.*:([0-9]+)$/\1/' | sort -n | uniq; }
current_services(){ systemctl list-units --type=service --state=running --no-legend 2>/dev/null | awk '{print $1}' | grep -E '^(coin-|miningcore|nginx|redis-server|fail2ban|chrony|netdata|push-agent|pm2-|systemd-journald@netdata)' | sort -u || true; }
pooly_units_all(){ systemctl list-units --type=service --all --no-legend 2>/dev/null | awk '{print $1}' | grep -E '^(coin-|miningcore|pm2-|nginx|redis-server|fail2ban|chrony|netdata|push-agent|systemd-journald@netdata)' | sort -u || true; }
baseline_services(){ $SUDO cat "$POOLY_STATE_DIR/services.txt" 2>/dev/null | sort -u || true; }
sshd_policy(){ $SUDO sshd -T 2>/dev/null | egrep '^(port|permitrootlogin|pubkeyauthentication|passwordauthentication|kbdinteractiveauthentication|allowusers|maxauthtries|maxsessions|maxstartups) ' | sort; }
ufw_rules(){ $SUDO ufw status numbered 2>/dev/null | sed 's/[[:space:]]\+$//' || true; }

key_fingerprints(){
  for u in "${ADMIN_USERS[@]}" root; do
    local home file
    [[ "$u" == root ]] && home=/root || home="$(getent passwd "$u" | cut -d: -f6)"
    file="$home/.ssh/authorized_keys"
    echo "[$u]"
    if $SUDO test -f "$file"; then
      $SUDO awk 'NF && $1 !~ /^#/' "$file" | while read -r line; do printf '%s\n' "$line" | ssh-keygen -lf - 2>/dev/null || echo "BAD_KEY_LINE"; done
    else
      echo "NO_FILE"
    fi
  done
}

version_info(){
  load_env; health_defaults
  section "POOLY SERVER GUARD VERSION"
  echo "Installed script version: $VERSION"
  echo "Configured install path:  $POOLY_INSTALL_PATH"
  echo "Configured repo path:     $POOLY_REPO_DIR"
  echo "Configured timer:         $POOLY_WATCH_ONCALENDAR"
  echo "Configured lock file:     $POOLY_LOCK_FILE"
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

self_update(){
  section "POOLY SERVER GUARD UPDATE CHECK"
  load_env; health_defaults
  echo "Running version: $VERSION"
  echo "Auto update: ${POOLY_GUARD_AUTO_UPDATE:-1}"
  echo "Repo dir: $POOLY_REPO_DIR"
  echo "Install path: $POOLY_INSTALL_PATH"
  echo "Git user: ${REPORT_OWNER:-$(id -un)}"
  if [[ "${POOLY_GUARD_AUTO_UPDATE:-1}" != "1" ]]; then echo "SKIP: auto update disabled"; echo "UPDATE RESULT: PASS"; return 0; fi
  if ! command -v git >/dev/null 2>&1; then echo "FAIL: git is not installed"; echo "UPDATE RESULT: FAIL"; return 1; fi
  if [[ ! -d "$POOLY_REPO_DIR/.git" ]]; then echo "FAIL: repo missing at $POOLY_REPO_DIR"; echo "UPDATE RESULT: FAIL"; return 1; fi
  local branch remote_ref before after repo_version installed_changed=0
  branch="${POOLY_GUARD_AUTO_UPDATE_BRANCH:-main}"; remote_ref="origin/$branch"
  before="$(run_as_report_owner git -C "$POOLY_REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  echo "Local repo before: $before"
  if ! run_as_report_owner git -C "$POOLY_REPO_DIR" fetch --quiet --all --prune; then echo "FAIL: git fetch failed"; echo "UPDATE RESULT: FAIL"; return 1; fi
  if ! run_as_report_owner git -C "$POOLY_REPO_DIR" reset --hard "$remote_ref" >/dev/null; then echo "FAIL: git reset to $remote_ref failed"; echo "UPDATE RESULT: FAIL"; return 1; fi
  after="$(run_as_report_owner git -C "$POOLY_REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  repo_version="$(cat "$POOLY_REPO_DIR/VERSION" 2>/dev/null || echo unknown)"
  echo "Local repo after:  $after"
  echo "Latest repo version: $repo_version"
  if [[ ! -x "$POOLY_INSTALL_PATH" ]] || ! cmp -s "$POOLY_REPO_DIR/pooly-server-guard.sh" "$POOLY_INSTALL_PATH"; then
    need_sudo
    $SUDO install -m 755 "$POOLY_REPO_DIR/pooly-server-guard.sh" "$POOLY_INSTALL_PATH"
    [[ ${EUID:-$(id -u)} -eq 0 ]] && chown "$REPORT_OWNER:$REPORT_OWNER" "$POOLY_INSTALL_PATH" 2>/dev/null || true
    installed_changed=1
    echo "UPDATED: installed script refreshed from repo"
  else
    echo "PASS: installed script already matches repo"
  fi
  if [[ "$repo_version" != "$VERSION" ]]; then echo "INFO: this running process is v$VERSION; installed script is now repo v$repo_version"; echo "INFO: the next timer/manual run will execute the updated script."; fi
  [[ "$installed_changed" == "1" ]] && echo "UPDATE ACTION: INSTALLED" || echo "UPDATE ACTION: NONE"
  echo "UPDATE RESULT: PASS"; return 0
}

verify(){
  section "POOLY SERVER GUARD VERIFY"
  local failed=0 ports sshdT root_count groups u
  ports="$(sshd_policy | awk '$1=="port"{print $2}' | xargs echo)"; sshdT="$(sshd_policy)"
  echo "SSH ports: $ports"
  [[ "$ports" == "$SSH_PORT" ]] && echo "PASS: SSH effective port is $SSH_PORT only" || { echo "FAIL: SSH effective port is not $SSH_PORT only"; failed=1; }
  ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Eq ':(22)$' && { echo "FAIL: sshd port 22 listener found"; failed=1; } || echo "PASS: no sshd port 22 listener found"
  ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Eq ":${SSH_PORT}$" && echo "PASS: sshd port $SSH_PORT listener found" || { echo "FAIL: sshd port $SSH_PORT listener missing"; failed=1; }
  awk '$1=="permitrootlogin" && $2=="no"{found=1} END{exit found ? 0 : 1}' <<< "$sshdT" && echo "PASS: root SSH disabled" || { echo "FAIL: root SSH not disabled"; failed=1; }
  awk '$1=="passwordauthentication" && $2=="no"{found=1} END{exit found ? 0 : 1}' <<< "$sshdT" && echo "PASS: password SSH disabled" || { echo "FAIL: password SSH not disabled"; failed=1; }
  awk '$1=="kbdinteractiveauthentication" && $2=="no"{found=1} END{exit found ? 0 : 1}' <<< "$sshdT" && echo "PASS: keyboard-interactive SSH disabled" || { echo "FAIL: keyboard-interactive SSH not disabled"; failed=1; }
  for u in "${ADMIN_USERS[@]}"; do awk -v user="$u" '$1=="allowusers"{for(i=2;i<=NF;i++) if($i==user) found=1} END{exit found ? 0 : 1}' <<< "$sshdT" && echo "PASS: $u allowed" || { echo "FAIL: $u missing from AllowUsers"; failed=1; }; done
  root_count="$($SUDO sh -c 'test -f /root/.ssh/authorized_keys && awk "NF && \$1 !~ /^#/" /root/.ssh/authorized_keys | wc -l || echo 0' 2>/dev/null | tail -1)"
  [[ "$root_count" == "0" ]] && echo "PASS: root authorized_keys empty" || { echo "FAIL: root authorized_keys has $root_count active key(s)"; failed=1; }
  for u in "${ADMIN_USERS[@]}"; do groups="$(id -nG "$u" 2>/dev/null || true)"; [[ " $groups " == *" sudo "* ]] && echo "PASS: $u in sudo" || { echo "FAIL: $u not in sudo"; failed=1; }; done
  $SUDO grep -RIs 'NOPASSWD' /etc/sudoers /etc/sudoers.d 2>/dev/null | grep -vE '^#|pooly-security-backups' >/dev/null && { echo "FAIL: active NOPASSWD sudo rule found"; failed=1; } || echo "PASS: no active NOPASSWD sudo rules"
  systemctl is-active --quiet fail2ban && echo "PASS: Fail2Ban active" || { echo "FAIL: Fail2Ban inactive"; failed=1; }
  echo; [[ $failed -eq 0 ]] && echo "RESULT: PASS" || echo "RESULT: FAIL"; return "$failed"
}

baseline_verify(){
  section "POOLY BASELINE VERIFY"
  local failed=0 swapgb filemax swappiness qdisc cc
  grep -q '22.04' /etc/os-release && echo "PASS: Ubuntu 22.04" || { echo "FAIL: not Ubuntu 22.04"; failed=1; }
  swapgb=$(free -g | awk '/Swap:/{print $2}'); [[ "${swapgb:-0}" -ge 19 ]] && echo "PASS: swap >= 20G" || { echo "FAIL: swap < 20G"; failed=1; }
  filemax=$(sysctl -n fs.file-max 2>/dev/null || echo 0); [[ "$filemax" -ge 4194304 ]] && echo "PASS: fs.file-max >= 4194304" || { echo "FAIL: fs.file-max too low"; failed=1; }
  swappiness=$(sysctl -n vm.swappiness 2>/dev/null || echo x); [[ "$swappiness" == 10 ]] && echo "PASS: vm.swappiness=10" || { echo "FAIL: vm.swappiness != 10"; failed=1; }
  cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true); [[ "$cc" == bbr ]] && echo "PASS: TCP BBR" || { echo "FAIL: TCP BBR not active"; failed=1; }
  qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || true); [[ "$qdisc" == fq ]] && echo "PASS: fq qdisc" || { echo "FAIL: fq qdisc not active"; failed=1; }
  systemctl is-active --quiet chrony && echo "PASS: chrony active" || { echo "FAIL: chrony inactive"; failed=1; }
  command -v wg >/dev/null && echo "PASS: wireguard tools present" || { echo "FAIL: wireguard tools missing"; failed=1; }
  command -v tcpdump >/dev/null && echo "PASS: tcpdump present" || { echo "FAIL: tcpdump missing"; failed=1; }
  echo; [[ $failed -eq 0 ]] && echo "BASELINE RESULT: PASS" || echo "BASELINE RESULT: FAIL"; return "$failed"
}

server_health(){
  section "POOLY SERVER HEALTH"
  load_env; health_defaults; POOLY_WORST_STATUS="PASS"
  local pct status worst_pct worst_mount ram_pct swap_pct swap_total swap_free load1 cpus load_per_cpu journal_mb gptlogs_mb uptime_seconds uptime_days
  echo "Thresholds: disk ${POOLY_DISK_WARN_PCT}/${POOLY_DISK_FAIL_PCT}% warn/fail, RAM ${POOLY_RAM_WARN_PCT}/${POOLY_RAM_FAIL_PCT}%, load per CPU ${POOLY_LOAD_WARN_PER_CPU}/${POOLY_LOAD_FAIL_PER_CPU}"
  pct="$(df -P / 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5}')"; pct="${pct:-0}"; status="$(num_status "$pct" "$POOLY_DISK_WARN_PCT" "$POOLY_DISK_FAIL_PCT")"; worst_mark "$status"; echo "DISK /: ${pct}% used — $status"
  read -r worst_pct worst_mount < <(df -P -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null | awk 'NR>1{gsub("%","",$5); if($5+0>max){max=$5+0; mount=$6}} END{print max+0, mount}')
  if [[ -n "${worst_mount:-}" && "$worst_mount" != "/" ]]; then status="$(num_status "$worst_pct" "$POOLY_DISK_WARN_PCT" "$POOLY_DISK_FAIL_PCT")"; worst_mark "$status"; echo "DISK WORST: ${worst_mount} ${worst_pct}% used — $status"; fi
  pct="$(df -Pi / 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5}')"; pct="${pct:-0}"; status="$(num_status "$pct" "$POOLY_INODE_WARN_PCT" "$POOLY_INODE_FAIL_PCT")"; worst_mark "$status"; echo "INODES /: ${pct}% used — $status"
  ram_pct="$(awk '/MemTotal:/{t=$2}/MemAvailable:/{a=$2} END{if(t>0) printf "%.0f", ((t-a)*100)/t; else print 0}' /proc/meminfo 2>/dev/null)"; ram_pct="${ram_pct:-0}"; status="$(num_status "$ram_pct" "$POOLY_RAM_WARN_PCT" "$POOLY_RAM_FAIL_PCT")"; worst_mark "$status"; echo "RAM: ${ram_pct}% pressure — $status"
  read -r swap_total swap_free < <(awk '/SwapTotal:/{t=$2}/SwapFree:/{f=$2} END{print t+0, f+0}' /proc/meminfo 2>/dev/null)
  if [[ "${swap_total:-0}" -gt 0 ]]; then swap_pct="$(awk -v t="$swap_total" -v f="$swap_free" 'BEGIN{printf "%.0f", ((t-f)*100)/t}')"; status="$(num_status "$swap_pct" "$POOLY_SWAP_WARN_PCT" "$POOLY_SWAP_FAIL_PCT")"; worst_mark "$status"; echo "SWAP: ${swap_pct}% used — $status"; else echo "SWAP: not configured — PASS"; fi
  load1="$(awk '{print $1}' /proc/loadavg 2>/dev/null)"; cpus="$(nproc 2>/dev/null || echo 1)"; load_per_cpu="$(awk -v l="${load1:-0}" -v c="${cpus:-1}" 'BEGIN{if(c>0) printf "%.2f", l/c; else print "0.00"}')"; status="$(num_status "$load_per_cpu" "$POOLY_LOAD_WARN_PER_CPU" "$POOLY_LOAD_FAIL_PER_CPU")"; worst_mark "$status"; echo "LOAD: ${load1:-0} on ${cpus:-1} CPU cores = ${load_per_cpu} per CPU — $status"
  uptime_seconds="$(awk '{printf "%.0f", $1}' /proc/uptime 2>/dev/null || echo 0)"; uptime_days="$(( ${uptime_seconds:-0} / 86400 ))"; echo "UPTIME: ${uptime_days} day(s) — PASS"
  if [[ -f /var/run/reboot-required ]]; then worst_mark "WARN"; echo "REBOOT REQUIRED: yes — WARN"; else echo "REBOOT REQUIRED: no — PASS"; fi
  journal_mb="$(du -sm /var/log/journal /run/log/journal 2>/dev/null | awk '{sum+=$1} END{print sum+0}')"; status="$(num_status "$journal_mb" "$POOLY_JOURNAL_WARN_MB" "$POOLY_JOURNAL_FAIL_MB")"; worst_mark "$status"; echo "JOURNAL SIZE: ${journal_mb}M — $status"
  [[ -d "$REPORT_DIR" ]] && gptlogs_mb="$(du -sm "$REPORT_DIR" 2>/dev/null | awk '{print $1+0}')" || gptlogs_mb=0; status="$(num_status "$gptlogs_mb" "$POOLY_GPTLOGS_WARN_MB" "$POOLY_GPTLOGS_FAIL_MB")"; worst_mark "$status"; echo "GPTLOGS SIZE: ${gptlogs_mb}M — $status"
  echo; echo "SERVER HEALTH RESULT: $POOLY_WORST_STATUS"; status_return "$POOLY_WORST_STATUS"
}

failed_services_check(){ section "FAILED SERVICES"; clear_self_failed_state; local out; out="$(systemctl --failed --no-pager 2>/dev/null || true)"; printf '%s\n' "$out"; if printf '%s\n' "$out" | grep -Eq '^●[[:space:]]+'; then echo "FAILED SERVICES RESULT: FAIL"; return 1; fi; echo "FAILED SERVICES RESULT: PASS"; return 0; }
health(){ version_info; section "POOLY HEALTH AUDIT"; echo "Host: $(hostname)"; echo "Node: $(node_id)"; echo "UTC:  $(date -u)"; section "OS / KERNEL / UPTIME"; lsb_release -a 2>/dev/null || true; uname -a; uptime; section "DISK / INODES"; df -hT; echo; df -ih; section "MEMORY / SWAP"; free -h; swapon --show || true; server_health || true; report_prune || true; memory_diagnostics || true; load_diagnostics || true; failed_services_check || true; section "RUNNING POOLY SERVICES"; systemctl list-units --type=service --state=running --no-pager | egrep 'coin-|miningcore|nginx|redis|fail2ban|chrony|netdata|push-agent|pm2' || true; section "ALL POOLY SERVICES"; systemctl list-units --type=service --all --no-pager | egrep 'coin-|miningcore|nginx|redis|fail2ban|chrony|netdata|push-agent|pm2' || true; section "LISTENING PORTS"; ss -lntu || true; }
init_state(){ need_sudo; $SUDO install -d -m 700 "$POOLY_STATE_DIR"; current_ports | $SUDO tee "$POOLY_STATE_DIR/ports.txt" >/dev/null; key_fingerprints | $SUDO tee "$POOLY_STATE_DIR/keys.txt" >/dev/null; sshd_policy | $SUDO tee "$POOLY_STATE_DIR/sshd.txt" >/dev/null; ufw_rules | $SUDO tee "$POOLY_STATE_DIR/ufw.txt" >/dev/null; current_services | $SUDO tee "$POOLY_STATE_DIR/services.txt" >/dev/null; echo "$VERSION" | $SUDO tee "$POOLY_STATE_DIR/guard-version.txt" >/dev/null; echo "Saved known-good state in $POOLY_STATE_DIR"; }
diff_state(){ local state_name state_cmd state_file tmp rc; state_name="${1:?missing state name}"; state_cmd="${2:?missing state command}"; state_file="$POOLY_STATE_DIR/$state_name.txt"; tmp="$(mktemp)"; $state_cmd > "$tmp"; if ! $SUDO test -f "$state_file"; then echo "WARN: missing baseline $state_file; run init-state"; return 2; fi; diff -u <($SUDO cat "$state_file") "$tmp"; rc=$?; return "$rc"; }
port_audit(){ section "PORT AUDIT"; local failed=0; echo "INFO: Miningcore and coin daemon ports can open and close quickly. Static port drift is informational unless strict mode is enabled."; if ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Eq ':(22)$'; then echo "FAIL: port 22 listener found"; failed=1; fi; if [[ "$POOLY_PORT_STRICT_BASELINE" == "1" ]]; then diff_state ports current_ports && echo "STATIC PORT RESULT: PASS" || { echo "STATIC PORT RESULT: FAIL"; failed=1; }; else if ! diff_state ports current_ports; then echo "INFO: dynamic port drift detected but not failing."; else echo "STATIC PORT RESULT: PASS"; fi; fi; [[ $failed -eq 0 ]] && { echo "PORT RESULT: PASS"; return 0; } || { echo "PORT RESULT: FAIL"; return 1; }; }
keys_drift(){ section "AUTHORIZED_KEYS DRIFT"; diff_state keys key_fingerprints && echo "KEYS RESULT: PASS" || { echo "KEYS RESULT: FAIL"; return 1; }; }
sshd_drift(){ section "SSHD POLICY DRIFT"; diff_state sshd sshd_policy && echo "SSHD DRIFT RESULT: PASS" || { echo "SSHD DRIFT RESULT: FAIL"; return 1; }; }
ufw_drift(){ section "UFW DRIFT"; diff_state ufw ufw_rules && echo "UFW DRIFT RESULT: PASS" || { echo "UFW DRIFT RESULT: FAIL"; return 1; }; }
services_drift(){ section "POOLY SERVICE DRIFT"; diff_state services current_services && echo "SERVICE RESULT: PASS" || { echo "SERVICE RESULT: FAIL"; return 1; }; }
service_health(){ section "POOLY SERVICE HEALTH"; local failed=0 svc active sub result nrestarts status units; units="$( { pooly_units_all; baseline_services; } | sort -u )"; if [[ -z "$units" ]]; then echo "WARN: no Pooly services found to check"; echo "SERVICE HEALTH RESULT: FAIL"; return 1; fi; while read -r svc; do [[ -n "$svc" ]] || continue; active="$(systemctl show "$svc" -p ActiveState --value 2>/dev/null || echo unknown)"; sub="$(systemctl show "$svc" -p SubState --value 2>/dev/null || echo unknown)"; result="$(systemctl show "$svc" -p Result --value 2>/dev/null || echo unknown)"; nrestarts="$(systemctl show "$svc" -p NRestarts --value 2>/dev/null || echo 0)"; status="$(systemctl show "$svc" -p ExecMainStatus --value 2>/dev/null || echo 0)"; printf '%-38s ActiveState=%s SubState=%s Result=%s NRestarts=%s ExecMainStatus=%s\n' "$svc" "$active" "$sub" "$result" "$nrestarts" "$status"; if [[ "$active" != "active" ]]; then failed=1; echo "FAIL: $svc ActiveState is $active"; fi; if [[ "$sub" == "auto-restart" || "$sub" == "failed" ]]; then failed=1; echo "FAIL: $svc SubState is $sub"; fi; if [[ "$result" == "exit-code" || "$result" == "signal" || "$result" == "core-dump" || "$result" == "timeout" ]]; then failed=1; echo "FAIL: $svc Result is $result"; fi; if [[ "$status" != "0" ]]; then failed=1; echo "FAIL: $svc ExecMainStatus is $status"; fi; done <<< "$units"; [[ $failed -eq 0 ]] && { echo "SERVICE HEALTH RESULT: PASS"; return 0; } || { echo "SERVICE HEALTH RESULT: FAIL"; return 1; }; }
watch_results_summary(){ local file="${1:?missing report tmp}"; grep -E '^(LOCK RESULT|UPDATE RESULT|RESULT|BASELINE RESULT|SERVER HEALTH RESULT|REPORT PRUNE RESULT|MEMORY DIAGNOSTIC RESULT|LOAD DIAGNOSTIC RESULT|PORT RESULT|KEYS RESULT|SSHD DRIFT RESULT|UFW DRIFT RESULT|SERVICE RESULT|SERVICE HEALTH RESULT|FAILED SERVICES RESULT|DISCORD RESULT|WATCH RESULT):' "$file" | sed 's/^/- /' | head -24; }
watch_health_summary(){ local file="${1:?missing report tmp}"; grep -E '^(DISK /|DISK WORST|INODES /|RAM:|SWAP:|LOAD:|UPTIME:|REBOOT REQUIRED:|JOURNAL SIZE:|GPTLOGS SIZE:)' "$file" | sed 's/^/- /' | head -12 || true; }
watch_issue_summary(){ local file="${1:?missing report tmp}"; { grep -E '^(DISK /|DISK WORST|INODES /|RAM:|SWAP:|LOAD:|REBOOT REQUIRED:|JOURNAL SIZE:|GPTLOGS SIZE:).*(— WARN|— FAIL)' "$file" | sed 's/^/- /'; grep -E '^(LOCK RESULT|UPDATE RESULT|RESULT|BASELINE RESULT|SERVER HEALTH RESULT|REPORT PRUNE RESULT|MEMORY DIAGNOSTIC RESULT|LOAD DIAGNOSTIC RESULT|PORT RESULT|KEYS RESULT|SSHD DRIFT RESULT|UFW DRIFT RESULT|SERVICE RESULT|SERVICE HEALTH RESULT|FAILED SERVICES RESULT|WATCH RESULT): (WARN|FAIL|SKIP|SKIP_LOCKED)' "$file" | sed 's/^/- /'; grep -E '^(FAIL:|WARN:|ERROR:)' "$file" | sed 's/^/- /'; } | awk '!seen[$0]++' | head -12; }
watch_issue_action(){ local file="${1:?missing report tmp}"; if grep -Eq '^(DISK /|DISK WORST|JOURNAL SIZE:|GPTLOGS SIZE:).*(— WARN|— FAIL)' "$file"; then echo "Storage/logs crossed a threshold. Check disk, journal size, and GPTlogs before services are affected."; elif grep -Eq '^(RAM:|SWAP:).*(— WARN|— FAIL)' "$file"; then echo "Memory pressure crossed a threshold. Alpha3.5.1 captured top memory/process evidence in the report."; elif grep -Eq '^LOAD: .*(— WARN|— FAIL)' "$file"; then echo "CPU/load pressure crossed a threshold. Alpha3.5.1 captured top CPU/process evidence in the report."; elif grep -Eq '^REBOOT REQUIRED: yes' "$file"; then echo "Server reports reboot required. Plan a controlled reboot window when safe."; elif grep -Eq 'REPORT PRUNE RESULT: WARN|REPORT PRUNE RESULT: FAIL' "$file"; then echo "Report pruning needs attention. Review REPORT_DIR safety checks and GPTlogs report counts."; elif grep -Eq 'SERVICE HEALTH RESULT: FAIL|FAILED SERVICES RESULT: FAIL|SERVICE RESULT: FAIL' "$file"; then echo "A Pooly/system service check failed. Review service health and failed systemd units on this node."; elif grep -Eq 'SSHD DRIFT RESULT: FAIL|KEYS RESULT: FAIL|UFW DRIFT RESULT: FAIL|RESULT: FAIL' "$file"; then echo "A security or access-control check failed. Review SSH, keys, sudo, and firewall drift immediately."; else echo "Review the issue summary and open the report path on the affected server."; fi; }

guard_watch(){
  clear_self_failed_state; mkdirs; load_env; health_defaults
  local lock_rc=0
  acquire_watch_lock || lock_rc=$?
  if [[ "$lock_rc" == "75" ]]; then return 0; elif [[ "$lock_rc" != "0" ]]; then return "$lock_rc"; fi
  local tmp failed=0 warned=0 host node report update_rc=0 outcome="PASS"
  host="$(hostname)"; node="$(node_id)"; tmp="$(mktemp)"
  { echo "LOCK RESULT: PASS"; self_update || update_rc=$?; report_prune || true; verify || true; baseline_verify || true; server_health || true; if memory_pressure_active; then memory_diagnostics || true; fi; if load_pressure_active; then load_diagnostics || true; fi; port_audit || true; keys_drift || true; sshd_drift || true; [[ "${POOLY_WATCH_WARN_UFW_DRIFT:-1}" == "1" ]] && ufw_drift || true; services_drift || true; service_health || true; failed_services_check || true; } | tee "$tmp"
  if [[ "$update_rc" != "0" ]] || grep -Eq 'UPDATE RESULT: FAIL|RESULT: FAIL|DRIFT RESULT: FAIL|PORT RESULT: FAIL|KEYS RESULT: FAIL|SERVICE RESULT: FAIL|SERVICE HEALTH RESULT: FAIL|FAILED SERVICES RESULT: FAIL|SERVER HEALTH RESULT: FAIL|REPORT PRUNE RESULT: FAIL' "$tmp"; then failed=1; outcome="FAIL"; elif grep -Eq 'SERVER HEALTH RESULT: WARN|REPORT PRUNE RESULT: WARN|WARN:' "$tmp"; then warned=1; outcome="WARN"; fi
  echo "WATCH RESULT: $outcome" | tee -a "$tmp"
  report="$REPORT_DIR/pooly-server-guard-watch-$host-$(date -u +%Y%m%d-%H%M%S).txt"
  cp "$tmp" "$report"
  [[ ${EUID:-$(id -u)} -eq 0 ]] && chown "$REPORT_OWNER:$REPORT_OWNER" "$report" 2>/dev/null || true
  if [[ $failed -ne 0 ]]; then discord_send_watch FAIL "$host" "$node" "$report" "$tmp" | tee -a "$tmp" "$report" >/dev/null || true; rm -f "$tmp"; return 1; fi
  if [[ $warned -ne 0 ]]; then [[ "${POOLY_ALERT_ON_WARN:-1}" == "1" ]] && discord_send_watch WARN "$host" "$node" "$report" "$tmp" | tee -a "$tmp" "$report" >/dev/null || true; rm -f "$tmp"; return 0; fi
  [[ "${POOLY_ALERT_ON_PASS:-0}" == "1" ]] && discord_send_watch PASS "$host" "$node" "$report" "$tmp" | tee -a "$tmp" "$report" >/dev/null || true
  rm -f "$tmp"; return 0
}

save_report(){ mkdirs; local f="$REPORT_DIR/pooly-server-guard-$(hostname)-$(date -u +%Y%m%d-%H%M%S).txt"; health | tee "$f"; [[ ${EUID:-$(id -u)} -eq 0 ]] && chown "$REPORT_OWNER:$REPORT_OWNER" "$f" 2>/dev/null || true; echo "Saved report: $f"; }
discord_test(){ discord_post "Pooly Server Guard Discord test from $(hostname) / node $(node_id)" && echo "Discord test sent"; }
install_timer(){ need_sudo; local script="$POOLY_INSTALL_PATH"; load_env; health_defaults; $SUDO install -d -m 755 -o "$REPORT_OWNER" -g "$REPORT_OWNER" "$REPORT_DIR" 2>/dev/null || true; $SUDO tee /etc/systemd/system/pooly-server-guard-watch.service >/dev/null <<EOF2
[Unit]
Description=Pooly Server Guard watch check
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=root
Environment=REPORT_OWNER=$REPORT_OWNER
Environment=REPORT_DIR=$REPORT_DIR
Environment=POOLY_REPO_DIR=$POOLY_REPO_DIR
Environment=POOLY_INSTALL_PATH=$POOLY_INSTALL_PATH
Environment=POOLY_WATCH_ONCALENDAR=$POOLY_WATCH_ONCALENDAR
Environment=POOLY_LOCK_FILE=$POOLY_LOCK_FILE
WorkingDirectory=$POOLY_REPO_DIR
ExecStart=$script watch
EOF2
$SUDO tee /etc/systemd/system/pooly-server-guard-watch.timer >/dev/null <<EOF2
[Unit]
Description=Run Pooly Server Guard watch on $POOLY_WATCH_ONCALENDAR

[Timer]
OnCalendar=$POOLY_WATCH_ONCALENDAR
Persistent=true

[Install]
WantedBy=timers.target
EOF2
$SUDO systemctl daemon-reload; $SUDO systemctl enable --now pooly-server-guard-watch.timer; $SUDO systemctl restart pooly-server-guard-watch.timer; $SUDO systemctl status pooly-server-guard-watch.timer --no-pager || true; }
uninstall_timer(){ need_sudo; $SUDO systemctl disable --now pooly-server-guard-watch.timer 2>/dev/null || true; $SUDO systemctl daemon-reload; }
usage(){ cat <<HELP
Pooly Server Guard v$VERSION
Commands:
  verify | baseline-verify | health | save-report
  init-state | watch | self-update | server-health | report-prune | memory-diagnostics | load-diagnostics
  port-audit | keys-drift | sshd-drift | ufw-drift | services-drift | service-health | failed-services
  discord-test | install-watch-timer | uninstall-watch-timer
HELP
}
cmd="${1:-help}"
case "$cmd" in verify) verify ;; baseline-verify) baseline_verify ;; health) health ;; save-report) save_report ;; init-state) init_state ;; watch) guard_watch ;; self-update) self_update ;; server-health) server_health ;; report-prune) report_prune ;; memory-diagnostics) memory_diagnostics ;; load-diagnostics) load_diagnostics ;; port-audit) port_audit ;; keys-drift) keys_drift ;; sshd-drift) sshd_drift ;; ufw-drift) ufw_drift ;; services-drift) services_drift ;; service-health) service_health ;; failed-services) failed_services_check ;; discord-test) discord_test ;; install-watch-timer) install_timer ;; uninstall-watch-timer) uninstall_timer ;; help|-h|--help|*) usage ;; esac
