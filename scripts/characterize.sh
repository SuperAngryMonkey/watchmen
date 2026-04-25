#!/usr/bin/env bash
# characterize.sh — Capture a full profile of a connected APC UPS for your
# per-model reference library. Run once per model you encounter in the field.
#
# Usage:
#   ./characterize.sh <name>
#     where <name> is one of: lab1, lab2, lab3, lab4
#
#   Output goes to stdout — redirect to a dated file:
#     ./characterize.sh lab1 > ~/apc-characterizations/$(date +%F)-smartups-1500.txt
#
# What it captures:
#   1. lsusb -v for the matching APC (vendor + product IDs, strings, descriptors)
#   2. HID report descriptor via usbhid-dump (if available) or /sys
#   3. Full apcaccess status dump (every field apcupsd surfaces for this model)
#   4. apcupsd events log tail (shows recent transitions, COMMLOST, selftests)
#
# Why this matters: different APC models populate different fields. Some don't
# report NOMPOWER. Some don't report BATTV. Some report INTERNAL_TEMP, most
# don't. Building a per-model library lets your downstream code know what to
# expect — no more "why is the Grafana dashboard blank for this one unit."

set -euo pipefail

name="${1:-}"
if [[ -z "$name" ]]; then
    echo "Usage: $0 <lab1|lab2|lab3|lab4>" >&2
    exit 1
fi

port_for_name() {
    case "$1" in
        lab1) echo 3551 ;;
        lab2) echo 3552 ;;
        lab3) echo 3553 ;;
        lab4) echo 3554 ;;
        *) echo "Unknown name: $1" >&2; exit 1 ;;
    esac
}

port=$(port_for_name "$name")

echo "================================================================"
echo "APC UPS Characterization — $name (apcupsd port $port)"
echo "Captured: $(date -Iseconds)"
echo "Host: $(hostname)"
echo "Kernel: $(uname -r)"
echo "================================================================"
echo

# --------- 1. apcaccess full status ---------
echo "--- apcaccess status (port $port) ---"
if command -v apcaccess >/dev/null 2>&1; then
    if ! apcaccess -h "127.0.0.1:$port" 2>&1; then
        echo "(apcaccess failed — is apcupsd@$name running?)"
    fi
else
    echo "(apcaccess not installed)"
fi
echo

# --------- 2. lsusb for APC devices ---------
echo "--- lsusb (APC vendor 051d) ---"
lsusb -d 051d: 2>/dev/null || echo "(none found)"
echo
echo "--- lsusb -v (full device descriptors) ---"
# lsusb -v needs root to read some fields
if [[ $EUID -eq 0 ]]; then
    lsusb -v -d 051d: 2>&1 || echo "(lsusb -v failed)"
else
    echo "(run as root for full descriptor dump — try: sudo $0 $name)"
    lsusb -v -d 051d: 2>&1 | head -80 || true
fi
echo

# --------- 3. HID report descriptor ---------
echo "--- HID report descriptor (usbhid-dump) ---"
if command -v usbhid-dump >/dev/null 2>&1; then
    if [[ $EUID -eq 0 ]]; then
        usbhid-dump -d 051d: 2>&1 || echo "(usbhid-dump failed)"
    else
        echo "(needs root — skipping)"
    fi
else
    echo "(install with: sudo apt install usbutils-hid  -- or -- apt install usbhid-dump)"
fi
echo

# --------- 4. /sys walk for HID report_descriptor ---------
echo "--- /sys HID report descriptors (APC vendor) ---"
for rd in /sys/bus/usb/devices/*/*/*/report_descriptor; do
    [[ -e "$rd" ]] || continue
    devdir=$(dirname "$rd")
    # Walk up to find the vendor
    search="$devdir"
    while [[ "$search" != "/" ]]; do
        if [[ -f "$search/idVendor" ]]; then
            vendor=$(cat "$search/idVendor")
            if [[ "$vendor" == "051d" ]]; then
                product=$(cat "$search/product" 2>/dev/null || echo "?")
                serial=$(cat "$search/serial" 2>/dev/null || echo "?")
                echo "  Device: $product"
                echo "  Serial: $serial"
                echo "  Path:   $rd"
                echo "  Size:   $(stat -c%s "$rd") bytes"
                echo "  Hex dump:"
                xxd "$rd" 2>/dev/null | sed 's/^/    /' || hexdump -C "$rd" | sed 's/^/    /'
                echo
                break
            fi
        fi
        search=$(dirname "$search")
    done
done

# --------- 5. apcupsd events log ---------
echo "--- Recent events ($name) ---"
logfile="/var/log/apcupsd-$name.events"
if [[ -r "$logfile" ]]; then
    tail -n 50 "$logfile" || true
else
    echo "(no events log at $logfile yet — this is normal for a fresh install)"
fi
echo

echo "================================================================"
echo "End of characterization for $name"
echo "================================================================"
