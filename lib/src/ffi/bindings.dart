// bindings.dart — lookupFunction wrappers for bluez_bridge.h C ABI.

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../internal/library_loader.dart';

/// FFI bindings to the native bluez_nc shared library.
class BlueZBindings {
  BlueZBindings._();

  static final DynamicLibrary _lib = loadBluezNc();

  static final _init = _lib
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('bluez_bridge_init');

  static void init(Pointer<Void> dartApiDlData) => _init(dartApiDlData);

  // ── Client lifecycle ──────────────────────────────────────────────────────

  static final _clientCreate = _lib
      .lookupFunction<
        Pointer<Void> Function(Int64),
        Pointer<Void> Function(int)
      >('bluez_client_create');

  static final _clientDestroy = _lib
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('bluez_client_destroy');

  static Pointer<Void> clientCreate(int eventsPort) =>
      _clientCreate(eventsPort);
  static void clientDestroy(Object handle) =>
      _clientDestroy(handle as Pointer<Void>);

  // ── Adapter operations ────────────────────────────────────────────────────

  static final _adapterStartDiscovery = _lib
      .lookupFunction<
        Void Function(Pointer<Void>, Pointer<Utf8>),
        void Function(Pointer<Void>, Pointer<Utf8>)
      >('bluez_adapter_start_discovery');

  static final _adapterStopDiscovery = _lib
      .lookupFunction<
        Void Function(Pointer<Void>, Pointer<Utf8>),
        void Function(Pointer<Void>, Pointer<Utf8>)
      >('bluez_adapter_stop_discovery');

