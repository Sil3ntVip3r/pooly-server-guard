#!/usr/bin/env bash

version_info(){
  load_env; health_defaults
  section "POOLY SERVER GUARD VERSION"
  echo "Installed script version: $VERSION"
  echo "Architecture:            modular lib/*.sh"
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
  else echo "Repo state:             missing"; fi
}

watch_results_summary(){ local file="${1:?missing report tmp}"; grep -E '^(LOCK RESULT|UPDATE RESULT|RESULT|BASELINE RESULT|SERVER HEALTH RESULT|TIMER RESULT|JOURNAL GROWTH RESULT|REPORT PRUNE RESULT|MEMORY DIAGNOSTIC RESULT|LOAD DIAGNOSTIC RESULT|PORT RESULT|KEYS RESULT|SSHD DRIFT RESULT|UFW DRIFT RESULT|SERVICE RESULT|SERVICE HEALTH RESULT|FAILED SERVICES RESULT|DISCORD RESULT|WATCH RESULT):' "$file" | sed 's/^/- /' | head -30; }
watch_health_summary(){ local file="${1:?missing report tmp}"; grep -E '^(DISK /|DISK WORST|INODES /|RAM:|SWAP:|LOAD:|UPTIME:|REBOOT REQUIRED:|JOURNAL SIZE:|JOURNAL GROWTH:|GPTLOGS SIZE:)' "$file" | sed 's/^/- /' | head -14 || true; }
watch_issue_summary(){ local file="${1:?missing report tmp}"; { grep -E '^(DISK /|DISK WORST|INODES /|RAM:|SWAP:|LOAD:|REBOOT REQUIRED:|JOURNAL SIZE:|JOURNAL GROWTH:|GPTLOGS SIZE:).*(— WARN|— FAIL)' "$file" | sed 's/^/- /'; grep -E '^(LOCK RESULT|UPDATE RESULT|RESULT|BASELINE RESULT|SERVER HEALTH RESULT|TIMER RESULT|JOURNAL GROWTH RESULT|REPORT PRUNE RESULT|MEMORY DIAGNOSTIC RESULT|LOAD DIAGNOSTIC RESULT|PORT RESULT|KEYS RESULT|SSHD DRIFT RESULT|UFW DRIFT RESULT|SERVICE RESULT|SERVICE HEALTH RESULT|FAILED SERVICES RESULT|WATCH RESULT): (WARN|FAIL|SKIP|SKIP_LOCKED)' "$file" | sed 's/^/- /'; grep -E '^(FAIL:|WARN:|ERROR:)' "$file" | sed 's/^/- /'; } | awk '!seen[$0]++' | head -14; }
watch_issue_action(){ local file="${1:?missing report tmp}"; if grep -Eq '^(DISK /|DISK WORST|JOURNAL SIZE:|JOURNAL GROWTH:|GPTLOGS SIZE:).*(— WARN|— FAIL)' "$file"; then echo "Storage/logs crossed a threshold. Check disk, journal growth, and GPTlogs before services are affected."; elif grep -Eq '^(RAM:|SWAP:).*(— WARN|— FAIL)' "$file"; then echo "Memory pressure crossed a threshold. Alpha4.0 captured top memory/process evidence in the report."; elif grep -Eq '^LOAD: .*(— WARN|— FAIL)' "$file"; then echo "CPU/load pressure crossed a threshold. Alpha4.0 captured top CPU/process evidence in the report."; elif grep -Eq '^REBOOT REQUIRED: yes' "$file"; then echo "Server reports reboot required. Plan a controlled reboot window when safe."; elif grep -Eq 'REPORT PRUNE RESULT: WARN|REPORT PRUNE RESULT: FAIL' "$file"; then echo "Report pruning needs attention. Review REPORT_DIR safety checks and GPTlogs report counts."; elif grep -Eq 'SERVICE HEALTH RESULT: FAIL|FAILED SERVICES RESULT: FAIL|SERVICE RESULT: FAIL' "$file"; then echo "A Pooly/system service check failed. Review service health and failed systemd units on this node."; elif grep -Eq 'SSHD DRIFT RESULT: FAIL|KEYS RESULT: FAIL|UFW DRIFT RESULT: FAIL|RESULT: FAIL' "$file"; then echo "A security or access-control check failed. Review SSH, keys, sudo, and firewall drift immediately."; else echo "Review the issue summary and open the report path on the affected server."; fi; }

