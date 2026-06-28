# Pooly Server Guard v0.5.0-alpha1

Defensive hardening, baseline verification, drift detection, self-updating scheduled checks, Discord alerting, and non-destructive server health monitoring for the 4 Pooly SSDNodes servers.

## Current release

Current release: `v0.5.0-alpha1`.

## Stage 1 health monitoring

This release adds server health monitoring without any automatic cleanup.

New command:

```bash
sudo ~/GPTlogs/pooly-server-guard.sh server-health
```

New watch output:

```text
POOLY SERVER HEALTH
SERVER HEALTH RESULT: PASS/WARN/FAIL
WATCH RESULT: PASS/WARN/FAIL
```

Health checks:

- disk usage
- inode usage
- RAM pressure
- swap usage
- load per CPU
- uptime
- reboot-required flag
- journal size
- GPTlogs/report folder size

Configurable defaults:

```bash
POOLY_ALERT_ON_WARN=1
POOLY_DISK_WARN_PCT=80
POOLY_DISK_FAIL_PCT=90
POOLY_INODE_WARN_PCT=80
POOLY_INODE_FAIL_PCT=90
POOLY_RAM_WARN_PCT=85
POOLY_RAM_FAIL_PCT=95
POOLY_SWAP_WARN_PCT=20
POOLY_SWAP_FAIL_PCT=50
POOLY_LOAD_WARN_PER_CPU=2
POOLY_LOAD_FAIL_PER_CPU=4
POOLY_JOURNAL_WARN_MB=5120
POOLY_JOURNAL_FAIL_MB=10240
POOLY_GPTLOGS_WARN_MB=1024
POOLY_GPTLOGS_FAIL_MB=2048
```

## Discord behavior

`PASS` means security, drift, service, and server-health checks are clean.

`WARN` means an early-warning health condition needs attention, but no critical security/service failure was detected. WARN exits cleanly so systemd does not mark the guard service as failed.

`FAIL` means a security, service, or critical health check failed. FAIL exits non-zero and sends a failure alert.

## Stage 2 plan

After Stage 1 runs overnight, Stage 2 will add guarded cleanup for Pooly Server Guard's own report files only.
