// SPDX-License-Identifier: MIT
//
// Handle lifetime.
//
// Every native entry point takes an opaque handle from Dart. Casting it
// straight to a pointer and dereferencing made any call after close a
// use-after-free, and that ordering is easy to reach: a retained
// BlueZGattCharacteristic captures the client handle at construction, so it
// keeps using it after BlueZClient.close — bypassing the null check on the
// client's own methods.
//
// It presented as a segfault inside __dynamic_cast on a freed sdbus
// connection: a crash two frames removed from anything the caller wrote,
// with no diagnostic at all.
//
// These call in with handles the registry has never issued or has already
// retired. Reaching the end of the test is the assertion — a use-after-free
// takes the process with it, so there is nothing to catch.

import 'dart:ffi';
import 'dart:typed_data';

import 'package:bluez_native/bluez_native.dart';
import 'package:bluez_native/src/ffi/bindings.dart';
import 'package:test/test.dart';

void main() {
  setUpAll(() => BlueZBindings.init(NativeApi.initializeApiDLData));

  /// Tokens the registry cannot have issued: it counts up from 1 and never
  /// reuses. Null is what creation returns on failure and Dart may pass it
  /// back before noticing.
  final bogus = <Pointer<Void>>[
    Pointer<Void>.fromAddress(0),
    Pointer<Void>.fromAddress(1 << 40),
    Pointer<Void>.fromAddress(0xdeadbeef),
  ];

  test('a handle the registry never issued is refused', () {
    for (final h in bogus) {
      BlueZBindings.agentRegister(h);
      BlueZBindings.agentUnregister(h);
      BlueZBindings.adapterStartDiscovery(h, '/org/bluez/hci0');
      BlueZBindings.adapterStopDiscovery(h, '/org/bluez/hci0');
      BlueZBindings.deviceConnect(
        h,
        '/org/bluez/hci0/dev_00_00_00_00_00_00',
        0,
      );
      BlueZBindings.charWriteValue(
        h,
        '/org/bluez/hci0/dev_00_00_00_00_00_00/service0001/char0002',
        Uint8List.fromList([1, 2, 3]),
        false,
        0,
      );
      BlueZBindings.charStartNotify(h, '/x/y', 0);
      BlueZBindings.charReadValue(h, '/x/y', 0);
    }
    expect(true, isTrue, reason: 'process survived every bogus handle');
  });

  test('destroying a handle that was never issued is not an error', () {
    for (final h in bogus) {
      BlueZBindings.clientDestroy(h);
    }
  });

  test('a retired handle is refused', () async {
    final client = BlueZClient();
    try {
      await client.connect();
    } on BlueZException {
      return; // No BlueZ here; the bogus-handle cases cover the same path.
    }

    // Reach in for the handle before it is dropped, the way a retained GATT
    // object holds one.
    final handle = BlueZBindings.clientCreate(0);
    BlueZBindings.clientDestroy(handle);

    // Every one of these previously followed a freed pointer.
    BlueZBindings.agentRegister(handle);
    BlueZBindings.charWriteValue(
      handle,
      '/org/bluez/hci0/dev_00_00_00_00_00_00/service0001/char0002',
      Uint8List.fromList([1, 2, 3]),
      false,
      0,
    );
    BlueZBindings.clientDestroy(handle); // double destroy

    await client.close();
    expect(true, isTrue, reason: 'process survived a retired handle');
  });
}
