// codec.dart — GlazeCodec for decoding the binary event payloads posted
// from native code.
// Matches the binary encoding in glaze_meta.h (little-endian, length-prefixed).

import 'dart:convert';
import 'dart:typed_data';

import 'types.dart';

/// Decodes glaze binary payloads from the native bridge.
class GlazeCodec {
  GlazeCodec._();

  static T decode<T>(Uint8List data, int offset) {
    final r = _Reader(data, offset);

    if (T == BlueZAdapterProps) {
      return _decodeAdapterProps(r) as T;
    } else if (T == BlueZDeviceProps) {
      return _decodeDeviceProps(r) as T;
    } else if (T == BlueZGattCharProps) {
      return _decodeGattCharProps(r) as T;
    } else if (T == BlueZGattServiceProps) {
      return _decodeGattServiceProps(r) as T;
    } else if (T == BlueZGattDescProps) {
      return _decodeGattDescProps(r) as T;
    } else if (T == BlueZValueResult) {
      return _decodeValueResult(r) as T;
    } else if (T == BlueZError) {
      return _decodeError(r) as T;
    } else if (T == BlueZAgentRequest) {
      return _decodeAgentRequest(r) as T;
    }
    throw ArgumentError('Unknown type: $T');
  }

  static BlueZAdapterProps _decodeAdapterProps(_Reader r) {
    return BlueZAdapterProps(
      objectPath: r.readString(),
      changedMask: r.readUint32(),
      address: r.readString(),
      name: r.readString(),
      alias: r.readString(),
      powered: r.readBool(),
      discoverable: r.readBool(),
      pairable: r.readBool(),
      discovering: r.readBool(),
      discoverableTimeout: r.readUint32(),
      uuids: r.readStringList(),
    );
  }

  static BlueZDeviceProps _decodeDeviceProps(_Reader r) {
    return BlueZDeviceProps(
      objectPath: r.readString(),
      changedMask: r.readUint32(),
      adapterPath: r.readString(),
      address: r.readString(),
      addressType: r.readString(),
      name: r.readString(),
      alias: r.readString(),
      rssi: r.readInt16(),
      txPower: r.readInt16(),
      appearance: r.readUint16(),
      deviceClass: r.readUint32(),
      paired: r.readBool(),
      trusted: r.readBool(),
      blocked: r.readBool(),
      connected: r.readBool(),
      servicesResolved: r.readBool(),
      legacyPairing: r.readBool(),
      uuids: r.readStringList(),
      manufacturerData: r.readManufacturerDataList(),
      serviceData: r.readServiceDataMap(),
    );
  }

  static BlueZGattCharProps _decodeGattCharProps(_Reader r) {
    return BlueZGattCharProps(
      objectPath: r.readString(),
      servicePath: r.readString(),
      uuid: r.readString(),
      value: r.readByteList(),
      notifying: r.readBool(),
      writeAcquired: r.readBool(),
      notifyAcquired: r.readBool(),
      handle: r.readUint16(),
      mtu: r.readUint16(),
      flags: r.readStringList(),
      // Appended last, mirroring glz::meta<BlueZGattCharProps>.
      changedMask: r.readUint32(),
    );
  }

  static BlueZGattServiceProps _decodeGattServiceProps(_Reader r) {
    return BlueZGattServiceProps(
      objectPath: r.readString(),
      devicePath: r.readString(),
      uuid: r.readString(),
      primary: r.readBool(),
      handle: r.readUint16(),
    );
  }

  static BlueZGattDescProps _decodeGattDescProps(_Reader r) {
    return BlueZGattDescProps(
      objectPath: r.readString(),
      charPath: r.readString(),
      uuid: r.readString(),
      value: r.readByteList(),
      handle: r.readUint16(),
    );
  }

  static BlueZValueResult _decodeValueResult(_Reader r) {
    return BlueZValueResult(
      objectPath: r.readString(),
      value: r.readByteList(),
    );
  }

  static BlueZError _decodeError(_Reader r) {
    return BlueZError(
      objectPath: r.readString(),
      name: r.readString(),
      message: r.readString(),
    );
  }

  static BlueZAgentRequest _decodeAgentRequest(_Reader r) {
    final requestId = r.readUint64();
    final requestType = r.readUint8();
    if (requestType >= AgentRequestType.values.length) {
      throw RangeError('Unknown AgentRequestType: $requestType');
    }
    return BlueZAgentRequest(
      requestId: requestId,
      requestType: AgentRequestType.values[requestType],
      devicePath: r.readString(),
      passkey: r.readUint32(),
      entered: r.readUint16(),
      pinCode: r.readString(),
      uuid: r.readString(),
    );
  }
}

class _Reader {
  final ByteData _data;
  final int _length;
  int _offset;

  _Reader(Uint8List bytes, int offset)
    : _data = bytes.buffer.asByteData(bytes.offsetInBytes),
      _length = bytes.length,
      _offset = offset;

  void _checkBounds(int needed) {
    if (_offset + needed > _length) {
      throw RangeError(
        'Codec read overrun: need $needed bytes at '
        'offset $_offset, but buffer is $_length bytes',
      );
    }
  }

  int readUint8() {
    _checkBounds(1);
    final v = _data.getUint8(_offset);
    _offset += 1;
    return v;
  }

  bool readBool() {
    _checkBounds(1);
    final v = _data.getUint8(_offset) != 0;
    _offset += 1;
    return v;
  }

  int readUint64() {
    _checkBounds(8);
    final v = _data.getUint64(_offset, Endian.little);
    _offset += 8;
    return v;
  }

  int readInt16() {
    _checkBounds(2);
    final v = _data.getInt16(_offset, Endian.little);
    _offset += 2;
    return v;
  }

  int readUint16() {
    _checkBounds(2);
    final v = _data.getUint16(_offset, Endian.little);
    _offset += 2;
    return v;
  }

  int readUint32() {
    _checkBounds(4);
    final v = _data.getUint32(_offset, Endian.little);
    _offset += 4;
    return v;
  }

  String readString() {
    final len = readUint32();
    _checkBounds(len);
    final bytes = Uint8List.view(
      _data.buffer,
      _data.offsetInBytes + _offset,
      len,
    );
    _offset += len;
    return utf8.decode(bytes);
  }

  List<String> readStringList() {
    final count = readUint32();
    return List.generate(count, (_) => readString());
  }

  List<int> readByteList() {
    final count = readUint32();
    _checkBounds(count);
    final bytes = List<int>.from(
      Uint8List.view(_data.buffer, _data.offsetInBytes + _offset, count),
    );
    _offset += count;
    return bytes;
  }

  List<ManufacturerDataEntry> readManufacturerDataList() {
    final count = readUint32();
    return List.generate(count, (_) {
      final companyId = readUint16();
      final data = readByteList();
      return ManufacturerDataEntry(companyId, data);
    });
  }

  Map<String, List<int>> readServiceDataMap() {
    final count = readUint32();
    final map = <String, List<int>>{};
    for (var i = 0; i < count; i++) {
      final key = readString();
      final value = readByteList();
      map[key] = value;
    }
    return map;
  }
}
