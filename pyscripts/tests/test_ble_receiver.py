"""BLE central test receiver for NOARK position data — simplepyble version.

Mirrors what Godot/GDBLE does: scans for NOARK_Tracker, connects, subscribes
to position notifications, and prints decoded packets.

Run this on the PC to verify BLE communication from the RPi before involving
Godot/Rust at all.

Usage
-----
    pip install simplepyble
    python pyscripts/test_ble_receiver.py
"""

import struct
import sys
import time

import simplepyble

DEVICE_NAME   = "NOARK_Tracker"
SERVICE_UUID  = "4e4f4152-4b00-0000-0000-000000000000"
POSITION_UUID = "4e4f4152-4b01-0000-0000-000000000000"
COMMAND_UUID  = "4e4f4152-4b02-0000-0000-000000000000"

MSG_CODES = {2.0: "START", -99.0: "STOP", 5.0: "RESET", 0.0: "IDLE"}
packet_count = 0


def on_notification(data: bytes) -> None:
    global packet_count
    if len(data) < 16:
        print(f"[RX] short packet ({len(data)} bytes): {data.hex()}")
        return
    msg, x, y, z = struct.unpack_from("<ffff", data)
    label = MSG_CODES.get(msg, f"code={msg:.1f}")
    packet_count += 1
    print(f"[RX #{packet_count:04d}] {label:<8}  x={x:+.4f}  y={y:+.4f}  z={z:+.4f}")


def main() -> None:
    # ── adapter check ─────────────────────────────────────────────────────────
    adapters = simplepyble.Adapter.get_adapters()
    if not adapters:
        print("[BLE] No Bluetooth adapters found.")
        print("      • Make sure Bluetooth is enabled in Windows Settings")
        print("      • If no built-in BT, plug in a USB Bluetooth dongle")
        sys.exit(1)

    adapter = adapters[0]
    print(f"[BLE] Adapter: {adapter.identifier()}  addr={adapter.address()}")

    # Power on if the adapter supports it and reports itself off
    try:
        if not adapter.is_powered():
            print("[BLE] Adapter is off — powering on…")
            adapter.power_on()
            time.sleep(1.5)
    except Exception:
        pass  # some adapters don't expose power state; continue anyway

    # ── scan ──────────────────────────────────────────────────────────────────
    print(f"[BLE] Scanning 10 s for '{DEVICE_NAME}'…")
    adapter.scan_for(10_000)

    peripherals = adapter.scan_get_results()
    print(f"[BLE] Scan complete — {len(peripherals)} device(s) found:")

    target = None
    for p in peripherals:
        name = p.identifier()
        addr = p.address()
        rssi = p.rssi() if hasattr(p, "rssi") else "?"
        print(f"  rssi={rssi:>4}  addr={addr}  name={name!r}")
        if name == DEVICE_NAME:
            target = p

    if target is None:
        print(f"\n[BLE] '{DEVICE_NAME}' not in scan results.")
        if not peripherals:
            print("      No devices found at all — check Bluetooth adapter and RPi proximity.")
        else:
            print("      Check RPi is running ble_streamer.py and device name matches exactly.")
        sys.exit(1)

    # ── connect ───────────────────────────────────────────────────────────────
    print(f"\n[BLE] Connecting to {target.identifier()} @ {target.address()}…")
    target.connect()
    print(f"[BLE] Connected: {target.is_connected()}")

    # Dump GATT map — useful for UUID mismatch debugging
    print("[BLE] GATT map:")
    for svc in target.services():
        marker = "  ← NOARK service" if svc.uuid().lower() == SERVICE_UUID.lower() else ""
        print(f"  service  {svc.uuid()}{marker}")
        for ch in svc.characteristics():
            print(f"    char   {ch.uuid()}  caps={ch.capabilities()}")

    # ── subscribe ─────────────────────────────────────────────────────────────
    target.notify(SERVICE_UUID, POSITION_UUID, on_notification)
    print("\n[BLE] Subscribed to position notifications — streaming (Ctrl+C to stop)\n")

    target.write_command(SERVICE_UUID, COMMAND_UUID, b"CONNECTED")

    try:
        while target.is_connected():
            time.sleep(3.0)
            target.write_command(SERVICE_UUID, COMMAND_UUID, b"CONNECTED")
    except KeyboardInterrupt:
        pass

    # ── cleanup ───────────────────────────────────────────────────────────────
    try:
        target.unsubscribe(SERVICE_UUID, POSITION_UUID)
        target.write_command(SERVICE_UUID, COMMAND_UUID, b"STOP")
    except Exception:
        pass

    target.disconnect()
    print(f"\n[BLE] Disconnected — {packet_count} packet(s) received total")


if __name__ == "__main__":
    main()
