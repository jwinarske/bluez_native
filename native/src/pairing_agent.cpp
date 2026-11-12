// pairing_agent.cpp — BlueZ Agent1 implementation.

#include "pairing_agent.h"

#include <cstdio>
#include <utility>

PairingAgent::PairingAgent(sdbus::IConnection& conn, Dart_Port_DL events_port)
    : conn_(conn), events_port_(events_port) {
  object_ = sdbus::createObject(conn_, sdbus::ObjectPath{kAgentPath});

  // clang-format off
  object_->addVTable(
      sdbus::registerMethod("RequestPinCode")
          .withInputParamNames("device")
          .withOutputParamNames("pincode")
          .implementedAs([this](sdbus::Result<std::string>&& r,
                                const sdbus::ObjectPath& d) {
            on_request_pin_code(std::move(r), d);
          }),
      sdbus::registerMethod("DisplayPinCode")
          .withInputParamNames("device", "pincode")
          .implementedAs([this](const sdbus::ObjectPath& d,
                                const std::string& p) {
            on_display_pin_code(d, p);
          }),
      sdbus::registerMethod("RequestPasskey")
          .withInputParamNames("device")
          .withOutputParamNames("passkey")
          .implementedAs([this](sdbus::Result<uint32_t>&& r,
                                const sdbus::ObjectPath& d) {
            on_request_passkey(std::move(r), d);
          }),
      sdbus::registerMethod("DisplayPasskey")
          .withInputParamNames("device", "passkey", "entered")
          .implementedAs([this](const sdbus::ObjectPath& d,
                                uint32_t k, uint16_t e) {
            on_display_passkey(d, k, e);
          }),
      sdbus::registerMethod("RequestConfirmation")
          .withInputParamNames("device", "passkey")
          .implementedAs([this](sdbus::Result<>&& r,
                                const sdbus::ObjectPath& d, uint32_t k) {
            on_request_confirmation(std::move(r), d, k);
          }),
      sdbus::registerMethod("RequestAuthorization")
          .withInputParamNames("device")
          .implementedAs([this](sdbus::Result<>&& r,
                                const sdbus::ObjectPath& d) {
            on_request_authorization(std::move(r), d);
          }),
      sdbus::registerMethod("AuthorizeService")
          .withInputParamNames("device", "uuid")
          .implementedAs([this](sdbus::Result<>&& r,
                                const sdbus::ObjectPath& d,
                                const std::string& u) {
            on_authorize_service(std::move(r), d, u);
          }),
      sdbus::registerMethod("Cancel")
          .implementedAs([this]() { on_cancel(); }),
      sdbus::registerMethod("Release")
          .implementedAs([this]() { on_release(); })
  ).forInterface(kAgentIface);
  // clang-format on
}

// ── Registration ────────────────────────────────────────────────────────────

void PairingAgent::register_agent() {
  auto proxy = sdbus::createProxy(conn_, sdbus::ServiceName{kBluezService},
                                  sdbus::ObjectPath{"/org/bluez"});
  proxy->callMethod("RegisterAgent")
      .onInterface(kAgentManagerIface)
      .withArguments(sdbus::ObjectPath{kAgentPath}, std::string{kCapability});
  proxy->callMethod("RequestDefaultAgent")
      .onInterface(kAgentManagerIface)
      .withArguments(sdbus::ObjectPath{kAgentPath});
}

void PairingAgent::unregister_agent() {
  try {
    auto proxy = sdbus::createProxy(conn_, sdbus::ServiceName{kBluezService},
                                    sdbus::ObjectPath{"/org/bluez"});
    proxy->callMethod("UnregisterAgent")
        .onInterface(kAgentManagerIface)
        .withArguments(sdbus::ObjectPath{kAgentPath});
  } catch (const sdbus::Error&) {
    // Best-effort: agent may already be unregistered.
  }

  // Reject any pending requests.
  std::scoped_lock lock(pending_mutex_);
  for (auto& [id, req] : pending_) {
    std::visit(
        [](auto& r) {
          using T = std::decay_t<decltype(r)>;
          if constexpr (!std::is_same_v<T, std::monostate>) {
            r.returnError(
                sdbus::Error{sdbus::Error::Name{"org.bluez.Error.Canceled"},
                             "Agent released"});
          }
        },
        req.result);
  }
  pending_.clear();
}

// ── Agent method handlers ───────────────────────────────────────────────────

void PairingAgent::on_request_pin_code(sdbus::Result<std::string>&& result,
                                       const sdbus::ObjectPath& device) {
  auto id = next_id_++;
  std::scoped_lock lock(pending_mutex_);
  pending_[id] = {kRequestPinCode, std::move(result)};
  post_request(id, kRequestPinCode, device, 0, 0, "", "");
}

void PairingAgent::on_display_pin_code(const sdbus::ObjectPath& device,
                                       const std::string& pincode) {
  post_request(0, kDisplayPinCode, device, 0, 0, pincode, "");
}

