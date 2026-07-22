# bluez_native

High-performance BlueZ Bluetooth client for Linux, built on sdbus-cpp. Zero-copy characteristic notifications via `Dart_PostCObject_DL`.
Drop-in API replacement for [`canonical/bluez.dart`](https://github.com/canonical/bluez.dart)
with lower latency.

## Features

- Full BlueZ D-Bus API surface: adapters, devices, GATT services,
  characteristics, and descriptors
- Zero-copy characteristic notifications — bytes arrive directly from the
  sdbus-cpp event loop thread via `kExternalTypedData`
- API compatible with [canonical/bluez.dart](https://github.com/canonical/bluez.dart)
  for straightforward migration
- Discovery filter support (transport, RSSI threshold, UUIDs)
- `StartNotify` / `StopNotify` via `org.bluez.GattCharacteristic1`
- `ReadValue` / `WriteValue` for characteristics and descriptors

## Platform Support

| Platform | Scan | Connect | GATT Read/Write | Notifications |
|----------|------|---------|-----------------|---------------|
| Linux (BlueZ >= 5.50) | Yes | Yes | Yes | Yes (zero-copy) |
| macOS | No | No | No | No |
| Windows | No | No | No | No |

## Getting Started

### 1. Install system dependencies

Ubuntu/Debian:
```bash
sudo apt-get install cmake ninja-build clang libsystemd-dev pkg-config
```

Fedora:
```bash
sudo dnf install cmake ninja-build clang systemd-devel pkgconf-pkg-config
```

### 2. Add the package

```yaml
dependencies:
  bluez_native: ^0.1.0
```

### 3. Clone with submodules and build the native library

```bash
git clone --recurse-submodules https://github.com/jwinarske/bluez_native.git
cd bluez_native
cmake -B build native/ -GNinja -DCMAKE_BUILD_TYPE=Release
cmake --build build --parallel
```

### 4. Run a Dart example

Set `BLUEZ_NC_LIB` to the built shared library, then run:

```bash
export BLUEZ_NC_LIB=$PWD/build/libbluez_nc.so
dart run example/scan_devices.dart
```

### 5. Run the Flutter example

```bash
cd example/flutter_ble_scanner
flutter pub get
BLUEZ_NC_LIB=$PWD/../../build/libbluez_nc.so flutter run
```

## Quick Start

```dart
import 'package:bluez_native/bluez_native.dart';

Future<void> main() async {
  final client = BlueZClient();
  await client.connect();

  // Enumerate adapters
  for (final adapter in client.adapters) {
    print('${adapter.address} (${adapter.name})');
    await adapter.startDiscovery();
  }

  // Watch for new devices
  client.deviceAdded.listen((device) {
    print('Found: ${device.address}  RSSI: ${device.rssi}');
  });

  // After 10 seconds...
  await client.close();
}
```

## API Surface

### BlueZClient

Top-level entry point. Call `connect()` to establish a D-Bus connection
and snapshot the BlueZ object tree.

| Property / Method | Description |
|---|---|
| `adapters` | All known HCI adapters |
| `devices` | All known devices |
| `deviceAdded` | Stream of newly discovered devices |
| `deviceRemoved` | Stream of removed devices |
| `adapterChanged` | Stream of adapter property changes |
| `connect()` | Connect to BlueZ system bus |
| `close()` | Release all resources |

### BlueZAdapter

| Method | Description |
|---|---|
| `setPowered()` | Power the adapter on or off |
| `startDiscovery()` | Begin scanning |
| `stopDiscovery()` | Stop scanning |
| `setDiscoveryFilter()` | Set transport, RSSI, UUIDs filter |
| `removeDevice()` | Remove a cached device |

### BlueZDevice

| Property / Method | Description |
|---|---|
| `address`, `name`, `rssi`, `paired`, `connected` | Device state |
| `connect()` / `disconnect()` | Connection management |
| `pair()` / `cancelPairing()` | Pairing |
| `waitForServicesResolved()` | Wait for GATT discovery |
| `gattServices` | Discovered GATT services |
| `propertiesChanged` | Stream of changed property names |
| `manufacturerData` | BLE advertisement data |

### BlueZGattCharacteristic

| Property / Method | Description |
|---|---|
| `uuid`, `flags`, `mtu` | Characteristic metadata |
| `readValue()` | Read from the device |
| `writeValue(data)` | Write to the device |
| `startNotify()` | Subscribe to value notifications |
| `stopNotify()` | Unsubscribe |
| `value` | `Stream<List<int>>` of notification bytes |

### BlueZGattDescriptor

| Method | Description |
|---|---|
| `readValue()` | Read descriptor value |
| `writeValue(data)` | Write descriptor value |

## Characteristic Notifications

The notification path is zero-copy from the D-Bus signal to Dart:

```
BlueZ PropertiesChanged (sdbus event loop thread)
  -> signal handler
    -> Dart_PostCObject_DL (kExternalTypedData)
      -> Dart ReceivePort
        -> Stream<List<int>> listener
```

```dart
await char.startNotify();
await for (final bytes in char.value) {
  print('Received: $bytes');
}
await char.stopNotify();
```

## Migration from canonical/bluez.dart

```dart
// Before (canonical/bluez.dart)
import 'package:bluez/bluez.dart';
final client = BlueZClient();
await client.connect();

// After (bluez_native) — same API
import 'package:bluez_native/bluez_native.dart';
final client = BlueZClient();
await client.connect();
```

Key differences:

- `characteristic.value` emits `List<int>` directly (not `DBusValue` variants)
- `device.propertiesChanged` emits `List<String>` (changed property names)
- Errors are `BlueZOperationException` (not `DBusMethodResponseException`)
- No `dbus` package dependency required

## Examples

- [`scan_devices.dart`](example/scan_devices.dart) — scan and print discovered devices
- [`connect_device.dart`](example/connect_device.dart) — connect and enumerate services
- [`read_characteristic.dart`](example/read_characteristic.dart) — read a GATT value
- [`write_characteristic.dart`](example/write_characteristic.dart) — write hex bytes to a characteristic
- [`read_descriptor.dart`](example/read_descriptor.dart) — read all descriptors on a characteristic
- [`notify_characteristic.dart`](example/notify_characteristic.dart) — subscribe to notifications
- [`notify_regression.dart`](example/notify_regression.dart) — assert subscription *state* (`notifying` before/after), not just that bytes arrive
- [`pair_device.dart`](example/pair_device.dart) — pair with a device
- [`device_properties.dart`](example/device_properties.dart) — monitor live property changes (RSSI, connection state)
- [`flutter_ble_scanner/`](example/flutter_ble_scanner/) — Flutter app with scan, connect, and GATT UI

## Troubleshooting

### `org.bluez.Error.NotReady` — Resource Not Ready

The Bluetooth adapter is not powered on. Check its status and power it on:

```bash
bluetoothctl show          # look for "Powered: yes/no"
bluetoothctl power on
```

Or programmatically:

```dart
if (!adapter.powered) {
  await adapter.setPowered(true);
}
```

### `org.bluez.Error.Failed` when setting adapter properties

This is usually caused by **rfkill** blocking the adapter or insufficient permissions.

Check rfkill status:

```bash
rfkill list bluetooth
```

If it shows `Soft blocked: yes`, unblock it:

```bash
sudo rfkill unblock bluetooth
```

If rfkill is not the issue, the process may lack permission to change adapter
properties. Run with elevated privileges:

```bash
sudo BLUEZ_NC_LIB=$PWD/build/libbluez_nc.so dart run example/scan_devices.dart
```

### `BlueZServiceUnavailableException` — BlueZ service is not available

The BlueZ daemon is not running:

```bash
sudo systemctl start bluetooth
sudo systemctl enable bluetooth   # start on boot
```

### Verify the Bluetooth stack is working

```bash
systemctl status bluetooth        # daemon running?
rfkill list bluetooth             # not blocked?
bluetoothctl show                 # adapter visible and powered?
```

## License

Apache 2.0 — see [LICENSE](LICENSE).
