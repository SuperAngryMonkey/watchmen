#!/usr/bin/env bash
# find-apc-serials.sh — List every APC UPS plugged in via USB, with vendor ID,
# product ID, serial number, and the hiddev device node the kernel assigned it.
#
# Run this BEFORE editing /etc/udev/rules.d/99-apc-ups.rules so you know which
# serials to fill in.
#
# Usage:  ./find-apc-serials.sh
set -euo pipefail

if ! command -v lsusb >/dev/null 2>&1; then
    echo "lsusb not found. Install with: sudo apt install usbutils" >&2
    exit 1
fi

printf "%-6s %-6s %-20s %-16s %s\n" "BUS" "DEV" "SERIAL" "HIDDEV" "MODEL"
printf "%-6s %-6s %-20s %-16s %s\n" "---" "---" "------" "------" "-----"

# APC vendor ID is 051d. Walk every USB device with that vendor.
for dev in /sys/bus/usb/devices/*/idVendor; do
    vendor=$(cat "$dev" 2>/dev/null || true)
    [[ "$vendor" != "051d" ]] && continue

    devdir=$(dirname "$dev")
    serial=$(cat "$devdir/serial" 2>/dev/null || echo "NO_SERIAL")
    product=$(cat "$devdir/product" 2>/dev/null || echo "?")
    busnum=$(cat "$devdir/busnum" 2>/dev/null || echo "?")
    devnum=$(cat "$devdir/devnum" 2>/dev/null || echo "?")

    # Find the hiddev node for this device, if present
    hiddev=$(find "$devdir" -name "hiddev*" -type d 2>/dev/null | head -1 | xargs -r basename)
    hiddev=${hiddev:-none}

    printf "%-6s %-6s %-20s %-16s %s\n" \
        "$busnum" "$devnum" "$serial" "$hiddev" "$product"
done

echo
echo "Copy each SERIAL above into /etc/udev/rules.d/99-apc-ups.rules, then:"
echo "    sudo udevadm control --reload && sudo udevadm trigger"