  static final _adapterRemoveDevice = _lib
      .lookupFunction<
        Void Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>),
        void Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>)
      >('bluez_adapter_remove_device');

  static final _adapterSetDiscoveryFilter = _lib
      .lookupFunction<
        Void Function(Pointer<Void>, Pointer<Utf8>, Pointer<Uint8>, Int32),
        void Function(Pointer<Void>, Pointer<Utf8>, Pointer<Uint8>, int)
      >('bluez_adapter_set_discovery_filter');

  static void adapterStartDiscovery(Object handle, String adapterPath) {
    final p = adapterPath.toNativeUtf8();
    _adapterStartDiscovery(handle as Pointer<Void>, p);
    calloc.free(p);
  }

  static void adapterStopDiscovery(Object handle, String adapterPath) {
    final p = adapterPath.toNativeUtf8();
    _adapterStopDiscovery(handle as Pointer<Void>, p);
    calloc.free(p);
  }

  static void adapterSetDiscoveryFilter(
    Object handle,
    String adapterPath,
    String? transport,
    int? rssi,
    List<String>? uuids,
  ) {
    final p = adapterPath.toNativeUtf8();
    // Pass null filter for now — the C side accepts empty filter.
    _adapterSetDiscoveryFilter(handle as Pointer<Void>, p, nullptr, 0);
    calloc.free(p);
  }

  static final _adapterSetProperty = _lib
      .lookupFunction<
        Void Function(
          Pointer<Void>,
          Pointer<Utf8>,
          Pointer<Utf8>,
          Pointer<Uint8>,
          Int32,
        ),
        void Function(
          Pointer<Void>,
          Pointer<Utf8>,
          Pointer<Utf8>,
          Pointer<Uint8>,
          int,
        )
      >('bluez_adapter_set_property');

  static void adapterSetPropertyBool(
    Object handle,
    String adapterPath,
    String propName,
    bool value,
  ) {
    final ap = adapterPath.toNativeUtf8();
    final pn = propName.toNativeUtf8();
    final buf = calloc<Uint8>();
    buf[0] = value ? 1 : 0;
    _adapterSetProperty(handle as Pointer<Void>, ap, pn, buf, 1);
    calloc.free(buf);
    calloc.free(pn);
    calloc.free(ap);
  }

  static void adapterRemoveDevice(
    Object handle,
    String adapterPath,
    String devicePath,
  ) {
    final ap = adapterPath.toNativeUtf8();
    final dp = devicePath.toNativeUtf8();
    _adapterRemoveDevice(handle as Pointer<Void>, ap, dp);
    calloc.free(dp);
    calloc.free(ap);
  }

  // ── Device operations ─────────────────────────────────────────────────────

  static final _deviceConnect = _lib
      .lookupFunction<
        Void Function(Pointer<Void>, Pointer<Utf8>, Int64),
        void Function(Pointer<Void>, Pointer<Utf8>, int)
      >('bluez_device_connect');

  static final _deviceDisconnect = _lib
      .lookupFunction<
        Void Function(Pointer<Void>, Pointer<Utf8>, Int64),
        void Function(Pointer<Void>, Pointer<Utf8>, int)
      >('bluez_device_disconnect');

  static final _devicePair = _lib
      .lookupFunction<
        Void Function(Pointer<Void>, Pointer<Utf8>, Int64),
        void Function(Pointer<Void>, Pointer<Utf8>, int)
      >('bluez_device_pair');

  static final _deviceCancelPairing = _lib
      .lookupFunction<
        Void Function(Pointer<Void>, Pointer<Utf8>),
        void Function(Pointer<Void>, Pointer<Utf8>)
      >('bluez_device_cancel_pairing');

  static final _deviceSetTrusted = _lib
      .lookupFunction<
        Void Function(Pointer<Void>, Pointer<Utf8>, Bool),
        void Function(Pointer<Void>, Pointer<Utf8>, bool)
      >('bluez_device_set_trusted');

  static void deviceConnect(Object handle, String path, int resultPort) {
    final p = path.toNativeUtf8();
    _deviceConnect(handle as Pointer<Void>, p, resultPort);
    calloc.free(p);
  }

  static void deviceDisconnect(Object handle, String path, int resultPort) {
    final p = path.toNativeUtf8();
    _deviceDisconnect(handle as Pointer<Void>, p, resultPort);
    calloc.free(p);
  }

  static void devicePair(Object handle, String path, int resultPort) {
    final p = path.toNativeUtf8();
    _devicePair(handle as Pointer<Void>, p, resultPort);
    calloc.free(p);
  }

  static void deviceCancelPairing(Object handle, String path) {
    final p = path.toNativeUtf8();
    _deviceCancelPairing(handle as Pointer<Void>, p);
    calloc.free(p);
  }

  static void deviceSetTrusted(Object handle, String path, bool value) {
    final dp = path.toNativeUtf8();
    _deviceSetTrusted(handle as Pointer<Void>, dp, value);
    calloc.free(dp);
  }

  // ── GATT characteristic operations ────────────────────────────────────────

  static final _charReadValue = _lib
      .lookupFunction<
        Void Function(Pointer<Void>, Pointer<Utf8>, Int64),
        void Function(Pointer<Void>, Pointer<Utf8>, int)
      >('bluez_char_read_value');

  static final _charWriteValue = _lib
      .lookupFunction<
        Void Function(
          Pointer<Void>,
          Pointer<Utf8>,
          Pointer<Uint8>,
          Int32,
          Bool,
          Int64,
        ),
        void Function(
          Pointer<Void>,
          Pointer<Utf8>,
          Pointer<Uint8>,
          int,
          bool,
          int,
        )
      >('bluez_char_write_value');

  static final _charStartNotify = _lib
      .lookupFunction<
        Void Function(Pointer<Void>, Pointer<Utf8>, Int64),
        void Function(Pointer<Void>, Pointer<Utf8>, int)
      >('bluez_char_start_notify');

  static final _charStopNotify = _lib
      .lookupFunction<
        Void Function(Pointer<Void>, Pointer<Utf8>, Int64),
        void Function(Pointer<Void>, Pointer<Utf8>, int)
      >('bluez_char_stop_notify');

  static void charReadValue(Object handle, String path, int resultPort) {
    final p = path.toNativeUtf8();
    _charReadValue(handle as Pointer<Void>, p, resultPort);
    calloc.free(p);
  }

  static void charWriteValue(
    Object handle,
    String path,
    Uint8List bytes,
    bool withResponse,
    int resultPort,
  ) {
    final p = path.toNativeUtf8();
    final buf = calloc<Uint8>(bytes.length);
    buf.asTypedList(bytes.length).setAll(0, bytes);
    _charWriteValue(
      handle as Pointer<Void>,
      p,
      buf,
      bytes.length,
      withResponse,
      resultPort,
    );
    calloc.free(buf);
    calloc.free(p);
  }

  static void charStartNotify(Object handle, String path, int resultPort) {
    final p = path.toNativeUtf8();
    _charStartNotify(handle as Pointer<Void>, p, resultPort);
    calloc.free(p);
  }

  static void charStopNotify(Object handle, String path, int resultPort) {
    final p = path.toNativeUtf8();
    _charStopNotify(handle as Pointer<Void>, p, resultPort);
    calloc.free(p);
  }

  // ── Pairing agent ─────────────────────────────────────────────────────────

  static final _agentRegister = _lib
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('bluez_agent_register');

  static final _agentUnregister = _lib
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('bluez_agent_unregister');

  static final _agentRespond = _lib
      .lookupFunction<
        Void Function(Pointer<Void>, Uint64, Bool, Pointer<Utf8>),
        void Function(Pointer<Void>, int, bool, Pointer<Utf8>)
      >('bluez_agent_respond');

  static void agentRegister(Object handle) =>
      _agentRegister(handle as Pointer<Void>);

  static void agentUnregister(Object handle) =>
      _agentUnregister(handle as Pointer<Void>);

  static void agentRespond(
    Object handle,
    int requestId,
    bool accepted,
    String? response,
  ) {
    final r = response?.toNativeUtf8() ?? nullptr;
    _agentRespond(handle as Pointer<Void>, requestId, accepted, r);
    if (r != nullptr) calloc.free(r);
  }

  // ── GATT descriptor operations ────────────────────────────────────────────

  static final _descReadValue = _lib
      .lookupFunction<
        Void Function(Pointer<Void>, Pointer<Utf8>, Int64),
        void Function(Pointer<Void>, Pointer<Utf8>, int)
      >('bluez_desc_read_value');

  static final _descWriteValue = _lib
      .lookupFunction<
        Void Function(
          Pointer<Void>,
          Pointer<Utf8>,
          Pointer<Uint8>,
          Int32,
          Int64,
        ),
        void Function(Pointer<Void>, Pointer<Utf8>, Pointer<Uint8>, int, int)
      >('bluez_desc_write_value');

  static void descReadValue(Object handle, String path, int resultPort) {
    final p = path.toNativeUtf8();
    _descReadValue(handle as Pointer<Void>, p, resultPort);
    calloc.free(p);
  }

  static void descWriteValue(
    Object handle,
    String path,
    Uint8List bytes,
    int resultPort,
  ) {
    final p = path.toNativeUtf8();
    final buf = calloc<Uint8>(bytes.length);
    buf.asTypedList(bytes.length).setAll(0, bytes);
    _descWriteValue(handle as Pointer<Void>, p, buf, bytes.length, resultPort);
    calloc.free(buf);
    calloc.free(p);
  }
}
