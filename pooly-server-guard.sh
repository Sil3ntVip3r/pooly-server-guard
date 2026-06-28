#!/usr/bin/env bash
set -uo pipefail

VERSION="0.4.5"
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
SUDO=""
[[ ${EUID:-$(id -u)} -eq 0 ]] || SUDO="sudo"

section(){ printf '\n============================================================\n %s\n============================================================\n' "$*"; }
need_sudo(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || sudo -v; }

run_as_report_owner(){
  if [[ ${EUID:-$(id -u)} -eq 0 && -n "${REPORT_OWNER:-}" && "$REPORT_OWNER" != "root" ]]; then
    sudo -H -u "$REPORT_OWNER" "$@"
  else
    "$@"
  fi
}

clear_self_failed_state(){
  if [[ ${EUID:-$(id -u)} -eq 0 ]] && command -v systemctl >/dev/null 2>&1; then
    systemctl reset-failed pooly-server-guard-watch.service 2>/dev/null || true
  fi
}

mkdirs(){
  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    install -d -m 755 -o "$REPORT_OWNER" -g "$REPORT_OWNER" "$REPORT_DIR" 2>/dev/null || mkdir -p "$REPORT_DIR"
  else
    mkdir -p "$REPORT_DIR" 2>/dev/null || true
  fi
}

