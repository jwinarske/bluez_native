// gatt_bridge.cpp — GATT Characteristic1 and Descriptor1 async operations.

#include "gatt_bridge.h"

#include <memory>
#include <optional>
#include <utility>

// Helper: create a shared proxy that stays alive through async callbacks.
static std::shared_ptr<sdbus::IProxy> make_proxy(sdbus::IConnection& conn,
                                                 const std::string& path) {
  return std::shared_ptr<sdbus::IProxy>(
      sdbus::createProxy(conn, sdbus::ServiceName{"org.bluez"},
                         sdbus::ObjectPath{path})
          .release());
}

// ═══════════════════════════════════════════════════════════════════════════
// GattCharBridge
// ═══════════════════════════════════════════════════════════════════════════

void GattCharBridge::read_value_async(sdbus::IConnection& conn,
                                      const std::string& char_path,
                                      Dart_Port_DL result_port) {
  auto proxy = make_proxy(conn, char_path);
  std::map<std::string, sdbus::Variant> options;

  proxy->callMethodAsync("ReadValue")
      .onInterface(kGattCharIface)
      .withArguments(options)
      .uponReplyInvoke(
          [proxy, char_path, result_port](std::optional<sdbus::Error> error,
                                          const std::vector<uint8_t>& value) {
            if (error) {
              post_error(result_port, char_path, error->getName(),
                         error->getMessage());
            } else {
              post_value_result(result_port, char_path, value);
            }
          });
}

void GattCharBridge::write_value_async(sdbus::IConnection& conn,
                                       const std::string& char_path,
                                       const uint8_t* data,
                                       int32_t len,
                                       bool with_response,
                                       Dart_Port_DL result_port) {
  if (len < 0 || data == nullptr) {
    post_error(result_port, char_path, "org.bluez.Error.InvalidArguments",
               "Invalid write data");
    return;
  }
  auto proxy = make_proxy(conn, char_path);

  // NOLINTNEXTLINE(cppcoreguidelines-pro-bounds-pointer-arithmetic)
  std::vector<uint8_t> value(data, data + static_cast<size_t>(len));
  std::map<std::string, sdbus::Variant> options;
  if (!with_response) {
    options["type"] = sdbus::Variant{std::string{"command"}};
  }

  proxy->callMethodAsync("WriteValue")
      .onInterface(kGattCharIface)
      .withArguments(value, options)
      .uponReplyInvoke(
          [proxy, char_path, result_port](std::optional<sdbus::Error> error) {
            if (error) {
              post_error(result_port, char_path, error->getName(),
                         error->getMessage());
            } else {
              post_success(result_port);
            }
          });
}

// Verifies the Notifying property after a Start/StopNotify reply.
//
// A successful method reply does NOT prove notifications changed state.
// BlueZ scopes a notification session to the D-Bus client that requested it,
// so a short-lived client (or one whose connection is torn down and recreated
// per operation) sees StartNotify succeed while Notifying silently stays
// false and no PropertiesChanged ever arrives. That failure presents as "the
// peripheral stopped responding" and is thoroughly unpleasant to trace.
//
// This bridge holds one long-lived connection, so it should not hit that --
// but checking is nearly free and converts a silent no-op into an exception.
//
// The read is async: this runs on the event loop thread, where a synchronous
// D-Bus call can deadlock.
//
// If the verification itself fails we report success. An unreadable property
// is not evidence the operation failed, and failing here would break working
// callers for no reason.
void GattCharBridge::verify_notifying(
    const std::shared_ptr<sdbus::IProxy>& proxy,
    const std::string& char_path,
    bool expected,
    Dart_Port_DL result_port,
    const std::function<void()>& on_complete) {
  // sdbus::apply invokes the reply handler with by-value arguments; const&
  // parameters do not bind and the template fails to instantiate. Do not
  // "optimize" these into references.
  // NOLINTBEGIN(performance-unnecessary-value-param)
  proxy->getPropertyAsync("Notifying")
      .onInterface(kGattCharIface)
      .uponReplyInvoke([proxy, char_path, expected, result_port, on_complete](
                           std::optional<sdbus::Error> error,
                           sdbus::Variant value) {
        if (on_complete) {
          on_complete();
        }
        if (error) {
          post_success(result_port);
          return;
        }
        bool actual = false;
        try {
          actual = value.get<bool>();
        } catch (...) {
          post_success(result_port);
          return;
        }
        if (actual == expected) {
          post_success(result_port);
        } else if (expected) {
          post_error(
              result_port, char_path, "org.bluez.Error.NotifyNotEnabled",
              "StartNotify returned success but Notifying is still false. "
              "BlueZ scopes the notification session to the requesting D-Bus "
              "client; no value notifications will arrive.");
        } else {
          post_error(result_port, char_path,
                     "org.bluez.Error.NotifyStillEnabled",
                     "StopNotify returned success but Notifying is still true; "
                     "value notifications may continue to arrive.");
        }
      });
  // NOLINTEND(performance-unnecessary-value-param)
}

