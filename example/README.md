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

## Sensirion SCD41 CO2 gadget

[`scd41_co2_sensor.dart`](scd41_co2_sensor.dart) is a complete client for a
Sensirion CO2 gadget, with the wire protocol factored into
[`sensirion_gadget.dart`](sensirion_gadget.dart).

```sh
dart run example/scd41_co2_sensor.dart scan
dart run example/scd41_co2_sensor.dart info E6:63:16:BE:3E:14
dart run example/scd41_co2_sensor.dart monitor E6:63:16:BE:3E:14
dart run example/scd41_co2_sensor.dart live E6:63:16:BE:3E:14
dart run example/scd41_co2_sensor.dart history E6:63:16:BE:3E:14 --plot
dart run example/scd41_co2_sensor.dart history E6:63:16:BE:3E:14 --csv out.csv
dart run example/scd41_co2_sensor.dart interval E6:63:16:BE:3E:14 60 --yes
dart run example/scd41_co2_sensor.dart led E6:63:16:BE:3E:14
dart run example/scd41_co2_sensor.dart name E6:63:16:BE:3E:14 "Office"
dart run example/scd41_co2_sensor.dart frc E6:63:16:BE:3E:14 420
dart run example/scd41_co2_sensor.dart wifi E6:63:16:BE:3E:14 <ssid> <password>
```

There are two paths to live values. `scan` and `monitor` decode the
manufacturer-specific advertisement data and need **no connection** at all.
`live` connects and subscribes instead, which updates faster: CO2 comes from
the SCD4x service as a 16-bit ppm value, and temperature and humidity from the
legacy Smart Gadget characteristics as float32.

`history` drives the gadget's download protocol: it writes the sample limit,
subscribes to the download packet characteristic (the subscription *is* the
request), parses the header, then reassembles 20-byte packets into samples.
The gadget has no real-time clock, so timestamps are reconstructed from the
host clock and the age of the newest sample reported in the header. `--plot`
draws a terminal sparkline per signal; `--csv` exports the series.

`interval` sets the logging interval, which **erases the gadget's stored
history** — the firmware resets its ring buffer on change, so the command
reports how many samples would be lost and requires `--yes`.

`frc` performs an SCD4x forced recalibration against a known reference
(outdoor air is ~420 ppm).

The protocol is not published as a spec. The UUIDs, byte layouts and the 21
sample layouts in `sensirion_gadget.dart` were taken from Sensirion's own
firmware — [`arduino-ble-gadget`](https://github.com/Sensirion/arduino-ble-gadget)
(`DataProvider.cpp`, `Download.cpp`, `AdvertisementHeader.cpp`) and
[`arduino-upt-core`](https://github.com/Sensirion/arduino-upt-core)
(`BLEProtocol.cpp`) — so any gadget built on that library works, not just the
SCD4x build ([Example8](https://github.com/Sensirion/arduino-ble-gadget/blob/master/examples/Example8_SCD4x_BLE_Gadget_with_RHT/Example8_SCD4x_BLE_Gadget_with_RHT.ino)).
`test/sensirion_gadget_test.dart` round-trips every layout through the
firmware's encoding functions and decodes a real MyCO2 advertisement capture.

Verified against a production Sensirion MyCO2 (SCD41), whose GATT table
differs substantially from the arduino reference firmware. Most of what follows
was established by reading each characteristic's `0x2901` user-description
descriptor off the device, which names them directly:

- it advertises `T_RH_CO2_ALT` but omits the two trailing reserved bytes, so
  the sample is shorter than the declared stride — slots are decoded
  individually rather than requiring a full-width sample;
- *Requested Samples* is 16-bit (it reads back `ffff`, meaning "all"), and
  rejects a 4-byte write with `Invalid Length`, so a limit falls back to
  16-bit and is skipped altogether when downloading everything;
- the settings service holds *LED Brightness* and *Ping Minion*, not the Wi-Fi
  credentials and alternative device name the arduino build puts there, so
  `wifi` and the gadget-name characteristic are absent. `led` is read-only:
  the characteristic is declared writable and accepts both 1-byte and 4-byte
  writes without error, but reads back unchanged as `ff 00 00 00`, so its
  write encoding is unconfirmed and no setter is exposed;
- renaming goes through the standard GAP Device Name (`0x2A00`), which is
  advertised as writable but rejects the write with `NotAuthorized` on an
  unencrypted link. Bonding would be required, and a MyCO2 does not accept
  pairing — both this library and `bluetoothctl` time out with no SMP response
  — so its name cannot be changed over BLE at all. The vendor app keeps its own
  label per device instead: its schema carries a
  `shouldFetchNameFromGadget` flag, which only makes sense for a local rename.
  Characteristic flags alone do not tell you whether a write will be accepted;
- the SCD4x service adds live CO2, the sensor feature set and its serial
  alongside the FRC request the reference firmware implements.

Note `0x2A26` is *Firmware Revision*, not Manufacturer Name (`0x2A29`) — the
MyCO2 reports `1.5` and `Sensirion AG` respectively.

## Flutter

[`flutter_ble_scanner/`](flutter_ble_scanner/) is a Flutter application with
scan, connect, pairing, and GATT browsing.
