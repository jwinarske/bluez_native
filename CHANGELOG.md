## 0.3.1

- Fix a use-after-free that took down the process. Every C ABI entry point
  cast the opaque handle straight to a BridgeContext and dereferenced it, so
  any call arriving after bluez_client_destroy followed freed memory. It
  presented as a segfault inside __dynamic_cast on a freed sdbus connection,
  two frames removed from anything the caller wrote and with no diagnostic.

  The ordering is not exotic: BlueZGattCharacteristic captures the client
  handle when it is constructed, so a retained characteristic keeps using it
  after BlueZClient.close, bypassing the null check on the client's own
  methods.

  Handles are now tokens resolved through a registry, and an entry point
  whose handle names nothing does nothing. The token is a counter rather than
  the address of the context: an allocator can reissue a freed address, and a
  stale handle would then name a different live client and act on it, which
  is defined behaviour and the wrong client.

  Lookup returns a shared_ptr so a client cannot be destroyed while a call is
  using it. Destruction removes it from the registry immediately, so no later
  call finds it, while a call already in flight finishes against a connection
  that is still alive.

  Destroying a handle that was never issued, or was already destroyed, is not
  an error.

## 0.3.0

- **Breaking**: Wire format changed — changedMask field added to GATT
  characteristic props. Requires matching native library rebuild.
- **Breaking**: startNotify() and stopNotify() now verify the Notifying
  property after the D-Bus reply and throw BlueZOperationException with
  org.bluez.Error.NotifyNotEnabled or org.bluez.Error.NotifyStillEnabled when
  it does not match the requested state. A successful method reply alone does
  not prove the notification state changed: BlueZ scopes a notification
  session to the requesting D-Bus client, so a client that does not outlive
  the call sees StartNotify succeed while Notifying stays false and no
  PropertiesChanged arrives.
- Fix BlueZGattCharacteristic.notifying keeping its discovery-time value while
  notifications were arriving. PropertiesChanged updates carrying Notifying or
  MTU were dropped because the handler returned early unless the update
  carried Value.
- Fix the PropertiesChanged listener being registered inside the StartNotify
  reply handler. BlueZ emits Notifying=true while servicing the call, so the
  signal had already been delivered. The subscription is now registered before
  the call and rolled back if it fails; on the stop path the unsubscribe is
  deferred until the property read resolves.
- Fix an exception escaping the characteristic PropertiesChanged handler when
  a peer sends an unexpected variant type, which took down the D-Bus event
  loop thread and every other subscription on it.
- Add BlueZGattCharacteristic.mergeChanged, which merges partial property
  updates and emits on the value stream only when the update carried a value.
- Add example/notify_regression.dart, which asserts the notifying state
  transitions around subscribing rather than only that bytes arrive.
- Document that the glaze_meta.h length and count prefixes are uint32 while
  other implementations of the same encoding use uint64.
- Restore the verbatim Apache-2.0 license text. Three sentences of the
  operative text had been reworded and the appendix was absent, so the file
  did not match the license it names.
- Raise the hooks constraint to ^2.1.0.
- Shorten the package description and drop the documentation URL, which
  pointed at a page that does not exist.
- Add example/README.md describing each example.

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
