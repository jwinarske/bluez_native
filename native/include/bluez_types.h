// bluez_types.h — wire types for all BlueZ-to-Dart payloads.
//
// Message discriminator byte at offset 0 in kExternalTypedData:
//   0x01 = BlueZAdapterProps   (adapter PropertiesChanged or initial state)
//   0x02 = BlueZDeviceProps    (device PropertiesChanged or initial state)
//   0x03 = BlueZGattCharProps  (characteristic PropertiesChanged — Value field)
//   0x04 = BlueZDeviceAdded    (InterfacesAdded for Device1)
//   0x05 = BlueZDeviceRemoved  (InterfacesRemoved for Device1)
//   0x06 = BlueZServiceAdded   (GattService1 appeared)
//   0x07 = BlueZCharAdded      (GattCharacteristic1 appeared)
//   0x08 = BlueZDescAdded      (GattDescriptor1 appeared)
//   0x09 = BlueZObjectRemoved  (InterfacesRemoved, generic)
//   0x10 = BlueZCharValue      (ReadValue / WriteValue result)
//   0x11 = BlueZDescValue      (ReadValue on descriptor)
//   0x20 = BlueZError          (method call failed)
//   0x30 = BlueZAgentRequest   (pairing agent callback from BlueZ)
//   0xFF = sentinel (stream done)

#pragma once
#include "glaze_meta.h"

#include <cstdint>
#include <map>
#include <string>
#include <vector>

// ── Shared types ────────────────────────────────────────────────────────────

struct ManufacturerDataEntry {
  uint16_t companyId{};
  std::vector<uint8_t> data;
};
template <>
struct glz::meta<ManufacturerDataEntry> {
  static constexpr auto fields = std::make_tuple(
      glz::field("companyId", &ManufacturerDataEntry::companyId),
      glz::field("data", &ManufacturerDataEntry::data));
};

// ── Adapter property change mask bits ───────────────────────────────────────
enum AdapterChangedBit : uint32_t {
  kPoweredBit = 1u << 0,
  kDiscoveringBit = 1u << 1,
  kDiscoverableBit = 1u << 2,
  kPairableBit = 1u << 3,
  kAdapterAliasBit = 1u << 4,
};

// ── Adapter properties ──────────────────────────────────────────────────────

struct BlueZAdapterProps {
  std::string objectPath;  // e.g. "/org/bluez/hci0"
  uint32_t changedMask{};  // Bitmask of AdapterChangedBit values.
  std::string address;
  std::string name;
  std::string alias;
  bool powered{};
  bool discoverable{};
  bool pairable{};
  bool discovering{};
  uint32_t discoverableTimeout{};
  std::vector<std::string> uuids;
};
template <>
struct glz::meta<BlueZAdapterProps> {
  static constexpr auto fields = std::make_tuple(
      glz::field("objectPath", &BlueZAdapterProps::objectPath),
      glz::field("changedMask", &BlueZAdapterProps::changedMask),
      glz::field("address", &BlueZAdapterProps::address),
      glz::field("name", &BlueZAdapterProps::name),
      glz::field("alias", &BlueZAdapterProps::alias),
      glz::field("powered", &BlueZAdapterProps::powered),
      glz::field("discoverable", &BlueZAdapterProps::discoverable),
      glz::field("pairable", &BlueZAdapterProps::pairable),
      glz::field("discovering", &BlueZAdapterProps::discovering),
      glz::field("discoverableTimeout",
                 &BlueZAdapterProps::discoverableTimeout),
      glz::field("uuids", &BlueZAdapterProps::uuids));
};

// ── Device property change mask bits ────────────────────────────────────────
// Used in BlueZDeviceProps::changedMask to indicate which fields were
// explicitly set in a PropertiesChanged update (vs. left at defaults).
// For 0x04 (DeviceAdded / full snapshot) events, changedMask == ~0u.
enum DeviceChangedBit : uint32_t {
  kConnectedBit = 1u << 0,
  kRSSIBit = 1u << 1,
  kPairedBit = 1u << 2,
  kServicesResolvedBit = 1u << 3,
  kNameBit = 1u << 4,
  kTrustedBit = 1u << 5,
  kBlockedBit = 1u << 6,
  kAliasBit = 1u << 7,
};

