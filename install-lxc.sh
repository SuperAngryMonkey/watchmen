#!/usr/bin/env bash
# install-lxc.sh — Install watchmen inside an unprivileged Debian LXC container.
#
# Run this INSIDE the container as root. The host-side USB passthrough must
# already be configured (see HOST-SIDE-SETUP.md) — this script does NOT touch
# the Proxmox host.
#
# Differences from install.sh (Pi version):
#   - No udev install (rules live on the host, not the container)
#   - No mosquitto WebSocket reload via systemctl restart (mosquitto's already
#     running thanks to the systemctl enable in package install)
#   - Dashboard binds to 0.0.0.0:8080 same as Pi
#   - Adds a sanity check that /dev/usb/hiddev* is reachable

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root inside the LXC container." >&2
    echo "Run from the Proxmox host: pct exec <vmid> -- /root/watchmen/install-lxc.sh" >&2
    exit 1
fi

HERE="$(cd "$(dirname "$0")" && pwd)"

echo "==> Detecting environment..."
if [[ ! -f /proc/1/cgroup ]] || ! grep -q lxc /proc/1/cgroup 2>/dev/null; then
    echo "    (warning: doesn't look like an LXC container — proceeding anyway)"
else
    echo "    Confirmed: running inside LXC"
fi

echo "==> Installing packages..."
apt update
DEBIAN_FRONTEND=noninteractive apt install -y \
    apcupsd python3-paho-mqtt mosquitto mosquitto-clients usbutils

echo "==> Disabling default single-UPS apcupsd service..."
systemctl disable --now apcupsd.service 2>/dev/null || true
systemctl mask apcupsd.service

echo "==> Installing apcupsd configs..."
for f in "$HERE"/apcupsd/apcupsd-lab*.conf; do
    install -m 0644 "$f" /etc/apcupsd/
done

echo "==> Installing systemd units..."
install -m 0644 "$HERE/systemd/apcupsd@.service"        /etc/systemd/system/
install -m 0644 "$HERE/systemd/apc-mqtt-bridge.service" /etc/systemd/system/
install -m 0644 "$HERE/systemd/watchmen-web.service"    /etc/systemd/system/

echo "==> Installing MQTT bridge..."
install -m 0755 "$HERE/bridge/apc-mqtt-bridge.py" /usr/local/bin/

echo "==> Installing helper scripts..."
install -m 0755 "$HERE/scripts/find-apc-serials.sh" /usr/local/bin/find-apc-serials
install -m 0755 "$HERE/scripts/characterize.sh"     /usr/local/bin/apc-characterize

echo "==> Installing mosquitto WebSocket listener..."
install -d /etc/mosquitto/conf.d
install -m 0644 "$HERE/mosquitto/websockets.conf" /etc/mosquitto/conf.d/

echo "==> Installing web dashboard..."
install -d /var/lib/watchmen-web
install -m 0644 "$HERE/web/index.html"        /var/lib/watchmen-web/
install -m 0644 "$HERE/web/monkey-theme.css"  /var/lib/watchmen-web/

echo "==> Restarting mosquitto to pick up WebSocket listener..."
systemctl enable mosquitto
systemctl restart mosquitto

echo "==> Reloading systemd..."
systemctl daemon-reload

echo
echo "==> USB passthrough sanity check..."
if ls /dev/usb/hiddev* >/dev/null 2>&1; then
    echo "    Found hiddev devices:"
    ls -la /dev/usb/hiddev* | sed 's/^/      /'
    echo "    USB passthrough looks correctly configured."
else
    echo "    !! No /dev/usb/hiddev* devices visible inside this container."
    echo "    !! USB passthrough is NOT configured yet (or no UPS plugged in)."
    echo "    !! See HOST-SIDE-SETUP.md for the Proxmox-host configuration steps."
fi

echo
echo "==============================================================="
echo "Container-side install complete. Next steps:"
echo
echo "  1. (If not done already) Configure host-side USB passthrough."
echo "     See HOST-SIDE-SETUP.md — must be done from Proxmox host, not here."
echo
echo "  2. After USB passthrough is configured, find UPS serials:"
echo "        find-apc-serials"
echo
echo "  3. Start daemons (one apcupsd@labN per UPS plugged in):"
echo "        systemctl enable --now apcupsd@lab1 apc-mqtt-bridge watchmen-web"
echo
echo "  4. Verify:"
echo "        apcaccess -h 127.0.0.1:3551"
echo "        mosquitto_sub -h localhost -t 'ups/#' -v -C 5"
echo
echo "  5. Open dashboard:"
echo "        http://<container-ip>:8080/"
echo "==============================================================="
