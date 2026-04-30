# Host-side setup — Proxmox USB passthrough to unprivileged LXC

> *"The hand that holds the key is the hand that opens the door."*

This document covers what runs on the **Proxmox host**, not inside the
container. Unprivileged LXC USB passthrough has more moving parts than
privileged because the container's UIDs are mapped (root inside = uid
100000 on the host), so device permissions need adjustment.

Read this **before** running `install-lxc.sh` inside the container.
The container-side install will refuse to fully start apcupsd if the
host-side passthrough isn't configured first.

---

## Concept

```
Proxmox host                     │   Container (unprivileged)
                                 │
APC UPS plugs in here ──USB──►   │
                                 │
/dev/usb/hiddev0  ←── kernel ── ─│ ─►  /dev/usb/hiddev0 (bind-mounted in)
  (owned root:root)              │       (uid 100000:100000 if not fixed)
                                 │
                                 │   apcupsd reads the device
                                 │     → talks to UPS
                                 │     → exposes status on TCP 3551
                                 │     → bridge → MQTT → dashboard
```

Three host-side things need to happen for this to work:

1. A **udev rule on the host** sets `/dev/usb/hiddev*` ownership to the
   uid range your unprivileged container's root maps to (default
   `100000:100000`), so the container's apcupsd can actually open it
2. **LXC config entries** in `/etc/pve/lxc/<vmid>.conf` allow the cgroup2
   device class and bind-mount the device nodes into the container
3. The container is **restarted** so the new mounts take effect

---

## 1. Find the UPS device on the Proxmox host

Plug each UPS into the host. From the host shell:

```bash
lsusb -d 051d:
```

You should see one line per APC. Example:

```
Bus 001 Device 005: ID 051d:0002 American Power Conversion Back-UPS XS 1500G
```

Find the corresponding hiddev node:

```bash
ls -la /dev/usb/hiddev*
```

Expected:

```
crw------- 1 root root 180, 96 Apr 25 18:00 /dev/usb/hiddev0
```

Note: only root can read it by default. That's the problem we're solving.

---

## 2. Install the host-side udev rule

On the **Proxmox host**, drop in the udev rule that fixes ownership when
an APC USB-HID device appears:

```bash
cat > /etc/udev/rules.d/99-watchmen-apc-host.rules <<'EOF'
# /etc/udev/rules.d/99-watchmen-apc-host.rules (HOST SIDE)
#
# Re-own APC USB-HID device nodes so they're readable by the unprivileged
# LXC container's mapped root user (default uid 100000).
#
# If your container uses a different UID mapping (custom lxc.idmap), adjust
# OWNER and GROUP accordingly.

SUBSYSTEM=="usb",     ATTRS{idVendor}=="051d", MODE="0660", OWNER="100000", GROUP="100000"
SUBSYSTEM=="usbmisc", KERNEL=="hiddev*", ATTRS{idVendor}=="051d", MODE="0660", OWNER="100000", GROUP="100000"
EOF

udevadm control --reload
udevadm trigger
```

Verify it worked — re-plug the UPS USB cable, then:

```bash
ls -la /dev/usb/hiddev0
```

Should now show:

```
crw-rw---- 1 100000 100000 180, 96 Apr 25 18:05 /dev/usb/hiddev0
```

The `100000:100000` is the host-visible representation of root inside
the unprivileged container.

---

## 3. Edit the LXC container config

Find your container's VMID (visible in the Proxmox web UI or via `pct list`).
Assume it's `200` for examples below — substitute your actual number.

Edit `/etc/pve/lxc/200.conf`:

```bash
nano /etc/pve/lxc/200.conf
```

Add these lines at the bottom:

```ini
# --- watchmen USB passthrough ---
# Allow access to USB device class (cgroup2 syntax for modern Proxmox)
lxc.cgroup2.devices.allow: c 180:* rwm
lxc.cgroup2.devices.allow: c 189:* rwm

# Bind-mount the hiddev nodes into the container
# Adjust these to match the actual hiddev nodes on your host (see ls /dev/usb/)
lxc.mount.entry: /dev/usb/hiddev0 dev/usb/hiddev0 none bind,optional,create=file
lxc.mount.entry: /dev/usb/hiddev1 dev/usb/hiddev1 none bind,optional,create=file
lxc.mount.entry: /dev/usb/hiddev2 dev/usb/hiddev2 none bind,optional,create=file
lxc.mount.entry: /dev/usb/hiddev3 dev/usb/hiddev3 none bind,optional,create=file

# Bind-mount the entire usb directory (lets new UPSs appear without re-config)
lxc.mount.entry: /dev/usb dev/usb none bind,optional,create=dir 0 0
```

The `optional` flag means the container will still start if a particular
hiddev node doesn't exist (e.g., if you have one UPS plugged in, only
hiddev0 will exist; hiddev1-3 are anticipatory).

