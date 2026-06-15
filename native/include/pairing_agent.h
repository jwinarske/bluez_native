// pairing_agent.h — BlueZ Agent1 D-Bus object for pairing.
//
// Registers a D-Bus object implementing org.bluez.Agent1 that BlueZ calls
// back into during pairing. Uses sdbus-c++ async Result<> to defer replies
// until Dart responds via bluez_agent_respond().

#pragma once

#include <sdbus-c++/sdbus-c++.h>

#include <atomic>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <variant>

#include "bluez_types.h"
#include "dart_api_dl.h"

class PairingAgent {
 public:
  PairingAgent(sdbus::IConnection& conn, Dart_Port_DL events_port);

  /// Register with org.bluez.AgentManager1 and request default agent status.
  void register_agent();

  /// Unregister from org.bluez.AgentManager1.
  void unregister_agent();

  /// Complete a pending agent request from Dart.
  /// @param request_id  ID from the BlueZAgentRequest event.
  /// @param accepted    true = approve, false = reject.
  /// @param response    PIN code or passkey string (empty for confirmations).
  void respond(uint64_t request_id, bool accepted, const std::string& response);

 private:
  static constexpr auto kAgentPath = "/org/bluez/agent";
  static constexpr auto kAgentIface = "org.bluez.Agent1";
  static constexpr auto kAgentManagerIface = "org.bluez.AgentManager1";
  static constexpr auto kBluezService = "org.bluez";
  static constexpr auto kCapability = "KeyboardDisplay";

  sdbus::IConnection& conn_;
  Dart_Port_DL events_port_;
  std::unique_ptr<sdbus::IObject> object_;

  // Pending async results, keyed by request ID.
  struct PendingRequest {
    uint8_t type{};
    std::variant<sdbus::Result<std::string>,  // RequestPinCode
                 sdbus::Result<uint32_t>,     // RequestPasskey
                 sdbus::Result<>,             // Confirmation/Authorization
                 std::monostate  // Display/Cancel/Release (no reply)
                 >
        result;
  };

  std::mutex pending_mutex_;
  std::map<uint64_t, PendingRequest> pending_;
  std::atomic<uint64_t> next_id_{1};

  // Agent1 method handlers.
  void on_request_pin_code(sdbus::Result<std::string>&& result,
                           const sdbus::ObjectPath& device);
  void on_display_pin_code(const sdbus::ObjectPath& device,
                           const std::string& pincode);
  void on_request_passkey(sdbus::Result<uint32_t>&& result,
                          const sdbus::ObjectPath& device);
  void on_display_passkey(const sdbus::ObjectPath& device,
                          uint32_t passkey,
                          uint16_t entered);
  void on_request_confirmation(sdbus::Result<>&& result,
                               const sdbus::ObjectPath& device,
                               uint32_t passkey);
  void on_request_authorization(sdbus::Result<>&& result,
                                const sdbus::ObjectPath& device);
  void on_authorize_service(sdbus::Result<>&& result,
                            const sdbus::ObjectPath& device,
                            const std::string& uuid);
  void on_cancel();
  void on_release();

  void post_request(uint64_t id,
                    uint8_t type,
                    const std::string& device_path,
                    uint32_t passkey,
                    uint16_t entered,
                    const std::string& pin_code,
                    const std::string& uuid) const;
};
