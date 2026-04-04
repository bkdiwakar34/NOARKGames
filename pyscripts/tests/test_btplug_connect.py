import asyncio
import struct
import sys

from bleak import BleakScanner, BleakClient

DEVICE_NAME   = "NOARK_Tracker"
SERVICE_UUID  = "4e4f4152-4b00-0000-0000-000000000000"
POSITION_UUID = "4e4f4152-4b01-0000-0000-000000000000"
COMMAND_UUID  = "4e4f4152-4b02-0000-0000-000000000000"

MSG_CODES = {2.0: "START", -99.0: "STOP", 5.0: "RESET", 0.0: "IDLE"}
packet_count = 0

def notification_handler(sender, data: bytearray):
    global packet_count
    if len(data) < 16:
        print(f"[RX] short packet ({len(data)} bytes): {data.hex()}")
        return
    msg, x, y, z = struct.unpack_from("<ffff", data)
    label = MSG_CODES.get(msg, f"code={msg:.1f}")
    packet_count += 1
    print(f"[RX #{packet_count:04d}] {label:<8}  x={x:+.4f}  y={y:+.4f}  z={z:+.4f}")

async def main():
    print(f"[BLE] Scanning for '{DEVICE_NAME}'...")
    
    # Scan for 10 seconds
    devices = await BleakScanner.discover(timeout=10.0)
    print(f"[BLE] Scan complete — {len(devices)} device(s) found:")
    
    target_device = None
    for d in devices:
        name = d.name or ""
        # Bleak BLEDevice might not expose rssi directly depending on version, 
        # but we mainly care about the name.
        print(f"  addr={d.address}  name={name!r}")
        if name == DEVICE_NAME:
            target_device = d
            
    if not target_device:
        print(f"\n[BLE] '{DEVICE_NAME}' not in scan results.")
        if not devices:
            print("      No devices found at all — check Bluetooth adapter and RPi proximity.")
        else:
            print("      Check RPi is running ble_streamer.py and device name matches exactly.")
        sys.exit(1)

    print(f"\n[BLE] Connecting to {target_device.name} @ {target_device.address}...")
    
    async with BleakClient(target_device) as client:
        print(f"[BLE] Connected: {client.is_connected}")
        
        # Dump GATT
        print("[BLE] GATT map:")
        for service in client.services:
            marker = "  <- NOARK service" if service.uuid.lower() == SERVICE_UUID.lower() else ""
            print(f"  service  {service.uuid}{marker}")
            for char in service.characteristics:
                print(f"    char   {char.uuid}  caps={char.properties}")

        # Subscribe
        await client.start_notify(POSITION_UUID, notification_handler)
        print("\n[BLE] Subscribed to position notifications — streaming (Ctrl+C to stop)\n")

        # Write CONNECTED command to start the stream if required
        try:
            await client.write_gatt_char(COMMAND_UUID, b"CONNECTED", response=False)
        except Exception as e:
            print(f"[BLE] Write without response failed or not supported by char: {e}")
            # Try with response if false fails
            try:
                await client.write_gatt_char(COMMAND_UUID, b"CONNECTED", response=True)
            except Exception as e:
                pass
        
        try:
            while client.is_connected:
                await asyncio.sleep(3.0)
                try:
                    await client.write_gatt_char(COMMAND_UUID, b"CONNECTED", response=False)
                except:
                    pass
        except asyncio.CancelledError:
            pass
            
        # Cleanup
        try:
            await client.stop_notify(POSITION_UUID)
            await client.write_gatt_char(COMMAND_UUID, b"STOP", response=False)
        except Exception as e:
            print(f"Error during cleanup: {e}")
            
    print(f"\n[BLE] Disconnected — {packet_count} packet(s) received total")

if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\n[BLE] Stopped by user")
