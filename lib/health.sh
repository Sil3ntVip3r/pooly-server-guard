#!/usr/bin/env bash

report_file_find_expr(){ find "$REPORT_DIR" -maxdepth 1 -xdev -type f \( -name 'pooly-server-guard-watch-*.txt' -o -name 'pooly-server-guard-*.txt' \); }

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
  section "POOLY REPORT PRUNE"; load_env; health_defaults
  local before_count after_count before_mb after_mb deleted_age=0 deleted_count=0 excess count max retention entry f
  echo "Report dir: $REPORT_DIR"; echo "Enabled: ${POOLY_REPORT_PRUNE_ENABLED:-1}"; echo "Retention days: ${POOLY_REPORT_RETENTION_DAYS:-14}"; echo "Max files: ${POOLY_REPORT_MAX_FILES:-1000}"
  if [[ "${POOLY_REPORT_PRUNE_ENABLED:-1}" != "1" ]]; then echo "SKIP: report pruning disabled"; echo "REPORT PRUNE RESULT: PASS"; return 0; fi
  if ! report_prune_safe_dir; then echo "REPORT PRUNE RESULT: WARN"; return 0; fi
  before_count="$(report_file_find_expr 2>/dev/null | wc -l | awk '{print $1}')"; before_mb="$(du -sm "$REPORT_DIR" 2>/dev/null | awk '{print $1+0}')"
  retention="${POOLY_REPORT_RETENTION_DAYS:-14}"
  if [[ "$retention" =~ ^[0-9]+$ && "$retention" -gt 0 ]]; then
    while IFS= read -r -d '' f; do [[ -f "$f" ]] && rm -f -- "$f" && deleted_age=$((deleted_age+1)); done < <(find "$REPORT_DIR" -maxdepth 1 -xdev -type f \( -name 'pooly-server-guard-watch-*.txt' -o -name 'pooly-server-guard-*.txt' \) -mtime +"$retention" -print0 2>/dev/null)
  else echo "WARN: invalid POOLY_REPORT_RETENTION_DAYS=$retention; age pruning skipped"; fi
  max="${POOLY_REPORT_MAX_FILES:-1000}"
  if [[ "$max" =~ ^[0-9]+$ && "$max" -gt 0 ]]; then
    count="$(report_file_find_expr 2>/dev/null | wc -l | awk '{print $1}')"
    if [[ "$count" -gt "$max" ]]; then
      excess=$((count-max))
      while IFS= read -r -d '' entry; do f="${entry#* }"; [[ -n "$f" && -f "$f" ]] && rm -f -- "$f" && deleted_count=$((deleted_count+1)); done < <(find "$REPORT_DIR" -maxdepth 1 -xdev -type f \( -name 'pooly-server-guard-watch-*.txt' -o -name 'pooly-server-guard-*.txt' \) -printf '%T@ %p\0' 2>/dev/null | sort -z -n | head -z -n "$excess")
    fi
  else echo "WARN: invalid POOLY_REPORT_MAX_FILES=$max; count pruning skipped"; fi
  after_count="$(report_file_find_expr 2>/dev/null | wc -l | awk '{print $1}')"; after_mb="$(du -sm "$REPORT_DIR" 2>/dev/null | awk '{print $1+0}')"
  echo "Before: ${before_count} report file(s), ${before_mb}M GPTlogs"; echo "Deleted by age: $deleted_age"; echo "Deleted by count cap: $deleted_count"; echo "After: ${after_count} report file(s), ${after_mb}M GPTlogs"; echo "REPORT PRUNE RESULT: PASS"
}

