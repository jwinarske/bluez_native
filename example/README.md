# Examples

Runnable CLI examples. Each takes a device address and optional `--timeout
<seconds>`.

Build the native library first, or let the build hook do it:

```sh
cmake -S native -B build && cmake --build build
export BLUEZ_NC_LIB=$PWD/build/libbluez_nc.so
```

## Scanning and connecting

```sh
dart run example/scan_devices.dart
dart run example/connect_device.dart AA:BB:CC:DD:EE:FF
dart run example/device_properties.dart AA:BB:CC:DD:EE:FF
dart run example/pair_device.dart AA:BB:CC:DD:EE:FF
```

`scan_devices.dart` prints discovered devices. `connect_device.dart` connects
and enumerates GATT services. `device_properties.dart` monitors live property
changes such as RSSI and connection state. `pair_device.dart` drives the
pairing agent.

## Reading and writing characteristics

```sh
dart run example/read_characteristic.dart AA:BB:CC:DD:EE:FF <char-uuid>
dart run example/write_characteristic.dart AA:BB:CC:DD:EE:FF <char-uuid> 01:02:03
dart run example/read_descriptor.dart AA:BB:CC:DD:EE:FF <char-uuid>
```

## Notifications

```sh
dart run example/notify_characteristic.dart AA:BB:CC:DD:EE:FF
dart run example/notify_regression.dart AA:BB:CC:DD:EE:FF <char-uuid> \
    [--write-uuid <uuid>] [--write <hex>]
```

`notify_characteristic.dart` subscribes to heart rate measurements and prints
incoming values.

`notify_regression.dart` asserts the subscription *state* rather than only
that bytes arrive: that `notifying` is false before subscribing, true after,
and false again after unsubscribing. Two bugs in that path were invisible to a
value-only check, because notifications still flowed while the `notifying`
getter reported the wrong value. Pass `--write-uuid` for peripherals that split
request and response across a characteristic pair.

## Flutter

[`flutter_ble_scanner/`](flutter_ble_scanner/) is a Flutter application with
scan, connect, pairing, and GATT browsing.