**Save, then restart the container:**

```bash
pct restart 200
```

---

## 4. Verify from inside the container

```bash
pct exec 200 -- ls -la /dev/usb/
```

You should see the hiddev nodes accessible from inside:

```
crw-rw---- 1 root root 180, 96 Apr 25 18:05 hiddev0
```

(Inside the unprivileged container, `100000:100000` from the host appears
as `root:root` thanks to UID mapping.)

```bash
pct exec 200 -- lsusb -d 051d:
```

Should show the same APC line you saw on the host. If that's working,
container-side install will work.

---

## 5. Now run the container-side install

```bash
# From the host, push the watchmen tarball into the container:
pct push 200 watchmen-v0.2.x.tar.gz /root/watchmen.tar.gz

# Enter the container
pct enter 200

# Inside the container:
cd /root
tar xzf watchmen.tar.gz
cd watchmen
./install-lxc.sh
```

Or if you're using git inside the container:

```bash
pct enter 200
apt install -y git    # if not already
cd /root
git clone https://github.com/SuperAngryMonkey/watchmen.git
cd watchmen
git checkout lxc-deployment
./install-lxc.sh
```

---

## Adding more UPSs later

When you plug in additional UPSs:

1. The host-side udev rule already handles ownership — no change needed
2. As long as your existing `lxc.mount.entry` lines cover hiddev0 through
   hiddev3 (and `optional,create=file`), new devices appear automatically
3. Inside the container: edit the bridge's `UPS_HOSTS` env via
   `systemctl edit apc-mqtt-bridge` and add the new lab port
4. Start the new instance: `systemctl enable --now apcupsd@lab2`

If you add a 5th UPS or beyond: extend the `lxc.mount.entry` lines in
the LXC conf for hiddev4+, then `pct restart` the container.

---

## Troubleshooting

### Inside the container: `find-apc-serials` shows nothing

Check from the host first:

```bash
lsusb -d 051d:                # UPS visible to host?
ls -la /dev/usb/hiddev*       # Owned 100000:100000?
```

If both look right but the container still doesn't see them:

```bash
pct exec <vmid> -- ls -la /dev/usb/   # devices visible inside?
cat /etc/pve/lxc/<vmid>.conf | grep -E 'cgroup2|mount.entry'
```

If the entries are missing, you didn't save the config correctly.
If they're there but the container doesn't see the devices, restart:

```bash
pct restart <vmid>
```

### `apcupsd` errors with "Permission denied" on the device

Check inside the container:

```bash
pct exec <vmid> -- stat /dev/usb/hiddev0
```

Should show `Uid: ( 0/ root)`. If it shows `Uid: (65534/ nobody)` or
something weird, the host-side udev rule isn't applying. Re-trigger:

```bash
udevadm control --reload && udevadm trigger
```

Then re-plug the USB cable to force re-enumeration with the new rule.

### Container won't start after editing the LXC conf

Most common: typo in `lxc.cgroup2.devices.allow` line. Proxmox 8+ uses
cgroup2 syntax; older Proxmox uses `lxc.cgroup.devices.allow` (no "2").
Check your Proxmox version:

```bash
pveversion
```

If `pve-manager/7.x`: use `lxc.cgroup.devices.allow`
If `pve-manager/8.x` or later: use `lxc.cgroup2.devices.allow`

### `nesting=1` and `keyctl=1` features

If the container has issues running systemd or apcupsd, ensure the
container has nesting enabled in the Proxmox web UI (Container → Options
→ Features → Nesting). Or via CLI:

```bash
pct set <vmid> -features nesting=1,keyctl=1
pct restart <vmid>
```

---

## Why unprivileged?

Worth a brief justification since "just use privileged, it's easier" is
common advice:

- **Defense in depth.** A container compromise in privileged mode means
  the attacker has uid 0 on the host. Unprivileged means uid 100000+,
  which has no host privileges at all
- **Mirrors production hardening practices.** When you eventually deploy
  this to customer sites or your own production stack, you'll already
  have the unprivileged passthrough story figured out
- **Modern Proxmox default.** Web UI defaults to unprivileged for new
  containers since Proxmox 7. Following the path of least resistance
  there is also the safer path

The only real cost is the host-side configuration above — which is a
one-time setup per Proxmox host, and the udev rule covers all current and
future APC UPSs you plug in.

---

## Optional: Tailscale inside the LXC

If you want the container reachable over Tailscale (recommended for
multi-site deployments):

In `/etc/pve/lxc/<vmid>.conf`:

```ini
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
```

Restart the container, then inside:

```bash
curl -fsSL https://tailscale.com/install.sh | sh
tailscale up
```

The dashboard becomes reachable at `http://<tailscale-ip>:8080/` from
anywhere on your tailnet.