guard_watch(){
  clear_self_failed_state; mkdirs; load_env; health_defaults
  local lock_rc=0; acquire_watch_lock || lock_rc=$?
  if [[ "$lock_rc" == "75" ]]; then return 0; elif [[ "$lock_rc" != "0" ]]; then return "$lock_rc"; fi
  local tmp failed=0 warned=0 host node report update_rc=0 outcome="PASS"
  host="$(hostname)"; node="$(node_id)"; tmp="$(mktemp)"
  { echo "LOCK RESULT: PASS"; self_update || update_rc=$?; report_prune || true; timer_status || true; verify || true; baseline_verify || true; server_health || true; journal_growth || true; if memory_pressure_active; then memory_diagnostics || true; fi; if load_pressure_active; then load_diagnostics || true; fi; port_audit || true; keys_drift || true; sshd_drift || true; [[ "${POOLY_WATCH_WARN_UFW_DRIFT:-1}" == "1" ]] && ufw_drift || true; services_drift || true; service_health || true; failed_services_check || true; } | tee "$tmp"
  if [[ "$update_rc" != "0" ]] || grep -Eq 'UPDATE RESULT: FAIL|RESULT: FAIL|DRIFT RESULT: FAIL|PORT RESULT: FAIL|KEYS RESULT: FAIL|SERVICE RESULT: FAIL|SERVICE HEALTH RESULT: FAIL|FAILED SERVICES RESULT: FAIL|SERVER HEALTH RESULT: FAIL|JOURNAL GROWTH RESULT: FAIL|REPORT PRUNE RESULT: FAIL' "$tmp"; then failed=1; outcome="FAIL"; elif grep -Eq 'SERVER HEALTH RESULT: WARN|JOURNAL GROWTH RESULT: WARN|REPORT PRUNE RESULT: WARN|WARN:' "$tmp"; then warned=1; outcome="WARN"; fi
  echo "WATCH RESULT: $outcome" | tee -a "$tmp"
  report="$REPORT_DIR/pooly-server-guard-watch-$host-$(date -u +%Y%m%d-%H%M%S).txt"; cp "$tmp" "$report"; [[ ${EUID:-$(id -u)} -eq 0 ]] && chown "$REPORT_OWNER:$REPORT_OWNER" "$report" 2>/dev/null || true
  if [[ $failed -ne 0 ]]; then discord_send_watch FAIL "$host" "$node" "$report" "$tmp" | tee -a "$tmp" "$report" >/dev/null || true; rm -f "$tmp"; return 1; fi
  if [[ $warned -ne 0 ]]; then [[ "${POOLY_ALERT_ON_WARN:-1}" == "1" ]] && discord_send_watch WARN "$host" "$node" "$report" "$tmp" | tee -a "$tmp" "$report" >/dev/null || true; rm -f "$tmp"; return 0; fi
  [[ "${POOLY_ALERT_ON_PASS:-0}" == "1" ]] && discord_send_watch PASS "$host" "$node" "$report" "$tmp" | tee -a "$tmp" "$report" >/dev/null || true
  rm -f "$tmp"; return 0
}

health(){ version_info; section "POOLY HEALTH AUDIT"; echo "Host: $(hostname)"; echo "Node: $(node_id)"; echo "UTC:  $(date -u)"; timer_status || true; section "OS / KERNEL / UPTIME"; lsb_release -a 2>/dev/null || true; uname -a; uptime; section "DISK / INODES"; df -hT; echo; df -ih; section "MEMORY / SWAP"; free -h; swapon --show || true; server_health || true; journal_growth || true; report_prune || true; memory_diagnostics || true; load_diagnostics || true; failed_services_check || true; section "RUNNING POOLY SERVICES"; systemctl list-units --type=service --state=running --no-pager | egrep 'coin-|miningcore|nginx|redis|fail2ban|chrony|netdata|push-agent|pm2' || true; section "ALL POOLY SERVICES"; systemctl list-units --type=service --all --no-pager | egrep 'coin-|miningcore|nginx|redis|fail2ban|chrony|netdata|push-agent|pm2' || true; section "LISTENING PORTS"; ss -lntu || true; }
save_report(){ mkdirs; local f="$REPORT_DIR/pooly-server-guard-$(hostname)-$(date -u +%Y%m%d-%H%M%S).txt"; health | tee "$f"; [[ ${EUID:-$(id -u)} -eq 0 ]] && chown "$REPORT_OWNER:$REPORT_OWNER" "$f" 2>/dev/null || true; echo "Saved report: $f"; }
discord_test(){ discord_post "Pooly Server Guard Discord test from $(hostname) / node $(node_id)" && echo "Discord test sent"; }
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
main(){ local cmd="${1:-help}"; case "$cmd" in verify) verify ;; baseline-verify) baseline_verify ;; health) health ;; save-report) save_report ;; init-state) init_state ;; watch) guard_watch ;; self-update) self_update ;; server-health) server_health ;; report-prune) report_prune ;; memory-diagnostics) memory_diagnostics ;; load-diagnostics) load_diagnostics ;; timer-status) timer_status ;; journal-growth) journal_growth ;; port-audit) port_audit ;; keys-drift) keys_drift ;; sshd-drift) sshd_drift ;; ufw-drift) ufw_drift ;; services-drift) services_drift ;; service-health) service_health ;; failed-services) failed_services_check ;; discord-test) discord_test ;; install-watch-timer) install_timer ;; uninstall-watch-timer) uninstall_timer ;; help|-h|--help|*) usage ;; esac; }
