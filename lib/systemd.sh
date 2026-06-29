#!/usr/bin/env bash

install_timer(){
  need_sudo; local script="$POOLY_INSTALL_PATH"; load_env; health_defaults
  $SUDO install -d -m 755 -o "$REPORT_OWNER" -g "$REPORT_OWNER" "$REPORT_DIR" 2>/dev/null || true
  $SUDO tee /etc/systemd/system/pooly-server-guard-watch.service >/dev/null <<EOF2
[Unit]
Description=Pooly Server Guard watch check
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=root
TimeoutStartSec=120
KillMode=control-group
PrivateTmp=true
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
  $SUDO systemctl daemon-reload
  $SUDO systemctl enable --now pooly-server-guard-watch.timer
  $SUDO systemctl restart pooly-server-guard-watch.timer
  $SUDO systemctl status pooly-server-guard-watch.timer --no-pager || true
}

uninstall_timer(){ need_sudo; $SUDO systemctl disable --now pooly-server-guard-watch.timer 2>/dev/null || true; $SUDO systemctl daemon-reload; }
