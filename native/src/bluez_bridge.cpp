// bluez_bridge.cpp — C ABI entry points wrapping all bridges.
//
// The BridgeContext owns one sdbus connection running its event loop on a
// dedicated thread. All bridge objects share this connection.
//
// HANDLE LIFETIME
//
// The handle Dart holds is a token, not the address of the context. Every
// entry point resolves it through a registry and does nothing if it names a
// client that has been destroyed.
//
// Casting the handle straight to a pointer and dereferencing it is a
// use-after-free the moment anything calls in after close, and that ordering
// is easy to reach: a write posted from a native worker can be handled by
// Dart after the client has gone. It presented as a segfault inside
// __dynamic_cast on a freed sdbus connection -- a crash with no diagnostic,
// two frames removed from anything the caller wrote.
//
// A counter rather than the address, because an allocator can reissue a freed
// address. A stale handle would then name a different live client and quietly
// act on it: defined behavior, wrong client, no error. Counters are not
// reused, so a stale handle is always recognizable as stale.
//
// RESULT PORTS
//
// An entry point that takes a result_port owes it exactly one message, on
// every path. Dart awaits the first message on that port and nothing else
// completes the future, so returning early -- a stale handle, a null
// argument, a throw from sdbus before the call is sent -- used to leave the
// caller awaiting forever. Those paths now post a BlueZError instead.
//
// No exception leaves an entry point. One crossing the C ABI into Dart is
// std::terminate, and it takes the VM with it.

#include "bluez_bridge.h"

#include <cstdint>
#include <cstdio>
#include <exception>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>

#include "adapter_bridge.h"
#include "dart_result.h"
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

namespace {

/// The live clients.
///
/// Held in a function-local static rather than at namespace scope: there is
/// no static initialization order to get wrong, and it is constructed the
/// first time a client is created rather than before main.
struct ClientRegistry {
  std::mutex mutex;
  std::unordered_map<uint64_t, std::shared_ptr<BridgeContext>> clients;

  // Starts at 1: zero is what creation returns on failure, and Dart reads
  // that as a null handle.
  uint64_t next_id{1};
};

ClientRegistry& registry() {
  static ClientRegistry r;
  return r;
}

// The C ABI hands Dart a void*, so the token travels as one. These two
// functions are the only places the conversion happens, which is why the
// cast is tolerated here and nowhere else.
//
// NOLINTBEGIN(cppcoreguidelines-pro-type-reinterpret-cast)
uint64_t token_of(void* handle) {
  return static_cast<uint64_t>(reinterpret_cast<uintptr_t>(handle));
}

void* handle_of(uint64_t token) {
  return reinterpret_cast<void*>(static_cast<uintptr_t>(token));
}
// NOLINTEND(cppcoreguidelines-pro-type-reinterpret-cast)

/// The client a token names, or null if it has been destroyed.
///
/// Returns a shared_ptr rather than a raw pointer so the client cannot be
/// destroyed while a call is using it. Destruction removes it from the
/// registry immediately -- no later call finds it -- while a call already in
/// flight finishes against a connection that is still alive.
std::shared_ptr<BridgeContext> client_for(void* handle) {
  auto& reg = registry();
  const std::lock_guard<std::mutex> lock(reg.mutex);
  const auto it = reg.clients.find(token_of(handle));
  return it == reg.clients.end() ? nullptr : it->second;
}

/// True if none of the pointers is null.
template <typename... Ptrs>
bool all_set(const Ptrs*... ptrs) {
  return ((ptrs != nullptr) && ...);
}

/// Runs an async operation against the client a handle names.
///
/// `op` starts a D-Bus call whose reply posts to result_port. Every path that
/// does not get as far as sending the call posts an error here instead, so
/// the port always hears back once.
template <typename Op>
void run_async(void* handle,
               const char* object_path,
               int64_t result_port,
               Op&& op) {
  if (object_path == nullptr) {
    dart_result::post_error(result_port, "", dart_result::kInvalidArguments,
                            "object path is null");
    return;
  }
  try {
    const auto ctx = client_for(handle);
    if (!ctx) {
      dart_result::post_error(result_port, object_path,
                              dart_result::kClientClosed,
                              "the BlueZ client has been closed");
      return;
    }
    op(*ctx);
  } catch (const sdbus::Error& e) {
    dart_result::post_error(result_port, object_path, e.getName(),
                            e.getMessage());
  } catch (const std::exception& e) {
    dart_result::post_error(result_port, object_path, dart_result::kFailed,
                            e.what());
  }
}

/// Runs a synchronous, fire-and-forget operation against the client a handle
/// names. There is no port to report to, so failures go to stderr.
template <typename Op>
void run_sync(const char* fn_name, void* handle, Op&& op) {
  try {
    const auto ctx = client_for(handle);
    if (!ctx)
      return;
    op(*ctx);
  } catch (const sdbus::Error& e) {
    fprintf(stderr, "%s: %s\n", fn_name, e.what());
  } catch (const std::exception& e) {
    fprintf(stderr, "%s: %s\n", fn_name, e.what());
  }
}

}  // namespace

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

    std::shared_ptr<BridgeContext> client = std::move(ctx);
    uint64_t id = 0;
    {
      auto& reg = registry();
      const std::lock_guard<std::mutex> lock(reg.mutex);
      id = reg.next_id++;
      reg.clients.emplace(id, std::move(client));
    }
    return handle_of(id);
  } catch (const sdbus::Error&) {
    // BlueZ service not available — return null so Dart can throw
    // BlueZServiceUnavailableException.
    return nullptr;
  } catch (const std::exception& e) {
    fprintf(stderr, "bluez_client_create: %s\n", e.what());
    return nullptr;
  }
}

