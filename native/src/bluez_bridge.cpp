// bluez_bridge.cpp — C ABI entry points wrapping all bridges.
//
// The BridgeContext owns one sdbus connection running its event loop on a
// dedicated thread. All bridge objects share this connection.

#include "bluez_bridge.h"

#include <cstdio>
#include <memory>
#include <string>
#include <thread>

#include "adapter_bridge.h"
#include "device_bridge.h"
#include "gatt_bridge.h"
#include "object_manager.h"
#include "pairing_agent.h"

struct BridgeContext {
  std::unique_ptr<sdbus::IConnection> conn;
  std::unique_ptr<ObjectManager> obj_mgr;
  std::unique_ptr<PairingAgent> agent;
  Dart_Port_DL events_port{};
  std::thread event_loop;
};

extern "C" {

void bluez_bridge_init(void* dart_api_dl_data) {
  Dart_InitializeApiDL(dart_api_dl_data);
}

void* bluez_client_create(int64_t events_port) {
  try {
    auto ctx = std::make_unique<BridgeContext>();
    ctx->events_port = events_port;

    ctx->conn = sdbus::createSystemBusConnection();
    ctx->obj_mgr =
        std::make_unique<ObjectManager>(*ctx->conn, ctx->events_port);

    // Snapshot the current BlueZ object tree.
    ctx->obj_mgr->get_managed_objects();

    // Post a 0x00 sentinel so the Dart side knows the initial snapshot
    // has been fully posted and can wait for it before accessing devices.
    {
      uint8_t sentinel = 0x00;
      Dart_CObject obj;
      obj.type = Dart_CObject_kTypedData;
      obj.value.as_typed_data.type = Dart_TypedData_kUint8;
      obj.value.as_typed_data.length = 1;
      obj.value.as_typed_data.values = &sentinel;
      Dart_PostCObject_DL(ctx->events_port, &obj);
    }

    // Run the sdbus event loop on a dedicated thread.
    ctx->event_loop =
        std::thread([&conn = *ctx->conn]() { conn.enterEventLoop(); });

    return ctx.release();
  } catch (const sdbus::Error&) {
    // BlueZ service not available — return null so Dart can throw
    // BlueZServiceUnavailableException.
    return nullptr;
  }
}

void bluez_client_destroy(void* handle) {
  if (handle == nullptr)
    return;
  auto* ctx = static_cast<BridgeContext*>(handle);
  ctx->conn->leaveEventLoop();
  if (ctx->event_loop.joinable()) {
    ctx->event_loop.join();
  }
  delete ctx;  // NOLINT(cppcoreguidelines-owning-memory)
}

// ── Adapter operations ──────────────────────────────────────────────────────

void bluez_adapter_start_discovery(void* handle, const char* adapter_path) {
  try {
    auto* ctx = static_cast<BridgeContext*>(handle);
    AdapterBridge adapter(*ctx->conn, adapter_path);
    adapter.start_discovery();
  } catch (const sdbus::Error& e) {
    fprintf(stderr, "bluez_adapter_start_discovery: %s\n", e.what());
  }
}

void bluez_adapter_stop_discovery(void* handle, const char* adapter_path) {
  try {
    auto* ctx = static_cast<BridgeContext*>(handle);
    AdapterBridge adapter(*ctx->conn, adapter_path);
    adapter.stop_discovery();
  } catch (const sdbus::Error& e) {
    fprintf(stderr, "bluez_adapter_stop_discovery: %s\n", e.what());
  }
}

void bluez_adapter_set_discovery_filter(void* handle,
                                        const char* adapter_path,
                                        const uint8_t* filter_json,
                                        int32_t len) {
  try {
    auto* ctx = static_cast<BridgeContext*>(handle);
    AdapterBridge adapter(*ctx->conn, adapter_path);

    // Decode the filter from glaze binary: Transport(s), UUIDs(as), RSSI(n).
    std::map<std::string, sdbus::Variant> filter;
    if (filter_json != nullptr && len > 0) {
      // For now, pass empty filter — full decode added with Dart FFI layer.
      (void)filter_json;
      (void)len;
    }
    adapter.set_discovery_filter(filter);
  } catch (const sdbus::Error& e) {
    fprintf(stderr, "bluez_adapter_set_discovery_filter: %s\n", e.what());
  }
}

void bluez_adapter_remove_device(void* handle,
                                 const char* adapter_path,
                                 const char* device_path) {
  try {
    auto* ctx = static_cast<BridgeContext*>(handle);
    AdapterBridge adapter(*ctx->conn, adapter_path);
    adapter.remove_device(device_path);
  } catch (const sdbus::Error& e) {
    fprintf(stderr, "bluez_adapter_remove_device: %s\n", e.what());
  }
}

void bluez_adapter_set_property(void* handle,
                                const char* adapter_path,
                                const char* prop_name,
                                const uint8_t* value_json,
                                int32_t len) {
  try {
    auto* ctx = static_cast<BridgeContext*>(handle);
    AdapterBridge adapter(*ctx->conn, adapter_path);

    // Decode property value from glaze binary.
    // For bool properties, the first byte is 0/1.
    if (len == 1) {
      // NOLINTNEXTLINE(cppcoreguidelines-pro-bounds-pointer-arithmetic)
      adapter.set_property_bool(prop_name, value_json[0] != 0);
    }
  } catch (const sdbus::Error& e) {
    fprintf(stderr, "bluez_adapter_set_property: %s\n", e.what());
  }
}

// ── Pairing agent ──────────────────────────────────────────────────────────

void bluez_agent_register(void* handle) {
  if (handle == nullptr)
    return;
  try {
    auto* ctx = static_cast<BridgeContext*>(handle);
    if (!ctx->agent) {
      ctx->agent = std::make_unique<PairingAgent>(*ctx->conn, ctx->events_port);
    }
    ctx->agent->register_agent();
  } catch (const sdbus::Error& e) {
    fprintf(stderr, "bluez_agent_register: %s\n", e.what());
  }
}

void bluez_agent_unregister(void* handle) {
  if (handle == nullptr)
    return;
  try {
    auto* ctx = static_cast<BridgeContext*>(handle);
    if (ctx->agent) {
      ctx->agent->unregister_agent();
      ctx->agent.reset();
    }
  } catch (const sdbus::Error& e) {
    fprintf(stderr, "bluez_agent_unregister: %s\n", e.what());
  }
}

void bluez_agent_respond(void* handle,
                         uint64_t request_id,
                         bool accepted,
                         const char* response) {
  auto* ctx = static_cast<BridgeContext*>(handle);
  if (ctx->agent) {
    ctx->agent->respond(request_id, accepted,
                        response != nullptr ? response : "");
  }
}

// ── Device operations ───────────────────────────────────────────────────────

void bluez_device_connect(void* handle,
                          const char* device_path,
                          int64_t result_port) {
  auto* ctx = static_cast<BridgeContext*>(handle);
  DeviceBridge::connect_async(*ctx->conn, device_path, result_port);
}

void bluez_device_disconnect(void* handle,
                             const char* device_path,
                             int64_t result_port) {
  auto* ctx = static_cast<BridgeContext*>(handle);
  DeviceBridge::disconnect_async(*ctx->conn, device_path, result_port);
}

void bluez_device_pair(void* handle,
                       const char* device_path,
                       int64_t result_port) {
  auto* ctx = static_cast<BridgeContext*>(handle);
  DeviceBridge::pair_async(*ctx->conn, device_path, result_port);
}

void bluez_device_cancel_pairing(void* handle, const char* device_path) {
  try {
    auto* ctx = static_cast<BridgeContext*>(handle);
    DeviceBridge device(*ctx->conn, device_path);
    device.cancel_pairing();
  } catch (const sdbus::Error& e) {
    fprintf(stderr, "bluez_device_cancel_pairing: %s\n", e.what());
  }
}

void bluez_device_set_trusted(void* handle,
                              const char* device_path,
                              bool value) {
  try {
    auto* ctx = static_cast<BridgeContext*>(handle);
    DeviceBridge device(*ctx->conn, device_path);
    device.set_trusted(value);
  } catch (const sdbus::Error& e) {
    fprintf(stderr, "bluez_device_set_trusted: %s\n", e.what());
  }
}

// ── GATT characteristic operations ──────────────────────────────────────────

void bluez_char_read_value(void* handle,
                           const char* char_path,
                           int64_t result_port) {
  auto* ctx = static_cast<BridgeContext*>(handle);
  GattCharBridge::read_value_async(*ctx->conn, char_path, result_port);
}

void bluez_char_write_value(void* handle,
                            const char* char_path,
                            const uint8_t* value_buf,
                            int32_t len,
                            bool with_response,
                            int64_t result_port) {
  auto* ctx = static_cast<BridgeContext*>(handle);
  GattCharBridge::write_value_async(*ctx->conn, char_path, value_buf, len,
                                    with_response, result_port);
}

void bluez_char_start_notify(void* handle,
                             const char* char_path,
                             int64_t result_port) {
  auto* ctx = static_cast<BridgeContext*>(handle);
  GattCharBridge::start_notify_async(*ctx->conn, char_path, *ctx->obj_mgr,
                                     result_port);
}

void bluez_char_stop_notify(void* handle,
                            const char* char_path,
                            int64_t result_port) {
  auto* ctx = static_cast<BridgeContext*>(handle);
  GattCharBridge::stop_notify_async(*ctx->conn, char_path, *ctx->obj_mgr,
                                    result_port);
}

// ── GATT descriptor operations ──────────────────────────────────────────────

void bluez_desc_read_value(void* handle,
                           const char* desc_path,
                           int64_t result_port) {
  auto* ctx = static_cast<BridgeContext*>(handle);
  GattDescBridge::read_value_async(*ctx->conn, desc_path, result_port);
}

void bluez_desc_write_value(void* handle,
                            const char* desc_path,
                            const uint8_t* value_buf,
                            int32_t len,
                            int64_t result_port) {
  auto* ctx = static_cast<BridgeContext*>(handle);
  GattDescBridge::write_value_async(*ctx->conn, desc_path, value_buf, len,
                                    result_port);
}

}  // extern "C"
