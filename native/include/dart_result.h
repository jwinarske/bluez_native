// dart_result.h — posting a call's outcome to its per-call Dart port.
//
// Every async entry point owes its result_port exactly one message: 0xFF on
// success, a 0x20 BlueZError on failure, or a 0x10/0x11 value. Dart awaits
// the first message and nothing else completes the future, so a path that
// returns without posting hangs the caller forever.

#pragma once

#include <cstdint>
#include <string>
#include <vector>

#include "bluez_types.h"
#include "dart_api_dl.h"

namespace dart_result {

/// Error name used when the client handle has already been destroyed.
inline constexpr auto kClientClosed = "org.bluez.Error.NotReady";

/// Error name used for null or otherwise unusable arguments.
inline constexpr auto kInvalidArguments = "org.bluez.Error.InvalidArguments";

/// Error name used when a non-D-Bus exception is caught.
inline constexpr auto kFailed = "org.bluez.Error.Failed";

inline void post_success(Dart_Port_DL port) {
  uint8_t sentinel = 0xFF;
  Dart_CObject obj;
  obj.type = Dart_CObject_kTypedData;
  obj.value.as_typed_data.type = Dart_TypedData_kUint8;
  obj.value.as_typed_data.length = 1;
  obj.value.as_typed_data.values = &sentinel;
  Dart_PostCObject_DL(port, &obj);
}

inline void post_error(Dart_Port_DL port,
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
  Dart_PostCObject_DL(port, &obj);
}

}  // namespace dart_result
