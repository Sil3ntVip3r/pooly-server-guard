# Pooly Server Guard v0.4.3

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
- failed systemd service detection
- self-update check from the local GitHub clone during scheduled `watch`
- stable report path for root/systemd timer runs
- optional Discord webhook alerts

## New in v0.4.3

### Self-updating scheduled checks

`watch` now runs a GitHub update check before the normal guard checks.

By default it uses:

```bash
POOLY_GUARD_AUTO_UPDATE=1
POOLY_GUARD_AUTO_UPDATE_BRANCH=main
POOLY_REPO_DIR=/home/pooly-sil3ntvip3r-admin/GPTrepos/pooly-server-guard
POOLY_INSTALL_PATH=/home/pooly-sil3ntvip3r-admin/GPTlogs/pooly-server-guard.sh
```

If the local repo is behind `origin/main`, the scheduled run fetches, resets to the latest `main`, and refreshes the installed script.

Run manually:

```bash
sudo ~/GPTlogs/pooly-server-guard.sh self-update
```

### Service health catches auto-restart loops

`systemctl --failed` does not catch every broken service. During the Node002/Node003/Node004 cleanup, `coin-kerrigan.service` and `coin-neoxa.service` could be stuck in:

```text
ActiveState=activating
SubState=auto-restart
Result=exit-code
```

v0.4.3 adds `service-health` and includes it in `watch`, so auto-restart loops now fail the guard check.

Run manually:

```bash
sudo ~/GPTlogs/pooly-server-guard.sh service-health
```

### Stable report location

Timer runs execute as root, but reports now stay under the admin user path by default:

```text
/home/pooly-sil3ntvip3r-admin/GPTlogs
```

The timer unit sets:

```ini
Environment=REPORT_OWNER=pooly-sil3ntvip3r-admin
Environment=REPORT_DIR=/home/pooly-sil3ntvip3r-admin/GPTlogs
Environment=POOLY_REPO_DIR=/home/pooly-sil3ntvip3r-admin/GPTrepos/pooly-server-guard
Environment=POOLY_INSTALL_PATH=/home/pooly-sil3ntvip3r-admin/GPTlogs/pooly-server-guard.sh
```

## Recovery notes learned from rollout

See:

```text
docs/POOLY_NODE_RECOVERY_NOTES.md
```

That file documents:

- Kerrigan Plan-X / sapling cache corruption
- Kerrigan `-resetchainstate` recovery
- Neoxa zero-byte/bad `sporks.dat` recovery
- why `systemctl --failed` is not enough
- final all-node timer proof workflow

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
UPDATE RESULT: PASS
RESULT: PASS
BASELINE RESULT: PASS
PORT RESULT: PASS
KEYS RESULT: PASS
SSHD DRIFT RESULT: PASS
UFW DRIFT RESULT: PASS
SERVICE RESULT: PASS
SERVICE HEALTH RESULT: PASS
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
