// bluez_device.dart

import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'bluez_gatt_characteristic.dart';
import 'bluez_gatt_descriptor.dart';
import 'bluez_gatt_service.dart';
import 'bluez_manufacturer_data.dart';
import 'bluez_uuid.dart';
import 'exceptions.dart';
import 'ffi/bindings.dart';
import 'ffi/codec.dart';
import 'ffi/types.dart';

/// A Bluetooth device discovered or connected via BlueZ.
class BlueZDevice {
  final Object _clientHandle;
  BlueZDeviceProps _props;

  final _propertiesChangedCtrl = StreamController<List<String>>.broadcast();

  /// Fires with the list of changed property names when any device
  /// property changes (Connected, RSSI, ServicesResolved, etc.)
  Stream<List<String>> get propertiesChanged => _propertiesChangedCtrl.stream;

  final _services = <String, BlueZGattService>{};
  final _characteristics = <String, BlueZGattCharacteristic>{};
  final _descriptors = <String, BlueZGattDescriptor>{};

  /// @nodoc — internal constructor, not part of public API.
  BlueZDevice.internal(this._clientHandle, BlueZDeviceProps props)
    : _props = props;

  /// D-Bus object path.
  String get objectPath => _props.objectPath;

  /// Bluetooth address.
  String get address => _props.address;

  /// Address type: "public" or "random".
  String get addressType => _props.addressType;

  /// Device name as reported by the remote device.
  String get name => _props.name;

  /// User-friendly alias.
  String get alias => _props.alias;

  /// RSSI of the last advertisement (dBm).
  int get rssi => _props.rssi;

  /// Transmit power level (dBm).
  int get txPower => _props.txPower;

  /// GAP appearance value.
  int get appearance => _props.appearance;

  /// Bluetooth class of device.
  int get deviceClass => _props.deviceClass;

  /// Whether the device is paired.
  bool get paired => _props.paired;

  /// Whether the device is trusted.
  bool get trusted => _props.trusted;

  /// Whether the device is blocked.
  bool get blocked => _props.blocked;

  /// Whether the device is currently connected.
  bool get connected => _props.connected;

  /// Whether GATT services have been resolved after connection.
  bool get servicesResolved => _props.servicesResolved;

  /// UUIDs of services advertised by the device.
  List<BlueZUUID> get uuids => _props.uuids.map(BlueZUUID.new).toList();

  /// Manufacturer-specific data from advertisements.
  List<BlueZManufacturerData> get manufacturerData => _props.manufacturerData
      .map((e) => BlueZManufacturerData(e.companyId, e.data))
      .toList();

  /// GATT services discovered after connection.
  List<BlueZGattService> get gattServices =>
      List.unmodifiable(_services.values);

  /// All characteristics across all services.
  Iterable<BlueZGattCharacteristic> get gattCharacteristics =>
      _characteristics.values;

  // ── Operations ────────────────────────────────────────────────────────────

  /// Connect to this device.
  Future<void> connect() async {
    final port = ReceivePort();
    BlueZBindings.deviceConnect(
      _clientHandle,
      objectPath,
      port.sendPort.nativePort,
    );
    await _awaitResult(port);
    if (!connected) {
      try {
        await propertiesChanged
            .where((_) => connected)
            .first
            .timeout(const Duration(seconds: 10));
      } on TimeoutException {
        // Connection property change didn't arrive in time.
      }
    }
  }

  /// Disconnect from this device.
  Future<void> disconnect() async {
    final port = ReceivePort();
    BlueZBindings.deviceDisconnect(
      _clientHandle,
      objectPath,
      port.sendPort.nativePort,
    );
    await _awaitResult(port);
    if (connected) {
      try {
        await propertiesChanged
            .where((_) => !connected)
            .first
            .timeout(const Duration(seconds: 5));
      } on TimeoutException {
        // Disconnect property change didn't arrive in time.
      }
    }
  }

  /// Initiate pairing with this device.
  Future<void> pair() async {
    final port = ReceivePort();
    BlueZBindings.devicePair(
      _clientHandle,
      objectPath,
      port.sendPort.nativePort,
    );
    await _awaitResult(port);
  }

  /// Cancel an in-progress pairing.
  Future<void> cancelPairing() async {
    BlueZBindings.deviceCancelPairing(_clientHandle, objectPath);
  }

  /// Mark this device as trusted or untrusted in BlueZ.
  Future<void> setTrust(bool value) async {
    BlueZBindings.deviceSetTrusted(_clientHandle, objectPath, value);
  }

