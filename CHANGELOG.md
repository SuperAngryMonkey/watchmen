# Changelog

## v0.2.0 — 2026-04-25 — First successful field deployment

First end-to-end working deployment on APCpi (Raspberry Pi 3B, Pi OS Lite Bookworm)
talking to a Back-UPS XS 1500G via USB-HID. Live data flowing from UPS through
apcupsd → MQTT → WebSocket → browser dashboard.

### Bugs fixed during deployment

- **install.sh path resolution.** `HERE="$(dirname "$0")/.."` resolved to one
  directory above the project root, breaking every `install -m` call.
  Fixed: `HERE="$(dirname "$0")"`.
- **apcupsd config v1.1 magic line.** apcupsd 3.14.14 emits a warning when
  the first line of a config file isn't `## apcupsd.conf v1.1 ##`. Now baked
  into all `apcupsd-labN.conf` files.
- **LOCKFILE path.** Was set to `/var/lock/apcupsd-labN` which apcupsd
  interpreted as a directory and then failed to write inside. Changed to
  `/var/lock` (apcupsd creates `LCK..apcupsd-labN` inside it).
- **systemd unit Type.** `Type=forking` with `PIDFile=` had timing issues —
  apcupsd would fork, exit cleanly, but systemd couldn't find the PID file
  before its timeout. Switched to `Type=simple` with `apcupsd -b` (foreground
  flag). Robust on all tested kernels.
- **Bridge default targets.** Originally polled all four lab instances by
  default, generating `Connection refused` errors for slots that don't have
  a UPS. Now defaults to `lab1` only; users add more via `systemctl edit`.
- **Conflicts directive on @ unit.** Default `apcupsd.service` (the
  Debian-package single-UPS unit) needs a hard conflict with the @ instances
  to prevent it from being unmasked or auto-started during package upgrades.

### Deployment tested against

- Raspberry Pi 3B with Pi OS Lite Bookworm, kernel 6.x
- apcupsd 3.14.14 (Debian Trixie package)
- mosquitto 2.0.21
- python3-paho-mqtt 2.1.0
- Back-UPS XS 1500G (FW 866.L8.D, USB FW L8, USB-HID via 940-0127B cable)

### Fields confirmed populated by Back-UPS XS 1500G

`MODEL`, `SERIALNO`, `FIRMWARE`, `STATUS`, `LINEV`, `LOADPCT`, `BCHARGE`,
`TIMELEFT`, `BATTV`, `NOMINV`, `NOMBATTV`, `NOMPOWER`, `LOTRANS`, `HITRANS`,
`SENSE`, `MBATTCHG`, `MINTIMEL`, `MAXTIME`, `LASTXFER`, `NUMXFERS`, `TONBATT`,
`CUMONBATT`, `XOFFBATT`, `SELFTEST`, `STATFLAG`, `BATTDATE`, `ALARMDEL`.

Better field coverage than predicted — `NOMPOWER` and `BATTV` both present.

### Known minor issues

- `apc-mqtt-bridge.service` runs as `nobody` user — systemd warns
  "Special user nobody configured, this is not safe!" Functional but should
  be moved to a dedicated `gorilla` system user in v0.3.

### Next steps tracked

- Phase 2: RS-232 / GPIO UART support
- Phase 3: ChirpStack MQTT broker integration over Tailscale
- Phase 4: RAK4631 + LoRaWAN node variant
- Phase 5: SQLite history logger for 24h sparkline backfill

## v0.1.0 — 2026-04-23 — Initial drop

Initial project scaffold:
- 4x apcupsd instances per Pi (NIS ports 3551-3554)
- Python MQTT bridge (native NIS protocol, no apcaccess subprocess)
- Mosquitto with WebSocket listener on 9001
- GORILLA dashboard (Monkey Theme, single-page HTML)
- udev rules for serial-pinning UPSs
- find-apc-serials and characterize.sh helper scripts
- One-shot install.sh and remote deploy.sh
