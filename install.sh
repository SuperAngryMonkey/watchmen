#!/usr/bin/env bash
# install.sh — Install the APC lab monitoring stack on a Raspberry Pi.
#
# Run as root on a fresh Pi OS Lite install. This script:
#   1. Installs apcupsd, mosquitto, paho-mqtt
#   2. Copies config files into place
#   3. Disables the default single-UPS apcupsd service
#   4. Prints next steps (you still need to edit the udev rules with your
#      actual UPS serial numbers, then start the instances)
#
# Usage: sudo ./install.sh

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root. Try: sudo $0" >&2
    exit 1
fi

HERE="$(cd "$(dirname "$0")" && pwd)"

echo "==> Installing packages..."
apt update
apt install -y apcupsd python3-paho-mqtt mosquitto mosquitto-clients usbutils

echo "==> Disabling default single-UPS apcupsd service..."
systemctl disable --now apcupsd.service 2>/dev/null || true
# Mask prevents the default service from being re-enabled by package upgrades
# and prevents systemctl-enable of @instances from inadvertently activating it
systemctl mask apcupsd.service

echo "==> Installing udev rules..."
install -m 0644 "$HERE/udev/99-apc-ups.rules" /etc/udev/rules.d/

echo "==> Installing apcupsd configs..."
for f in "$HERE"/apcupsd/apcupsd-lab*.conf; do
    install -m 0644 "$f" /etc/apcupsd/
done

echo "==> Installing systemd units..."
install -m 0644 "$HERE/systemd/apcupsd@.service"       /etc/systemd/system/
install -m 0644 "$HERE/systemd/apc-mqtt-bridge.service" /etc/systemd/system/

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
install -m 0644 "$HERE/systemd/watchmen-web.service" /etc/systemd/system/

echo "==> Enabling + restarting mosquitto..."
systemctl enable --now mosquitto
systemctl restart mosquitto

echo "==> Reloading systemd..."
systemctl daemon-reload

echo
echo "==============================================================="
echo "Install complete. Next steps:"
echo
echo "  1. Plug in your APC UPSs (powered hub strongly recommended)."
echo
echo "  2. Find their serial numbers:"
echo "        sudo find-apc-serials"
echo
echo "  3. Edit the udev rules to match YOUR serials:"
echo "        sudo nano /etc/udev/rules.d/99-apc-ups.rules"
echo "        sudo udevadm control --reload && sudo udevadm trigger"
echo
echo "  4. Start one daemon per UPS you have connected:"
echo "        sudo systemctl enable --now apcupsd@lab1"
echo "        sudo systemctl enable --now apcupsd@lab2"
echo "        # ... etc, up to lab4"
echo
echo "  5. Verify each daemon sees its UPS:"
echo "        apcaccess -h 127.0.0.1:3551"
echo "        apcaccess -h 127.0.0.1:3552"
echo
echo "  6. Start the MQTT bridge and web dashboard:"
echo "        sudo systemctl enable --now apc-mqtt-bridge watchmen-web"
echo
echo "  7. Watch the traffic:"
echo "        mosquitto_sub -h localhost -t 'ups/#' -v"
echo
echo "  8. Open the dashboard in a browser:"
echo "        http://$(hostname -I | awk '{print $1}'):8080/"
echo "==============================================================="
