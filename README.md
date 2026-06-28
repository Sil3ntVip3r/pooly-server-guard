# Pooly Server Guard v0.4.9

Defensive hardening, baseline verification, drift detection, self-updating scheduled checks, and optional Discord alerting for the 4 Pooly SSDNodes servers.

## Current stable release

Current stable release: v0.4.9.

## Approved next staged rollout

Stage 1 will add non-destructive server health monitoring only. It should monitor disk, inodes, RAM, swap, load, uptime, reboot-required state, journal size, and GPTlogs size. It should also add PASS/WARN/FAIL Discord summaries.

Stage 2 will add safe Pooly Server Guard report pruning after Stage 1 runs overnight and the health output is proven stable.
