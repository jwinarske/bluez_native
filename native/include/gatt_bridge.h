// gatt_bridge.h — GATT Characteristic1 and Descriptor1 D-Bus proxy wrappers.
//
// All operations are async (callMethodAsync) to avoid blocking the Dart
// isolate. Results are posted to a per-call result_port.

#pragma once

#include <sdbus-c++/sdbus-c++.h>

#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <vector>

#include "bluez_types.h"
#include "dart_api_dl.h"
#include "object_manager.h"

class GattCharBridge {
 public:
  // ── Async operations ────────────────────────────────────────────────────

  // Read the characteristic value.
  // Posts 0x10 BlueZValueResult on success, 0x20 BlueZError on failure.
  static void read_value_async(sdbus::IConnection& conn,
                               const std::string& char_path,
                               Dart_Port_DL result_port);

  // Write bytes to the characteristic.
  // with_response selects Write (true) vs WriteWithoutResponse (false).
  // Posts 0xFF on success, 0x20 BlueZError on failure.
  static void write_value_async(sdbus::IConnection& conn,
                                const std::string& char_path,
                                const uint8_t* data,
                                int32_t len,
                                bool with_response,
                                Dart_Port_DL result_port);

  // Subscribe to characteristic notifications.
  // Posts 0xFF on success, 0x20 BlueZError on failure.
  static void start_notify_async(sdbus::IConnection& conn,
                                 const std::string& char_path,
                                 ObjectManager& obj_mgr,
                                 Dart_Port_DL result_port);

  // Unsubscribe from characteristic notifications.
  // Posts 0xFF on success, 0x20 BlueZError on failure.
  static void stop_notify_async(sdbus::IConnection& conn,
                                const std::string& char_path,
                                ObjectManager& obj_mgr,
                                Dart_Port_DL result_port);

 private:
  static constexpr auto kBluezService = "org.bluez";
  static constexpr auto kGattCharIface = "org.bluez.GattCharacteristic1";

  static void post_success(Dart_Port_DL result_port);
  static void post_value_result(Dart_Port_DL result_port,
                                const std::string& object_path,
                                const std::vector<uint8_t>& value);
  static void post_error(Dart_Port_DL result_port,
                         const std::string& object_path,
                         const std::string& error_name,
                         const std::string& error_message);

  // Confirms Notifying reached `expected` after a Start/StopNotify reply,
  // then posts the final success or error. See the definition for why a
  // successful method reply is not sufficient evidence on its own.
  // `on_complete` runs once the property read has resolved, before the
  // result is posted. Used to defer teardown until the subscription has had
  // the chance to observe the final Notifying transition.
  static void verify_notifying(const std::shared_ptr<sdbus::IProxy>& proxy,
                               const std::string& char_path,
                               bool expected,
                               Dart_Port_DL result_port,
                               const std::function<void()>& on_complete = {});
};

class GattDescBridge {
 public:
  // Read the descriptor value.
  // Posts 0x11 BlueZDescValue on success, 0x20 BlueZError on failure.
  static void read_value_async(sdbus::IConnection& conn,
                               const std::string& desc_path,
                               Dart_Port_DL result_port);

  // Write bytes to the descriptor.
  // Posts 0xFF on success, 0x20 BlueZError on failure.
  static void write_value_async(sdbus::IConnection& conn,
                                const std::string& desc_path,
                                const uint8_t* data,
                                int32_t len,
                                Dart_Port_DL result_port);

 private:
  static constexpr auto kBluezService = "org.bluez";
  static constexpr auto kGattDescIface = "org.bluez.GattDescriptor1";

  static void post_success(Dart_Port_DL result_port);
  static void post_value_result(Dart_Port_DL result_port,
                                const std::string& object_path,
                                const std::vector<uint8_t>& value);
  static void post_error(Dart_Port_DL result_port,
                         const std::string& object_path,
                         const std::string& error_name,
                         const std::string& error_message);
};