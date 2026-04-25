#!/usr/bin/env python3
"""
apc-mqtt-bridge.py — Poll multiple apcupsd daemons and publish status to MQTT.

Reads config from environment:
    MQTT_HOST           MQTT broker host (default: 127.0.0.1)
    MQTT_PORT           MQTT broker port (default: 1883)
    MQTT_USER           Optional MQTT username
    MQTT_PASS           Optional MQTT password
    MQTT_TOPIC_PREFIX   Topic prefix (default: ups)
    POLL_INTERVAL       Seconds between polls (default: 30)
    UPS_HOSTS           Comma-separated list: name@host:port,name@host:port,...
                        e.g. lab1@127.0.0.1:3551,lab2@127.0.0.1:3552

Publishes the following per UPS:
    {prefix}/{name}/state        Full JSON status (retained)
    {prefix}/{name}/alert        JSON published on state transitions
    {prefix}/{name}/error        Text, on poll failure
    {prefix}/{name}/available    "online" / "offline" (retained, LWT-style)

The STATE topic is retained so late subscribers see the last known value.
ALERT fires once per status change so your downstream alerting (Twilio etc.)
doesn't get a notification on every poll while the UPS is on battery.
"""

import json
import logging
import os
import socket
import sys
import time
from dataclasses import dataclass, field
from typing import Optional

import paho.mqtt.client as mqtt


log = logging.getLogger("apc-bridge")


# -----------------------------------------------------------------------------
# apcupsd NIS protocol client
# -----------------------------------------------------------------------------

def apcaccess_status(host: str, port: int, timeout: float = 5.0) -> dict:
    """
    Speak the apcupsd NIS protocol directly — no subprocess to apcaccess needed.

    The protocol is trivial: connect, send a 16-bit big-endian length followed
    by the command bytes ("status"), then read length-prefixed reply lines
    until you get a zero-length frame.
    """
    result: dict = {}
    with socket.create_connection((host, port), timeout=timeout) as s:
        cmd = b"status"
        s.sendall(len(cmd).to_bytes(2, "big") + cmd)

        buf = b""
        while True:
            # Read 2-byte length prefix
            while len(buf) < 2:
                chunk = s.recv(4096)
                if not chunk:
                    raise ConnectionError("apcupsd closed connection mid-frame")
                buf += chunk
            n = int.from_bytes(buf[:2], "big")
            buf = buf[2:]
            if n == 0:
                break
            # Read n bytes of payload
            while len(buf) < n:
                chunk = s.recv(4096)
                if not chunk:
                    raise ConnectionError("apcupsd closed connection mid-payload")
                buf += chunk
            line = buf[:n].decode("ascii", errors="replace")
            buf = buf[n:]

            if ":" in line:
                key, _, value = line.partition(":")
                result[key.strip()] = value.strip()
    return result


# -----------------------------------------------------------------------------
# Value parsing
# -----------------------------------------------------------------------------

def _first_float(s: Optional[str]) -> Optional[float]:
    if not s:
        return None
    try:
        return float(s.split()[0])
    except (ValueError, IndexError):
        return None


def _first_int(s: Optional[str]) -> Optional[int]:
    f = _first_float(s)
    return int(f) if f is not None else None


def normalize(raw: dict) -> dict:
    """
    Turn the apcupsd key/value strings into clean typed values. Missing fields
    are returned as None rather than missing — easier for downstream consumers
    to build dashboards that don't blow up on model variance.
    """
    return {
        "status":            raw.get("STATUS"),
        "model":             raw.get("MODEL"),
        "serial":            raw.get("SERIALNO"),
        "firmware":          raw.get("FIRMWARE"),
        "battery_date":      raw.get("BATTDATE"),
        "line_v":            _first_float(raw.get("LINEV")),
        "nominal_line_v":    _first_float(raw.get("NOMINV")),
        "output_v":          _first_float(raw.get("OUTPUTV")),
        "load_pct":          _first_float(raw.get("LOADPCT")),
        "battery_pct":       _first_float(raw.get("BCHARGE")),
        "battery_v":         _first_float(raw.get("BATTV")),
        "nominal_battery_v": _first_float(raw.get("NOMBATTV")),
        "runtime_min":       _first_float(raw.get("TIMELEFT")),
        "nominal_power_w":   _first_int(raw.get("NOMPOWER")),
        "line_freq_hz":      _first_float(raw.get("LINEFREQ")),
        "internal_temp_c":   _first_float(raw.get("ITEMP")),
        "line_transfer_low":  _first_float(raw.get("LOTRANS")),
        "line_transfer_high": _first_float(raw.get("HITRANS")),
        "num_xfers":         _first_int(raw.get("NUMXFERS")),
        "time_on_batt_sec":  _first_int(raw.get("TONBATT")),
        "cum_on_batt_sec":   _first_int(raw.get("CUMONBATT")),
        "last_xfer_reason":  raw.get("LASTXFER"),
        "last_xfer_on":      raw.get("XONBATT"),
        "last_xfer_off":     raw.get("XOFFBATT"),
        "selftest_result":   raw.get("SELFTEST"),
        "status_flag":       raw.get("STATFLAG"),
        "mains_v":           _first_float(raw.get("MBATTCHG")),  # model-specific
        "apcupsd_version":   raw.get("VERSION"),
        "hostname":          raw.get("HOSTNAME"),
        "ts":                int(time.time()),
    }


# -----------------------------------------------------------------------------
# Per-UPS state tracking (for edge-triggered alerts)
# -----------------------------------------------------------------------------