memory_pressure_active(){ load_env; health_defaults; local ram_pct swap_total swap_free swap_pct=0; ram_pct="$(awk '/MemTotal:/{t=$2}/MemAvailable:/{a=$2} END{if(t>0) printf "%.0f", ((t-a)*100)/t; else print 0}' /proc/meminfo 2>/dev/null)"; ram_pct="${ram_pct:-0}"; [[ "$ram_pct" =~ ^[0-9]+$ && "$ram_pct" -ge "${POOLY_RAM_WARN_PCT:-85}" ]] && return 0; read -r swap_total swap_free < <(awk '/SwapTotal:/{t=$2}/SwapFree:/{f=$2} END{print t+0, f+0}' /proc/meminfo 2>/dev/null); if [[ "${swap_total:-0}" -gt 0 ]]; then swap_pct="$(awk -v t="$swap_total" -v f="$swap_free" 'BEGIN{printf "%.0f", ((t-f)*100)/t}')"; [[ "$swap_pct" =~ ^[0-9]+$ && "$swap_pct" -ge "${POOLY_SWAP_WARN_PCT:-20}" ]] && return 0; fi; return 1; }
load_pressure_active(){ load_env; health_defaults; local load1 cpus load_per_cpu; load1="$(awk '{print $1}' /proc/loadavg 2>/dev/null)"; cpus="$(nproc 2>/dev/null || echo 1)"; load_per_cpu="$(awk -v l="${load1:-0}" -v c="${cpus:-1}" 'BEGIN{if(c>0) printf "%.2f", l/c; else print "0.00"}')"; awk -v v="$load_per_cpu" -v w="${POOLY_LOAD_WARN_PER_CPU:-2}" 'BEGIN{exit (v>=w)?0:1}'; }

memory_diagnostics(){ section "MEMORY PRESSURE DETAILS"; echo "Reason: RAM or swap crossed a warning/fail threshold, so alpha4.0 captured process evidence."; echo "Snapshot UTC: $(date -u)"; echo; echo "FREE -H"; free -h || true; echo; echo "MEMINFO SUMMARY"; awk '/MemTotal|MemFree|MemAvailable|Buffers|Cached|SwapCached|SwapTotal|SwapFree|Slab|SReclaimable|SUnreclaim|Committed_AS|CommitLimit/ {print}' /proc/meminfo 2>/dev/null || true; echo; echo "TOP MEMORY PROCESSES BY RSS"; ps -eo pid,ppid,user,comm,%mem,%cpu,rss,vsz,etime,args --sort=-rss 2>/dev/null | head -25 || true; echo; echo "TOP POOLY/COIN MEMORY PROCESSES"; ps -eo pid,ppid,user,comm,%mem,%cpu,rss,vsz,etime,args --sort=-rss 2>/dev/null | awk 'NR==1 || /\/opt\/pooly|Miningcore|coin-|buckd|ycashd|zerod|firod|ravend|bitcoinzd|neoxad|kerrigand|gemlink/ {print}' | head -30 || true; echo; echo "KERNEL OOM CHECK - LAST 24 HOURS"; journalctl -k --since "24 hours ago" --no-pager 2>/dev/null | grep -Ei 'oom|out of memory|killed process|memory allocation|page allocation|segfault' | tail -40 || true; echo; echo "MEMORY DIAGNOSTIC RESULT: PASS"; }
load_diagnostics(){ section "LOAD PRESSURE DETAILS"; local load1 load5 load15 cpus load_per_cpu; read -r load1 load5 load15 _ < /proc/loadavg 2>/dev/null || true; cpus="$(nproc 2>/dev/null || echo 1)"; load_per_cpu="$(awk -v l="${load1:-0}" -v c="${cpus:-1}" 'BEGIN{if(c>0) printf "%.2f", l/c; else print "0.00"}')"; echo "Reason: load per CPU crossed a warning/fail threshold, so alpha4.0 captured CPU/process evidence."; echo "Snapshot UTC: $(date -u)"; echo "Load averages: ${load1:-0} ${load5:-0} ${load15:-0}"; echo "CPU cores: ${cpus:-1}"; echo "Load per CPU: $load_per_cpu"; echo; echo "UPTIME"; uptime || true; echo; echo "TOP CPU PROCESSES"; ps -eo pid,ppid,user,comm,%cpu,%mem,rss,vsz,etime,args --sort=-%cpu 2>/dev/null | head -25 || true; echo; echo "TOP POOLY/COIN CPU PROCESSES"; ps -eo pid,ppid,user,comm,%cpu,%mem,rss,vsz,etime,args --sort=-%cpu 2>/dev/null | awk 'NR==1 || /\/opt\/pooly|Miningcore|coin-|buckd|ycashd|zerod|firod|ravend|bitcoinzd|neoxad|kerrigand|gemlink|dotnet/ {print}' | head -30 || true; echo; echo "LOAD DIAGNOSTIC RESULT: PASS"; }

