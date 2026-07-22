// bluez_gatt_characteristic.dart

import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'bluez_gatt_descriptor.dart';
import 'bluez_uuid.dart';
import 'enums.dart';
import 'exceptions.dart';
import 'ffi/bindings.dart';
import 'ffi/codec.dart';
import 'ffi/types.dart';

/// A GATT characteristic on a remote Bluetooth device.
class BlueZGattCharacteristic {
  final Object _clientHandle;
  BlueZGattCharProps _props;

  final _valueCtrl = StreamController<List<int>>.broadcast();
  final _descriptors = <String, BlueZGattDescriptor>{};

  /// Stream of raw bytes emitted each time the characteristic Value changes
  /// via StartNotify / PropertiesChanged. Zero allocation per notification.
  Stream<List<int>> get value => _valueCtrl.stream;

  /// Close the value stream. Called when the characteristic is removed.
  void dispose() => _valueCtrl.close();

  /// @nodoc — internal constructor, not part of public API.
  BlueZGattCharacteristic.internal(this._clientHandle, BlueZGattCharProps props)
    : _props = props;

  /// D-Bus object path of this characteristic.
  String get objectPath => _props.objectPath;

  /// Object path of the parent service.
  String get servicePath => _props.servicePath;

  /// Characteristic UUID.
  BlueZUUID get uuid => BlueZUUID(_props.uuid);

  /// Last known characteristic value.
  List<int> get cachedValue => List.unmodifiable(_props.value);

  /// Whether notifications are active.
  bool get notifying => _props.notifying;

  /// ATT handle.
  int get handle => _props.handle;

  /// Negotiated MTU.
  int get mtu => _props.mtu;

  /// Characteristic flags (read, write, notify, etc.)
  List<BlueZGattCharacteristicFlag> get flags =>
      _props.flags.map(BlueZGattCharacteristicFlag.fromString).toList();

  /// Descriptors belonging to this characteristic.
  List<BlueZGattDescriptor> get descriptors =>
      List.unmodifiable(_descriptors.values);

  /// Read the characteristic value from the device.
  Future<List<int>> readValue() async {
    final port = ReceivePort();
    BlueZBindings.charReadValue(
      _clientHandle,
      objectPath,
      port.sendPort.nativePort,
    );
    final msg = await port.first as Uint8List;
    port.close();
    if (msg[0] == 0x20) {
      final err = GlazeCodec.decode<BlueZError>(msg, 1);
      throw BlueZOperationException(err.message, name: err.name);
    }
    final result = GlazeCodec.decode<BlueZValueResult>(msg, 1);
    return List.unmodifiable(result.value);
  }

  /// Write [data] to the characteristic.
  /// [withResponse] selects Write (true) vs WriteWithoutResponse (false).
  Future<void> writeValue(List<int> data, {bool withResponse = true}) async {
    final bytes = Uint8List.fromList(data);
    final port = ReceivePort();
    BlueZBindings.charWriteValue(
      _clientHandle,
      objectPath,
      bytes,
      withResponse,
      port.sendPort.nativePort,
    );
    final msg = await port.first as Uint8List;
    port.close();
    if (msg[0] == 0x20) {
      final err = GlazeCodec.decode<BlueZError>(msg, 1);
      throw BlueZOperationException(err.message, name: err.name);
    }
  }

  /// Subscribe to characteristic value change notifications.
  Future<void> startNotify() async {
    final port = ReceivePort();
    BlueZBindings.charStartNotify(
      _clientHandle,
      objectPath,
      port.sendPort.nativePort,
    );
    final msg = await port.first as Uint8List;
    port.close();
    if (msg[0] == 0x20) {
      final err = GlazeCodec.decode<BlueZError>(msg, 1);
      throw BlueZOperationException(err.message, name: err.name);
    }
  }

  /// Unsubscribe from characteristic value change notifications.
  Future<void> stopNotify() async {
    final port = ReceivePort();
    BlueZBindings.charStopNotify(
      _clientHandle,
      objectPath,
      port.sendPort.nativePort,
    );
    final msg = await port.first as Uint8List;
    port.close();
    if (msg[0] == 0x20) {
      final err = GlazeCodec.decode<BlueZError>(msg, 1);
      throw BlueZOperationException(err.message, name: err.name);
    }
  }

  // Called by BlueZClient._onEvent when 0x03 arrives.
  void postValue(List<int> bytes) => _valueCtrl.add(bytes);

  /// Merges a partial property update, emitting on [value] only when the
  /// update actually carried a value.
  ///
  /// Before this existed, a 0x03 event unconditionally pushed `props.value`
  /// onto the stream -- so a Notifying-only change would have emitted a
  /// spurious empty payload -- and `notifying` was never refreshed at all.
  void mergeChanged(BlueZGattCharProps changed) {
    const valueBit = 1 << 0;
    const notifyingBit = 1 << 1;
    const mtuBit = 1 << 2;
    final mask = changed.changedMask;

    if (mask & (notifyingBit | mtuBit) != 0) {
      _props = BlueZGattCharProps(
        objectPath: _props.objectPath,
        servicePath: _props.servicePath,
        uuid: _props.uuid,
        value: _props.value,
        notifying: mask & notifyingBit != 0
            ? changed.notifying
            : _props.notifying,
        writeAcquired: _props.writeAcquired,
        notifyAcquired: _props.notifyAcquired,
        handle: _props.handle,
        mtu: mask & mtuBit != 0 ? changed.mtu : _props.mtu,
        flags: _props.flags,
        changedMask: _props.changedMask,
      );
    }
    if (mask & valueBit != 0) {
      _valueCtrl.add(changed.value);
    }
  }

  void addDescriptor(BlueZGattDescriptor d) => _descriptors[d.objectPath] = d;
}
