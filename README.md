# watchmen

APC UPS monitoring stack for Raspberry Pi. Polls UPSs over USB-HID, publishes
metrics to MQTT, renders a live ops-grade dashboard in the browser.

UPS monitoring stack designed as a lab characterization bench and the
foundation for customer-site UPS monitoring deployments.

## What it does

```
  APC UPS ──USB-HID──┐
  APC UPS ──USB-HID──┤
  APC UPS ──USB-HID──┤── Pi ── apcupsd@labN ── MQTT ── WebSocket ── Browser
  APC UPS ──USB-HID──┘     (×N)                  (mosquitto)        (dashboard)
                                                       │
                                                       └── future: ChirpStack,
                                                           InfluxDB, Cyrano,
                                                           Twilio alerts
```

- Up to 4 APC UPSs per Pi (more with a powered hub)
- Each UPS gets its own apcupsd instance pinned by serial via udev
- Native NIS protocol bridge to MQTT (no `apcaccess` subprocess overhead)
- Single-page HTML dashboard styled with Monkey Theme — live sparklines, fleet
  summary, event log, simulated event injection
- WebSocket transport so the dashboard works from any device on the LAN/Tailscale
- Edge-triggered alerts on status transitions (one notification per outage,
  not one per poll)

## Quick start

```bash
# On a fresh Raspberry Pi OS Lite (Bookworm or Trixie):
git clone https://github.com/SuperAngryMonkey/watchmen.git
cd watchmen
sudo ./install.sh

# Find your UPS's serial number
sudo find-apc-serials

# Edit the udev rules to pin by serial
sudo nano /etc/udev/rules.d/99-apc-ups.rules
sudo udevadm control --reload && sudo udevadm trigger

# Start the daemons (one per UPS you have plugged in)
sudo systemctl enable --now apcupsd@lab1 apc-mqtt-bridge watchmen-web

# Verify
apcaccess -h 127.0.0.1:3551
```

Open the dashboard: **http://&lt;pi-ip&gt;:8080/**

## Remote deploy from your laptop

If you've got the tarball and want to push to a Pi without cloning the repo
on it:

```bash
./deploy.sh
# (configurable via PI_USER / PI_HOST environment variables)
```

## Repo layout

```
watchmen/
├── install.sh                       installer for a Pi
├── deploy.sh                        push from laptop to a remote Pi
├── apcupsd/apcupsd-lab{1..4}.conf   per-instance daemon configs
├── systemd/
│   ├── apcupsd@.service             template unit, one instance per UPS
│   ├── apc-mqtt-bridge.service      bridge service
│   └── watchmen-web.service          dashboard HTTP server
├── bridge/apc-mqtt-bridge.py        Python MQTT bridge
├── web/
│   ├── index.html                   dashboard
│   └── monkey-theme.css             shared design system
├── mosquitto/websockets.conf        WebSocket listener config
├── udev/99-apc-ups.rules            UPS serial-to-symlink pinning
└── scripts/
    ├── find-apc-serials.sh          discover connected APCs
    └── characterize.sh              dump per-model HID + status profile
```

## MQTT topic structure

```
ups/lab1/state        JSON, retained, every poll cycle (~30s)
ups/lab1/alert        JSON, on STATUS transition only (edge-triggered)
ups/lab1/error        Text, on poll failure
ups/lab1/available    "online" / "offline" (LWT-style)
ups/_bridge/available "online" / "offline" (the bridge itself)
```

## Field characterization

Use `apc-characterize lab1 > ~/chars/$(date +%F)-$model.txt` to capture full
profile of any APC model you encounter — lsusb descriptor, HID report
descriptor hex dump, and full apcaccess output. Build a library of per-model
quirks over time.

## Tested working

- Raspberry Pi 3B + Pi OS Lite Trixie + Back-UPS XS 1500G (FW 866.L8.D)
  via 940-0127B USB cable

See [CHANGELOG.md](CHANGELOG.md) for what worked, what broke, and what we
learned along the way.

## Roadmap

- [x] USB-HID multi-UPS monitoring
- [x] MQTT bridge with edge-triggered alerts
- [x] Live dashboard with sparklines
- [x] Lab event simulator for testing
- [ ] Phase 2: RS-232 / GPIO UART support for older Smart-UPS units
- [ ] Phase 3: Bridge to ChirpStack Mosquitto over Tailscale
- [ ] Phase 4: RAK4631 + LoRaWAN node variant for remote sites
- [ ] Phase 5: SQLite logger for 24h sparkline backfill
- [ ] Move bridge service off `nobody` user to dedicated `watchmen` user

## License

MIT — see [LICENSE](LICENSE).
