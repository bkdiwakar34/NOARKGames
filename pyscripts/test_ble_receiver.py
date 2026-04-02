"""BLE central test receiver for NOARK position data.

Mirrors what Godot/GDBLE does: scans for NOARK_Tracker, connects, subscribes
to position notifications, and prints decoded packets.

Run this on the PC to verify BLE communication from the RPi before involving
Godot/Rust at all.

Usage
-----
    pip install bleak
    python pyscripts/test_ble_receiver.py

If the device is not found, all discovered devices are printed so you can
see what is actually advertising and check the name matches.
"""

import asyncio
import struct
import sys

from bleak import BleakClient, BleakScanner

DEVICE_NAME   = "NOARK_Tracker"
SERVICE_UUID  = "4e4f4152-4b00-0000-0000-000000000000"
POSITION_UUID = "4e4f4152-4b01-0000-0000-000000000000"
COMMAND_UUID  = "4e4f4152-4b02-0000-0000-000000000000"

MSG_CODES = {2.0: "START", -99.0: "STOP", 5.0: "RESET", 0.0: "IDLE"}
packet_count = 0


def on_notification(_sender, data: bytearray) -> None:
    global packet_count
    if len(data) < 16:
        print(f"[RX] short packet ({len(data)} bytes): {data.hex()}")
        return
    msg, x, y, z = struct.unpack_from("<ffff", data)
    label = MSG_CODES.get(msg, f"code={msg:.1f}")
    packet_count += 1
    print(f"[RX #{packet_count:04d}] {label:<8}  x={x:+.4f}  y={y:+.4f}  z={z:+.4f}")


async def scan_and_list() -> None:
    """Fallback: list every advertising device so we can see what's out there."""
    print("[BLE] Listing all advertising devices (5 s)…")
    devices = await BleakScanner.discover(timeout=5.0)
    if not devices:
        print("[BLE] No BLE devices found at all — check Bluetooth is on")
        return
    for d in sorted(devices, key=lambda d: d.rssi or -999, reverse=True):
        print(f"  rssi={d.rssi:4d}  addr={d.address}  name={d.name!r}")


async def main() -> None:
    print(f"[BLE] Scanning for '{DEVICE_NAME}' (15 s timeout)…")

    device = await BleakScanner.find_device_by_name(DEVICE_NAME, timeout=15.0)

    if device is None:
        print(f"[BLE] '{DEVICE_NAME}' not found.")
        await scan_and_list()
        sys.exit(1)

    print(f"[BLE] Found → {device.name!r}  addr={device.address}")
    print("[BLE] Connecting…")

    async with BleakClient(device) as client:
        print(f"[BLE] Connected: {client.is_connected}")

        # Dump service/characteristic map — useful for debugging UUID mismatches
        print("[BLE] GATT map:")
        for svc in client.services:
            marker = " ← NOARK service" if svc.uuid.lower() == SERVICE_UUID.lower() else ""
            print(f"  service  {svc.uuid}{marker}")
            for ch in svc.characteristics:
                print(f"    char   {ch.uuid}  props={ch.properties}")

        # Subscribe to position notifications
        await client.start_notify(POSITION_UUID, on_notification)
        print("[BLE] Subscribed to position notifications — streaming (Ctrl+C to stop)\n")

        # Tell the peripheral we are connected
        await client.write_gatt_char(COMMAND_UUID, b"CONNECTED", response=False)

        try:
            while client.is_connected:
                await asyncio.sleep(3.0)
                # Heartbeat keeps the peripheral happy (mirrors Godot behaviour)
                await client.write_gatt_char(COMMAND_UUID, b"CONNECTED", response=False)
        except (asyncio.CancelledError, KeyboardInterrupt):
            pass

        await client.stop_notify(POSITION_UUID)
        try:
            await client.write_gatt_char(COMMAND_UUID, b"STOP", response=False)
        except Exception:
            pass

    print(f"\n[BLE] Disconnected — received {packet_count} packet(s) total")


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\n[BLE] Stopped by user")
