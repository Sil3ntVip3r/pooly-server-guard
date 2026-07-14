#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

load_env(){ return 0; }
json_escape(){ python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'; }
POOLY_WATCH_ONCALENDAR='*:0/10'
POOLY_DISCORD_SUPPRESS_PASS=1
VERSION='0.5.0-alpha4.1.0'
# shellcheck source=../lib/discord.sh
source "$ROOT/lib/discord.sh"

cat > "$TMP/watch.txt" <<'WATCH_FIXTURE'
RESULT: PASS
BASELINE RESULT: PASS
DISK /: 41% used — PASS
RAM: 82% pressure — PASS
SWAP: 28% used — WARN
LOAD: 0.10 on 12 CPU cores = 0.01 per CPU — PASS
JOURNAL SIZE: 4500M — PASS
JOURNAL GROWTH: +0M since last watch — PASS
GPTLOGS SIZE: 50M — PASS
SERVER HEALTH RESULT: WARN
BALLOON SUPPORTED: yes
BALLOON STATE: ACTIVE
BALLOON OUTSTANDING: 63.25 GiB
BALLOON INFLATE SINCE LAST CHECK: 18.50 GiB
BALLOON DEFLATE SINCE LAST CHECK: 0.00 GiB
MEM AVAILABLE: 17111.00 MiB
RAM PRESSURE: 82%
SWAP USED: 5900.00 MiB / 28%
SWAP-OUT DELTA: 74.00 MiB
OOM KILL DELTA: 0
BALLOON RESULT: WARN
TIMER RESULT: PASS
JOURNAL GROWTH RESULT: PASS
REPORT PRUNE RESULT: PASS
PORT RESULT: PASS
KEYS RESULT: PASS
SSHD DRIFT RESULT: PASS
UFW DRIFT RESULT: PASS
SERVICE RESULT: PASS
SERVICE HEALTH RESULT: PASS
FAILED SERVICES RESULT: PASS
WATCH RESULT: WARN
WATCH_FIXTURE

discord_watch_payload_file WARN pooly-ssdnodes-003-tokyo2 003 /tmp/report.txt "$TMP/watch.txt" "$TMP/payload.json"
python3 - "$TMP/payload.json" <<'PY'
import json, sys
p=json.load(open(sys.argv[1]))
assert p['allowed_mentions']['parse']==[]
embed=p['embeds'][0]
assert 'Node 003 WARN' in embed['title']
fields={f['name']:f['value'] for f in embed['fields']}
assert 'BALLOON RESULT: WARN' in fields['Cause']
assert 'BALLOON STATE: ACTIVE' in fields['Cause']
assert 'BALLOON OUTSTANDING: 63.25 GiB' in fields['Cause']
assert 'host-side memory ballooning' in fields['Action'].lower()
assert 'Phase 1 performs no remediation.' in fields['Action']
assert 'BALLOON STATE: ACTIVE' in fields['Evidence']
for field in embed['fields']:
    assert len(field['name']) <= 256
    assert len(field['value']) <= 1024
assert len(embed['description']) <= 4096
PY

cat > "$TMP/pass.txt" <<'PASS_FIXTURE'
RESULT: PASS
BASELINE RESULT: PASS
DISK /: 41% used — PASS
RAM: 20% pressure — PASS
SWAP: 0% used — PASS
LOAD: 0.10 on 12 CPU cores = 0.01 per CPU — PASS
JOURNAL SIZE: 4500M — PASS
JOURNAL GROWTH: +0M since last watch — PASS
GPTLOGS SIZE: 50M — PASS
SERVER HEALTH RESULT: PASS
BALLOON STATE: DISABLED
BALLOON RESULT: PASS
TIMER RESULT: PASS
JOURNAL GROWTH RESULT: PASS
SERVICE HEALTH RESULT: PASS
FAILED SERVICES RESULT: PASS
WATCH RESULT: PASS
PASS_FIXTURE

discord_watch_payload_file PASS pooly-ssdnodes-001-toronto 001 /tmp/report.txt "$TMP/pass.txt" "$TMP/pass.json"
python3 - "$TMP/pass.json" <<'PY'
import json, sys
p=json.load(open(sys.argv[1]))
assert p.get('flags') == 4096
embed=p['embeds'][0]
fields={f['name']:f['value'] for f in embed['fields']}
assert 'Checks OK' in fields['Checks']
assert 'Balloon DISABLED' in fields['Checks']
PY

sed 's/BALLOON STATE: DISABLED/BALLOON STATE: ACTIVE_CONTINUING/' "$TMP/pass.txt" > "$TMP/pass-active.txt"
discord_watch_payload_file PASS pooly-ssdnodes-003-tokyo2 003 /tmp/report.txt "$TMP/pass-active.txt" "$TMP/pass-active.json"
python3 - "$TMP/pass-active.json" <<'PY'
import json, sys
p=json.load(open(sys.argv[1]))
fields={f['name']:f['value'] for f in p['embeds'][0]['fields']}
assert 'Checks Review' in fields['Checks']
assert 'Balloon ACTIVE_CONTINUING' in fields['Checks']
PY

cat > "$TMP/fail.txt" <<'FAIL_FIXTURE'
RESULT: FAIL
BASELINE RESULT: PASS
DISK /: 41% used — PASS
RAM: 82% pressure — PASS
SWAP: 28% used — WARN
LOAD: 0.10 on 12 CPU cores = 0.01 per CPU — PASS
JOURNAL SIZE: 4500M — PASS
JOURNAL GROWTH: +0M since last watch — PASS
GPTLOGS SIZE: 50M — PASS
SERVER HEALTH RESULT: WARN
BALLOON STATE: ACTIVE
BALLOON OUTSTANDING: 63.25 GiB
BALLOON RESULT: WARN
SSHD DRIFT RESULT: FAIL
SERVICE HEALTH RESULT: PASS
FAILED SERVICES RESULT: PASS
WATCH RESULT: FAIL
FAIL_FIXTURE

discord_watch_payload_file FAIL pooly-ssdnodes-003-tokyo2 003 /tmp/report.txt "$TMP/fail.txt" "$TMP/fail.json"
python3 - "$TMP/fail.json" <<'PY'
import json, sys
p=json.load(open(sys.argv[1]))
fields={f['name']:f['value'] for f in p['embeds'][0]['fields']}
assert 'memory pressure' in fields['Action'].lower()
assert 'host-side memory ballooning' not in fields['Action'].lower()
PY

cat > "$TMP/oom.txt" <<'OOM_FIXTURE'
RESULT: PASS
BASELINE RESULT: PASS
SERVER HEALTH RESULT: PASS
BALLOON STATE: OOM_OBSERVED
OOM KILL DELTA: 1
BALLOON RESULT: WARN
SERVICE HEALTH RESULT: PASS
FAILED SERVICES RESULT: PASS
WATCH RESULT: WARN
OOM_FIXTURE

discord_watch_payload_file WARN pooly-ssdnodes-003-tokyo2 003 /tmp/report.txt "$TMP/oom.txt" "$TMP/oom.json"
python3 - "$TMP/oom.json" <<'PY'
import json, sys
p=json.load(open(sys.argv[1]))
fields={f['name']:f['value'] for f in p['embeds'][0]['fields']}
assert 'oom-kill counter increased' in fields['Action'].lower()
assert 'host-side memory ballooning' not in fields['Action'].lower()
PY

printf 'PASS: Discord balloon payload tests\n'