// Which characteristic properties a 0x03 update carries.
//
// BlueZ emits PropertiesChanged for Notifying and MTU as well as Value, but
// only Value was ever forwarded -- so BlueZGattCharacteristic.notifying stayed
// frozen at its discovery-time value (false) even while notifications were
// demonstrably flowing. Consumers checking that getter were silently misled.
//
// For full snapshots (discovery), changedMask == ~0u.
enum GattCharChangedBit : uint32_t {
  kCharValueBit = 1u << 0,
  kCharNotifyingBit = 1u << 1,
  kCharMTUBit = 1u << 2,
};

// ── Device properties ───────────────────────────────────────────────────────

struct BlueZDeviceProps {
  std::string objectPath;
  uint32_t changedMask{};  // Bitmask of DeviceChangedBit values.
  std::string adapterPath;
  std::string address;
  std::string addressType;  // "public" | "random"
  std::string name;
  std::string alias;
  int16_t rssi{};
  int16_t txPower{};
  uint16_t appearance{};
  uint32_t deviceClass{};
  bool paired{};
  bool trusted{};
  bool blocked{};
  bool connected{};
  bool servicesResolved{};
  bool legacyPairing{};
  std::vector<std::string> uuids;
  std::vector<ManufacturerDataEntry> manufacturerData;
  // ServiceData: uuid → bytes
  std::map<std::string, std::vector<uint8_t>> serviceData;
};
template <>
struct glz::meta<BlueZDeviceProps> {
  static constexpr auto fields = std::make_tuple(
      glz::field("objectPath", &BlueZDeviceProps::objectPath),
      glz::field("changedMask", &BlueZDeviceProps::changedMask),
      glz::field("adapterPath", &BlueZDeviceProps::adapterPath),
      glz::field("address", &BlueZDeviceProps::address),
      glz::field("addressType", &BlueZDeviceProps::addressType),
      glz::field("name", &BlueZDeviceProps::name),
      glz::field("alias", &BlueZDeviceProps::alias),
      glz::field("rssi", &BlueZDeviceProps::rssi),
      glz::field("txPower", &BlueZDeviceProps::txPower),
      glz::field("appearance", &BlueZDeviceProps::appearance),
      glz::field("deviceClass", &BlueZDeviceProps::deviceClass),
      glz::field("paired", &BlueZDeviceProps::paired),
      glz::field("trusted", &BlueZDeviceProps::trusted),
      glz::field("blocked", &BlueZDeviceProps::blocked),
      glz::field("connected", &BlueZDeviceProps::connected),
      glz::field("servicesResolved", &BlueZDeviceProps::servicesResolved),
      glz::field("legacyPairing", &BlueZDeviceProps::legacyPairing),
      glz::field("uuids", &BlueZDeviceProps::uuids),
      glz::field("manufacturerData", &BlueZDeviceProps::manufacturerData),
      glz::field("serviceData", &BlueZDeviceProps::serviceData));
};

// ── GATT characteristic properties ──────────────────────────────────────────

struct BlueZGattCharProps {
  std::string objectPath;
  std::string servicePath;
  std::string uuid;
  std::vector<uint8_t> value;
  bool notifying{};
  bool writeAcquired{};
  bool notifyAcquired{};
  uint16_t handle{};
  uint16_t mtu{};
  std::vector<std::string> flags;
  // Bitmask of GattCharChangedBit. Appended last so the wire layout of the
  // preceding fields is unchanged; lib/src/ffi/codec.dart reads it last too.
  uint32_t changedMask{};
};
template <>
struct glz::meta<BlueZGattCharProps> {
  static constexpr auto fields = std::make_tuple(
      glz::field("objectPath", &BlueZGattCharProps::objectPath),
      glz::field("servicePath", &BlueZGattCharProps::servicePath),
      glz::field("uuid", &BlueZGattCharProps::uuid),
      glz::field("value", &BlueZGattCharProps::value),
      glz::field("notifying", &BlueZGattCharProps::notifying),
      glz::field("writeAcquired", &BlueZGattCharProps::writeAcquired),
      glz::field("notifyAcquired", &BlueZGattCharProps::notifyAcquired),
      glz::field("handle", &BlueZGattCharProps::handle),
      glz::field("mtu", &BlueZGattCharProps::mtu),
      glz::field("flags", &BlueZGattCharProps::flags),
      glz::field("changedMask", &BlueZGattCharProps::changedMask));
};

