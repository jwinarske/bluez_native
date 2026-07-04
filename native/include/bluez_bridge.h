// bluez_bridge.h — C ABI exported to Dart FFI.
//
// The bridge owns ONE sdbus connection to the system bus and ONE event loop
// thread. All proxies share the connection.

#pragma once
#include "dart_api_dl.h"

#include <cstdint>

#define BLUEZ_EXPORT __attribute__((visibility("default")))

#ifdef __cplusplus
extern "C" {
#endif

// Initialise Dart API dynamic linking. Call once at startup.
BLUEZ_EXPORT void bluez_bridge_init(void* dart_api_dl_data);

// ── Client lifecycle ────────────────────────────────────────────────────────
BLUEZ_EXPORT void* bluez_client_create(int64_t events_port);
BLUEZ_EXPORT void bluez_client_destroy(void* handle);

// ── Adapter operations ──────────────────────────────────────────────────────
BLUEZ_EXPORT void bluez_adapter_start_discovery(void* handle,
                                                const char* adapter_path);
BLUEZ_EXPORT void bluez_adapter_stop_discovery(void* handle,
                                               const char* adapter_path);
BLUEZ_EXPORT void bluez_adapter_set_discovery_filter(void* handle,
                                                     const char* adapter_path,
                                                     const uint8_t* filter_json,
                                                     int32_t len);
BLUEZ_EXPORT void bluez_adapter_remove_device(void* handle,
                                              const char* adapter_path,
                                              const char* device_path);
BLUEZ_EXPORT void bluez_adapter_set_property(void* handle,
                                             const char* adapter_path,
                                             const char* prop_name,
                                             const uint8_t* value_json,
                                             int32_t len);

// ── Device operations ───────────────────────────────────────────────────────
BLUEZ_EXPORT void bluez_device_connect(void* handle,
                                       const char* device_path,
                                       int64_t result_port);
BLUEZ_EXPORT void bluez_device_disconnect(void* handle,
                                          const char* device_path,
                                          int64_t result_port);
BLUEZ_EXPORT void bluez_device_pair(void* handle,
                                    const char* device_path,
                                    int64_t result_port);
BLUEZ_EXPORT void bluez_device_cancel_pairing(void* handle,
                                              const char* device_path);
BLUEZ_EXPORT void bluez_device_set_trusted(void* handle,
                                           const char* device_path,
                                           bool value);

// ── GATT characteristic operations ──────────────────────────────────────────
BLUEZ_EXPORT void bluez_char_read_value(void* handle,
                                        const char* char_path,
                                        int64_t result_port);
BLUEZ_EXPORT void bluez_char_write_value(void* handle,
                                         const char* char_path,
                                         const uint8_t* value_buf,
                                         int32_t len,
                                         bool with_response,
                                         int64_t result_port);
BLUEZ_EXPORT void bluez_char_start_notify(void* handle,
                                          const char* char_path,
                                          int64_t result_port);
BLUEZ_EXPORT void bluez_char_stop_notify(void* handle,
                                         const char* char_path,
                                         int64_t result_port);

// ── Pairing agent ──────────────────────────────────────────────────────────
BLUEZ_EXPORT void bluez_agent_register(void* handle);
BLUEZ_EXPORT void bluez_agent_unregister(void* handle);
BLUEZ_EXPORT void bluez_agent_respond(void* handle,
                                      uint64_t request_id,
                                      bool accepted,
                                      const char* response);

// ── GATT descriptor operations ──────────────────────────────────────────────
BLUEZ_EXPORT void bluez_desc_read_value(void* handle,
                                        const char* desc_path,
                                        int64_t result_port);
BLUEZ_EXPORT void bluez_desc_write_value(void* handle,
                                         const char* desc_path,
                                         const uint8_t* value_buf,
                                         int32_t len,
                                         int64_t result_port);

#ifdef __cplusplus
}
#endif
