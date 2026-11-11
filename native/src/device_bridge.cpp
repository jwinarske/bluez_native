// device_bridge.cpp — Device1 D-Bus proxy implementation.

#include "device_bridge.h"

#include "dart_result.h"

#include <memory>
#include <optional>
#include <utility>

DeviceBridge::DeviceBridge(sdbus::IConnection& conn, std::string device_path)
    : conn_(conn),
      device_path_(std::move(device_path)),
      proxy_(sdbus::createProxy(conn_,
                                sdbus::ServiceName{kBluezService},
                                sdbus::ObjectPath{device_path_})) {}

// ── Async operations ────────────────────────────────────────────────────────

void DeviceBridge::connect_async(sdbus::IConnection& conn,
                                 const std::string& device_path,
                                 Dart_Port_DL result_port) {
  call_device_method_async(conn, device_path, "Connect", result_port);
}

void DeviceBridge::connect_profile_async(sdbus::IConnection& conn,
                                         const std::string& device_path,
                                         const std::string& profile_uuid,
                                         Dart_Port_DL result_port) {
  call_device_method_async(conn, device_path, "ConnectProfile", result_port,
                           profile_uuid);
}

void DeviceBridge::disconnect_async(sdbus::IConnection& conn,
                                    const std::string& device_path,
                                    Dart_Port_DL result_port) {
  call_device_method_async(conn, device_path, "Disconnect", result_port);
}

void DeviceBridge::pair_async(sdbus::IConnection& conn,
                              const std::string& device_path,
                              Dart_Port_DL result_port) {
  call_device_method_async(conn, device_path, "Pair", result_port);
}

template <typename... Args>
void DeviceBridge::call_device_method_async(sdbus::IConnection& conn,
                                            const std::string& device_path,
                                            const char* method_name,
                                            Dart_Port_DL result_port,
                                            const Args&... args) {
  // The proxy must stay alive until the async callback fires.
  // Capture it as a shared_ptr in the callback lambda.
  auto proxy = std::shared_ptr<sdbus::IProxy>(
      sdbus::createProxy(conn, sdbus::ServiceName{kBluezService},
                         sdbus::ObjectPath{device_path})
          .release());

  proxy->callMethodAsync(method_name)
      .onInterface(kDeviceIface)
      .withArguments(args...)
      .uponReplyInvoke(
          [proxy, device_path, result_port](std::optional<sdbus::Error> error) {
            if (error) {
              post_error(result_port, device_path, error->getName(),
                         error->getMessage());
            } else {
              post_success(result_port);
            }
          });
}

void DeviceBridge::cancel_pairing() {
  try {
    proxy_->callMethod("CancelPairing").onInterface(kDeviceIface);
  } catch (const sdbus::Error&) {
    // Best-effort: ignore errors on cancel.
  }
}

// ── Properties ──────────────────────────────────────────────────────────────

void DeviceBridge::set_trusted(bool value) {
  set_property_bool("Trusted", value);
}

void DeviceBridge::set_blocked(bool value) {
  set_property_bool("Blocked", value);
}

void DeviceBridge::set_alias(const std::string& value) {
  set_property_string("Alias", value);
}

void DeviceBridge::set_property_bool(const std::string& name, bool value) {
  proxy_->setProperty(name).onInterface(kDeviceIface).toValue(value);
}

void DeviceBridge::set_property_string(const std::string& name,
                                       const std::string& value) {
  proxy_->setProperty(name).onInterface(kDeviceIface).toValue(value);
}

// ── Dart posting helpers ────────────────────────────────────────────────────

void DeviceBridge::post_success(Dart_Port_DL result_port) {
  dart_result::post_success(result_port);
}

void DeviceBridge::post_error(Dart_Port_DL result_port,
                              const std::string& object_path,
                              const std::string& error_name,
                              const std::string& error_message) {
  dart_result::post_error(result_port, object_path, error_name, error_message);
}