void GattCharBridge::start_notify_async(sdbus::IConnection& conn,
                                        const std::string& char_path,
                                        ObjectManager& obj_mgr,
                                        Dart_Port_DL result_port) {
  auto proxy = make_proxy(conn, char_path);

  // Subscribe BEFORE calling StartNotify, not after.
  //
  // BlueZ emits PropertiesChanged for Notifying=true while servicing
  // StartNotify. Registering the listener in the reply handler is too late --
  // the signal has already been delivered, so the cached `notifying` state
  // stays false forever even though notifications are flowing. Value
  // notifications happen to arrive later and so were unaffected, which is why
  // this went unnoticed.
  obj_mgr.subscribe_char_notify(char_path);

  proxy->callMethodAsync("StartNotify")
      .onInterface(kGattCharIface)
      .uponReplyInvoke([proxy, char_path, &obj_mgr,
                        result_port](std::optional<sdbus::Error> error) {
        if (error) {
          // Roll back the early subscription so a failed StartNotify does not
          // leave a listener behind.
          obj_mgr.unsubscribe_char_notify(char_path);
          post_error(result_port, char_path, error->getName(),
                     error->getMessage());
        } else {
          verify_notifying(proxy, char_path, /*expected=*/true, result_port);
        }
      });
}

void GattCharBridge::stop_notify_async(sdbus::IConnection& conn,
                                       const std::string& char_path,
                                       ObjectManager& obj_mgr,
                                       Dart_Port_DL result_port) {
  auto proxy = make_proxy(conn, char_path);

  proxy->callMethodAsync("StopNotify")
      .onInterface(kGattCharIface)
      .uponReplyInvoke([proxy, char_path, &obj_mgr,
                        result_port](std::optional<sdbus::Error> error) {
        if (error) {
          post_error(result_port, char_path, error->getName(),
                     error->getMessage());
        } else {
          // Unsubscribe only after the property read resolves. Tearing the
          // subscription down first would drop a Notifying=false signal that
          // arrives after the reply, leaving the cached state stuck at true.
          verify_notifying(proxy, char_path, /*expected=*/false, result_port,
                           [&obj_mgr, char_path] {
                             obj_mgr.unsubscribe_char_notify(char_path);
                           });
        }
      });
}

// ── Dart posting helpers ────────────────────────────────────────────────────

void GattCharBridge::post_success(Dart_Port_DL result_port) {
  uint8_t sentinel = 0xFF;
  Dart_CObject obj;
  obj.type = Dart_CObject_kTypedData;
  obj.value.as_typed_data.type = Dart_TypedData_kUint8;
  obj.value.as_typed_data.length = 1;
  obj.value.as_typed_data.values = &sentinel;
  Dart_PostCObject_DL(result_port, &obj);
}

void GattCharBridge::post_value_result(Dart_Port_DL result_port,
                                       const std::string& object_path,
                                       const std::vector<uint8_t>& value) {
  BlueZValueResult result;
  result.objectPath = object_path;
  result.value = value;

  auto payload = glz::encode(result);

  std::vector<uint8_t> buf;
  buf.reserve(1 + payload.size());
  buf.push_back(0x10);
  buf.insert(buf.end(), payload.begin(), payload.end());

  Dart_CObject obj;
  obj.type = Dart_CObject_kTypedData;
  obj.value.as_typed_data.type = Dart_TypedData_kUint8;
  obj.value.as_typed_data.length = static_cast<intptr_t>(buf.size());
  obj.value.as_typed_data.values = buf.data();
  Dart_PostCObject_DL(result_port, &obj);
}

