#!/usr/bin/env bash
set -euo pipefail

TARGET="$HOME/GPTlogs/pooly-server-guard.sh"
BACKUP="$TARGET.backup-$(date -u +%Y%m%d-%H%M%S)"

cp "$TARGET" "$BACKUP"

python3 - <<'PY'
from pathlib import Path
p = Path.home() / 'GPTlogs' / 'pooly-server-guard.sh'
s = p.read_text()
s = s.replace('VERSION="0.4.1"', 'VERSION="0.4.2"')
old = '''port_audit(){ section "PORT DRIFT AUDIT"; diff_state ports current_ports && echo "PORT RESULT: PASS" || { echo "PORT RESULT: FAIL"; return 1; }; }'''
new = '''port_audit(){
  section "PORT AUDIT"
  echo "INFO: Miningcore/coin ports can open and close quickly. Static port drift is informational by default."
  if ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Eq ':(22)$'; then
    echo "FAIL: port 22 listener found"
    echo "PORT RESULT: FAIL"
    return 1
  fi
  if ! diff_state ports current_ports; then
    echo "INFO: dynamic port drift detected but not failing."
  else
    echo "STATIC PORT RESULT: PASS"
  fi
  echo "PORT RESULT: PASS"
  return 0
}'''
if old not in s:
    raise SystemExit('Expected v0.4.1 port_audit function not found; no changes made')
p.write_text(s.replace(old, new))
PY

chmod 700 "$TARGET"

echo "Patched $TARGET"
echo "Backup: $BACKUP"
"$TARGET" --help
