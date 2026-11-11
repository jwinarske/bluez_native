// SPDX-License-Identifier: MIT
//
// Result ports.
//
// Every async operation hands native code a port and awaits the first
// message on it. A native path that returned without posting -- a stale
// handle, most easily -- left that future pending forever: no error, no
// timeout, just a caller that never resumes.
//
// These run each operation against a handle the registry never issued and
// expect it to fail promptly. The timeout is what turns a hang into a
// failure.

import 'dart:ffi';

import 'package:bluez_native/bluez_native.dart';
import 'package:bluez_native/src/ffi/bindings.dart';
import 'package:bluez_native/src/ffi/types.dart';
import 'package:bluez_native/src/ffi/uuid.dart';
import 'package:test/test.dart';

const _devPath = '/org/bluez/hci0/dev_00_00_00_00_00_00';
const _charPath = '$_devPath/service0001/char0002';
const _descPath = '$_charPath/desc0003';

final _closed = isA<BlueZOperationException>().having(
  (e) => e.name,
  'name',
  'org.bluez.Error.NotReady',
);

void main() {
  setUpAll(() => BlueZBindings.init(NativeApi.initializeApiDLData));

  final handle = Pointer<Void>.fromAddress(1 << 40);
  final device = BlueZDevice.internal(
    handle,
    const BlueZDeviceProps(objectPath: _devPath),
  );
  final characteristic = BlueZGattCharacteristic.internal(
    handle,
    const BlueZGattCharProps(objectPath: _charPath),
  );
  final descriptor = BlueZGattDescriptor.internal(
    handle,
    const BlueZGattDescProps(objectPath: _descPath),
  );

  final operations = <String, Future<Object?> Function()>{
    'connect': device.connect,
    'connectProfile': () => device.connectProfile(
      const BlueZUUID('0000111e-0000-1000-8000-00805f9b34fb'),
    ),
    'disconnect': device.disconnect,
    'pair': device.pair,
    'characteristic readValue': characteristic.readValue,
    'characteristic writeValue': () => characteristic.writeValue([1, 2, 3]),
    'startNotify': characteristic.startNotify,
    'stopNotify': characteristic.stopNotify,
    'descriptor readValue': descriptor.readValue,
    'descriptor writeValue': () => descriptor.writeValue([1]),
  };

  group('on a closed client', () {
    for (final MapEntry(key: name, value: op) in operations.entries) {
      test('$name fails instead of hanging', () async {
        await expectLater(
          op().timeout(const Duration(seconds: 5)),
          throwsA(_closed),
        );
      });
    }
  });

  group('canonicalUuid', () {
    test('expands a 16-bit short form', () {
      expect(canonicalUuid('111E'), '0000111e-0000-1000-8000-00805f9b34fb');
      expect(canonicalUuid('0x180d'), '0000180d-0000-1000-8000-00805f9b34fb');
    });

    test('expands a 32-bit short form', () {
      expect(canonicalUuid('0000180D'), '0000180d-0000-1000-8000-00805f9b34fb');
    });

    test('lower-cases a full UUID', () {
      expect(
        canonicalUuid('0000111E-0000-1000-8000-00805F9B34FB'),
        '0000111e-0000-1000-8000-00805f9b34fb',
      );
    });

    test('passes anything else through lower-cased', () {
      expect(canonicalUuid(' Not-A-UUID '), 'not-a-uuid');
    });
  });
}
