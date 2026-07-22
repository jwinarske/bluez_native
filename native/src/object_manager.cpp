// object_manager.cpp — BlueZ ObjectManager proxy implementation.

#include "object_manager.h"

#include <cstdint>

// ── Constructor / Destructor ────────────────────────────────────────────────

ObjectManager::ObjectManager(sdbus::IConnection& conn, Dart_Port_DL events_port)
    : conn_(conn), events_port_(events_port) {
  root_proxy_ = sdbus::createProxy(conn_, sdbus::ServiceName{kBluezService},
                                   sdbus::ObjectPath{"/"});

  root_proxy_->uponSignal("InterfacesAdded")
      .onInterface(kObjectManagerIface)
      .call([this](const sdbus::ObjectPath& object,
                   const InterfacesMap& interfaces) {
        on_interfaces_added(object, interfaces);
      });

  root_proxy_->uponSignal("InterfacesRemoved")
      .onInterface(kObjectManagerIface)
      .call([this](const sdbus::ObjectPath& object,
                   const std::vector<std::string>& interfaces) {
        on_interfaces_removed(object, interfaces);
      });
}

ObjectManager::~ObjectManager() {
  std::scoped_lock lock(proxies_mutex_);
  notify_proxies_.clear();
  device_proxies_.clear();
  adapter_proxies_.clear();
}

// ── GetManagedObjects ───────────────────────────────────────────────────────

void ObjectManager::get_managed_objects() {
  std::map<sdbus::ObjectPath,
           std::map<std::string, std::map<std::string, sdbus::Variant>>>
      objects;
  root_proxy_->callMethod("GetManagedObjects")
      .onInterface(kObjectManagerIface)
      .storeResultsTo(objects);

  for (const auto& [object_path, interfaces] : objects) {
    on_interfaces_added(object_path, interfaces);
  }
}

// ── InterfacesAdded handler ─────────────────────────────────────────────────

void ObjectManager::on_interfaces_added(const sdbus::ObjectPath& object_path,
                                        const InterfacesMap& interfaces) {
  for (const auto& [iface, props] : interfaces) {
    if (iface == kAdapterIface) {
      auto adapter = extract_adapter_props(object_path, props);
      post_glaze(0x01, adapter);
      subscribe_adapter_props(object_path);
    } else if (iface == kDeviceIface) {
      auto device = extract_device_props(object_path, props);
      post_glaze(0x04, device);
      subscribe_device_props(object_path);
    } else if (iface == kGattServiceIface) {
      auto service = extract_service_props(object_path, props);
      post_glaze(0x06, service);
    } else if (iface == kGattCharIface) {
      auto char_props = extract_char_props(object_path, props);
      post_glaze(0x07, char_props);
    } else if (iface == kGattDescIface) {
      auto desc = extract_desc_props(object_path, props);
      post_glaze(0x08, desc);
    }
  }
}

// ── InterfacesRemoved handler ───────────────────────────────────────────────

void ObjectManager::on_interfaces_removed(
    const sdbus::ObjectPath& object_path,
    const std::vector<std::string>& interfaces) {
  for (const auto& iface : interfaces) {
    if (iface == kDeviceIface) {
      // Post device removed with minimal info.
      BlueZDeviceProps dp;
      dp.objectPath = object_path;
      post_glaze(0x05, dp);

      // Clean up PropertiesChanged subscription.
      std::scoped_lock lock(proxies_mutex_);
      device_proxies_.erase(object_path);
    } else if (iface == kAdapterIface) {
      std::scoped_lock lock(proxies_mutex_);
      adapter_proxies_.erase(object_path);
    } else if (iface == kGattCharIface) {
      std::scoped_lock lock(proxies_mutex_);
      notify_proxies_.erase(object_path);
    } else if (iface == kGattServiceIface || iface == kGattDescIface) {
      // Post generic object removed.
      BlueZGattServiceProps sp;
      sp.objectPath = object_path;
      post_glaze(0x09, sp);
    }
  }
}

// ── PropertiesChanged subscriptions ─────────────────────────────────────────

