# Pooly Server Guard v0.4.2

Defensive hardening, baseline verification, drift detection, and optional Discord alerting for the 4 Pooly SSDNodes servers.

## Core checks

- SSH hardening on port 6200 only
- no port 22 listener
- root SSH disabled
- password and keyboard-interactive SSH disabled
- `AllowUsers poolyadmin pooly-sil3ntvip3r-admin`
- root `authorized_keys` empty
- active NOPASSWD sudo rule detection
- Fail2Ban sshd jail on port 6200
- Ubuntu/Pooly baseline checks
- hostname/node identification
- authorized_keys fingerprint drift detection
- sshd policy drift detection
- UFW drift detection
- Pooly service drift detection
- failed systemd service detection
- optional Discord webhook alerts

## New in v0.4.2

- Miningcore-aware port audit.
- Dynamic Miningcore/coin daemon ports can open and close quickly without failing the watch check.
- Static port drift is informational by default.
- Strict static port drift can be re-enabled with:

```bash
POOLY_PORT_STRICT_BASELINE=1
```

- The timer now uses a clear 30-minute calendar schedule:

```ini
OnCalendar=*:0/30
Persistent=true
```

- Removed the need for a separate Node003 hotfix workflow.

## GitHub install

Recommended server path:

```bash
mkdir -p ~/GPTrepos
cd ~/GPTrepos
git clone git@github.com:Sil3ntVip3r/pooly-server-guard.git
cd pooly-server-guard
bash install-local.sh
```

If the repo is already cloned:

```bash
cd ~/GPTrepos/pooly-server-guard
git pull --ff-only
bash install-local.sh
```

`install-local.sh` installs the active script to:

```text
~/GPTlogs/pooly-server-guard.sh
```

## First safe test sequence

Run on each node after installing:

```bash
~/GPTlogs/pooly-server-guard.sh verify
~/GPTlogs/pooly-server-guard.sh baseline-verify
sudo ~/GPTlogs/pooly-server-guard.sh init-state
sudo ~/GPTlogs/pooly-server-guard.sh watch
```

Expected:

```text
RESULT: PASS
BASELINE RESULT: PASS
PORT RESULT: PASS
KEYS RESULT: PASS
SSHD DRIFT RESULT: PASS
UFW DRIFT RESULT: PASS
SERVICE RESULT: PASS
```

## Discord setup

Create/edit:

```bash
sudo nano /etc/pooly/server-guard.env
```

Set:

```bash
POOLY_DISCORD_ENABLED=1
POOLY_DISCORD_WEBHOOK="https://discord.com/api/webhooks/..."
POOLY_ALERT_ON_PASS=0
POOLY_WATCH_WARN_UPDATES=0
POOLY_WATCH_WARN_REBOOT=1
POOLY_WATCH_WARN_UFW_DRIFT=1
```

Lock down permissions:

```bash
sudo chown root:sudo /etc/pooly/server-guard.env
sudo chmod 640 /etc/pooly/server-guard.env
```

Test:

```bash
sudo ~/GPTlogs/pooly-server-guard.sh discord-test
```

## Enable scheduled checks

Only after manual `watch` passes:

```bash
sudo ~/GPTlogs/pooly-server-guard.sh install-watch-timer
systemctl list-timers --all | grep pooly-server-guard
sudo systemctl status pooly-server-guard-watch.timer --no-pager
```

Disable:

```bash
sudo ~/GPTlogs/pooly-server-guard.sh uninstall-watch-timer
```

## SSH lockdown preview

This does not change firewall rules. It only prints commands to review:

```bash
sudo ~/GPTlogs/pooly-server-guard.sh ssh-lockdown-preview
```

Do not remove the broad SSH 6200 UFW rule until a new trusted-source SSH login has been tested.