void GattCharBridge::post_error(Dart_Port_DL result_port,
                                const std::string& object_path,
                                const std::string& error_name,
                                const std::string& error_message) {
  BlueZError err;
  err.objectPath = object_path;
  err.name = error_name;
  err.message = error_message;

  auto payload = glz::encode(err);

  std::vector<uint8_t> buf;
  buf.reserve(1 + payload.size());
  buf.push_back(0x20);
  buf.insert(buf.end(), payload.begin(), payload.end());

  Dart_CObject obj;
  obj.type = Dart_CObject_kTypedData;
  obj.value.as_typed_data.type = Dart_TypedData_kUint8;
  obj.value.as_typed_data.length = static_cast<intptr_t>(buf.size());
  obj.value.as_typed_data.values = buf.data();
  Dart_PostCObject_DL(result_port, &obj);
}

// ═══════════════════════════════════════════════════════════════════════════
// GattDescBridge
// ═══════════════════════════════════════════════════════════════════════════

void GattDescBridge::read_value_async(sdbus::IConnection& conn,
                                      const std::string& desc_path,
                                      Dart_Port_DL result_port) {
  auto proxy = make_proxy(conn, desc_path);
  std::map<std::string, sdbus::Variant> options;

  proxy->callMethodAsync("ReadValue")
      .onInterface(kGattDescIface)
      .withArguments(options)
      .uponReplyInvoke(
          [proxy, desc_path, result_port](std::optional<sdbus::Error> error,
                                          const std::vector<uint8_t>& value) {
            if (error) {
              post_error(result_port, desc_path, error->getName(),
                         error->getMessage());
            } else {
              post_value_result(result_port, desc_path, value);
            }
          });
}

void GattDescBridge::write_value_async(sdbus::IConnection& conn,
                                       const std::string& desc_path,
                                       const uint8_t* data,
                                       int32_t len,
                                       Dart_Port_DL result_port) {
  if (len < 0 || data == nullptr) {
    post_error(result_port, desc_path, "org.bluez.Error.InvalidArguments",
               "Invalid write data");
    return;
  }
  auto proxy = make_proxy(conn, desc_path);

  // NOLINTNEXTLINE(cppcoreguidelines-pro-bounds-pointer-arithmetic)
  std::vector<uint8_t> value(data, data + static_cast<size_t>(len));
  std::map<std::string, sdbus::Variant> options;

  proxy->callMethodAsync("WriteValue")
      .onInterface(kGattDescIface)
      .withArguments(value, options)
      .uponReplyInvoke(
          [proxy, desc_path, result_port](std::optional<sdbus::Error> error) {
            if (error) {
              post_error(result_port, desc_path, error->getName(),
                         error->getMessage());
            } else {
              post_success(result_port);
            }
          });
}

// ── Dart posting helpers ────────────────────────────────────────────────────

void GattDescBridge::post_success(Dart_Port_DL result_port) {
  uint8_t sentinel = 0xFF;
  Dart_CObject obj;
  obj.type = Dart_CObject_kTypedData;
  obj.value.as_typed_data.type = Dart_TypedData_kUint8;
  obj.value.as_typed_data.length = 1;
  obj.value.as_typed_data.values = &sentinel;
  Dart_PostCObject_DL(result_port, &obj);
}

void GattDescBridge::post_value_result(Dart_Port_DL result_port,
                                       const std::string& object_path,
                                       const std::vector<uint8_t>& value) {
  BlueZValueResult result;
  result.objectPath = object_path;
  result.value = value;

  auto payload = glz::encode(result);

  std::vector<uint8_t> buf;
  buf.reserve(1 + payload.size());
  buf.push_back(0x11);
  buf.insert(buf.end(), payload.begin(), payload.end());

  Dart_CObject obj;
  obj.type = Dart_CObject_kTypedData;
  obj.value.as_typed_data.type = Dart_TypedData_kUint8;
  obj.value.as_typed_data.length = static_cast<intptr_t>(buf.size());
  obj.value.as_typed_data.values = buf.data();
  Dart_PostCObject_DL(result_port, &obj);
}

void GattDescBridge::post_error(Dart_Port_DL result_port,
                                const std::string& object_path,
                                const std::string& error_name,
                                const std::string& error_message) {
  BlueZError err;
  err.objectPath = object_path;
  err.name = error_name;
  err.message = error_message;

  auto payload = glz::encode(err);

  std::vector<uint8_t> buf;
  buf.reserve(1 + payload.size());
  buf.push_back(0x20);
  buf.insert(buf.end(), payload.begin(), payload.end());

  Dart_CObject obj;
  obj.type = Dart_CObject_kTypedData;
  obj.value.as_typed_data.type = Dart_TypedData_kUint8;
  obj.value.as_typed_data.length = static_cast<intptr_t>(buf.size());
  obj.value.as_typed_data.values = buf.data();
  Dart_PostCObject_DL(result_port, &obj);
}