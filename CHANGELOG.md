## 0.2.0

- **Breaking**: Wire format changed — changedMask field added to adapter and
  device props. Requires matching native library rebuild.
- Fix device Connect/Disconnect/Pair blocking the Dart isolate by switching
  from synchronous to async D-Bus method calls (callMethodAsync).
- Fix property updates replacing entire props struct with partial data. Both
  adapter and device properties now use a changedMask bitmask to merge only
  changed fields, preserving cached values.
- Fix characteristics and descriptors not linking to parent devices
  (_devicePathFromCharPath used .take(6) instead of .take(5)).
- Fix BlueZClient.connect() returning before initial GetManagedObjects
  snapshot was fully processed. A 0x00 sentinel is now posted after the
  snapshot completes.
- Add rfkill unblock to setPowered(true) for Linux desktops where the
  adapter is soft-blocked.
- Add human-readable toString() on BlueZGattCharacteristicFlag enum.
- Remove unused generated proxy headers, XML interface schemas, and
  codegen script — all D-Bus access uses runtime introspection.
- Examples: check known devices before scanning, add --timeout flag via
  shared example_utils.dart, handle scan timeouts gracefully.
- Flutter example: monitor adapter power state with icon indicator,
  pop to scanner on device disconnect or adapter power-off, seed known
  devices on init and power-on, show "Power On" button when unpowered.

## 0.1.0

- Initial release.
- BlueZClient, BlueZAdapter, BlueZDevice APIs matching canonical/bluez.dart.
- Zero-copy characteristic notifications via `Dart_PostCObject_DL`.
- StartNotify / StopNotify via org.bluez.GattCharacteristic1.
- ReadValue / WriteValue for characteristics and descriptors.
- Discovery filter support (transport, RSSI threshold, UUIDs).
- Flutter BLE scanner example (mirrors jwinarske/flutter_reactive_ble pattern).
- CI: Ubuntu 24.04 + Fedora 41, x86_64 + arm64, ASAN, clang-tidy-19.