void PairingAgent::on_request_passkey(sdbus::Result<uint32_t>&& result,
                                      const sdbus::ObjectPath& device) {
  auto id = next_id_++;
  std::scoped_lock lock(pending_mutex_);
  pending_[id] = {kRequestPasskey, std::move(result)};
  post_request(id, kRequestPasskey, device, 0, 0, "", "");
}

void PairingAgent::on_display_passkey(const sdbus::ObjectPath& device,
                                      uint32_t passkey,
                                      uint16_t entered) {
  post_request(0, kDisplayPasskey, device, passkey, entered, "", "");
}

void PairingAgent::on_request_confirmation(sdbus::Result<>&& result,
                                           const sdbus::ObjectPath& device,
                                           uint32_t passkey) {
  auto id = next_id_++;
  std::scoped_lock lock(pending_mutex_);
  pending_[id] = {kRequestConfirmation, std::move(result)};
  post_request(id, kRequestConfirmation, device, passkey, 0, "", "");
}

void PairingAgent::on_request_authorization(sdbus::Result<>&& result,
                                            const sdbus::ObjectPath& device) {
  auto id = next_id_++;
  std::scoped_lock lock(pending_mutex_);
  pending_[id] = {kRequestAuthorization, std::move(result)};
  post_request(id, kRequestAuthorization, device, 0, 0, "", "");
}

void PairingAgent::on_authorize_service(sdbus::Result<>&& result,
                                        const sdbus::ObjectPath& device,
                                        const std::string& uuid) {
  auto id = next_id_++;
  std::scoped_lock lock(pending_mutex_);
  pending_[id] = {kAuthorizeService, std::move(result)};
  post_request(id, kAuthorizeService, device, 0, 0, "", uuid);
}

void PairingAgent::on_cancel() {
  post_request(0, kAgentCancel, "", 0, 0, "", "");

  // Reject all pending requests — BlueZ has canceled them.
  std::scoped_lock lock(pending_mutex_);
  for (auto& [id, req] : pending_) {
    std::visit(
        [](auto& r) {
          using T = std::decay_t<decltype(r)>;
          if constexpr (!std::is_same_v<T, std::monostate>) {
            r.returnError(sdbus::Error{
                sdbus::Error::Name{"org.bluez.Error.Canceled"}, "Canceled"});
          }
        },
        req.result);
  }
  pending_.clear();
}

void PairingAgent::on_release() {
  post_request(0, kAgentRelease, "", 0, 0, "", "");
}

// ── Response from Dart ──────────────────────────────────────────────────────

void PairingAgent::respond(uint64_t request_id,
                           bool accepted,
                           const std::string& response) {
  PendingRequest req;
  {
    std::scoped_lock lock(pending_mutex_);
    auto it = pending_.find(request_id);
    if (it == pending_.end()) {
      return;  // Already canceled or timed out.
    }
    req = std::move(it->second);
    pending_.erase(it);
  }

  if (!accepted) {
    std::visit(
        [](auto& r) {
          using T = std::decay_t<decltype(r)>;
          if constexpr (!std::is_same_v<T, std::monostate>) {
            r.returnError(
                sdbus::Error{sdbus::Error::Name{"org.bluez.Error.Rejected"},
                             "User rejected"});
          }
        },
        req.result);
    return;
  }

  std::visit(
      [&response](auto& r) {
        using T = std::decay_t<decltype(r)>;
        if constexpr (std::is_same_v<T, sdbus::Result<std::string>>) {
          r.returnResults(response);
        } else if constexpr (std::is_same_v<T, sdbus::Result<uint32_t>>) {
          uint32_t passkey = 0;
          try {
            passkey = static_cast<uint32_t>(std::stoul(response));
          } catch (...) {
          }
          r.returnResults(passkey);
        } else if constexpr (std::is_same_v<T, sdbus::Result<>>) {
          r.returnResults();
        }
        // std::monostate: nothing to do.
      },
      req.result);
}

// ── Dart posting ────────────────────────────────────────────────────────────

void PairingAgent::post_request(uint64_t id,
                                uint8_t type,
                                const std::string& device_path,
                                uint32_t passkey,
                                uint16_t entered,
                                const std::string& pin_code,
                                const std::string& uuid) const {
  BlueZAgentRequest req;
  req.requestId = id;
  req.requestType = type;
  req.devicePath = device_path;
  req.passkey = passkey;
  req.entered = entered;
  req.pinCode = pin_code;
  req.uuid = uuid;

  auto payload = glz::encode(req);

  std::vector<uint8_t> buf;
  buf.reserve(1 + payload.size());
  buf.push_back(0x30);
  buf.insert(buf.end(), payload.begin(), payload.end());

  Dart_CObject obj;
  obj.type = Dart_CObject_kTypedData;
  obj.value.as_typed_data.type = Dart_TypedData_kUint8;
  obj.value.as_typed_data.length = static_cast<intptr_t>(buf.size());
  obj.value.as_typed_data.values = buf.data();
  Dart_PostCObject_DL(events_port_, &obj);
}
