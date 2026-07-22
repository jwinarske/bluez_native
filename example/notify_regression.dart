// example/notify_regression.dart — verifies notification subscription state.
//
// Unlike notify_characteristic.dart, which just prints incoming values, this
// asserts the *state transitions* around subscribing. It exists because two
// bugs in that path were invisible to a value-only test:
//
//   1. PropertiesChanged for Notifying and MTU was never forwarded to Dart,
//      so `characteristic.notifying` stayed at its discovery-time value.
//   2. The PropertiesChanged listener was registered inside the StartNotify
//      reply handler -- but BlueZ emits Notifying=true *while servicing*
//      StartNotify, so the signal had already been delivered by then.
//
// Both are silent: value notifications still arrive, so anything that only
// checks "did bytes show up" passes. Only the `notifying` getter lies. This
// example fails loudly instead.
//
// Usage:
//   dart run example/notify_regression.dart <address> <char-uuid> \
//       [--write <hex bytes>] [--timeout <seconds>]
//
// Example (GoPro Control & Query -- ask for BUSY and ENCODING status):
//   dart run example/notify_regression.dart AA:BB:CC:DD:EE:FF \
//       b5f90077-aa8d-11e3-9046-0002a5d5c51b \
//       --write 20:03:13:08:0a
//
// The --write value is sent to the characteristic named by --write-uuid, or to
// the sibling "request" characteristic if you pass one; many peripherals split
// request and response across a pair.

import 'dart:async';
import 'dart:typed_data';

import 'package:bluez_native/bluez_native.dart';

import 'example_utils.dart';

int _failures = 0;

void check(bool ok, String what) {
  print('  [${ok ? "pass" : "FAIL"}] $what');
  if (!ok) _failures++;
}

String? _optArg(List<String> args, String name) {
  final i = args.indexOf(name);
  return (i != -1 && i + 1 < args.length) ? args[i + 1] : null;
}

Uint8List? _parseHex(String? s) {
  if (s == null) return null;
  final parts = s.split(RegExp(r'[:\s,]+')).where((p) => p.isNotEmpty);
  return Uint8List.fromList(
    parts.map((p) => int.parse(p.replaceFirst('0x', ''), radix: 16)).toList(),
  );
}

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    print(
      'Usage: dart run example/notify_regression.dart <address> <char-uuid> '
      '[--write <hex>] [--write-uuid <uuid>] [--timeout <seconds>]',
    );
    return;
  }

  final address = args[0];
  final notifyUuid = BlueZUUID(args[1]);
  final payload = _parseHex(_optArg(args, '--write'));
  final writeUuidArg = _optArg(args, '--write-uuid');
  final timeout = parseScanTimeout(args);

  final client = BlueZClient();
  await client.connect();
  final adapter = client.adapters.first;
  if (!adapter.powered) await adapter.setPowered(true);

  final device = await findDevice(client, adapter, address, timeout: timeout);
  if (device == null) {
    await client.close();
    return;
  }

  if (!device.connected) {
    print('Connecting to ${device.address}...');
    await device.connect();
  }
  await device.waitForServicesResolved();
  print('${device.gattServices.length} services resolved.\n');

  BlueZGattCharacteristic? notify, write;
  for (final c in device.gattCharacteristics) {
    if (c.uuid == notifyUuid) notify = c;
    if (writeUuidArg != null && c.uuid == BlueZUUID(writeUuidArg)) write = c;
  }
  if (notify == null) {
    print('Characteristic ${args[1]} not found on this device.');
    await client.close();
    return;
  }
  write ??= notify;

  print('characteristic ${notify.uuid}');
  print(
    '  mtu=${notify.mtu} flags=${notify.flags.map((f) => f.name).join(",")}',
  );
  print('');

  check(!notify.notifying, 'notifying is false before subscribing');

  final received = Completer<List<int>>();
  final sub = notify.value.listen((v) {
    if (!received.isCompleted) received.complete(v);
  });

  // Regression 1: a successful StartNotify must not throw. The post-condition
  // check added to the bridge reads the live Notifying property, and reading a
  // stale cached value here would fail every healthy subscription.
  var startThrew = false;
  try {
    await notify.startNotify();
  } on BlueZOperationException catch (e) {
    startThrew = true;
    print('  startNotify threw: $e');
  }
  check(!startThrew, 'startNotify() succeeds on a healthy link');

  // Regression 2: the cached property must reflect reality. This is false if
  // PropertiesChanged for Notifying is not forwarded, or if the listener is
  // registered after StartNotify has already emitted it.
  check(notify.notifying, 'notifying is true after subscribing');

  if (payload != null) {
    print(
      '  writing ${payload.map((b) => b.toRadixString(16).padLeft(2, "0")).join(" ")} '
      'to ${write.uuid}',
    );
    await write.writeValue(payload);
    try {
      final v = await received.future.timeout(const Duration(seconds: 10));
      final hex = v.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
      print('  notification: $hex');
      check(v.isNotEmpty, 'notification received with a non-empty payload');
    } on TimeoutException {
      check(false, 'notification received within 10s');
    }
  }

  var stopThrew = false;
  try {
    await notify.stopNotify();
  } on BlueZOperationException catch (e) {
    stopThrew = true;
    print('  stopNotify threw: $e');
  }
  check(!stopThrew, 'stopNotify() succeeds');
  check(!notify.notifying, 'notifying is false after unsubscribing');

  await sub.cancel();
  await client.close();

  print('\n$_failures check(s) failed');
}