timer_status(){ section "POOLY TIMER STATUS"; load_env; health_defaults; local mode="CUSTOM"; [[ "$POOLY_WATCH_ONCALENDAR" == "*:0/2" ]] && mode="TEST"; [[ "$POOLY_WATCH_ONCALENDAR" == "$POOLY_PRODUCTION_ONCALENDAR" ]] && mode="PRODUCTION"; echo "Active timer: $POOLY_WATCH_ONCALENDAR"; echo "Recommended production timer: $POOLY_PRODUCTION_ONCALENDAR"; echo "Timer mode: $mode"; echo "TIMER RESULT: PASS"; }

journal_growth(){
  section "JOURNAL GROWTH"; load_env; health_defaults
  local state_file="$POOLY_STATE_DIR/journal-size-mb.txt" current previous delta status abs
  current="$(du -sm /var/log/journal /run/log/journal 2>/dev/null | awk '{sum+=$1} END{print sum+0}')"; current="${current:-0}"
  echo "Current journal size: ${current}M"
  if $SUDO test -f "$state_file" 2>/dev/null; then previous="$($SUDO cat "$state_file" 2>/dev/null | tail -1 | awk '{print $1+0}')"; else previous=""; fi
  if [[ -z "${previous:-}" ]]; then
    echo "Previous journal size: none"; echo "JOURNAL GROWTH: baseline saved — PASS"; status="PASS"
  else
    delta=$((current-previous))
    echo "Previous journal size: ${previous}M"
    if (( delta < 0 )); then abs=$(( -delta )); echo "JOURNAL GROWTH: -${abs}M since last watch — PASS"; status="PASS"; else status="$(num_status "$delta" "$POOLY_JOURNAL_GROWTH_WARN_MB" "$POOLY_JOURNAL_GROWTH_FAIL_MB")"; echo "JOURNAL GROWTH: +${delta}M since last watch — $status"; fi
  fi
  $SUDO install -d -m 700 "$POOLY_STATE_DIR" 2>/dev/null || true
  printf '%s\n' "$current" | $SUDO tee "$state_file" >/dev/null 2>&1 || echo "WARN: unable to save journal growth state"
  echo "JOURNAL GROWTH RESULT: $status"; status_return "$status"
}

