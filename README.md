# Pooly Server Guard v0.5.0-alpha4.1.0

Defensive hardening, baseline verification, drift detection, self-updating scheduled checks, Discord alerting, report pruning, non-destructive server health monitoring, and observe-only memory-balloon detection for the 4 Pooly SSDNodes servers.

## Current release

Current release: `v0.5.0-alpha4.1.0`.

## Purpose

Pooly Server Guard checks that each node remains close to the known-good hardened baseline. It reports security drift, service drift, server-health warnings, failed systemd units, journal growth, host-driven memory balloon activity, and Discord alert delivery status.

## Current features

- SSH/security baseline verification
- service drift detection
- failed systemd unit detection
- server-health checks
- safe report pruning for Pooly Server Guard reports only
- memory pressure evidence capture
- observe-only virtio memory-balloon detection and bounded history
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
sudo ~/GPTlogs/pooly-server-guard.sh balloon-status
sudo ~/GPTlogs/pooly-server-guard.sh balloon-history 50
sudo ~/GPTlogs/pooly-server-guard.sh journal-growth
sudo ~/GPTlogs/pooly-server-guard.sh timer-status
sudo ~/GPTlogs/pooly-server-guard.sh report-prune
sudo ~/GPTlogs/pooly-server-guard.sh install-watch-timer
```

## Memory-balloon monitoring

Phase 1 is intentionally observe-only and disabled by default:

```bash
POOLY_BALLOON_MONITOR_ENABLED=0
POOLY_BALLOON_WARN_MIB=1024
POOLY_BALLOON_HISTORY_MAX_LINES=10000
POOLY_BALLOON_LOCK_WAIT_SECONDS=2
```

When enabled, the guard reads cumulative Linux balloon, swap, major-fault, OOM, memory, and PSI counters. It stores an atomic protected baseline under `/etc/pooly/server-guard-state/balloon/` and reports transitions such as:

```text
BASELINE
IDLE
ACTIVE
ACTIVE_CONTINUING
CYCLE_ACTIVE
CYCLE_COMPLETED
DEFLATING
RECOVERED
COUNTER_RESET
STATE_RESET
OOM_OBSERVED
ERROR
```

Balloon warnings are transition-based to avoid repeated Discord alerts during one event. A `CYCLE_ACTIVE` warning means one or more complete inflate/deflate cycles occurred between checks and significant ballooning was active again at sampling time. Existing RAM and swap thresholds continue to determine overall server-health severity.

Only the scheduled/manual `watch` command advances balloon alert state. `balloon-status`, `health`, and `save-report` collect read-only samples, so a diagnostic command cannot consume a transition before the next scheduled Discord alert.

Balloon history is event-focused. Ordinary idle swap-in and page-fault movement updates the current baseline but does not append history unless balloon activity or an OOM transition provides relevant context.

Phase 1 does **not** run `swapoff`/`swapon`, change kernel settings, stop or restart services, kill processes, reboot the server, or add a second daemon. Remediation belongs to a later separately approved phase.

## Discord behavior

`PASS` means security, drift, service, and server-health checks are clean.

`WARN` means an early-warning health condition needs attention, but no critical security/service failure was detected. WARN exits cleanly so systemd does not mark the guard service as failed.

`FAIL` means a security, service, or critical health check failed. FAIL exits non-zero and sends a failure alert.

PASS Discord messages are intentionally compact and may use Discord's silent notification flag when `POOLY_DISCORD_SUPPRESS_PASS=1`.

The webhook URL is supplied to `curl` through protected standard input rather than as a process argument. This prevents ordinary process snapshots and `/proc/<pid>/cmdline` collection from exposing the webhook token. A webhook captured by an older release must still be revoked and replaced; changing transport does not invalidate an already exposed credential.

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

## Important alpha4.1.0 changes

- Added optional `lib/balloon.sh` observe-only monitoring.
- Added `balloon-status` and `balloon-history` commands.
- Added transition-based balloon WARN reporting to watch reports and Discord embeds.
- Detects complete cycles even when a later inflation is active at the next sample.
- Keeps manual status and health commands read-only so they cannot consume scheduled alert transitions.
- Keeps balloon history focused on balloon/OOM events instead of ordinary idle page-fault noise.
- Added atomic, validated, bounded balloon state under the existing protected state directory.
- Isolated the optional balloon module in a subshell so module failures cannot abort remaining watch checks.
- Kept the balloon module optional so rollback to Alpha4.0.1 remains possible after the feature branch removes it.
- Prevented Discord webhook URLs from appearing in `curl` process arguments.
- Added fixture, rollback, Discord, webhook-transport, fault-isolation, syntax, and ShellCheck CI coverage.
- Kept balloon monitoring disabled by default.

## Important alpha4.0 changes

- Removed the runtime `git show` core-overlay loader.
- Split the guard into `lib/*.sh` modules.
- Added syntax validation for self-update before installing a new script.
- Added hardened env-file ownership and permission checks.
- Fixed journal shrink handling so journal cleanup does not create false growth WARN/FAIL alerts.
- Added `TimeoutStartSec=120` to the systemd service.