@dataclass
class UPSTarget:
    name: str
    host: str
    port: int
    last_status: Optional[str] = None
    last_publish_ok: bool = False
    consecutive_errors: int = 0
    history: list = field(default_factory=list)


def parse_targets(spec: str) -> list[UPSTarget]:
    """
    Parse 'lab1@127.0.0.1:3551,lab2@127.0.0.1:3552' into UPSTarget objects.
    """
    targets = []
    for entry in spec.split(","):
        entry = entry.strip()
        if not entry:
            continue
        if "@" not in entry:
            raise ValueError(f"Bad UPS_HOSTS entry (missing @): {entry!r}")
        name, addr = entry.split("@", 1)
        if ":" in addr:
            host, port = addr.rsplit(":", 1)
            port = int(port)
        else:
            host, port = addr, 3551
        targets.append(UPSTarget(name=name.strip(), host=host.strip(), port=port))
    return targets


# -----------------------------------------------------------------------------
# MQTT
# -----------------------------------------------------------------------------

def make_mqtt_client(host: str, port: int,
                     user: Optional[str], password: Optional[str],
                     client_id: str) -> mqtt.Client:
    client = mqtt.Client(client_id=client_id, clean_session=True)
    if user:
        client.username_pw_set(user, password or "")
    client.reconnect_delay_set(min_delay=1, max_delay=60)
    # Last-will for the bridge itself, so you can alert if the bridge dies
    client.will_set(
        f"{os.environ.get('MQTT_TOPIC_PREFIX', 'ups')}/_bridge/available",
        payload="offline", qos=1, retain=True,
    )
    client.connect_async(host, port, keepalive=60)
    client.loop_start()
    return client


def publish_state(client: mqtt.Client, prefix: str, target: UPSTarget, payload: dict) -> None:
    topic = f"{prefix}/{target.name}/state"
    client.publish(topic, json.dumps(payload, default=str), qos=1, retain=True)
    client.publish(f"{prefix}/{target.name}/available", "online", qos=1, retain=True)


def publish_alert(client: mqtt.Client, prefix: str, target: UPSTarget,
                  old_status: Optional[str], new_status: Optional[str],
                  payload: dict) -> None:
    alert = {
        "ups": target.name,
        "event": "status_change",
        "from": old_status,
        "to": new_status,
        "snapshot": payload,
    }
    client.publish(f"{prefix}/{target.name}/alert",
                   json.dumps(alert, default=str), qos=1, retain=False)


def publish_error(client: mqtt.Client, prefix: str, target: UPSTarget, err: str) -> None:
    client.publish(f"{prefix}/{target.name}/error", err, qos=1, retain=False)
    client.publish(f"{prefix}/{target.name}/available", "offline", qos=1, retain=True)


# -----------------------------------------------------------------------------
# Main loop
# -----------------------------------------------------------------------------

def main() -> int:
    logging.basicConfig(
        level=os.environ.get("LOG_LEVEL", "INFO"),
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )

    mqtt_host = os.environ.get("MQTT_HOST", "127.0.0.1")
    mqtt_port = int(os.environ.get("MQTT_PORT", "1883"))
    mqtt_user = os.environ.get("MQTT_USER") or None
    mqtt_pass = os.environ.get("MQTT_PASS") or None
    prefix    = os.environ.get("MQTT_TOPIC_PREFIX", "ups")
    interval  = int(os.environ.get("POLL_INTERVAL", "30"))
    spec      = os.environ.get("UPS_HOSTS", "lab1@127.0.0.1:3551")

    targets = parse_targets(spec)
    log.info("Monitoring %d UPS target(s): %s",
             len(targets),
             ", ".join(f"{t.name}@{t.host}:{t.port}" for t in targets))

    client = make_mqtt_client(mqtt_host, mqtt_port, mqtt_user, mqtt_pass,
                              client_id=f"apc-bridge-{socket.gethostname()}")
    client.publish(f"{prefix}/_bridge/available", "online", qos=1, retain=True)

    try:
        while True:
            cycle_start = time.monotonic()
            for t in targets:
                try:
                    raw = apcaccess_status(t.host, t.port)
                    if not raw:
                        raise RuntimeError("empty response from apcupsd")
                    payload = normalize(raw)
                    publish_state(client, prefix, t, payload)

                    new_status = payload.get("status")
                    if t.last_status is not None and new_status != t.last_status:
                        log.info("[%s] status transition: %s → %s",
                                 t.name, t.last_status, new_status)
                        publish_alert(client, prefix, t, t.last_status, new_status, payload)
                    t.last_status = new_status
                    t.consecutive_errors = 0
                    t.last_publish_ok = True

                except (socket.timeout, ConnectionError, OSError, ValueError, RuntimeError) as e:
                    t.consecutive_errors += 1
                    msg = f"{type(e).__name__}: {e}"
                    log.warning("[%s] poll failed (%d consecutive): %s",
                                t.name, t.consecutive_errors, msg)
                    publish_error(client, prefix, t, msg)
                    t.last_publish_ok = False

            elapsed = time.monotonic() - cycle_start
            sleep_for = max(1.0, interval - elapsed)
            time.sleep(sleep_for)

    except KeyboardInterrupt:
        log.info("Shutting down (SIGINT).")
    finally:
        client.publish(f"{prefix}/_bridge/available", "offline", qos=1, retain=True)
        client.loop_stop()
        client.disconnect()
    return 0


if __name__ == "__main__":
    sys.exit(main())