void ObjectManager::subscribe_char_notify(const std::string& char_path) {
  std::scoped_lock lock(proxies_mutex_);
  if (notify_proxies_.contains(char_path)) {
    return;  // Already subscribed.
  }

  auto proxy = sdbus::createProxy(conn_, sdbus::ServiceName{kBluezService},
                                  sdbus::ObjectPath{char_path});
  proxy->uponSignal("PropertiesChanged")
      .onInterface(kPropertiesIface)
      .call([this, char_path](
                const std::string& iface,
                const std::map<std::string, sdbus::Variant>& changed,
                const std::vector<std::string>& /*invalidated*/) {
        if (iface != kGattCharIface) {
          return;
        }
        // Forward Notifying and MTU alongside Value. Previously only Value
        // was relayed, so the Dart-side `notifying` getter never left its
        // discovery-time value -- it read false while notifications were
        // actively arriving.
        BlueZGattCharProps p;
        p.objectPath = char_path;

        // Variant::get<T> throws when the peer sends an unexpected type. This
        // runs on the D-Bus event loop thread, where an escaping exception
        // takes down the loop and with it every other subscription. Drop the
        // malformed update instead.
        try {
          if (auto it = changed.find("Value"); it != changed.end()) {
            p.value = it->second.get<std::vector<uint8_t>>();
            p.changedMask |= kCharValueBit;
          }
          if (auto it = changed.find("Notifying"); it != changed.end()) {
            p.notifying = it->second.get<bool>();
            p.changedMask |= kCharNotifyingBit;
          }
          if (auto it = changed.find("MTU"); it != changed.end()) {
            p.mtu = it->second.get<uint16_t>();
            p.changedMask |= kCharMTUBit;
          }
        } catch (const sdbus::Error&) {
          return;
        }

        // Nothing we track changed; stay off the hot path.
        if (p.changedMask == 0) {
          return;
        }
        post_glaze(0x03, p);
      });

  notify_proxies_[char_path] = std::move(proxy);
}

void ObjectManager::unsubscribe_char_notify(const std::string& char_path) {
  std::scoped_lock lock(proxies_mutex_);
  notify_proxies_.erase(char_path);
}

void ObjectManager::subscribe_device_props(const std::string& device_path) {
  std::scoped_lock lock(proxies_mutex_);
  if (device_proxies_.contains(device_path)) {
    return;
  }

  auto proxy = sdbus::createProxy(conn_, sdbus::ServiceName{kBluezService},
                                  sdbus::ObjectPath{device_path});
  proxy->uponSignal("PropertiesChanged")
      .onInterface(kPropertiesIface)
      .call([this, device_path](
                const std::string& iface,
                const std::map<std::string, sdbus::Variant>& changed,
                const std::vector<std::string>& /*invalidated*/) {
        if (iface != kDeviceIface) {
          return;
        }
        // Build a partial BlueZDeviceProps with only changed fields.
        // The Dart side merges this into its cached state using changedMask.
        BlueZDeviceProps dp;
        dp.objectPath = device_path;

        if (auto it = changed.find("Connected"); it != changed.end()) {
          dp.connected = it->second.get<bool>();
          dp.changedMask |= kConnectedBit;
        }
        if (auto it = changed.find("RSSI"); it != changed.end()) {
          dp.rssi = it->second.get<int16_t>();
          dp.changedMask |= kRSSIBit;
        }
        if (auto it = changed.find("Paired"); it != changed.end()) {
          dp.paired = it->second.get<bool>();
          dp.changedMask |= kPairedBit;
        }
        if (auto it = changed.find("Trusted"); it != changed.end()) {
          dp.trusted = it->second.get<bool>();
          dp.changedMask |= kTrustedBit;
        }
        if (auto it = changed.find("Blocked"); it != changed.end()) {
          dp.blocked = it->second.get<bool>();
          dp.changedMask |= kBlockedBit;
        }
        if (auto it = changed.find("ServicesResolved"); it != changed.end()) {
          dp.servicesResolved = it->second.get<bool>();
          dp.changedMask |= kServicesResolvedBit;
        }
        if (auto it = changed.find("Name"); it != changed.end()) {
          dp.name = it->second.get<std::string>();
          dp.changedMask |= kNameBit;
        }
        if (auto it = changed.find("Alias"); it != changed.end()) {
          dp.alias = it->second.get<std::string>();
          dp.changedMask |= kAliasBit;
        }

        post_glaze(0x02, dp);
      });

  device_proxies_[device_path] = std::move(proxy);
}

