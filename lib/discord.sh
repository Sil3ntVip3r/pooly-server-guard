#!/usr/bin/env bash

discord_post(){ load_env; [[ "${POOLY_DISCORD_ENABLED:-0}" == "1" ]] || return 0; [[ -n "${POOLY_DISCORD_WEBHOOK:-}" ]] || { echo "Missing POOLY_DISCORD_WEBHOOK in $POOLY_GUARD_ENV"; return 1; }; local payload; payload="{\"content\":$(printf '%s' "$1" | json_escape),\"allowed_mentions\":{\"parse\":[]}}"; curl -fsS -H 'Content-Type: application/json' -d "$payload" "$POOLY_DISCORD_WEBHOOK" >/dev/null; }

discord_post_json_file(){
  local payload_file="${1:?missing payload file}"; load_env
  [[ "${POOLY_DISCORD_ENABLED:-0}" == "1" ]] || { echo "DISCORD RESULT: SKIP_DISABLED"; return 0; }
  [[ -n "${POOLY_DISCORD_WEBHOOK:-}" ]] || { echo "DISCORD RESULT: FAIL_MISSING_WEBHOOK"; return 0; }
  command -v curl >/dev/null 2>&1 || { echo "DISCORD RESULT: FAIL_CURL_MISSING"; return 0; }
  local response_file http_code retry_after http_code2; response_file="$(mktemp)"
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
      sleep "${retry_after:-1}"; http_code2="$(curl -sS -o "$response_file" -w '%{http_code}' -H 'Content-Type: application/json' -d @"$payload_file" "$POOLY_DISCORD_WEBHOOK" 2>/dev/null || echo curl_failed)"; rm -f "$response_file"; case "$http_code2" in 200|204) echo "DISCORD RESULT: PASS_AFTER_429_RETRY" ;; *) echo "DISCORD RESULT: FAIL_HTTP_${http_code2}_AFTER_429" ;; esac; return 0 ;;
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
def health(): return f"Disk {metric('DISK /:','disk')} | RAM {metric('RAM:','ram')} | Swap {metric('SWAP:','swap')} | Load/CPU {metric('LOAD:','load')}\nJournal {metric('JOURNAL SIZE:','mb')} | Δ {jdelta_full()} | Reports {metric('GPTLOGS SIZE:','mb')}"
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

discord_send_watch(){ local status="${1:?missing status}" host="${2:?missing host}" node="${3:?missing node}" report="${4:?missing report}" tmp="${5:?missing tmp}" payload_file; payload_file="$(mktemp)"; if discord_watch_payload_file "$status" "$host" "$node" "$report" "$tmp" "$payload_file"; then discord_post_json_file "$payload_file"; else echo "DISCORD RESULT: FAIL_PAYLOAD"; fi; rm -f "$payload_file"; }