// ── GATT service properties ─────────────────────────────────────────────────

struct BlueZGattServiceProps {
  std::string objectPath;
  std::string devicePath;
  std::string uuid;
  bool primary{};
  uint16_t handle{};
};
template <>
struct glz::meta<BlueZGattServiceProps> {
  static constexpr auto fields = std::make_tuple(
      glz::field("objectPath", &BlueZGattServiceProps::objectPath),
      glz::field("devicePath", &BlueZGattServiceProps::devicePath),
      glz::field("uuid", &BlueZGattServiceProps::uuid),
      glz::field("primary", &BlueZGattServiceProps::primary),
      glz::field("handle", &BlueZGattServiceProps::handle));
};

// ── GATT descriptor properties ──────────────────────────────────────────────

struct BlueZGattDescProps {
  std::string objectPath;
  std::string charPath;
  std::string uuid;
  std::vector<uint8_t> value;
  uint16_t handle{};
};
template <>
struct glz::meta<BlueZGattDescProps> {
  static constexpr auto fields =
      std::make_tuple(glz::field("objectPath", &BlueZGattDescProps::objectPath),
                      glz::field("charPath", &BlueZGattDescProps::charPath),
                      glz::field("uuid", &BlueZGattDescProps::uuid),
                      glz::field("value", &BlueZGattDescProps::value),
                      glz::field("handle", &BlueZGattDescProps::handle));
};

// ── Value result (ReadValue / StartNotify notification) ─────────────────────

struct BlueZValueResult {
  std::string objectPath;  // characteristic or descriptor path
  std::vector<uint8_t> value;
};
template <>
struct glz::meta<BlueZValueResult> {
  static constexpr auto fields =
      std::make_tuple(glz::field("objectPath", &BlueZValueResult::objectPath),
                      glz::field("value", &BlueZValueResult::value));
};

// ── Error ───────────────────────────────────────────────────────────────────

struct BlueZError {
  std::string objectPath;  // which object triggered the error
  std::string name;        // D-Bus error name, e.g. org.bluez.Error.Failed
  std::string message;
};
template <>
struct glz::meta<BlueZError> {
  static constexpr auto fields =
      std::make_tuple(glz::field("objectPath", &BlueZError::objectPath),
                      glz::field("name", &BlueZError::name),
                      glz::field("message", &BlueZError::message));
};

// ── Agent request types ────────────────────────────────────────────────────

enum AgentRequestType : uint8_t {
  kRequestPinCode = 0,
  kDisplayPinCode = 1,
  kRequestPasskey = 2,
  kDisplayPasskey = 3,
  kRequestConfirmation = 4,
  kRequestAuthorization = 5,
  kAuthorizeService = 6,
  kAgentCancel = 7,
  kAgentRelease = 8,
};

// ── Agent request (0x30) ───────────────────────────────────────────────────

struct BlueZAgentRequest {
  uint64_t requestId{};
  uint8_t requestType{};
  std::string devicePath;
  uint32_t passkey{};
  uint16_t entered{};
  std::string pinCode;
  std::string uuid;
};
template <>
struct glz::meta<BlueZAgentRequest> {
  static constexpr auto fields = std::make_tuple(
      glz::field("requestId", &BlueZAgentRequest::requestId),
      glz::field("requestType", &BlueZAgentRequest::requestType),
      glz::field("devicePath", &BlueZAgentRequest::devicePath),
      glz::field("passkey", &BlueZAgentRequest::passkey),
      glz::field("entered", &BlueZAgentRequest::entered),
      glz::field("pinCode", &BlueZAgentRequest::pinCode),
      glz::field("uuid", &BlueZAgentRequest::uuid));
};
