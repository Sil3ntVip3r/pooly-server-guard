#!/usr/bin/env bash

node_id(){ local h ip; h="$(hostname 2>/dev/null || true)"; ip="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+\.' | head -1 || true)"; case "$h $ip" in *001*toronto*|*104.225.219.167*) echo 001 ;; *002*mumbai*|*209.182.232.151*) echo 002 ;; *003*tokyo2*|*63.250.52.172*) echo 003 ;; *004*frankfurt*|*208.87.129.34*) echo 004 ;; *) echo unknown ;; esac; }
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
  section "POOLY BASELINE VERIFY"; local failed=0 swapgb filemax swappiness qdisc cc
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

init_state(){ need_sudo; $SUDO install -d -m 700 "$POOLY_STATE_DIR"; current_ports | $SUDO tee "$POOLY_STATE_DIR/ports.txt" >/dev/null; key_fingerprints | $SUDO tee "$POOLY_STATE_DIR/keys.txt" >/dev/null; sshd_policy | $SUDO tee "$POOLY_STATE_DIR/sshd.txt" >/dev/null; ufw_rules | $SUDO tee "$POOLY_STATE_DIR/ufw.txt" >/dev/null; current_services | $SUDO tee "$POOLY_STATE_DIR/services.txt" >/dev/null; echo "$VERSION" | $SUDO tee "$POOLY_STATE_DIR/guard-version.txt" >/dev/null; echo "Saved known-good state in $POOLY_STATE_DIR"; }
diff_state(){ local state_name state_cmd state_file tmp rc; state_name="${1:?missing state name}"; state_cmd="${2:?missing state command}"; state_file="$POOLY_STATE_DIR/$state_name.txt"; tmp="$(mktemp)"; $state_cmd > "$tmp"; if ! $SUDO test -f "$state_file"; then echo "WARN: missing baseline $state_file; run init-state"; rm -f "$tmp"; return 2; fi; diff -u <($SUDO cat "$state_file") "$tmp"; rc=$?; rm -f "$tmp"; return "$rc"; }
port_audit(){ section "PORT AUDIT"; local failed=0; echo "INFO: Miningcore and coin daemon ports can open and close quickly. Static port drift is informational unless strict mode is enabled."; if ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Eq ':(22)$'; then echo "FAIL: port 22 listener found"; failed=1; fi; if [[ "$POOLY_PORT_STRICT_BASELINE" == "1" ]]; then diff_state ports current_ports && echo "STATIC PORT RESULT: PASS" || { echo "STATIC PORT RESULT: FAIL"; failed=1; }; else if ! diff_state ports current_ports; then echo "INFO: dynamic port drift detected but not failing."; else echo "STATIC PORT RESULT: PASS"; fi; fi; [[ $failed -eq 0 ]] && { echo "PORT RESULT: PASS"; return 0; } || { echo "PORT RESULT: FAIL"; return 1; }; }
keys_drift(){ section "AUTHORIZED_KEYS DRIFT"; diff_state keys key_fingerprints && echo "KEYS RESULT: PASS" || { echo "KEYS RESULT: FAIL"; return 1; }; }
sshd_drift(){ section "SSHD POLICY DRIFT"; diff_state sshd sshd_policy && echo "SSHD DRIFT RESULT: PASS" || { echo "SSHD DRIFT RESULT: FAIL"; return 1; }; }
ufw_drift(){ section "UFW DRIFT"; diff_state ufw ufw_rules && echo "UFW DRIFT RESULT: PASS" || { echo "UFW DRIFT RESULT: FAIL"; return 1; }; }
services_drift(){ section "POOLY SERVICE DRIFT"; diff_state services current_services && echo "SERVICE RESULT: PASS" || { echo "SERVICE RESULT: FAIL"; return 1; }; }

service_health(){ section "POOLY SERVICE HEALTH"; local failed=0 svc active sub result nrestarts status units; units="$( { pooly_units_all; baseline_services; } | sort -u )"; if [[ -z "$units" ]]; then echo "WARN: no Pooly services found to check"; echo "SERVICE HEALTH RESULT: FAIL"; return 1; fi; while read -r svc; do [[ -n "$svc" ]] || continue; active="$(systemctl show "$svc" -p ActiveState --value 2>/dev/null || echo unknown)"; sub="$(systemctl show "$svc" -p SubState --value 2>/dev/null || echo unknown)"; result="$(systemctl show "$svc" -p Result --value 2>/dev/null || echo unknown)"; nrestarts="$(systemctl show "$svc" -p NRestarts --value 2>/dev/null || echo 0)"; status="$(systemctl show "$svc" -p ExecMainStatus --value 2>/dev/null || echo 0)"; printf '%-38s ActiveState=%s SubState=%s Result=%s NRestarts=%s ExecMainStatus=%s\n' "$svc" "$active" "$sub" "$result" "$nrestarts" "$status"; if [[ "$active" != "active" ]]; then failed=1; echo "FAIL: $svc ActiveState is $active"; fi; if [[ "$sub" == "auto-restart" || "$sub" == "failed" ]]; then failed=1; echo "FAIL: $svc SubState is $sub"; fi; if [[ "$result" == "exit-code" || "$result" == "signal" || "$result" == "core-dump" || "$result" == "timeout" ]]; then failed=1; echo "FAIL: $svc Result is $result"; fi; if [[ "$status" != "0" ]]; then failed=1; echo "FAIL: $svc ExecMainStatus is $status"; fi; done <<< "$units"; [[ $failed -eq 0 ]] && { echo "SERVICE HEALTH RESULT: PASS"; return 0; } || { echo "SERVICE HEALTH RESULT: FAIL"; return 1; }; }
failed_services_check(){ section "FAILED SERVICES"; clear_self_failed_state; local out; out="$(systemctl --failed --no-pager 2>/dev/null || true)"; printf '%s\n' "$out"; if printf '%s\n' "$out" | grep -Eq '^●[[:space:]]+'; then echo "FAILED SERVICES RESULT: FAIL"; return 1; fi; echo "FAILED SERVICES RESULT: PASS"; return 0; }
