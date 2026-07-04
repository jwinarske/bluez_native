// bluez_adapter.dart

import 'dart:io';

import 'bluez_uuid.dart';
import 'enums.dart';
import 'ffi/bindings.dart';
import 'ffi/types.dart';

/// A Bluetooth adapter (HCI controller) managed by BlueZ.
class BlueZAdapter {
  final Object _clientHandle;
  BlueZAdapterProps _props;

  /// @nodoc — internal constructor, not part of public API.
  BlueZAdapter.internal(this._clientHandle, this._props);

  /// D-Bus object path, e.g. `/org/bluez/hci0`.
  String get objectPath => _props.objectPath;

  /// Bluetooth address of the adapter.
  String get address => _props.address;

  /// Adapter name (kernel).
  String get name => _props.name;

  /// User-friendly alias.
  String get alias => _props.alias;

  /// Whether the adapter is powered on.
  bool get powered => _props.powered;

  /// Whether the adapter is discoverable.
  bool get discoverable => _props.discoverable;

  /// Whether the adapter is pairable.
  bool get pairable => _props.pairable;

  /// Whether the adapter is currently scanning.
  bool get discovering => _props.discovering;

  /// Discoverable timeout in seconds.
  int get discoverableTimeout => _props.discoverableTimeout;

  /// UUIDs of supported profiles.
  List<BlueZUUID> get uuids => _props.uuids.map(BlueZUUID.new).toList();

  /// Power the adapter on or off.
  ///
  /// When powering on, automatically unblocks rfkill if the adapter is
  /// soft-blocked (common on Linux desktops). Requires `rfkill` on PATH.
  Future<void> setPowered(bool value) async {
    if (value) {
      await _rfkillUnblock();
    }
    BlueZBindings.adapterSetPropertyBool(
      _clientHandle,
      objectPath,
      'Powered',
      value,
    );
  }

  /// Set whether the adapter is discoverable.
  Future<void> setDiscoverable(bool value) async {
    BlueZBindings.adapterSetPropertyBool(
      _clientHandle,
      objectPath,
      'Discoverable',
      value,
    );
  }

  /// Set whether the adapter is pairable.
  Future<void> setPairable(bool value) async {
    BlueZBindings.adapterSetPropertyBool(
      _clientHandle,
      objectPath,
      'Pairable',
      value,
    );
  }

  /// Unblock Bluetooth via rfkill if soft-blocked.
  Future<void> _rfkillUnblock() async {
    try {
      await Process.run('rfkill', ['unblock', 'bluetooth']);
    } on ProcessException {
      // rfkill not available — ignore, setPowered may still succeed.
    }
  }

  /// Start scanning for nearby Bluetooth devices.
  Future<void> startDiscovery() async {
    BlueZBindings.adapterStartDiscovery(_clientHandle, objectPath);
  }

  /// Stop scanning.
  Future<void> stopDiscovery() async {
    BlueZBindings.adapterStopDiscovery(_clientHandle, objectPath);
  }

  /// Set discovery filter (transport, RSSI threshold, UUIDs).
  Future<void> setDiscoveryFilter({
    BlueZDiscoveryTransport? transport,
    int? rssiThreshold,
    List<String>? uuids,
  }) async {
    BlueZBindings.adapterSetDiscoveryFilter(
      _clientHandle,
      objectPath,
      transport?.value,
      rssiThreshold,
      uuids,
    );
  }

  /// Remove a discovered device from BlueZ's cache.
  Future<void> removeDevice(String devicePath) async {
    BlueZBindings.adapterRemoveDevice(_clientHandle, objectPath, devicePath);
  }

  void updateProps(BlueZAdapterProps partial) {
    final mask = partial.changedMask;
    bool m(int bit) => mask & bit != 0;

    _props = BlueZAdapterProps(
      objectPath: _props.objectPath,
      changedMask: mask,
      address: _props.address,
      name: _props.name,
      alias: m(BlueZAdapterProps.kAliasBit) ? partial.alias : _props.alias,
      powered: m(BlueZAdapterProps.kPoweredBit)
          ? partial.powered
          : _props.powered,
      discoverable: m(BlueZAdapterProps.kDiscoverableBit)
          ? partial.discoverable
          : _props.discoverable,
      pairable: m(BlueZAdapterProps.kPairableBit)
          ? partial.pairable
          : _props.pairable,
      discovering: m(BlueZAdapterProps.kDiscoveringBit)
          ? partial.discovering
          : _props.discovering,
      discoverableTimeout: _props.discoverableTimeout,
      uuids: _props.uuids,
    );
  }
}