server_health(){ section "POOLY SERVER HEALTH"; load_env; health_defaults; POOLY_WORST_STATUS="PASS"; local pct status worst_pct worst_mount ram_pct swap_pct swap_total swap_free load1 cpus load_per_cpu journal_mb gptlogs_mb uptime_seconds uptime_days; echo "Thresholds: disk ${POOLY_DISK_WARN_PCT}/${POOLY_DISK_FAIL_PCT}% warn/fail, RAM ${POOLY_RAM_WARN_PCT}/${POOLY_RAM_FAIL_PCT}%, load per CPU ${POOLY_LOAD_WARN_PER_CPU}/${POOLY_LOAD_FAIL_PER_CPU}"; pct="$(df -P / 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5}')"; pct="${pct:-0}"; status="$(num_status "$pct" "$POOLY_DISK_WARN_PCT" "$POOLY_DISK_FAIL_PCT")"; worst_mark "$status"; echo "DISK /: ${pct}% used — $status"; read -r worst_pct worst_mount < <(df -P -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null | awk 'NR>1{gsub("%","",$5); if($5+0>max){max=$5+0; mount=$6}} END{print max+0, mount}'); if [[ -n "${worst_mount:-}" && "$worst_mount" != "/" ]]; then status="$(num_status "$worst_pct" "$POOLY_DISK_WARN_PCT" "$POOLY_DISK_FAIL_PCT")"; worst_mark "$status"; echo "DISK WORST: ${worst_mount} ${worst_pct}% used — $status"; fi; pct="$(df -Pi / 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5}')"; pct="${pct:-0}"; status="$(num_status "$pct" "$POOLY_INODE_WARN_PCT" "$POOLY_INODE_FAIL_PCT")"; worst_mark "$status"; echo "INODES /: ${pct}% used — $status"; ram_pct="$(awk '/MemTotal:/{t=$2}/MemAvailable:/{a=$2} END{if(t>0) printf "%.0f", ((t-a)*100)/t; else print 0}' /proc/meminfo 2>/dev/null)"; ram_pct="${ram_pct:-0}"; status="$(num_status "$ram_pct" "$POOLY_RAM_WARN_PCT" "$POOLY_RAM_FAIL_PCT")"; worst_mark "$status"; echo "RAM: ${ram_pct}% pressure — $status"; read -r swap_total swap_free < <(awk '/SwapTotal:/{t=$2}/SwapFree:/{f=$2} END{print t+0, f+0}' /proc/meminfo 2>/dev/null); if [[ "${swap_total:-0}" -gt 0 ]]; then swap_pct="$(awk -v t="$swap_total" -v f="$swap_free" 'BEGIN{printf "%.0f", ((t-f)*100)/t}')"; status="$(num_status "$swap_pct" "$POOLY_SWAP_WARN_PCT" "$POOLY_SWAP_FAIL_PCT")"; worst_mark "$status"; echo "SWAP: ${swap_pct}% used — $status"; else echo "SWAP: not configured — PASS"; fi; load1="$(awk '{print $1}' /proc/loadavg 2>/dev/null)"; cpus="$(nproc 2>/dev/null || echo 1)"; load_per_cpu="$(awk -v l="${load1:-0}" -v c="${cpus:-1}" 'BEGIN{if(c>0) printf "%.2f", l/c; else print "0.00"}')"; status="$(num_status "$load_per_cpu" "$POOLY_LOAD_WARN_PER_CPU" "$POOLY_LOAD_FAIL_PER_CPU")"; worst_mark "$status"; echo "LOAD: ${load1:-0} on ${cpus:-1} CPU cores = ${load_per_cpu} per CPU — $status"; uptime_seconds="$(awk '{printf "%.0f", $1}' /proc/uptime 2>/dev/null || echo 0)"; uptime_days="$(( ${uptime_seconds:-0} / 86400 ))"; echo "UPTIME: ${uptime_days} day(s) — PASS"; if [[ -f /var/run/reboot-required ]]; then worst_mark "WARN"; echo "REBOOT REQUIRED: yes — WARN"; else echo "REBOOT REQUIRED: no — PASS"; fi; journal_mb="$(du -sm /var/log/journal /run/log/journal 2>/dev/null | awk '{sum+=$1} END{print sum+0}')"; status="$(num_status "$journal_mb" "$POOLY_JOURNAL_WARN_MB" "$POOLY_JOURNAL_FAIL_MB")"; worst_mark "$status"; echo "JOURNAL SIZE: ${journal_mb}M — $status"; [[ -d "$REPORT_DIR" ]] && gptlogs_mb="$(du -sm "$REPORT_DIR" 2>/dev/null | awk '{print $1+0}')" || gptlogs_mb=0; status="$(num_status "$gptlogs_mb" "$POOLY_GPTLOGS_WARN_MB" "$POOLY_GPTLOGS_FAIL_MB")"; worst_mark "$status"; echo "GPTLOGS SIZE: ${gptlogs_mb}M — $status"; echo; echo "SERVER HEALTH RESULT: $POOLY_WORST_STATUS"; status_return "$POOLY_WORST_STATUS"; }