load_env(){ [[ -f "$POOLY_GUARD_ENV" ]] && source "$POOLY_GUARD_ENV"; }
json_escape(){ python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'; }

discord_post(){
  load_env
  [[ "${POOLY_DISCORD_ENABLED:-0}" == "1" ]] || return 0
  [[ -n "${POOLY_DISCORD_WEBHOOK:-}" ]] || { echo "Missing POOLY_DISCORD_WEBHOOK in $POOLY_GUARD_ENV"; return 1; }
  local payload
  payload="{\"content\":$(printf '%s' "$1" | json_escape)}"
  curl -fsS -H 'Content-Type: application/json' -d "$payload" "$POOLY_DISCORD_WEBHOOK" >/dev/null
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

current_ports(){ ss -H -lntu 2>/dev/null | awk '{print $5}' | sed -E 's/.*:([0-9]+)$/\1/' | sort -n | uniq; }

current_services(){
  systemctl list-units --type=service --state=running --no-legend 2>/dev/null \
    | awk '{print $1}' \
    | grep -E '^(coin-|miningcore|nginx|redis-server|fail2ban|chrony|netdata|push-agent|pm2-|systemd-journald@netdata)' \
    | sort -u || true
}

pooly_units_all(){
  systemctl list-units --type=service --all --no-legend 2>/dev/null \
    | awk '{print $1}' \
    | grep -E '^(coin-|miningcore|pm2-|nginx|redis-server|fail2ban|chrony|netdata|push-agent|systemd-journald@netdata)' \
    | sort -u || true
}

baseline_services(){
  $SUDO cat "$POOLY_STATE_DIR/services.txt" 2>/dev/null | sort -u || true
}

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

sshd_policy(){ $SUDO sshd -T 2>/dev/null | egrep '^(port|permitrootlogin|pubkeyauthentication|passwordauthentication|kbdinteractiveauthentication|allowusers|maxauthtries|maxsessions|maxstartups) ' | sort; }
ufw_rules(){ $SUDO ufw status numbered 2>/dev/null | sed 's/[[:space:]]\+$//' || true; }

version_info(){
  section "POOLY SERVER GUARD VERSION"
  echo "Installed script version: $VERSION"
  echo "Installed script path:    ${BASH_SOURCE[0]:-$POOLY_INSTALL_PATH}"
  echo "Configured install path:  $POOLY_INSTALL_PATH"
  echo "Configured repo path:     $POOLY_REPO_DIR"
  if [[ -d "$POOLY_REPO_DIR/.git" ]]; then
    run_as_report_owner git -C "$POOLY_REPO_DIR" rev-parse --short HEAD 2>/dev/null | awk '{print "Repo HEAD:              "$0}' || true
    [[ -f "$POOLY_REPO_DIR/VERSION" ]] && awk '{print "Repo VERSION:           "$0}' "$POOLY_REPO_DIR/VERSION" || true
  else
    echo "Repo state:             missing"
  fi
}

self_update(){
  section "POOLY SERVER GUARD UPDATE CHECK"
  load_env
  echo "Running version: $VERSION"
  echo "Auto update: ${POOLY_GUARD_AUTO_UPDATE:-1}"
  echo "Repo dir: $POOLY_REPO_DIR"
  echo "Install path: $POOLY_INSTALL_PATH"
  echo "Git user: ${REPORT_OWNER:-$(id -un)}"

  if [[ "${POOLY_GUARD_AUTO_UPDATE:-1}" != "1" ]]; then
    echo "SKIP: auto update disabled"
    echo "UPDATE RESULT: PASS"
    return 0
  fi

  if ! command -v git >/dev/null 2>&1; then
    echo "FAIL: git is not installed"
    echo "UPDATE RESULT: FAIL"
    return 1
  fi

  if [[ ! -d "$POOLY_REPO_DIR/.git" ]]; then
    echo "FAIL: repo missing at $POOLY_REPO_DIR"
    echo "UPDATE RESULT: FAIL"
    return 1
  fi

  local branch remote_ref before after repo_version installed_changed=0
  branch="${POOLY_GUARD_AUTO_UPDATE_BRANCH:-main}"
  remote_ref="origin/$branch"

  before="$(run_as_report_owner git -C "$POOLY_REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  echo "Local repo before: $before"

  if ! run_as_report_owner git -C "$POOLY_REPO_DIR" fetch --quiet --all --prune; then
    echo "FAIL: git fetch failed"
    echo "UPDATE RESULT: FAIL"
    return 1
  fi

  if ! run_as_report_owner git -C "$POOLY_REPO_DIR" rev-parse --verify "$remote_ref" >/dev/null 2>&1; then
    echo "FAIL: remote ref $remote_ref not found"
    echo "UPDATE RESULT: FAIL"
    return 1
  fi

  if ! run_as_report_owner git -C "$POOLY_REPO_DIR" reset --hard "$remote_ref" >/dev/null; then
    echo "FAIL: git reset to $remote_ref failed"
    echo "UPDATE RESULT: FAIL"
    return 1
  fi

  after="$(run_as_report_owner git -C "$POOLY_REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  repo_version="$(cat "$POOLY_REPO_DIR/VERSION" 2>/dev/null || echo unknown)"
  echo "Local repo after:  $after"
  echo "Latest repo version: $repo_version"

  if [[ ! -x "$POOLY_INSTALL_PATH" ]] || ! cmp -s "$POOLY_REPO_DIR/pooly-server-guard.sh" "$POOLY_INSTALL_PATH"; then
    need_sudo
    $SUDO install -m 755 "$POOLY_REPO_DIR/pooly-server-guard.sh" "$POOLY_INSTALL_PATH"
    if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
      chown "$REPORT_OWNER:$REPORT_OWNER" "$POOLY_INSTALL_PATH" 2>/dev/null || true
    fi
    installed_changed=1
    echo "UPDATED: installed script refreshed from repo"
  else
    echo "PASS: installed script already matches repo"
  fi

  if [[ "$repo_version" != "$VERSION" ]]; then
    echo "INFO: this running process is v$VERSION; installed script is now repo v$repo_version"
    echo "INFO: the next timer/manual run will execute the updated script."
  fi

  [[ "$installed_changed" == "1" ]] && echo "UPDATE ACTION: INSTALLED" || echo "UPDATE ACTION: NONE"
  echo "UPDATE RESULT: PASS"
  return 0
}

verify(){
  section "POOLY SERVER GUARD VERIFY"
  local failed=0 ports sshdT root_count
  ports="$(sshd_policy | awk '$1=="port"{print $2}' | xargs echo)"
  sshdT="$(sshd_policy)"
  echo "SSH ports: $ports"
  [[ "$ports" == "$SSH_PORT" ]] && echo "PASS: SSH effective port is $SSH_PORT only" || { echo "FAIL: SSH effective port is not $SSH_PORT only"; failed=1; }
  ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Eq ':(22)$' && { echo "FAIL: sshd port 22 listener found"; failed=1; } || echo "PASS: no sshd port 22 listener found"
  ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Eq ":${SSH_PORT}$" && echo "PASS: sshd port $SSH_PORT listener found" || { echo "FAIL: sshd port $SSH_PORT listener missing"; failed=1; }
  echo "$sshdT" | grep -q '^permitrootlogin no$' && echo "PASS: root SSH disabled" || { echo "FAIL: root SSH not disabled"; failed=1; }
  echo "$sshdT" | grep -q '^passwordauthentication no$' && echo "PASS: password SSH disabled" || { echo "FAIL: password SSH not disabled"; failed=1; }
  echo "$sshdT" | grep -q '^kbdinteractiveauthentication no$' && echo "PASS: keyboard-interactive SSH disabled" || { echo "FAIL: keyboard-interactive SSH not disabled"; failed=1; }
  for u in "${ADMIN_USERS[@]}"; do echo "$sshdT" | grep -q "$u" && echo "PASS: $u allowed" || { echo "FAIL: $u missing from AllowUsers"; failed=1; }; done
  root_count="$($SUDO sh -c 'test -f /root/.ssh/authorized_keys && awk "NF && \$1 !~ /^#/" /root/.ssh/authorized_keys | wc -l || echo 0' 2>/dev/null | tail -1)"
  [[ "$root_count" == "0" ]] && echo "PASS: root authorized_keys empty" || { echo "FAIL: root authorized_keys has $root_count active key(s)"; failed=1; }
  for u in "${ADMIN_USERS[@]}"; do id -nG "$u" 2>/dev/null | tr ' ' '\n' | grep -qx sudo && echo "PASS: $u in sudo" || { echo "FAIL: $u not in sudo"; failed=1; }; done
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

failed_services_check(){
  section "FAILED SERVICES"
  clear_self_failed_state
  local out
  out="$(systemctl --failed --no-pager 2>/dev/null || true)"
  printf '%s\n' "$out"
  if printf '%s\n' "$out" | grep -Eq '^●[[:space:]]+'; then
    echo "FAILED SERVICES RESULT: FAIL"
    return 1
  fi
  echo "FAILED SERVICES RESULT: PASS"
  return 0
}

health(){
  version_info
  section "POOLY HEALTH AUDIT"; echo "Host: $(hostname)"; echo "Node: $(node_id)"; echo "UTC:  $(date -u)"
  section "OS / KERNEL / UPTIME"; lsb_release -a 2>/dev/null || true; uname -a; uptime
  section "REBOOT / UPDATES"; test -f /var/run/reboot-required && cat /var/run/reboot-required || echo "No reboot-required flag"; apt list --upgradable 2>/dev/null || true
  section "DISK / INODES"; df -hT; echo; df -ih
  section "MEMORY / SWAP"; free -h; swapon --show || true
  failed_services_check || true
  section "RUNNING POOLY SERVICES"; systemctl list-units --type=service --state=running --no-pager | egrep 'coin-|miningcore|nginx|redis|fail2ban|chrony|netdata|push-agent|pm2' || true
  section "ALL POOLY SERVICES"; systemctl list-units --type=service --all --no-pager | egrep 'coin-|miningcore|nginx|redis|fail2ban|chrony|netdata|push-agent|pm2' || true
  section "LISTENING PORTS"; ss -lntu || true
  section "WIREGUARD"; $SUDO wg show 2>/dev/null || true
}

init_state(){
  need_sudo; $SUDO install -d -m 700 "$POOLY_STATE_DIR"
  current_ports | $SUDO tee "$POOLY_STATE_DIR/ports.txt" >/dev/null
  key_fingerprints | $SUDO tee "$POOLY_STATE_DIR/keys.txt" >/dev/null
  sshd_policy | $SUDO tee "$POOLY_STATE_DIR/sshd.txt" >/dev/null
  ufw_rules | $SUDO tee "$POOLY_STATE_DIR/ufw.txt" >/dev/null
  current_services | $SUDO tee "$POOLY_STATE_DIR/services.txt" >/dev/null
  echo "$VERSION" | $SUDO tee "$POOLY_STATE_DIR/guard-version.txt" >/dev/null
  echo "Saved known-good state in $POOLY_STATE_DIR"
}

diff_state(){
  local state_name state_cmd state_file tmp rc
  state_name="${1:?missing state name}"
  state_cmd="${2:?missing state command}"
  state_file="$POOLY_STATE_DIR/$state_name.txt"
  tmp="$(mktemp)"
  $state_cmd > "$tmp"
  if ! $SUDO test -f "$state_file"; then echo "WARN: missing baseline $state_file; run init-state"; rm -f "$tmp"; return 2; fi
  diff -u <($SUDO cat "$state_file") "$tmp"
  rc=$?
  rm -f "$tmp"
  return "$rc"
}

port_audit(){
  section "PORT AUDIT"
  local failed=0
  echo "INFO: Miningcore and coin daemon ports can open and close quickly. Static port drift is informational unless strict mode is enabled."
  if ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Eq ':(22)$'; then
    echo "FAIL: port 22 listener found"
    failed=1
  fi
  if [[ "$POOLY_PORT_STRICT_BASELINE" == "1" ]]; then
    diff_state ports current_ports && echo "STATIC PORT RESULT: PASS" || { echo "STATIC PORT RESULT: FAIL"; failed=1; }
  else
    if ! diff_state ports current_ports; then
      echo "INFO: dynamic port drift detected but not failing."
    else
      echo "STATIC PORT RESULT: PASS"
    fi
  fi
  [[ $failed -eq 0 ]] && { echo "PORT RESULT: PASS"; return 0; } || { echo "PORT RESULT: FAIL"; return 1; }
}

keys_drift(){ section "AUTHORIZED_KEYS DRIFT"; diff_state keys key_fingerprints && echo "KEYS RESULT: PASS" || { echo "KEYS RESULT: FAIL"; return 1; }; }
sshd_drift(){ section "SSHD POLICY DRIFT"; diff_state sshd sshd_policy && echo "SSHD DRIFT RESULT: PASS" || { echo "SSHD DRIFT RESULT: FAIL"; return 1; }; }
ufw_drift(){ section "UFW DRIFT"; diff_state ufw ufw_rules && echo "UFW DRIFT RESULT: PASS" || { echo "UFW DRIFT RESULT: FAIL"; return 1; }; }
services_drift(){ section "POOLY SERVICE DRIFT"; diff_state services current_services && echo "SERVICE RESULT: PASS" || { echo "SERVICE RESULT: FAIL"; return 1; }; }

service_health(){
  section "POOLY SERVICE HEALTH"
  local failed=0 svc active sub result nrestarts status units
  units="$( { pooly_units_all; baseline_services; } | sort -u )"
  if [[ -z "$units" ]]; then
    echo "WARN: no Pooly services found to check"
    echo "SERVICE HEALTH RESULT: FAIL"
    return 1
  fi

  while read -r svc; do
    [[ -n "$svc" ]] || continue
    active="$(systemctl show "$svc" -p ActiveState --value 2>/dev/null || echo unknown)"
    sub="$(systemctl show "$svc" -p SubState --value 2>/dev/null || echo unknown)"
    result="$(systemctl show "$svc" -p Result --value 2>/dev/null || echo unknown)"
    nrestarts="$(systemctl show "$svc" -p NRestarts --value 2>/dev/null || echo 0)"
    status="$(systemctl show "$svc" -p ExecMainStatus --value 2>/dev/null || echo 0)"
    printf '%-38s ActiveState=%s SubState=%s Result=%s NRestarts=%s ExecMainStatus=%s\n' "$svc" "$active" "$sub" "$result" "$nrestarts" "$status"

    if [[ "$active" != "active" ]]; then failed=1; echo "FAIL: $svc ActiveState is $active"; fi
    if [[ "$sub" == "auto-restart" || "$sub" == "failed" ]]; then failed=1; echo "FAIL: $svc SubState is $sub"; fi
    if [[ "$result" == "exit-code" || "$result" == "signal" || "$result" == "core-dump" || "$result" == "timeout" ]]; then failed=1; echo "FAIL: $svc Result is $result"; fi
    if [[ "$status" != "0" ]]; then failed=1; echo "FAIL: $svc ExecMainStatus is $status"; fi
  done <<< "$units"

  [[ $failed -eq 0 ]] && { echo "SERVICE HEALTH RESULT: PASS"; return 0; } || { echo "SERVICE HEALTH RESULT: FAIL"; return 1; }
}

guard_watch(){
  clear_self_failed_state
  mkdirs; load_env
  local tmp failed=0 host node report update_rc=0
  host="$(hostname)"; node="$(node_id)"; tmp="$(mktemp)"

  {
    self_update || update_rc=$?
    verify || true
    baseline_verify || true
    port_audit || true
    keys_drift || true
    sshd_drift || true
    [[ "${POOLY_WATCH_WARN_UFW_DRIFT:-1}" == "1" ]] && ufw_drift || true
    services_drift || true
    service_health || true
    failed_services_check || true
    if test -f /var/run/reboot-required && [[ "${POOLY_WATCH_WARN_REBOOT:-1}" == "1" ]]; then echo "WARN: reboot required"; fi
  } | tee "$tmp"

  report="$REPORT_DIR/pooly-server-guard-watch-$host-$(date -u +%Y%m%d-%H%M%S).txt"
  cp "$tmp" "$report"
  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    chown "$REPORT_OWNER:$REPORT_OWNER" "$report" 2>/dev/null || true
  fi

  if [[ "$update_rc" != "0" ]] || grep -Eq 'UPDATE RESULT: FAIL|RESULT: FAIL|DRIFT RESULT: FAIL|PORT RESULT: FAIL|KEYS RESULT: FAIL|SERVICE RESULT: FAIL|SERVICE HEALTH RESULT: FAIL|FAILED SERVICES RESULT: FAIL|WARN: reboot required' "$tmp"; then
    failed=1
  fi

  if [[ $failed -ne 0 ]]; then
    discord_post "Pooly Server Guard FAIL on $host / node $node. Report: $report" || true
    rm -f "$tmp"
    return 1
  fi

  [[ "${POOLY_ALERT_ON_PASS:-0}" == "1" ]] && discord_post "Pooly Server Guard PASS on $host / node $node" || true
  rm -f "$tmp"; return 0
}

save_report(){ mkdirs; local f="$REPORT_DIR/pooly-server-guard-$(hostname)-$(date -u +%Y%m%d-%H%M%S).txt"; health | tee "$f"; [[ ${EUID:-$(id -u)} -eq 0 ]] && chown "$REPORT_OWNER:$REPORT_OWNER" "$f" 2>/dev/null || true; echo "Saved report: $f"; }
discord_test(){ discord_post "Pooly Server Guard Discord test from $(hostname) / node $(node_id)" && echo "Discord test sent"; }

install_timer(){
  need_sudo
  local script="$POOLY_INSTALL_PATH"
  $SUDO install -d -m 755 -o "$REPORT_OWNER" -g "$REPORT_OWNER" "$REPORT_DIR" 2>/dev/null || true
  $SUDO tee /etc/systemd/system/pooly-server-guard-watch.service >/dev/null <<EOF2
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
WorkingDirectory=$POOLY_REPO_DIR
ExecStart=$script watch
EOF2
  $SUDO tee /etc/systemd/system/pooly-server-guard-watch.timer >/dev/null <<'EOF2'
[Unit]
Description=Run Pooly Server Guard watch every 30 minutes

[Timer]
OnCalendar=*:0/30
Persistent=true

[Install]
WantedBy=timers.target
EOF2
  $SUDO systemctl daemon-reload
  $SUDO systemctl enable --now pooly-server-guard-watch.timer
  $SUDO systemctl status pooly-server-guard-watch.timer --no-pager || true
}

uninstall_timer(){ need_sudo; $SUDO systemctl disable --now pooly-server-guard-watch.timer 2>/dev/null || true; $SUDO rm -f /etc/systemd/system/pooly-server-guard-watch.{timer,service}; $SUDO systemctl daemon-reload; }

ssh_lockdown_preview(){
  section "SSH 6200 LOCKDOWN PREVIEW"
  local client_ip wg_subnets
  client_ip="$(printf '%s\n' "${SSH_CONNECTION:-}" | awk '{print $1}')"
  wg_subnets="$($SUDO wg show 2>/dev/null | awk '/allowed ips:/{sub(/^.*allowed ips: /,""); print}' | tr ',' '\n' | awk '{$1=$1;print}' | sort -u | xargs echo)"
  echo "Current SSH client IP: ${client_ip:-unknown}"
  echo "Detected WireGuard allowed IPs/subnets: ${wg_subnets:-none}"
  echo; echo "Review-only examples:"
  [[ -n "$client_ip" ]] && echo "sudo ufw allow from $client_ip to any port $SSH_PORT proto tcp comment 'SSH $SSH_PORT current admin IP'"
  echo "sudo ufw allow from <trusted_admin_or_wireguard_subnet> to any port $SSH_PORT proto tcp comment 'SSH $SSH_PORT trusted admin'"
  echo "sudo ufw status numbered"
  echo "Only delete broad $SSH_PORT/tcp allow after a new trusted-source SSH login works."
}

usage(){ cat <<HELP
Pooly Server Guard v$VERSION
Commands:
  verify | baseline-verify | health | save-report
  init-state | watch | self-update
  port-audit | keys-drift | sshd-drift | ufw-drift | services-drift | service-health | failed-services
  discord-test
  install-watch-timer | uninstall-watch-timer
  ssh-lockdown-preview

Update env:
  POOLY_GUARD_AUTO_UPDATE=1
  POOLY_REPO_DIR=$POOLY_REPO_DIR
  POOLY_INSTALL_PATH=$POOLY_INSTALL_PATH
HELP
}

cmd="${1:-help}"
case "$cmd" in
  verify) verify ;;
  baseline-verify) baseline_verify ;;
  health) health ;;
  save-report) save_report ;;
  init-state) init_state ;;
  watch) guard_watch ;;
  self-update) self_update ;;
  port-audit) port_audit ;;
  keys-drift) keys_drift ;;
  sshd-drift) sshd_drift ;;
  ufw-drift) ufw_drift ;;
  services-drift) services_drift ;;
  service-health) service_health ;;
  failed-services) failed_services_check ;;
  discord-test) discord_test ;;
  install-watch-timer) install_timer ;;
  uninstall-watch-timer) uninstall_timer ;;
  ssh-lockdown-preview) ssh_lockdown_preview ;;
  help|-h|--help|*) usage ;;
esac
