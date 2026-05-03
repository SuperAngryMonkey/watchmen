# watchmen

> *"Quis custodiet ipsos custodes?"*

Multi-UPS monitoring stack for Raspberry Pi. Reads APC UPSs over USB-HID,
publishes telemetry to MQTT, renders a live ops-grade dashboard in the
browser. Designed as both a lab characterization bench and the foundation
for customer-site UPS monitoring deployments.

---

## Table of contents

- [What it does](#what-it-does)
- [Architecture](#architecture)
- [Hardware](#hardware)
- [Software stack](#software-stack)
- [Quick start](#quick-start)
- [Remote deployment](#remote-deployment)
- [Configuration](#configuration)
- [The dashboard](#the-dashboard)
- [MQTT topic schema](#mqtt-topic-schema)
- [Per-model field characterization](#per-model-field-characterization)
- [Operations and maintenance](#operations-and-maintenance)
- [Troubleshooting](#troubleshooting)
- [Repository layout](#repository-layout)
- [Design choices](#design-choices)
- [Roadmap](#roadmap)
- [Contributing](#contributing)
- [License](#license)

---

## What it does

- Monitors **up to 4 APC UPSs per Pi** via USB-HID (more with a powered hub)
- Each UPS gets its own `apcupsd` instance, pinned by serial number via udev
- A native MQTT bridge publishes per-UPS state every 30 seconds (configurable)
- A single-page browser dashboard subscribes to MQTT over WebSocket and
  renders live state with sparklines, fleet summary, event log, and alert
  styling
- **Edge-triggered alerts** fire once per status transition (one notification
  per outage, not one per poll cycle while on battery)
- Built for the long term: every component restartable independently,
  every state field nullable for varying APC model field coverage,
  every theme token designed for live re-skinning

It's intentionally not a turnkey enterprise product. It's a working
foundation you can deploy in 90 minutes, characterize your fleet against,
and extend toward whatever monitoring story your customer needs.

---

## Architecture

```
  APC UPS ──USB-HID──┐
  APC UPS ──USB-HID──┤
  APC UPS ──USB-HID──┤── Raspberry Pi ─── apcupsd@labN ─── MQTT ─── WebSocket ─── Browser
  APC UPS ──USB-HID──┘     (Pi 3+)        (one per UPS)  (mosquitto)              (dashboard)
                                              │              │
                                              │              ├─── future: ChirpStack subscribers
                                              │              ├─── future: InfluxDB / Grafana
                                              │              └─── future: Cyrano / Twilio alerts
                                              │
                                              └─── apc-mqtt-bridge service
                                                   (speaks NIS protocol natively over TCP)
```

Each UPS → `apcupsd` instance (port 3551, 3552, 3553, 3554) → bridge polls
each on a 30-second cycle → publishes typed JSON to `ups/labN/state` →
mosquitto holds the retained value → dashboard subscribes via WebSocket.

The bridge speaks apcupsd's **Network Information Server protocol** directly
over TCP, not by shelling out to `apcaccess` for each cycle. This saves
~40-50 ms per poll per UPS in subprocess overhead and means you can poll
faster without paying a fork-exec cost.

---

## Hardware

### Required

- **Raspberry Pi 3B / 3B+ / 4 / 5** running Raspberry Pi OS Lite
  (Bookworm or Trixie, 32-bit or 64-bit)
- USB-A → APC data cable for each UPS:
  - **940-0127B** (or **940-0625A** clone) — RJ50-to-USB for Back-UPS XS,
    Back-UPS Pro, older Smart-UPS with the proprietary "fat ethernet" jack
  - **standard USB-B cable** for newer Smart-UPS units with a real USB-B port
- **Powered USB 2.0/3.0 hub** strongly recommended even for a Pi 4
  (see [design choices](#design-choices))
- Ethernet to the network — do **not** rely on Wi-Fi for a power-critical
  monitor; the access point may go down before the Pi notices the outage

### Tested working

| Pi | OS | UPS | Cable |
|----|-----|------|-------|
| Pi 3B | Pi OS Lite Trixie | Back-UPS XS 1500G (FW 866.L8.D) | 940-0127B (RJ50→USB) |

---

## Software stack

| Component | Version (tested) | Purpose |
|-----------|------------------|---------|
| `apcupsd` | 3.14.14 (Debian) | Reads UPS over USB-HID, exposes status via TCP NIS protocol |
| `mosquitto` | 2.0.21 | MQTT broker — native on `:1883`, WebSocket on `:9001` |
| `python3-paho-mqtt` | 2.1.0 | MQTT client library used by the bridge |
| Python | 3.11+ | Bridge runtime |
| systemd | any current | Service supervision and template instances |

All dependencies install via `apt` from the standard Debian repos. No pip,
no npm, no Docker required.

---

## Quick start

On a fresh Raspberry Pi OS Lite install:

```bash
git clone https://github.com/SuperAngryMonkey/watchmen.git
cd watchmen
sudo ./install.sh
```

The installer will:

1. Install `apcupsd`, `mosquitto`, `python3-paho-mqtt`, `mosquitto-clients`,
   `usbutils`
2. Disable and mask the default single-UPS `apcupsd` service so it doesn't
   fight the per-instance template units
3. Drop udev rules into `/etc/udev/rules.d/`
4. Drop apcupsd configs into `/etc/apcupsd/`
5. Drop systemd units into `/etc/systemd/system/`
6. Drop the bridge into `/usr/local/bin/`
7. Drop the dashboard into `/var/lib/watchmen-web/`
8. Drop helper scripts (`find-apc-serials`, `apc-characterize`) into
   `/usr/local/bin/`
9. Configure mosquitto's WebSocket listener
10. Enable mosquitto

You then run three things manually:

```bash
# 1. Discover your UPS serials
sudo find-apc-serials

# 2. Edit the udev rules to pin each UPS to a stable name by serial
sudo nano /etc/udev/rules.d/99-apc-ups.rules
sudo udevadm control --reload && sudo udevadm trigger

# 3. Start the daemons (one per UPS you have plugged in)
sudo systemctl enable --now apcupsd@lab1 apc-mqtt-bridge watchmen-web
```

Verify:

```bash
# UPS data flowing
apcaccess -h 127.0.0.1:3551

# MQTT messages publishing
mosquitto_sub -h localhost -t 'ups/#' -v -C 5

# Dashboard reachable
curl -I http://localhost:8080/
```

Open the dashboard: **http://&lt;pi-ip&gt;:8080/**

---

## Remote deployment

If you've cloned the repo on your laptop and want to push to a Pi over SSH
without manually transferring files:

```bash
PI_USER=monkey PI_HOST=<pi-lan-ip> ./deploy.sh
```

Defaults are `monkey@<pi-lan-ip>`. The script:

1. Confirms SSH connectivity
2. Tarballs the working tree
3. Copies it to `~/watchmen.tar.gz` on the Pi
4. Extracts and runs `sudo ./install.sh`
5. Prints next-step commands

For Tailscale-attached Pis, just use the Tailscale IP:

```bash
PI_HOST=100.96.124.7 ./deploy.sh
```

---

## Configuration

### Per-instance apcupsd config

`/etc/apcupsd/apcupsd-lab1.conf` through `apcupsd-lab4.conf`. Each instance
binds to one UPS and exposes its data on a unique TCP port.

| Setting | Default | Notes |
|---------|---------|-------|
| `UPSNAME` | `lab1` | Identifier used in MQTT topics |
| `UPSCABLE` | `usb` | USB-HID is the supported path |
| `UPSTYPE` | `usb` | Driver selector |
| `DEVICE` | (blank) | apcupsd auto-discovers an unclaimed hiddev device |
| `POLLTIME` | `30` | Seconds between local apcupsd polls of the UPS |
| `LOCKFILE` | `/var/lock` | apcupsd creates `LCK..apcupsd-labN` inside this dir |
| `NETSERVER` | `on` | Required for the bridge to read it |
| `NISIP` | `127.0.0.1` | Bind only to localhost |
| `NISPORT` | `3551` (lab1), `3552` (lab2), etc | Different per instance |

Pin a specific UPS to a specific instance by uncommenting the `DEVICE` line
and pointing it at the udev-created symlink:

```
DEVICE /dev/ups-lab1-hid
```

### Bridge configuration

The bridge reads from environment variables, set in
`/etc/systemd/system/apc-mqtt-bridge.service`:

| Variable | Default | Purpose |
|----------|---------|---------|
| `MQTT_HOST` | `127.0.0.1` | Broker host |
| `MQTT_PORT` | `1883` | Broker port |
| `MQTT_USER` | (unset) | Optional auth |
| `MQTT_PASS` | (unset) | Optional auth |
| `MQTT_TOPIC_PREFIX` | `ups` | All topics prefixed with this |
| `POLL_INTERVAL` | `30` | Seconds between bridge poll cycles |
| `UPS_HOSTS` | `lab1@127.0.0.1:3551` | Comma-separated `name@host:port` |

To monitor multiple UPSs, override:

```bash
sudo systemctl edit apc-mqtt-bridge
```

Paste:

```ini
[Service]
Environment=
Environment=MQTT_HOST=127.0.0.1
Environment=MQTT_PORT=1883
Environment=MQTT_TOPIC_PREFIX=ups
Environment=POLL_INTERVAL=30
Environment=UPS_HOSTS=lab1@127.0.0.1:3551,lab2@127.0.0.1:3552,lab3@127.0.0.1:3553
```

The empty `Environment=` line clears the parent's full environment list so
your override fully replaces it instead of merging.

```bash
sudo systemctl restart apc-mqtt-bridge
```

### Mosquitto configuration

`/etc/mosquitto/conf.d/websockets.conf` adds a WebSocket listener on `:9001`
alongside the native MQTT listener on `:1883`. The bridge talks to native
MQTT; the browser dashboard talks to WebSocket. Both are anonymous by
default — fine for a lab on a trusted LAN, **set up auth before deploying
anywhere else.**

Add auth:

```bash
sudo mosquitto_passwd -c /etc/mosquitto/passwd watchmen
# enter password when prompted

# edit /etc/mosquitto/conf.d/websockets.conf:
#   allow_anonymous false
#   password_file /etc/mosquitto/passwd

sudo systemctl restart mosquitto
```

Then update the bridge's `MQTT_USER` and `MQTT_PASS`, and add
`?user=watchmen&pass=...` to the dashboard URL (or modify
`web/index.html` to default-include them).

### udev rules

`/etc/udev/rules.d/99-apc-ups.rules` pins each UPS by serial number to a
stable `/dev/ups-labN` symlink and a matching `/dev/ups-labN-hid` symlink
on the kernel hiddev node. Edit the placeholder serials to match the
output of `sudo find-apc-serials`.

---

## The dashboard

A single-page HTML application served from `/var/lib/watchmen-web/` by a
small Python `http.server` on port 8080. No build tooling, no framework, no
backend beyond the static files.

### Live elements

- **Header** — wordmark, connection status indicator, wall clock
- **Fleet summary strip** — count / online / on-battery / alert state
  metrics, color-coded
- **Monitoring host strip** — broker, topic prefix, last-message time,
  message rate, bridge uptime
- **Per-UPS panels** — appear automatically as messages arrive; show
  model/serial/firmware, large readouts of line voltage, load %, battery %,
  runtime, plus battery-voltage / nominal-watts / transfer-count detail
  rows. Each panel has a 60-sample sparkline of line voltage with a
  reference dashed line at the inferred nominal voltage (120 V or 230 V)
- **Event log** — real-time stream of state transitions, alerts, errors,
  and bridge availability changes; capped at 200 lines, color-coded by
  severity using the theme's existing `.cmd-out.ok/.err` conventions
- **Lab command interface** — inject simulated UPS events for dashboard
  development without pulling power cords:
  - `sim lab1 onbatt` — force ON BATTERY state
  - `sim lab1 lowbatt` — force LOW BATTERY (flashing red border)
  - `sim lab1 online` — restore
  - `clear` — clear the event log

### Query string overrides

For viewing the dashboard from a different machine pointing at a different
broker:

```
http://your-pi:8080/?broker=<pi-lan-ip>&port=9001&prefix=ups
```

You can also override the client and site labels at view time:

```
http://your-pi:8080/?client=Acme%20Corp&site=Rack%202
```

Defaults to `location.hostname` so opening the dashboard on the Pi itself
"just works." Falls back to `<pi-lan-ip>` if neither is available.

### Client and site labels

The dashboard header shows a configurable `client` and `site` label so you
can tell at a glance which deployment you're looking at. Set during install
with the prompts, or update later without reinstalling:

```bash
sudo watchmen-set-client "Pat Gallager" "Surfside 6H"
```

Or run it without arguments for an interactive prompt that shows current
values first. Or set non-interactively via environment variables during
install:

```bash
WATCHMEN_CLIENT="Acme Corp" WATCHMEN_SITE="Rack 2" sudo ./install.sh
```

### Theme

Styled with **Monkey Theme** (`web/monkey-theme.css`), the shared design
system across SuperAngryMonkey projects (Sentinel, Watchmen, etc). All
theme tokens are CSS variables, so reskinning is a matter of editing a few
lines and the entire dashboard — including live sparkline colors which are
read via `getComputedStyle` at draw time — re-themes without touching JS.

If you want a different look, edit `:root { --acc, --acc2, --acc3, ... }`
in `monkey-theme.css` and refresh.

---

## MQTT topic schema

```
ups/<name>/state         retained JSON, every poll cycle (~30s)
ups/<name>/alert         JSON, on STATUS transition only (edge-triggered)
ups/<name>/error         text, on poll failure
ups/<name>/available     "online" / "offline" (LWT-style)
ups/_bridge/available    "online" / "offline" (the bridge process itself)
```

### State payload

```json
{
  "status": "ONLINE",
  "model": "Back-UPS XS 1500G",
  "serial": "4B1424P23533",
  "firmware": "866.L8 .D USB FW:L8",
  "battery_date": "2014-06-11",
  "line_v": 122.0,
  "nominal_line_v": 120.0,
  "output_v": null,
  "load_pct": 0.0,
  "battery_pct": 100.0,
  "battery_v": 27.2,
  "nominal_battery_v": 24.0,
  "runtime_min": 217.9,
  "nominal_power_w": 865,
  "line_freq_hz": null,
  "internal_temp_c": null,
  "line_transfer_low": 88.0,
  "line_transfer_high": 139.0,
  "num_xfers": 0,
  "time_on_batt_sec": 0,
  "cum_on_batt_sec": 0,
  "last_xfer_reason": "Unacceptable line voltage changes",
  "selftest_result": "NO",
  "status_flag": "0x05000008",
  "apcupsd_version": "3.14.14 (31 May 2016) debian",
  "hostname": "APCpi",
  "ts": 1714076700
}
```

Fields that aren't populated by a given UPS model come through as `null`
rather than missing, so downstream consumers can assume a stable schema.

### Alert payload

```json
{
  "ups": "lab1",
  "event": "status_change",
  "from": "ONLINE",
  "to": "ONBATT",
  "snapshot": { /* full state payload at moment of transition */ }
}
```

---

## Per-model field characterization

Different APC models populate different fields. Build a per-model reference
library by running:

```bash
sudo apc-characterize lab1 > ~/chars/$(date +%F)-back-ups-xs-1500g.txt
```

The script captures:

1. Full `apcaccess` snapshot
2. `lsusb -d 051d:` and `lsusb -v` output for the device descriptor
3. HID report descriptor hex dump from `/sys/bus/usb/devices/.../report_descriptor`
4. Kernel hiddev nodes for the device
5. Recent events log

After a few months you'll have a library that tells you: for any APC model
you encounter in the field, which fields will populate, what their typical
ranges are, and which model-specific quirks to expect.

### Confirmed populated by Back-UPS XS 1500G (FW 866.L8.D)

`MODEL`, `SERIALNO`, `FIRMWARE`, `STATUS`, `LINEV`, `LOADPCT`, `BCHARGE`,
`TIMELEFT`, `BATTV`, `NOMINV`, `NOMBATTV`, `NOMPOWER`, `LOTRANS`, `HITRANS`,
`SENSE`, `MBATTCHG`, `MINTIMEL`, `MAXTIME`, `LASTXFER`, `NUMXFERS`,
`TONBATT`, `CUMONBATT`, `XOFFBATT`, `SELFTEST`, `STATFLAG`, `BATTDATE`,
`ALARMDEL`.

Better field coverage than typical for consumer-grade APCs. `NOMPOWER`,
`BATTV`, and `LOTRANS`/`HITRANS` all populate, which is unusual.

---

## Operations and maintenance

### Service control

```bash
# Status
sudo systemctl status apcupsd@lab1 apc-mqtt-bridge watchmen-web mosquitto

# Restart the data pipeline (UPS data keeps flowing during a brief gap)
sudo systemctl restart apcupsd@lab1
sudo systemctl restart apc-mqtt-bridge

# Restart just the dashboard (data still flowing, browser shows reconnect)
sudo systemctl restart watchmen-web
```

### Log inspection

```bash
# apcupsd events for a specific UPS
tail -f /var/log/apcupsd-lab1.events

# Bridge logs (systemd journal)
sudo journalctl -u apc-mqtt-bridge -f

# Mosquitto logs
sudo journalctl -u mosquitto -f

# Watch every MQTT topic in real time
mosquitto_sub -h localhost -t 'ups/#' -v
```

### Updating the battery date in apcupsd

The UPS stores the battery installation date in NVRAM. apcupsd reports
whatever's there — most units come from the factory with a date that's not
the date you actually swapped batteries. To update:

```bash
sudo systemctl stop apcupsd@lab1
sudo apctest
# Use the menu — "View/Change battery date"
# Quit with Q
sudo systemctl start apcupsd@lab1
```

The dashboard reflects the new date on the next poll.

### Pulling a UPS out of service

```bash
sudo systemctl stop apcupsd@lab1
sudo systemctl disable apcupsd@lab1
# Optionally remove from bridge UPS_HOSTS
```

The dashboard will mark it stale after 90 seconds, then drop the panel on
next page load.

### Smoke test (verifies the entire pipeline)

With a UPS plugged in and reporting `ONLINE`, **pull the input cord on the
UPS** (the cord going from UPS to wall, not the Pi's power). Within 2-5
seconds:

1. Dashboard status pill flips to `ON BATTERY` (orange, flashing)
2. Panel border turns orange
3. Event log shows `lab1: status ONLINE → ONBATT`
4. `LINEV` drops to 0
5. `BCHARGE` decreases over time
6. `TIMELEFT` updates dynamically based on load
7. MQTT alert fires once on `ups/lab1/alert`

Plug it back in. Status returns to `ONLINE`. `NUMXFERS` increments. That
round-trip — physical event → USB-HID → apcupsd → MQTT → WebSocket → DOM —
is the entire architecture exercised end-to-end in 30 seconds.

---

## Troubleshooting

### `apcupsd@lab1` fails to start

Check the journal:

```bash
sudo journalctl -u apcupsd@lab1 -n 30 --no-pager
```

Common causes:

- **`Cannot create /var/lock/apcupsd-lab1/LCK..` or similar** — `LOCKFILE`
  in the conf is interpreted as a directory. Fix: change to `/var/lock`
  (apcupsd writes the lockfile *inside* this directory)
- **`Configuration file not found`** — the systemd template instance
  expects `/etc/apcupsd/apcupsd-<instance>.conf`
- **`old configuration file found` warning** — apcupsd 3.14 expects the
  first line of every config to be `## apcupsd.conf v1.1 ##`. Harmless
  warning; the configs in this repo include it
- **`Unable to open UPS device`** — another apcupsd or apctest is holding
  the device. Check: `ps aux | grep apcupsd`
- **Default `apcupsd.service` competing for the device** — should be
  masked by the installer. Verify: `systemctl status apcupsd.service`
  should show "masked"

### Dashboard says "CONNECT FAILED"

The browser can't reach mosquitto's WebSocket listener.

```bash
# Confirm mosquitto is listening on 9001
sudo ss -tlnp | grep 9001

# Confirm the WebSocket config is loaded
sudo grep -r "listener 9001" /etc/mosquitto/

# Restart and watch logs
sudo systemctl restart mosquitto
sudo journalctl -u mosquitto -f
```

### Bridge logs show `ConnectionRefusedError` for lab2/lab3/lab4

The bridge is configured to poll instances that aren't running. Either
start the missing instances or trim the `UPS_HOSTS` env to only the ones
you actually have. See [Bridge configuration](#configuration) above.

### Dashboard shows a UPS panel but data is stale

The panel goes semi-transparent with a diagonal hatch pattern after 90
seconds without an update. Causes:

- The bridge stopped (`sudo systemctl status apc-mqtt-bridge`)
- That apcupsd instance died (`sudo systemctl status apcupsd@lab1`)
- USB cable came loose — kernel will log it (`dmesg | tail`)

### `apctest` won't open the device

Same exclusive-access issue: another apcupsd is holding it. Stop
the corresponding instance first:

```bash
sudo systemctl stop apcupsd@lab1
sudo apctest
# ... do your thing, quit with Q ...
sudo systemctl start apcupsd@lab1
```

---

## Repository layout

```
watchmen/
├── README.md                           this file
├── CHANGELOG.md                        version history with debugging stories
├── LICENSE                             MIT
├── .gitignore                          standard Python/Pi runtime exclusions
│
├── install.sh                          installs everything on a fresh Pi
├── deploy.sh                           push from laptop to remote Pi over SSH
│
├── apcupsd/
│   ├── apcupsd-lab1.conf               instance 1 — NIS port 3551
│   ├── apcupsd-lab2.conf               instance 2 — NIS port 3552
│   ├── apcupsd-lab3.conf               instance 3 — NIS port 3553
│   └── apcupsd-lab4.conf               instance 4 — NIS port 3554
│
├── systemd/
│   ├── apcupsd@.service                template unit, one instance per UPS
│   ├── apc-mqtt-bridge.service         the bridge service
│   └── watchmen-web.service            the dashboard HTTP server
│
├── bridge/
│   └── apc-mqtt-bridge.py              MQTT bridge — speaks NIS protocol natively
│
├── web/
│   ├── index.html                      single-page dashboard
│   └── monkey-theme.css                shared design system
│
├── mosquitto/
│   └── websockets.conf                 WebSocket listener on :9001
│
├── udev/
│   └── 99-apc-ups.rules                pin each UPS to /dev/ups-labN by serial
│
└── scripts/
    ├── find-apc-serials.sh             discover connected APCs with serials
    └── characterize.sh                 dump per-model HID descriptor + status
```

---

## Design choices

A few decisions worth calling out, since they're not obvious from reading
the source:

**The bridge speaks NIS protocol natively** instead of shelling out to
`apcaccess`. The NIS protocol is trivial — 16-bit length-prefixed frames
of `key: value` strings — and not running a subprocess per UPS per poll
saves time and lets the bridge run as a constrained user. Shelling out to
`apcaccess` would also require that user to be in the right group to read
hiddev, which is a privilege escalation we don't need.

**Edge-triggered alerts.** The `ups/<name>/alert` topic only fires on
status transitions, not every poll. So when you wire this into your
notification system (Twilio, PagerDuty, whatever) you get one
"power went out on rack 1" message, not one every 30 seconds for the
duration of the outage. Wakes humans up exactly the right number of
times.

**Null-safe field normalization.** Different APC models populate
different fields. The normalizer returns `None` for missing fields rather
than omitting them, so downstream code (Grafana queries, alert decoders,
custom dashboards) can assume a stable schema across the fleet.

**LWT-style availability topics.** `ups/<name>/available` flips to
`offline` when the bridge fails to poll that UPS, and
`ups/_bridge/available` flips to `offline` via MQTT last-will if the
bridge process itself dies. That means downstream alerting can
distinguish "the UPS is on battery" (one alert class) from "the
monitoring is broken" (a completely different alert class). Two very
different incidents that should not be confused.

**Powered USB hub strongly recommended even on Pi 4/5.** The Pi 3's
LAN9514 USB+Ethernet bridge chip shares one upstream link between all
ports. The Pi 4/5 have proper USB 3.0 controllers, but APC USB-HID
devices can still draw enough during enumeration transients to cause
unexplained `COMMLOST` events. A $15 powered hub eliminates a whole
class of intermittent failures and gives you stable enumeration order
across reboots.

**Per-instance lockfiles in `/var/lock/`.** apcupsd creates
`LCK..apcupsd-labN` files inside this directory rather than using the
filename directly, which is why the configs set `LOCKFILE /var/lock`
(directory) rather than `/var/lock/apcupsd-labN` (path). Easy mistake
to make; the v0.2.0 release shipped with this bug and it's documented
in the CHANGELOG.

**`Type=simple` with `apcupsd -b`** instead of `Type=forking`. The
forking version had PID file timing problems where systemd's default
timeout would expire before apcupsd had written the PID file, even
though the daemon had already successfully started. Foreground mode
sidesteps the whole class of issue.

---

## Roadmap

| Phase | Status | What |
|-------|--------|------|
| 1 | ✅ done | USB-HID multi-UPS monitoring |
| 1 | ✅ done | MQTT bridge with edge-triggered alerts |
| 1 | ✅ done | Live dashboard with sparklines |
| 1 | ✅ done | Lab event simulator for testing |
| 2 | planned | RS-232 / GPIO UART support for older Smart-UPS units (no USB) |
| 3 | planned | Bridge to ChirpStack Mosquitto over Tailscale (single broker for whole fleet) |
| 4 | planned | RAK4631 + LoRaWAN node variant for remote sites without IP networking |
| 5 | planned | SQLite logger for 24h sparkline backfill on dashboard load |
| ops | planned | Move bridge service off `nobody` user to dedicated `watchmen` system user |
| ops | planned | Per-site config split (`*.local.conf` files, gitignored) |
| ops | planned | TLS + auth on Mosquitto by default |

---

## Contributing

This is primarily a deployment artifact for 800 Pound Gorilla Inc., but if
you're using it elsewhere and have improvements:

1. Fork
2. Branch from `main`
3. Make the change with a clear commit message explaining *why* not just
   *what*
4. Update `CHANGELOG.md` with what you changed
5. Open a PR

Particularly welcome:
- Per-model characterization captures from APCs we haven't tested
- Translations of the dashboard into other languages (the strings are all
  inline in `web/index.html`)
- Improvements to the LoRaWAN node variant when phase 4 starts

---

## License

MIT — see [LICENSE](LICENSE).

The Monkey Theme CSS and the `Quis custodiet` epigraph are decorative
references, not project requirements.
