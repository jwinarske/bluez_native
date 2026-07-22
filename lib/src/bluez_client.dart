// bluez_client.dart
//
// BlueZClient mirrors the public API of canonical/bluez.dart so that
// migration is a dependency swap without source changes for common usage.

import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'bluez_adapter.dart';
import 'bluez_device.dart';
import 'exceptions.dart';
import 'ffi/bindings.dart';
import 'ffi/codec.dart';
import 'ffi/types.dart';

export 'bluez_adapter.dart';
export 'bluez_device.dart';
export 'bluez_gatt_characteristic.dart';
export 'bluez_gatt_descriptor.dart';
export 'bluez_gatt_service.dart';
export 'bluez_manufacturer_data.dart';
export 'bluez_uuid.dart';
export 'enums.dart';
export 'exceptions.dart';
export 'ffi/types.dart' show AgentRequestType, BlueZAgentRequest;

/// Top-level Bluetooth client. API mirrors canonical/bluez.dart.
///
/// ```dart
/// final client = BlueZClient();
/// await client.connect();
///
/// for (final adapter in client.adapters) {
///   print(adapter.address);
///   await adapter.startDiscovery();
/// }
///
/// client.deviceAdded.listen((device) {
///   print('Found: ${device.address}  RSSI: ${device.rssi}');
/// });
///
/// await client.close();
/// ```
class BlueZClient {
  ReceivePort? _eventsPort;
  Object? _handle;
  bool _connected = false;
  Completer<void>? _initialSnapshotDone;

  // Object caches.
  final _adapters = <String, BlueZAdapter>{};
  final _devices = <String, BlueZDevice>{};

  // Event streams.
  final _deviceAddedCtrl = StreamController<BlueZDevice>.broadcast();
  final _deviceRemovedCtrl = StreamController<BlueZDevice>.broadcast();
  final _deviceChangedCtrl = StreamController<BlueZDevice>.broadcast();
  final _adapterChangedCtrl = StreamController<BlueZAdapter>.broadcast();
  final _agentRequestCtrl = StreamController<BlueZAgentRequest>.broadcast();

  /// Fires when a new Bluetooth device is discovered.
  Stream<BlueZDevice> get deviceAdded => _deviceAddedCtrl.stream;

  /// Fires when a device is removed from the BlueZ object manager.
  Stream<BlueZDevice> get deviceRemoved => _deviceRemovedCtrl.stream;

  /// Fires when any known device's properties change (RSSI, Connected, etc.)
  Stream<BlueZDevice> get deviceChanged => _deviceChangedCtrl.stream;

  /// Fires when an adapter property changes.
  Stream<BlueZAdapter> get adapterChanged => _adapterChangedCtrl.stream;

  /// Fires when BlueZ sends a pairing agent request.
  /// Only active after [registerAgent] is called.
  Stream<BlueZAgentRequest> get agentRequest => _agentRequestCtrl.stream;

  /// Connect to BlueZ on the system bus and snapshot the object tree.
  Future<void> connect() async {
    if (_connected) return;
    _connected = true;

    // Initialize the Dart API DL.
    BlueZBindings.init(NativeApi.initializeApiDLData);

    _eventsPort = ReceivePort('bluez.events');
    final handle = BlueZBindings.clientCreate(_eventsPort!.sendPort.nativePort);

    // Null pointer means BlueZ daemon is not available.
    if (handle == Pointer<Void>.fromAddress(0)) {
      _eventsPort!.close();
      _eventsPort = null;
      _connected = false;
      throw const BlueZServiceUnavailableException(
        'BlueZ service is not available. '
        'Ensure bluetoothd is running (systemctl start bluetooth).',
      );
    }

    _handle = handle;
    _initialSnapshotDone = Completer<void>();
    _eventsPort!.listen(_onEvent);

    // Wait for the 0x00 sentinel posted after GetManagedObjects completes.
    // This ensures all adapters and already-known devices are populated.
    await _initialSnapshotDone!.future;
  }

  /// All currently known Bluetooth adapters.
  List<BlueZAdapter> get adapters => List.unmodifiable(_adapters.values);

  /// All currently known Bluetooth devices.
  List<BlueZDevice> get devices => List.unmodifiable(_devices.values);

  // ── Pairing agent ─────────────────────────────────────────────────────────

  /// Register a custom pairing agent with BlueZ (KeyboardDisplay capability).
  ///
  /// When registered, pairing requests arrive on the [agentRequest] stream
  /// instead of being handled by the system agent (e.g. GNOME Bluetooth).
  /// Call [unregisterAgent] to revert to the system agent.
  void registerAgent() => BlueZBindings.agentRegister(_handle!);

  /// Unregister the custom pairing agent. The system agent resumes handling
  /// pairing requests.
  void unregisterAgent() => BlueZBindings.agentUnregister(_handle!);

  /// Respond to a pending agent request.
  ///
  /// [requestId] is from the [BlueZAgentRequest.requestId] field.
  /// [accepted] approves or rejects the request.
  /// [response] is the PIN code or passkey string (for requestPinCode /
  /// requestPasskey types).
  void agentRespond(int requestId, {bool accepted = true, String? response}) {
    BlueZBindings.agentRespond(_handle!, requestId, accepted, response);
  }

