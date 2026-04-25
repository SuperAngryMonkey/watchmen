#!/usr/bin/env bash
# deploy.sh — Push the lab stack to monkey@<pi-lan-ip> in one command.
#
# Run from your MacBook (or wherever you have the tarball + SSH key):
#   ./deploy.sh
#
# What it does:
#   1. scp's apc-lab-pi.tar.gz to the Pi
#   2. Extracts it
#   3. Runs the installer with sudo (you'll be prompted once for the monkey password)
#   4. Prints the dashboard URL
#
# Assumes:
#   - SSH key already authorized on the Pi (or you're OK typing the pw a few times)
#   - apc-lab-pi.tar.gz is in the current directory

set -euo pipefail

PI_USER="${PI_USER:-monkey}"
PI_HOST="${PI_HOST:-<pi-lan-ip>}"
PI_ADDR="${PI_USER}@${PI_HOST}"
TARBALL="${TARBALL:-apc-lab-pi.tar.gz}"

if [[ ! -f "$TARBALL" ]]; then
    echo "error: $TARBALL not found in $(pwd)" >&2
    echo "download it from the Claude artifact or rebuild it first." >&2
    exit 1
fi

echo "==> Checking connectivity to ${PI_ADDR} ..."
if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "$PI_ADDR" 'echo ok' >/dev/null 2>&1; then
    echo "    (will prompt for password — consider ssh-copy-id for next time)"
fi

echo "==> Copying tarball to ${PI_ADDR}:~/"
scp "$TARBALL" "${PI_ADDR}:~/"

echo "==> Extracting and running installer on Pi (sudo password may be needed)..."
ssh -t "$PI_ADDR" "
    set -e
    cd ~
    rm -rf apc-lab
    tar xzf '$TARBALL'
    cd apc-lab
    sudo ./install.sh
"

echo
echo "==============================================================="
echo "Deployed. Next steps on the Pi:"
echo
echo "  ssh ${PI_ADDR}"
echo "  sudo find-apc-serials"
echo "  sudo nano /etc/udev/rules.d/99-apc-ups.rules   # paste serials"
echo "  sudo udevadm control --reload && sudo udevadm trigger"
echo "  sudo systemctl enable --now apcupsd@lab1 apcupsd@lab2 apcupsd@lab3 apcupsd@lab4"
echo "  sudo systemctl enable --now apc-mqtt-bridge watchmen-web"
echo
echo "Then open the dashboard:"
echo "  http://${PI_HOST}:8080/"
echo
echo "From a machine on Tailscale, use the Pi's Tailscale IP in place of ${PI_HOST}."
echo "==============================================================="