  /// Wait for ServicesResolved = true after connect().
  ///
  /// Times out after [timeout] (default 10 seconds) to avoid hanging
  /// indefinitely if GATT discovery fails. Returns silently on timeout.
  Future<void> waitForServicesResolved({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (servicesResolved) return;
    try {
      await propertiesChanged
          .where((_) => servicesResolved)
          .first
          .timeout(timeout);
    } on TimeoutException {
      // GATT discovery didn't complete in time — return rather than hang.
    }
  }

  // ── Internal ──────────────────────────────────────────────────────────────

  void updateProps(BlueZDeviceProps partial) {
    final mask = partial.changedMask;
    final changed = <String>[];

    // Merge: only update fields whose bits are set in the mask.
    // For full snapshots (0x04), mask == ~0 so every field is taken.
    bool m(int bit) => mask & bit != 0;

    final connected = m(BlueZDeviceProps.kConnectedBit)
        ? partial.connected
        : _props.connected;
    final rssi = m(BlueZDeviceProps.kRSSIBit) ? partial.rssi : _props.rssi;
    final paired = m(BlueZDeviceProps.kPairedBit)
        ? partial.paired
        : _props.paired;
    final servicesResolved = m(BlueZDeviceProps.kServicesResolvedBit)
        ? partial.servicesResolved
        : _props.servicesResolved;
    final name = m(BlueZDeviceProps.kNameBit) ? partial.name : _props.name;
    final trusted = m(BlueZDeviceProps.kTrustedBit)
        ? partial.trusted
        : _props.trusted;
    final blocked = m(BlueZDeviceProps.kBlockedBit)
        ? partial.blocked
        : _props.blocked;
    final alias = m(BlueZDeviceProps.kAliasBit) ? partial.alias : _props.alias;

    // Detect actual changes for notification.
    if (connected != _props.connected) changed.add('Connected');
    if (rssi != _props.rssi) changed.add('RSSI');
    if (paired != _props.paired) changed.add('Paired');
    if (servicesResolved != _props.servicesResolved) {
      changed.add('ServicesResolved');
    }
    if (name != _props.name) changed.add('Name');
    if (trusted != _props.trusted) changed.add('Trusted');
    if (blocked != _props.blocked) changed.add('Blocked');
    if (alias != _props.alias) changed.add('Alias');

    _props = BlueZDeviceProps(
      objectPath: _props.objectPath,
      changedMask: mask,
      adapterPath: _props.adapterPath,
      address: _props.address,
      addressType: _props.addressType,
      name: name,
      alias: alias,
      rssi: rssi,
      txPower: _props.txPower,
      appearance: _props.appearance,
      deviceClass: _props.deviceClass,
      paired: paired,
      trusted: trusted,
      blocked: blocked,
      connected: connected,
      servicesResolved: servicesResolved,
      legacyPairing: _props.legacyPairing,
      uuids: _props.uuids,
      manufacturerData: _props.manufacturerData,
      serviceData: _props.serviceData,
    );

    if (changed.isNotEmpty) _propertiesChangedCtrl.add(changed);
  }

  /// Close all stream controllers. Called when the device is removed.
  void dispose() {
    _propertiesChangedCtrl.close();
    for (final c in _characteristics.values) {
      c.dispose();
    }
  }

  void clearGatt() {
    for (final c in _characteristics.values) {
      c.dispose();
    }
    _services.clear();
    _characteristics.clear();
    _descriptors.clear();
  }

  void removeGattObject(String objectPath) {
    _characteristics[objectPath]?.dispose();
    _services.remove(objectPath);
    _characteristics.remove(objectPath);
    _descriptors.remove(objectPath);
  }

  void addService(BlueZGattServiceProps props) =>
      _services[props.objectPath] = BlueZGattService.internal(props);

  void addCharacteristic(BlueZGattCharProps props) {
    final char = BlueZGattCharacteristic.internal(_clientHandle, props);
    _characteristics[props.objectPath] = char;
    _services[props.servicePath]?.addCharacteristic(char);
  }

  void addDescriptor(BlueZGattDescProps props) {
    final desc = BlueZGattDescriptor.internal(_clientHandle, props);
    _descriptors[props.objectPath] = desc;
    _characteristics[props.charPath]?.addDescriptor(desc);
  }

  static Future<void> _awaitResult(ReceivePort port) async {
    final msg = await port.first;
    port.close();
    if (msg is Uint8List && msg[0] == 0x20) {
      final err = GlazeCodec.decode<BlueZError>(msg, 1);
      throw BlueZOperationException(err.message, name: err.name);
    }
  }
}
