import 'dart:typed_data';

import 'package:bluez_native/src/ffi/codec.dart';
import 'package:bluez_native/src/ffi/types.dart';
import 'package:test/test.dart';

/// Helper: encode a string as length-prefixed UTF-8 (matches glaze_meta.h).
void _writeString(BytesBuilder b, String s) {
  final bytes = Uint8List.fromList(s.codeUnits);
  final len = ByteData(4)..setUint32(0, bytes.length, Endian.little);
  b.add(len.buffer.asUint8List());
  b.add(bytes);
}

void _writeBool(BytesBuilder b, bool v) {
  b.addByte(v ? 1 : 0);
}

void _writeUint16(BytesBuilder b, int v) {
  final d = ByteData(2)..setUint16(0, v, Endian.little);
  b.add(d.buffer.asUint8List());
}

void _writeInt16(BytesBuilder b, int v) {
  final d = ByteData(2)..setInt16(0, v, Endian.little);
  b.add(d.buffer.asUint8List());
}

void _writeUint32(BytesBuilder b, int v) {
  final d = ByteData(4)..setUint32(0, v, Endian.little);
  b.add(d.buffer.asUint8List());
}

void _writeByteList(BytesBuilder b, List<int> bytes) {
  _writeUint32(b, bytes.length);
  b.add(bytes);
}

void _writeStringList(BytesBuilder b, List<String> strings) {
  _writeUint32(b, strings.length);
  for (final s in strings) {
    _writeString(b, s);
  }
}

void main() {
  group('GlazeCodec', () {
    test('decodes BlueZAdapterProps', () {
      final b = BytesBuilder();
      _writeString(b, '/org/bluez/hci0');
      _writeUint32(b, 0xFFFFFFFF); // changedMask (full snapshot)
      _writeString(b, '00:11:22:33:44:55');
      _writeString(b, 'hci0');
      _writeString(b, 'My Adapter');
      _writeBool(b, true); // powered
      _writeBool(b, false); // discoverable
      _writeBool(b, true); // pairable
      _writeBool(b, true); // discovering
      _writeUint32(b, 180); // discoverableTimeout
      _writeStringList(b, ['uuid-a', 'uuid-b']);

      final data = Uint8List.fromList(b.toBytes());
      final props = GlazeCodec.decode<BlueZAdapterProps>(data, 0);

      expect(props.objectPath, '/org/bluez/hci0');
      expect(props.changedMask, 0xFFFFFFFF);
      expect(props.address, '00:11:22:33:44:55');
      expect(props.name, 'hci0');
      expect(props.alias, 'My Adapter');
      expect(props.powered, true);
      expect(props.discoverable, false);
      expect(props.discovering, true);
      expect(props.discoverableTimeout, 180);
      expect(props.uuids, ['uuid-a', 'uuid-b']);
    });

    test('decodes BlueZDeviceProps', () {
      final b = BytesBuilder();
      _writeString(b, '/dev/path');
      _writeUint32(b, 0xFFFFFFFF); // changedMask (full snapshot)
      _writeString(b, '/org/bluez/hci0');
      _writeString(b, 'AA:BB:CC:DD:EE:FF');
      _writeString(b, 'public');
      _writeString(b, 'HR Sensor');
      _writeString(b, 'alias');
      _writeInt16(b, -65); // rssi
      _writeInt16(b, 4); // txPower
      _writeUint16(b, 0x0340); // appearance
      _writeUint32(b, 0); // deviceClass
      _writeBool(b, false); // paired
      _writeBool(b, false); // trusted
      _writeBool(b, false); // blocked
      _writeBool(b, true); // connected
      _writeBool(b, true); // servicesResolved
      _writeBool(b, false); // legacyPairing
      _writeStringList(b, ['uuid1']);
      // manufacturerData: 1 entry
      _writeUint32(b, 1);
      _writeUint16(b, 0x004C);
      _writeByteList(b, [0x01, 0x02]);
      // serviceData: 1 entry
      _writeUint32(b, 1);
      _writeString(b, 'svc-uuid');
      _writeByteList(b, [0x06, 0x50]);

      final data = Uint8List.fromList(b.toBytes());
      final props = GlazeCodec.decode<BlueZDeviceProps>(data, 0);

      expect(props.address, 'AA:BB:CC:DD:EE:FF');
      expect(props.rssi, -65);
      expect(props.txPower, 4);
      expect(props.connected, true);
      expect(props.manufacturerData.length, 1);
      expect(props.manufacturerData[0].companyId, 0x004C);
      expect(props.manufacturerData[0].data, [0x01, 0x02]);
      expect(props.serviceData['svc-uuid'], [0x06, 0x50]);
    });

    test('decodes BlueZGattCharProps', () {
      final b = BytesBuilder();
      _writeString(b, '/char/path');
      _writeString(b, '/service/path');
      _writeString(b, 'char-uuid');
      _writeByteList(b, [0x06, 0x50]);
      _writeBool(b, true); // notifying
      _writeBool(b, false); // writeAcquired
      _writeBool(b, false); // notifyAcquired
      _writeUint16(b, 11); // handle
      _writeUint16(b, 512); // mtu
      _writeStringList(b, ['read', 'notify']);
      // changedMask is appended last, mirroring glz::meta<BlueZGattCharProps>.
      _writeUint32(b, 0x1 | 0x2); // value + notifying

      final data = Uint8List.fromList(b.toBytes());
      final props = GlazeCodec.decode<BlueZGattCharProps>(data, 0);

      expect(props.objectPath, '/char/path');
      expect(props.uuid, 'char-uuid');
      expect(props.value, [0x06, 0x50]);
      expect(props.notifying, true);
      expect(props.mtu, 512);
      expect(props.flags, ['read', 'notify']);
      expect(props.changedMask, 0x3);
    });

    test('decodes BlueZValueResult', () {
      final b = BytesBuilder();
      _writeString(b, '/char/path');
      _writeByteList(b, [0xAA, 0xBB, 0xCC]);

      final data = Uint8List.fromList(b.toBytes());
      final result = GlazeCodec.decode<BlueZValueResult>(data, 0);

      expect(result.objectPath, '/char/path');
      expect(result.value, [0xAA, 0xBB, 0xCC]);
    });

    test('decodes BlueZError', () {
      final b = BytesBuilder();
      _writeString(b, '/dev/path');
      _writeString(b, 'org.bluez.Error.Failed');
      _writeString(b, 'Connection refused');

      final data = Uint8List.fromList(b.toBytes());
      final err = GlazeCodec.decode<BlueZError>(data, 0);

      expect(err.objectPath, '/dev/path');
      expect(err.name, 'org.bluez.Error.Failed');
      expect(err.message, 'Connection refused');
    });

    test('decodes with offset', () {
      final b = BytesBuilder();
      b.addByte(0x20); // discriminator
      _writeString(b, '/path');
      _writeString(b, 'err.name');
      _writeString(b, 'msg');

      final data = Uint8List.fromList(b.toBytes());
      final err = GlazeCodec.decode<BlueZError>(data, 1);

      expect(err.objectPath, '/path');
      expect(err.name, 'err.name');
      expect(err.message, 'msg');
    });

    test('throws on unknown type', () {
      final data = Uint8List(0);
      expect(() => GlazeCodec.decode<int>(data, 0), throwsArgumentError);
    });
  });
}