void ObjectManager::subscribe_adapter_props(const std::string& adapter_path) {
  std::scoped_lock lock(proxies_mutex_);
  if (adapter_proxies_.contains(adapter_path)) {
    return;
  }

  auto proxy = sdbus::createProxy(conn_, sdbus::ServiceName{kBluezService},
                                  sdbus::ObjectPath{adapter_path});
  proxy->uponSignal("PropertiesChanged")
      .onInterface(kPropertiesIface)
      .call([this, adapter_path](
                const std::string& iface,
                const std::map<std::string, sdbus::Variant>& changed,
                const std::vector<std::string>& /*invalidated*/) {
        if (iface != kAdapterIface) {
          return;
        }
        BlueZAdapterProps ap;
        ap.objectPath = adapter_path;

        if (auto it = changed.find("Powered"); it != changed.end()) {
          ap.powered = it->second.get<bool>();
          ap.changedMask |= kPoweredBit;
        }
        if (auto it = changed.find("Discovering"); it != changed.end()) {
          ap.discovering = it->second.get<bool>();
          ap.changedMask |= kDiscoveringBit;
        }
        if (auto it = changed.find("Discoverable"); it != changed.end()) {
          ap.discoverable = it->second.get<bool>();
          ap.changedMask |= kDiscoverableBit;
        }
        if (auto it = changed.find("Pairable"); it != changed.end()) {
          ap.pairable = it->second.get<bool>();
          ap.changedMask |= kPairableBit;
        }
        if (auto it = changed.find("Alias"); it != changed.end()) {
          ap.alias = it->second.get<std::string>();
          ap.changedMask |= kAdapterAliasBit;
        }

        post_glaze(0x01, ap);
      });

  adapter_proxies_[adapter_path] = std::move(proxy);
}

// ── Property extraction ─────────────────────────────────────────────────────

template <typename T>
T ObjectManager::get_prop(const PropertiesMap& props,
                          const std::string& key,
                          const T& fallback) {
  auto it = props.find(key);
  if (it == props.end()) {
    return fallback;
  }
  try {
    return it->second.get<T>();
  } catch (...) {
    return fallback;
  }
}

BlueZAdapterProps ObjectManager::extract_adapter_props(
    const std::string& object_path,
    const PropertiesMap& props) {
  BlueZAdapterProps a;
  a.objectPath = object_path;
  a.changedMask = ~0u;  // Full snapshot: all fields valid.
  a.address = get_prop<std::string>(props, "Address");
  a.name = get_prop<std::string>(props, "Name");
  a.alias = get_prop<std::string>(props, "Alias");
  a.powered = get_prop<bool>(props, "Powered");
  a.discoverable = get_prop<bool>(props, "Discoverable");
  a.pairable = get_prop<bool>(props, "Pairable");
  a.discovering = get_prop<bool>(props, "Discovering");
  a.discoverableTimeout = get_prop<uint32_t>(props, "DiscoverableTimeout");
  a.uuids = get_prop<std::vector<std::string>>(props, "UUIDs");
  return a;
}

BlueZDeviceProps ObjectManager::extract_device_props(
    const std::string& object_path,
    const PropertiesMap& props) {
  BlueZDeviceProps d;
  d.objectPath = object_path;
  d.changedMask = ~0u;  // Full snapshot: all fields valid.
  d.address = get_prop<std::string>(props, "Address");
  d.addressType = get_prop<std::string>(props, "AddressType");
  d.name = get_prop<std::string>(props, "Name");
  d.alias = get_prop<std::string>(props, "Alias");
  d.rssi = get_prop<int16_t>(props, "RSSI");
  d.txPower = get_prop<int16_t>(props, "TxPower");
  d.appearance = get_prop<uint16_t>(props, "Appearance");
  d.deviceClass = get_prop<uint32_t>(props, "Class");
  d.paired = get_prop<bool>(props, "Paired");
  d.trusted = get_prop<bool>(props, "Trusted");
  d.blocked = get_prop<bool>(props, "Blocked");
  d.connected = get_prop<bool>(props, "Connected");
  d.servicesResolved = get_prop<bool>(props, "ServicesResolved");
  d.legacyPairing = get_prop<bool>(props, "LegacyPairing");
  d.uuids = get_prop<std::vector<std::string>>(props, "UUIDs");

  // Adapter path: extract from object path (parent of dev_XX_XX...).
  // e.g. /org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF → /org/bluez/hci0
  d.adapterPath = get_prop<sdbus::ObjectPath>(props, "Adapter");

  // ManufacturerData: a{qv} where v is ay.
  if (auto it = props.find("ManufacturerData"); it != props.end()) {
    try {
      auto mfr_map = it->second.get<std::map<uint16_t, sdbus::Variant>>();
      for (const auto& [company_id, variant] : mfr_map) {
        ManufacturerDataEntry entry;
        entry.companyId = company_id;
        entry.data = variant.get<std::vector<uint8_t>>();
        d.manufacturerData.push_back(std::move(entry));
      }
    } catch (...) {
    }
  }

  // ServiceData: a{sv} where v is ay.
  if (auto it = props.find("ServiceData"); it != props.end()) {
    try {
      auto svc_map = it->second.get<std::map<std::string, sdbus::Variant>>();
      for (const auto& [uuid, variant] : svc_map) {
        d.serviceData[uuid] = variant.get<std::vector<uint8_t>>();
      }
    } catch (...) {
    }
  }

  return d;
}

