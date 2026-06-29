# Pooly Server Guard v0.5.0-alpha4.0

Defensive hardening, baseline verification, drift detection, self-updating scheduled checks, Discord alerting, report pruning, and non-destructive server health monitoring for the 4 Pooly SSDNodes servers.

## Current release

Current release: `v0.5.0-alpha4.0`.

## Purpose

Pooly Server Guard checks that each node remains close to the known-good hardened baseline. It reports security drift, service drift, server-health warnings, failed systemd units, journal growth, and Discord alert delivery status.

## Current features

- SSH/security baseline verification
- service drift detection
- failed systemd unit detection
- server-health checks
- safe report pruning for Pooly Server Guard reports only
- memory pressure evidence capture
- CPU/load evidence capture
- Discord webhook embed alerts
- journal growth visibility
- timer mode visibility
- run-lock/no-overlap protection
- validated self-update before install
- modular `lib/*.sh` architecture

## Commands

```bash
sudo ~/GPTlogs/pooly-server-guard.sh watch
sudo ~/GPTlogs/pooly-server-guard.sh server-health
sudo ~/GPTlogs/pooly-server-guard.sh journal-growth
sudo ~/GPTlogs/pooly-server-guard.sh timer-status
sudo ~/GPTlogs/pooly-server-guard.sh report-prune
sudo ~/GPTlogs/pooly-server-guard.sh install-watch-timer
```

## Discord behavior

`PASS` means security, drift, service, and server-health checks are clean.

`WARN` means an early-warning health condition needs attention, but no critical security/service failure was detected. WARN exits cleanly so systemd does not mark the guard service as failed.

`FAIL` means a security, service, or critical health check failed. FAIL exits non-zero and sends a failure alert.

PASS Discord messages are intentionally compact and may use Discord's silent notification flag when `POOLY_DISCORD_SUPPRESS_PASS=1`.

## Timer behavior

The active timer is controlled by:

```bash
POOLY_WATCH_ONCALENDAR="*:0/2"
```

The recommended production value is:

```bash
POOLY_WATCH_ONCALENDAR="*:0/10"
```

During active alpha testing, the 2-minute timer is useful for fast feedback.

## Important alpha4.0 changes

- Removed the runtime `git show` core-overlay loader.
- Split the guard into `lib/*.sh` modules.
- Added syntax validation for self-update before installing a new script.
- Added hardened env-file ownership and permission checks.
- Fixed journal shrink handling so journal cleanup does not create false growth WARN/FAIL alerts.
- Added `TimeoutStartSec=120` to the systemd service.
