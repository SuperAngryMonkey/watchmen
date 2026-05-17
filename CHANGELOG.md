# Changelog

## v0.2.4 — 2026-05-17 — Surface NOBATT / REPLACEBATT / OVERLOAD

The dashboard was silently dropping critical status modifiers. A UPS
reporting `ONLINE NOBATT` was being rendered as a healthy green
"ONLINE" badge — hiding the fact that the UPS would not actually
provide backup power when mains fails.

Caught in the field when adding a second UPS (a Back-UPS ES 600G with
a dead battery) to a working watchmen deployment. The user explicitly
said he wanted watchmen working so he could detect a dead battery. The
dashboard's first job is to surface conditions that make the UPS
useless. Silent fall-through to "ONLINE" was the worst possible failure
mode.

### What changed

Status badge priority is now (highest first):

| Status flag | Badge | Color |
|---|---|---|
| `COMMLOST` | COMM LOST | red |
| `LOWBATT` | LOW BATTERY | red |
| `NOBATT` | NO BATTERY | **red (new)** |
| `REPLACEBATT` | REPLACE BATTERY | **red (new)** |
| `OVERLOAD` | OVERLOAD | **red (new)** |
| `ONBATT` | ON BATTERY | amber |
| `ONLINE` | ONLINE | green |

Fleet summary counter (top of dashboard) updated to count any of the
red-badge conditions as "alert" instead of "online."

### New simulator commands

```
sim lab1 nobatt
sim lab1 replacebatt
sim lab1 overload
```

For testing the new badges without unplugging hardware.

### Why this matters

A UPS reporting NOBATT is broadcasting its own uselessness. Same for
REPLACEBATT (battery so degraded it needs replacement) and OVERLOAD
(load exceeds capacity, will trip when on battery). These are exactly
the conditions a monitoring dashboard exists to detect. Surfacing them
in the same red-alert prominence as COMMLOST is the right shape.

## v0.2.3 — 2026-05-02 — Config page (gear icon)

A gear icon in the dashboard header now opens a config modal where you can
edit settings without SSHing in.

### What's new

- **Gear icon** top-right of header, next to the clock
- **Modal opens** with form fields for the configurable settings:
  - Client name and site/location
  - MQTT broker host and WebSocket port
  - Topic prefix
  - Stale threshold (seconds)
- **Settings persist in browser localStorage** under `watchmen.config.v1`
- **Each browser remembers its own settings** — your Mac saves them once,
  future visits load them automatically
- **Reset button** clears everything back to install-time defaults
- **Modal closes** on Save, Cancel, ESC key, or click outside the panel
- **Save reloads the page** so broker/topic changes take effect cleanly

### Resolution order

For any single setting, watchmen now checks (highest priority first):

1. **localStorage** — saved via gear icon
2. **Query string** — `?broker=foo&client=bar` for one-off testing
3. **HTML install-time values** — `__CLIENT_NAME__` replaced by `install.sh`
4. **Hardcoded defaults**

This means you can override per-browser without touching the install, and
override per-visit without touching localStorage. Three independent layers.

### Why localStorage instead of server-side

This is the v1 shape: per-browser state, no backend, no auth, no new service.
The watchmen-web HTTP server stays a static-file server. When you eventually
need fleet-wide shared settings (different operators seeing the same client
label) or an audit trail, the storage layer can swap to a server-side JSON
file or MQTT retained topic — the UI doesn't change.

### Backward compatibility

Existing deployments keep working unchanged. localStorage starts empty, so
on first load the dashboard falls through to the install-time HTML values
(or defaults if those weren't substituted). No migration needed.

## v0.2.2 — 2026-05-02 — Client and site labels in dashboard header

When you start deploying watchmen to multiple sites, looking at "WATCHMEN"
on every dashboard tells you nothing about *which* deployment you're looking
at. This release adds configurable client and site labels in the header.

### What's new

- Dashboard header now shows `WATCHMEN // Power Monitor // <client name>`
  with the site/location underneath, replacing the generic "APC UPS Fleet //
  Lab" placeholder
- Browser tab title updates to `WATCHMEN // <client name>` so you can find
  the right tab when juggling multiple deployments
- Three ways to set the labels:
  1. **Interactive prompt during `./install.sh`** — the installer asks for
     client and site names and bakes them in
  2. **Environment variables during install** — set `WATCHMEN_CLIENT` and
     `WATCHMEN_SITE` for non-interactive deploys
  3. **Query string** at view time — `?client=Acme&site=Rack%202` overrides
     for one-off testing
- New helper script `watchmen-set-client` lets you change labels on a
  deployed dashboard without reinstalling:
  ```
  sudo watchmen-set-client "Pat Gallager" "Surfside 6H"
  ```

### Why this matters

Visual identification of deployment context is the difference between
"which dashboard is this?" and "this is clearly Acme's." When you eventually
have five customers and your own house all running watchmen, the header
label is the first thing your eye lands on.

### Backward compatibility

Existing deployments keep working unchanged — the JS gracefully handles the
case where the placeholders weren't substituted (falls back to "APC UPS
Fleet" and `location.hostname`).

## v0.2.1 — 2026-04-25 — Renamed to `watchmen`

Rebranded from `gorilla-power` to `watchmen`. Functionally identical to v0.2.0;
just a name change.

### What changed

- Repo name: `gorilla-power` → `watchmen`
- Dashboard wordmark: `GORILLA` → `WATCHMEN`
- Web service: `gorilla-web.service` → `watchmen-web.service`
- Install path: `/var/lib/gorilla-web/` → `/var/lib/watchmen-web/`
- Browser tab title and JS client ID updated to match

### Migrating an existing v0.2.0 deployment

For Pis already running the old service names:

```bash
# Stop and disable the old service
sudo systemctl disable --now gorilla-web

# Re-run the installer (idempotent, drops in new units and paths)
sudo ./install.sh

# Enable the renamed service
sudo systemctl enable --now watchmen-web

# Optional cleanup of the old install dir
sudo rm -rf /var/lib/gorilla-web /etc/systemd/system/gorilla-web.service
sudo systemctl daemon-reload
```

The `apc-mqtt-bridge` and `apcupsd@labN` services are unchanged.

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
  be moved to a dedicated `watchmen` system user in v0.3.

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
- WATCHMEN dashboard (Monkey Theme, single-page HTML)
- udev rules for serial-pinning UPSs
- find-apc-serials and characterize.sh helper scripts
- One-shot install.sh and remote deploy.sh