BlueZGattServiceProps ObjectManager::extract_service_props(
    const std::string& object_path,
    const PropertiesMap& props) {
  BlueZGattServiceProps s;
  s.objectPath = object_path;
  s.uuid = get_prop<std::string>(props, "UUID");
  s.primary = get_prop<bool>(props, "Primary");
  s.devicePath = get_prop<sdbus::ObjectPath>(props, "Device");
  s.handle = get_prop<uint16_t>(props, "Handle");
  return s;
}

BlueZGattCharProps ObjectManager::extract_char_props(
    const std::string& object_path,
    const PropertiesMap& props) {
  BlueZGattCharProps c;
  c.objectPath = object_path;
  c.uuid = get_prop<std::string>(props, "UUID");
  c.servicePath = get_prop<sdbus::ObjectPath>(props, "Service");
  c.value = get_prop<std::vector<uint8_t>>(props, "Value");
  c.notifying = get_prop<bool>(props, "Notifying");
  c.writeAcquired = get_prop<bool>(props, "WriteAcquired");
  c.notifyAcquired = get_prop<bool>(props, "NotifyAcquired");
  c.handle = get_prop<uint16_t>(props, "Handle");
  c.mtu = get_prop<uint16_t>(props, "MTU");
  c.flags = get_prop<std::vector<std::string>>(props, "Flags");
  // Full snapshot: every field is authoritative.
  c.changedMask = ~0u;
  return c;
}

BlueZGattDescProps ObjectManager::extract_desc_props(
    const std::string& object_path,
    const PropertiesMap& props) {
  BlueZGattDescProps desc;
  desc.objectPath = object_path;
  desc.uuid = get_prop<std::string>(props, "UUID");
  desc.charPath = get_prop<sdbus::ObjectPath>(props, "Characteristic");
  desc.value = get_prop<std::vector<uint8_t>>(props, "Value");
  desc.handle = get_prop<uint16_t>(props, "Handle");
  return desc;
}

// ── Dart posting ────────────────────────────────────────────────────────────

template <typename T>
void ObjectManager::post_glaze(uint8_t discriminator, const T& value) {
  auto payload = glz::encode(value);

  std::vector<uint8_t> buf;
  buf.reserve(1 + payload.size());
  buf.push_back(discriminator);
  buf.insert(buf.end(), payload.begin(), payload.end());

  Dart_CObject obj;
  obj.type = Dart_CObject_kTypedData;
  obj.value.as_typed_data.type = Dart_TypedData_kUint8;
  obj.value.as_typed_data.length = static_cast<intptr_t>(buf.size());
  obj.value.as_typed_data.values = buf.data();
  Dart_PostCObject_DL(events_port_, &obj);
}

// Explicit template instantiations for all posted types.
template void ObjectManager::post_glaze(uint8_t, const BlueZAdapterProps&);
template void ObjectManager::post_glaze(uint8_t, const BlueZDeviceProps&);
template void ObjectManager::post_glaze(uint8_t, const BlueZGattCharProps&);
template void ObjectManager::post_glaze(uint8_t, const BlueZGattServiceProps&);
template void ObjectManager::post_glaze(uint8_t, const BlueZGattDescProps&);
