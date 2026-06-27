# Changelog

## v0.4.2

### Changed

- Made `port-audit` Miningcore-aware.
- Dynamic Miningcore/coin daemon port changes are now informational by default instead of failing `watch`.
- Added `POOLY_PORT_STRICT_BASELINE=1` for optional strict static port drift checks.
- Changed the watch timer to a clear calendar schedule:
  - `OnCalendar=*:0/30`
  - `Persistent=true`
- Removed the need for the Node003 hotfix workflow.

### Still fails on

- SSH port 22 returning.
- SSH port 6200 disappearing.
- root SSH login being re-enabled.
- password or keyboard-interactive SSH being re-enabled.
- approved admin users drifting from sshd policy.
- root `authorized_keys` gaining active keys.
- active NOPASSWD sudo rules returning.
- Fail2Ban stopping.
- approved SSH key fingerprints changing.
- UFW rule drift.
- Pooly service drift.
- failed systemd services.

## v0.4.1

### Fixed

- Fixed `diff_state` unbound variable failure during `watch`.

## v0.4.0

### Added

- Discord webhook alert support.
- `watch` mode.
- baseline state capture with `init-state`.
- port drift detection.
- authorized_keys drift detection.
- sshd policy drift detection.
- UFW drift detection.
- Pooly service drift detection.
- systemd timer install/uninstall commands.
- SSH lockdown preview command.