  /// Disconnect and release resources.
  Future<void> close() async {
    if (_handle != null) {
      BlueZBindings.clientDestroy(_handle!);
      _handle = null;
    }
    _eventsPort?.close();
    _eventsPort = null;
    await _deviceAddedCtrl.close();
    await _deviceRemovedCtrl.close();
    await _deviceChangedCtrl.close();
    await _adapterChangedCtrl.close();
    await _agentRequestCtrl.close();
  }

  // ── Internal event routing ──────────────────────────────────────────────

  void _onEvent(dynamic msg) {
    if (msg is! Uint8List || msg.isEmpty) return;
    try {
      _dispatchEvent(msg);
    } on Exception catch (e) {
      // Log and continue — a malformed event must not kill the event loop.
      // ignore: avoid_print
      print(
        '[bluez] error processing event 0x'
        '${msg[0].toRadixString(16).padLeft(2, '0')}: $e',
      );
    }
  }

  void _dispatchEvent(Uint8List msg) {
    switch (msg[0]) {
      case 0x00: // Initial snapshot complete sentinel.
        _initialSnapshotDone?.complete();
        _initialSnapshotDone = null;

      case 0x01: // BlueZAdapterProps
        final props = GlazeCodec.decode<BlueZAdapterProps>(msg, 1);
        final adapter = _adapters.putIfAbsent(
          props.objectPath,
          () => BlueZAdapter.internal(_handle!, props),
        );
        adapter.updateProps(props);
        _adapterChangedCtrl.add(adapter);

      case 0x02: // BlueZDeviceProps (property update)
        final props = GlazeCodec.decode<BlueZDeviceProps>(msg, 1);
        final device = _devices[props.objectPath];
        if (device != null) {
          device.updateProps(props);
          _deviceChangedCtrl.add(device);
        }

      case 0x03: // BlueZGattCharProps (Value / Notifying / MTU changed)
        final props = GlazeCodec.decode<BlueZGattCharProps>(msg, 1);
        _devices.values
            .expand((d) => d.gattCharacteristics)
            .where((c) => c.objectPath == props.objectPath)
            .firstOrNull
            ?.mergeChanged(props);

      case 0x04: // BlueZDeviceAdded
        final props = GlazeCodec.decode<BlueZDeviceProps>(msg, 1);
        final existing = _devices[props.objectPath];
        if (existing != null) {
          // Device re-appeared (e.g. after pairing reconnect) — update
          // the existing object so UI references remain valid.
          // Don't clear GATT here; BlueZ sends individual
          // InterfacesRemoved (0x09) for GATT objects if needed.
          existing.updateProps(props);
          _deviceChangedCtrl.add(existing);
        } else {
          final device = BlueZDevice.internal(_handle!, props);
          _devices[props.objectPath] = device;
          _deviceAddedCtrl.add(device);
        }

      case 0x05: // BlueZDeviceRemoved
        final props = GlazeCodec.decode<BlueZDeviceProps>(msg, 1);
        final removed = _devices.remove(props.objectPath);
        if (removed != null) {
          _deviceRemovedCtrl.add(removed);
          removed.dispose();
        }

      case 0x06: // GattService added
        final svcProps = GlazeCodec.decode<BlueZGattServiceProps>(msg, 1);
        _devices[svcProps.devicePath]?.addService(svcProps);

      case 0x07: // GattCharacteristic added
        final props = GlazeCodec.decode<BlueZGattCharProps>(msg, 1);
        final devicePath = _devicePathFromCharPath(props.objectPath);
        _devices[devicePath]?.addCharacteristic(props);

      case 0x08: // GattDescriptor added
        final props = GlazeCodec.decode<BlueZGattDescProps>(msg, 1);
        final devicePath = _devicePathFromDescPath(props.objectPath);
        _devices[devicePath]?.addDescriptor(props);

      case 0x09: // GATT object removed (InterfacesRemoved)
        final props = GlazeCodec.decode<BlueZGattServiceProps>(msg, 1);
        // Object path could be a service, characteristic, or descriptor.
        // Try to find the owning device and remove the object.
        final parts = props.objectPath.split('/');
        if (parts.length >= 6) {
          final devicePath = parts.take(5).join('/');
          _devices[devicePath]?.removeGattObject(props.objectPath);
        }

      case 0x30: // Agent request
        final req = GlazeCodec.decode<BlueZAgentRequest>(msg, 1);
        _agentRequestCtrl.add(req);
    }
  }

  // /org/bluez/hci0/dev_AA_BB.../service.../char... → /org/bluez/hci0/dev_AA_BB...
  // Split: ['', 'org', 'bluez', 'hci0', 'dev_AA_BB...', 'service...', 'char...']
  //         0     1       2       3        4               5             6
  static String _devicePathFromCharPath(String p) =>
      p.split('/').take(5).join('/');
  // /org/bluez/hci0/dev_AA_BB.../service.../char.../desc... → same device path
  static String _devicePathFromDescPath(String p) =>
      p.split('/').take(5).join('/');
}
