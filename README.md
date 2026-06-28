# Pooly Server Guard v0.4.9

Defensive hardening, baseline verification, drift detection, self-updating scheduled checks, and optional Discord alerting for the 4 Pooly SSDNodes servers.

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
- Pooly service health detection, including `activating auto-restart`
- failed systemd service detection with `FAILED SERVICES RESULT`
- self-update check from the local GitHub clone during scheduled `watch`
- root-safe GitHub self-update using the admin user's SSH deploy-key config
- stable report path for root/systemd timer runs
- configurable systemd timer cadence
- optional Discord webhook alerts

## New in v0.4.9

v0.4.9 makes Discord alerts more useful for moderators and anyone watching the server-guard channel.

Old alert style:

```text
Pooly Server Guard PASS on pooly-ssdnodes-001-toronto / node 001
```

New PASS alert style includes:

```text
[POOLY SERVER GUARD PASS]
Node: 001
Host: pooly-ssdnodes-001-toronto
Version: v0.4.9
Timer: *:0/10
Time: 2026-06-28 03:40:00 UTC

What this is: automated Pooly server security + health watchdog.
Meaning: All automated security, config drift, service health, and failed-service checks completed successfully.

Checks covered:
- SSH hardening and admin access
- Ubuntu/server baseline
- authorized_keys, sshd policy, and UFW drift
- Pooly/mining services and failed systemd units
- GitHub self-update check

Results:
- UPDATE RESULT: PASS
- RESULT: PASS
- BASELINE RESULT: PASS
- PORT RESULT: PASS
- KEYS RESULT: PASS
- SSHD DRIFT RESULT: PASS
- UFW DRIFT RESULT: PASS
- SERVICE RESULT: PASS
- SERVICE HEALTH RESULT: PASS
- FAILED SERVICES RESULT: PASS

Report: /home/pooly-sil3ntvip3r-admin/GPTlogs/...
```

FAIL alerts include the same context plus a short failure summary and action guidance.

## New in v0.4.8

v0.4.8 changes the default scheduled watch timer from every 30 minutes to every 10 minutes for live flow testing and faster GitHub self-update pickup while actively fixing the guard.

Default timer:

```text
OnCalendar=*:0/10
```

The timer cadence is configurable with:

```bash
POOLY_WATCH_ONCALENDAR="*:0/10"
```

To later go back to 30 minutes:

```bash
POOLY_WATCH_ONCALENDAR="*:0/30"
sudo ~/GPTlogs/pooly-server-guard.sh install-watch-timer
```

## Recent fixes

### v0.4.7

Fixed `AllowUsers` parsing when sshd reports the effective policy across multiple `allowusers` lines. The verifier now checks each allowed admin user as an exact token with `awk`.

### v0.4.6

Fixed a false SSH `AllowUsers` failure caused by `echo "$sshdT" | grep -q ...` under `set -o pipefail`.

### v0.4.5

Added `failed-services`, `FAILED SERVICES RESULT: PASS/FAIL`, and cleanup for stale `pooly-server-guard-watch.service` failed state.

### v0.4.4

Fixed root/systemd self-update Git operations by running Git as `REPORT_OWNER` so each node can use the admin user's deploy-key SSH config.

### v0.4.3

Added `self-update`, automatic update checks during `watch`, `service-health`, auto-restart detection, and stable root/systemd report paths.

## GitHub install/update

Recommended server path:

```bash
mkdir -p ~/GPTrepos
cd ~/GPTrepos
git clone git@github.com:Sil3ntVip3r/pooly-server-guard.git
cd pooly-server-guard
bash install-local.sh
```

If already cloned:

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

```bash
~/GPTlogs/pooly-server-guard.sh verify
~/GPTlogs/pooly-server-guard.sh baseline-verify
sudo ~/GPTlogs/pooly-server-guard.sh init-state
sudo ~/GPTlogs/pooly-server-guard.sh watch
```

Expected:

```text
UPDATE RESULT: PASS
RESULT: PASS
BASELINE RESULT: PASS
PORT RESULT: PASS
KEYS RESULT: PASS
SSHD DRIFT RESULT: PASS
UFW DRIFT RESULT: PASS
SERVICE RESULT: PASS
SERVICE HEALTH RESULT: PASS
FAILED SERVICES RESULT: PASS
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
POOLY_WATCH_ONCALENDAR="*:0/10"
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

```bash
sudo ~/GPTlogs/pooly-server-guard.sh ssh-lockdown-preview
```

Do not remove the broad SSH 6200 UFW rule until a new trusted-source SSH login has been tested.
