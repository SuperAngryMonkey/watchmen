#!/usr/bin/env bash
# deploy-lxc.sh — Deploy watchmen into a Proxmox unprivileged LXC container.
#
# This script is run from your laptop. It SSHs to the Proxmox HOST (root),
# uses `pct push` to copy the tarball into the container, and `pct exec` to
# run the install. Assumes the host-side USB passthrough is already
# configured per HOST-SIDE-SETUP.md.
#
# Usage:
#   PVE_HOST=proxmox.local CT_ID=200 ./deploy-lxc.sh
#
# Or with all defaults (override as needed):
#   ./deploy-lxc.sh
#
# Required:
#   - SSH access to the Proxmox host as root (or sudo without password)
#   - The container must already exist and be running
#   - watchmen-v0.2.x.tar.gz in the current directory
#
# What it does NOT do:
#   - Configure host-side USB passthrough — that's a one-time manual setup
#     described in HOST-SIDE-SETUP.md
#   - Create the LXC container — bring your own

set -euo pipefail

PVE_USER="${PVE_USER:-root}"
PVE_HOST="${PVE_HOST:-proxmox.local}"
CT_ID="${CT_ID:-200}"
TARBALL="${TARBALL:-$(ls -1 watchmen-v*.tar.gz 2>/dev/null | head -1)}"

if [[ -z "$TARBALL" || ! -f "$TARBALL" ]]; then
    echo "error: tarball not found in $(pwd)" >&2
    echo "  set TARBALL=path/to/watchmen-vX.Y.Z.tar.gz" >&2
    exit 1
fi

PVE_ADDR="${PVE_USER}@${PVE_HOST}"

echo "==> Deploying $TARBALL"
echo "    Proxmox host:  $PVE_ADDR"
echo "    Container ID:  $CT_ID"

echo
echo "==> Checking SSH access to Proxmox host..."
if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "$PVE_ADDR" 'true' 2>/dev/null; then
    echo "    (SSH key auth not set up — will prompt for password)"
fi

echo
echo "==> Confirming container $CT_ID exists and is running..."
ssh -t "$PVE_ADDR" "
    set -e
    if ! pct status $CT_ID >/dev/null 2>&1; then
        echo 'ERROR: container $CT_ID does not exist on this Proxmox host'
        exit 1
    fi
    status=\$(pct status $CT_ID | awk '{print \$2}')
    echo \"    Container $CT_ID status: \$status\"
    if [ \"\$status\" != 'running' ]; then
        echo 'ERROR: container is not running. Start it first: pct start $CT_ID'
        exit 1
    fi
"

echo
echo "==> Verifying USB passthrough is configured..."
ssh -t "$PVE_ADDR" "
    set -e
    if ! grep -q 'lxc.mount.entry.*hiddev' /etc/pve/lxc/$CT_ID.conf 2>/dev/null; then
        echo 'WARNING: no lxc.mount.entry for hiddev devices in container config.'
        echo '         USB passthrough is likely NOT configured yet.'
        echo '         See HOST-SIDE-SETUP.md before proceeding.'
        echo ''
        echo '         Continuing anyway — install will succeed but apcupsd'
        echo '         will not be able to read any UPS until passthrough is set up.'
    else
        echo '    USB passthrough mount entries found in container config.'
    fi
"

echo
echo "==> Copying tarball to Proxmox host..."
scp "$TARBALL" "${PVE_ADDR}:/tmp/watchmen.tar.gz"

echo
echo "==> Pushing tarball into container $CT_ID..."
ssh -t "$PVE_ADDR" "
    set -e
    pct push $CT_ID /tmp/watchmen.tar.gz /root/watchmen.tar.gz
    rm /tmp/watchmen.tar.gz
"

echo
echo "==> Extracting and installing inside container $CT_ID..."
ssh -t "$PVE_ADDR" "
    set -e
    pct exec $CT_ID -- bash -c '
        set -e
        cd /root
        rm -rf watchmen
        tar xzf watchmen.tar.gz
        cd watchmen
        ./install-lxc.sh
    '
"

echo
echo "==============================================================="
echo "Deployed. Next steps inside the container:"
echo
echo "  ssh ${PVE_ADDR}"
echo "  pct enter $CT_ID"
echo
echo "  # If USB passthrough was already set up:"
echo "  find-apc-serials"
echo "  systemctl enable --now apcupsd@lab1 apc-mqtt-bridge watchmen-web"
echo "  apcaccess -h 127.0.0.1:3551"
echo
echo "  # Find the container's IP:"
echo "  ip -4 addr show eth0 | grep inet"
echo
echo "Then open the dashboard:"
echo "  http://<container-ip>:8080/"
echo "==============================================================="