void bluez_client_destroy(void* handle) {
  std::shared_ptr<BridgeContext> ctx;
  {
    auto& reg = registry();
    const std::lock_guard<std::mutex> lock(reg.mutex);
    const auto it = reg.clients.find(token_of(handle));
    if (it == reg.clients.end()) {
      // Never valid, or already destroyed. Destroying twice is what a
      // close-on-error path followed by an ordinary close looks like, and it
      // is not an error.
      return;
    }
    ctx = std::move(it->second);
    reg.clients.erase(it);
  }

  // Outside the lock. Leaving the event loop blocks until the loop thread
  // notices, and that thread takes no part in the registry -- holding the
  // lock across it would serialize every other client's calls behind this
  // one shutting down.
  try {
    ctx->conn->leaveEventLoop();
    if (ctx->event_loop.joinable()) {
      ctx->event_loop.join();
    }
  } catch (const std::exception& e) {
    fprintf(stderr, "bluez_client_destroy: %s\n", e.what());
  }
  // The context dies here unless a call is still in flight against it, in
  // which case it dies when that call returns.
}

// ── Adapter operations ──────────────────────────────────────────────────────

void bluez_adapter_start_discovery(void* handle, const char* adapter_path) {
  if (!all_set(adapter_path))
    return;
  run_sync(__func__, handle, [&](BridgeContext& ctx) {
    AdapterBridge adapter(*ctx.conn, adapter_path);
    adapter.start_discovery();
  });
}

void bluez_adapter_stop_discovery(void* handle, const char* adapter_path) {
  if (!all_set(adapter_path))
    return;
  run_sync(__func__, handle, [&](BridgeContext& ctx) {
    AdapterBridge adapter(*ctx.conn, adapter_path);
    adapter.stop_discovery();
  });
}

void bluez_adapter_set_discovery_filter(void* handle,
                                        const char* adapter_path,
                                        const uint8_t* filter_json,
                                        int32_t len) {
  if (!all_set(adapter_path))
    return;
  run_sync(__func__, handle, [&](BridgeContext& ctx) {
    AdapterBridge adapter(*ctx.conn, adapter_path);

    // Decode the filter from glaze binary: Transport(s), UUIDs(as), RSSI(n).
    std::map<std::string, sdbus::Variant> filter;
    if (filter_json != nullptr && len > 0) {
      // For now, pass empty filter — full decode added with Dart FFI layer.
      (void)filter_json;
      (void)len;
    }
    adapter.set_discovery_filter(filter);
  });
}

void bluez_adapter_remove_device(void* handle,
                                 const char* adapter_path,
                                 const char* device_path) {
  if (!all_set(adapter_path, device_path))
    return;
  run_sync(__func__, handle, [&](BridgeContext& ctx) {
    AdapterBridge adapter(*ctx.conn, adapter_path);
    adapter.remove_device(device_path);
  });
}

void bluez_adapter_set_property(void* handle,
                                const char* adapter_path,
                                const char* prop_name,
                                const uint8_t* value_json,
                                int32_t len) {
  if (!all_set(adapter_path, prop_name, value_json))
    return;
  run_sync(__func__, handle, [&](BridgeContext& ctx) {
    AdapterBridge adapter(*ctx.conn, adapter_path);

    // Decode property value from glaze binary.
    // For bool properties, the first byte is 0/1.
    if (len == 1) {
      // NOLINTNEXTLINE(cppcoreguidelines-pro-bounds-pointer-arithmetic)
      adapter.set_property_bool(prop_name, value_json[0] != 0);
    }
  });
}

// ── Pairing agent ──────────────────────────────────────────────────────────

void bluez_agent_register(void* handle) {
  run_sync(__func__, handle, [](BridgeContext& ctx) {
    if (!ctx.agent) {
      ctx.agent = std::make_unique<PairingAgent>(*ctx.conn, ctx.events_port);
    }
    ctx.agent->register_agent();
  });
}

void bluez_agent_unregister(void* handle) {
  run_sync(__func__, handle, [](BridgeContext& ctx) {
    if (ctx.agent) {
      ctx.agent->unregister_agent();
      ctx.agent.reset();
    }
  });
}

void bluez_agent_respond(void* handle,
                         uint64_t request_id,
                         bool accepted,
                         const char* response) {
  run_sync(__func__, handle, [&](BridgeContext& ctx) {
    if (ctx.agent) {
      ctx.agent->respond(request_id, accepted,
                         response != nullptr ? response : "");
    }
  });
}

// ── Device operations ───────────────────────────────────────────────────────

void bluez_device_connect(void* handle,
                          const char* device_path,
                          int64_t result_port) {
  run_async(handle, device_path, result_port, [&](BridgeContext& ctx) {
    DeviceBridge::connect_async(*ctx.conn, device_path, result_port);
  });
}

void bluez_device_connect_profile(void* handle,
                                  const char* device_path,
                                  const char* profile_uuid,
                                  int64_t result_port) {
  run_async(handle, device_path, result_port, [&](BridgeContext& ctx) {
    if (profile_uuid == nullptr) {
      dart_result::post_error(result_port, device_path,
                              dart_result::kInvalidArguments,
                              "profile UUID is null");
      return;
    }
    DeviceBridge::connect_profile_async(*ctx.conn, device_path, profile_uuid,
                                        result_port);
  });
}

void bluez_device_disconnect(void* handle,
                             const char* device_path,
                             int64_t result_port) {
  run_async(handle, device_path, result_port, [&](BridgeContext& ctx) {
    DeviceBridge::disconnect_async(*ctx.conn, device_path, result_port);
  });
}

void bluez_device_pair(void* handle,
                       const char* device_path,
                       int64_t result_port) {
  run_async(handle, device_path, result_port, [&](BridgeContext& ctx) {
    DeviceBridge::pair_async(*ctx.conn, device_path, result_port);
  });
}

void bluez_device_cancel_pairing(void* handle, const char* device_path) {
  if (!all_set(device_path))
    return;
  run_sync(__func__, handle, [&](BridgeContext& ctx) {
    DeviceBridge device(*ctx.conn, device_path);
    device.cancel_pairing();
  });
}

void bluez_device_set_property(void* handle,
                               const char* device_path,
                               const char* prop_name,
                               const uint8_t* value_json,
                               int32_t len) {
  if (!all_set(device_path, prop_name, value_json))
    return;
  run_sync(__func__, handle, [&](BridgeContext& ctx) {
    DeviceBridge device(*ctx.conn, device_path);

    if (len == 1) {
      // NOLINTNEXTLINE(cppcoreguidelines-pro-bounds-pointer-arithmetic)
      device.set_property_bool(prop_name, value_json[0] != 0);
    }
  });
}

// ── GATT characteristic operations ──────────────────────────────────────────

void bluez_char_read_value(void* handle,
                           const char* char_path,
                           int64_t result_port) {
  run_async(handle, char_path, result_port, [&](BridgeContext& ctx) {
    GattCharBridge::read_value_async(*ctx.conn, char_path, result_port);
  });
}

void bluez_char_write_value(void* handle,
                            const char* char_path,
                            const uint8_t* value_buf,
                            int32_t len,
                            bool with_response,
                            int64_t result_port) {
  run_async(handle, char_path, result_port, [&](BridgeContext& ctx) {
    GattCharBridge::write_value_async(*ctx.conn, char_path, value_buf, len,
                                      with_response, result_port);
  });
}

void bluez_char_start_notify(void* handle,
                             const char* char_path,
                             int64_t result_port) {
  run_async(handle, char_path, result_port, [&](BridgeContext& ctx) {
    GattCharBridge::start_notify_async(*ctx.conn, char_path, *ctx.obj_mgr,
                                       result_port);
  });
}

void bluez_char_stop_notify(void* handle,
                            const char* char_path,
                            int64_t result_port) {
  run_async(handle, char_path, result_port, [&](BridgeContext& ctx) {
    GattCharBridge::stop_notify_async(*ctx.conn, char_path, *ctx.obj_mgr,
                                      result_port);
  });
}

// ── GATT descriptor operations ──────────────────────────────────────────────

void bluez_desc_read_value(void* handle,
                           const char* desc_path,
                           int64_t result_port) {
  run_async(handle, desc_path, result_port, [&](BridgeContext& ctx) {
    GattDescBridge::read_value_async(*ctx.conn, desc_path, result_port);
  });
}

void bluez_desc_write_value(void* handle,
                            const char* desc_path,
                            const uint8_t* value_buf,
                            int32_t len,
                            int64_t result_port) {
  run_async(handle, desc_path, result_port, [&](BridgeContext& ctx) {
    GattDescBridge::write_value_async(*ctx.conn, desc_path, value_buf, len,
                                      result_port);
  });
}

}  // extern "C"
