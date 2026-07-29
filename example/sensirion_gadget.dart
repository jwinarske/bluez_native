// example/sensirion_gadget.dart
// Sensirion BLE Gadget protocol: advertisement decoding, history download,
// and gadget settings. Covers the SCD4x (SCD41) CO2 sensor and every other
// DataType the gadget firmware defines.
//
// The protocol is not published as a spec; the constants and byte layouts
// below were taken from Sensirion's own firmware, which is the authority:
//
//   arduino-ble-gadget: DataProvider.cpp, Download.cpp, AdvertisementHeader.cpp,
//                       IBLELibraryWrapper.h, NimBLELibraryWrapper.cpp
//   arduino-upt-core:   BLEProtocol.cpp (sample layouts + decode functions)
//
// All multi-byte fields are little-endian.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:bluez_native/bluez_native.dart';

// ---------------------------------------------------------------------------
// UUIDs
// ---------------------------------------------------------------------------

/// Bluetooth SIG company identifier for Sensirion AG.
const int kSensirionCompanyId = 0x06D5;

/// Sensirion advertisement type carried at byte 0 of the manufacturer data.
const int kSensirionAdvertisementType = 0x00;

/// History download service and its characteristics.
const String kDownloadServiceUuid = '00008000-b38d-4985-720e-0f993a68ee41';
const String kSampleHistoryIntervalUuid =
    '00008001-b38d-4985-720e-0f993a68ee41';
const String kNumberOfSamplesUuid = '00008002-b38d-4985-720e-0f993a68ee41';
const String kRequestedSamplesUuid = '00008003-b38d-4985-720e-0f993a68ee41';
const String kDownloadPacketUuid = '00008004-b38d-4985-720e-0f993a68ee41';

/// Settings service. The arduino firmware puts Wi-Fi credentials and the
/// alternative device name here; a production MyCO2 instead exposes LED
/// brightness. Which characteristics exist varies by build, so every accessor
/// for them reports absence rather than assuming.
const String kSettingsServiceUuid = '00008100-b38d-4985-720e-0f993a68ee41';
const String kLedBrightnessUuid = '00008101-b38d-4985-720e-0f993a68ee41';
const String kAltDeviceNameUuid = '00008120-b38d-4985-720e-0f993a68ee41';
const String kWifiSsidUuid = '00008171-b38d-4985-720e-0f993a68ee41';
const String kWifiPasswordUuid = '00008172-b38d-4985-720e-0f993a68ee41';

/// SCD4x service. The arduino firmware only implements the FRC request; a
/// production MyCO2 adds live CO2, the sensor feature set and its serial.
const String kScdServiceUuid = '00007000-b38d-4985-720e-0f993a68ee41';
const String kScdCo2Uuid = '00007001-b38d-4985-720e-0f993a68ee41';
const String kScdFeatureSetUuid = '00007002-b38d-4985-720e-0f993a68ee41';
const String kScdSerialUuid = '00007003-b38d-4985-720e-0f993a68ee41';
const String kScdFrcRequestUuid = '00007004-b38d-4985-720e-0f993a68ee41';

/// Legacy Smart Gadget live-value services, each a single float32 in degrees
/// Celsius / percent relative humidity. A MyCO2 keeps these for compatibility
/// and they are the connected path to live temperature and humidity.
const String kLegacyHumidityServiceUuid =
    '00001234-b38d-4985-720e-0f993a68ee41';
const String kLegacyHumidityUuid = '00001235-b38d-4985-720e-0f993a68ee41';
const String kLegacyTemperatureServiceUuid =
    '00002234-b38d-4985-720e-0f993a68ee41';
const String kLegacyTemperatureUuid = '00002235-b38d-4985-720e-0f993a68ee41';

/// Generic Access. Device Name is writable on a MyCO2, and is what the vendor
/// app renames.
const String kGapServiceUuid = '00001800-0000-1000-8000-00805f9b34fb';
const String kDeviceNameUuid = '00002a00-0000-1000-8000-00805f9b34fb';

/// Standard services the gadget also exposes.
const String kBatteryServiceUuid = '0000180f-0000-1000-8000-00805f9b34fb';
const String kBatteryLevelUuid = '00002a19-0000-1000-8000-00805f9b34fb';
const String kDeviceInfoServiceUuid = '0000180a-0000-1000-8000-00805f9b34fb';
const String kManufacturerNameUuid = '00002a29-0000-1000-8000-00805f9b34fb';
const String kModelNumberUuid = '00002a24-0000-1000-8000-00805f9b34fb';
const String kHardwareRevisionUuid = '00002a27-0000-1000-8000-00805f9b34fb';
const String kFirmwareRevisionUuid = '00002a26-0000-1000-8000-00805f9b34fb';

/// A download packet is always 20 bytes: a 2-byte sequence number followed by
/// 18 bytes of payload.
const int kDownloadPacketSizeBytes = 20;
const int kDownloadPacketHeaderBytes = 2;

// ---------------------------------------------------------------------------
// Signals
// ---------------------------------------------------------------------------

/// A physical quantity a gadget can report.
enum GadgetSignal {
  temperature('T', '°C'),
  humidity('RH', '%'),
  co2('CO2', 'ppm'),
  hcho('HCHO', 'ppb'),
  pm1p0('PM1.0', 'µg/m³'),
  pm2p5('PM2.5', 'µg/m³'),
  pm4p0('PM4.0', 'µg/m³'),
  pm10p0('PM10', 'µg/m³'),
  vocIndex('VOC', ''),
  noxIndex('NOx', ''),
  velocity('Velocity', 'm/s'),
  h2('H2', 'vol%'),
  pressure('Pressure', 'mbar');

  const GadgetSignal(this.label, this.unit);

  /// Short display label, e.g. `CO2`.
  final String label;

  /// Unit string, empty for unitless indices.
  final String unit;

  /// Sensible number of decimal places for display.
  int get precision => switch (this) {
    GadgetSignal.co2 ||
    GadgetSignal.vocIndex ||
    GadgetSignal.noxIndex ||
    GadgetSignal.pressure => 0,
    _ => 1,
  };

  /// Format [value] with unit, e.g. `812 ppm`.
  String format(double value) {
    final text = value.toStringAsFixed(precision);
    return unit.isEmpty ? text : '$text $unit';
  }
}

// ---------------------------------------------------------------------------
// Decoding functions (arduino-upt-core/src/BLEProtocol.cpp)
// ---------------------------------------------------------------------------

double _decodeSimple(int raw) => raw.toDouble();
double _decodeTemperatureV1(int raw) => -45.0 + (175.0 * raw) / 65535;
double _decodeHumidityV1(int raw) => (100.0 * raw) / 65535;
double _decodeHumidityV2(int raw) => (125.0 * raw) / 65535 - 6.0;
double _decodePm2p5V1(int raw) => (1000.0 * raw) / 65535;
double _decodePmV2(int raw) => raw / 10.0;
double _decodeHchoV1(int raw) => raw / 5.0;
double _decodeVelocityV1(int raw) => raw * 1024.0 / 65535.0;
double _decodeH2V1(int raw) => raw / 100.0;

// ---------------------------------------------------------------------------
// Sample layout
// ---------------------------------------------------------------------------

/// One signal's position within a sample and how to decode it.
class GadgetSampleSlot {
  const GadgetSampleSlot(this.signal, this.offset, this.decode);

  final GadgetSignal signal;

  /// Byte offset of the raw 16-bit value within the sample.
  final int offset;

  /// Converts the raw 16-bit value to a physical value.
  final double Function(int raw) decode;
}

/// The wire layout for one gadget DataType.
///
/// [sampleType] identifies the layout in advertisements; [downloadType]
/// identifies it in a history download header. They are distinct namespaces.
class GadgetSampleConfig {
  const GadgetSampleConfig({
    required this.name,
    required this.downloadType,
    required this.sampleType,
    required this.sampleSizeBytes,
    required this.sampleCountPerPacket,
    required this.slots,
  });

  /// Firmware DataType enum name, e.g. `T_RH_CO2`.
  final String name;
  final int downloadType;
  final int sampleType;
  final int sampleSizeBytes;

  /// Samples the firmware packs per download packet. Advisory only — the
  /// decoder derives the real count from each packet's actual length, which
  /// keeps it correct for the one upstream config whose declared value
  /// overflows a 20-byte packet.
  final int sampleCountPerPacket;

  final List<GadgetSampleSlot> slots;

  /// Signals this layout carries, in byte order.
  List<GadgetSignal> get signals => [for (final s in slots) s.signal];

  /// Decode one sample from [bytes] starting at [offset].
  ///
  /// Only slots that fit within [bytes] are decoded, so a truncated payload
  /// still yields the values it does carry. Real gadgets do this: a MyCO2
  /// advertises `T_RH_CO2_ALT` but omits the two trailing reserved bytes, so
  /// the advertisement is shorter than [sampleSizeBytes]. Returns an empty map
  /// only when no slot fits.
  Map<GadgetSignal, double> decodeSample(List<int> bytes, int offset) {
    final values = <GadgetSignal, double>{};
    for (final slot in slots) {
      final i = offset + slot.offset;
      if (i < 0 || i + 1 >= bytes.length) continue;
      final raw = bytes[i] | (bytes[i + 1] << 8);
      values[slot.signal] = slot.decode(raw);
    }
    return values;
  }

  @override
  String toString() =>
      'GadgetSampleConfig($name, sampleType: $sampleType, '
      'downloadType: $downloadType, ${sampleSizeBytes}B)';
}

/// Every DataType the gadget firmware defines.
///
/// Generated from `arduino-upt-core/src/BLEProtocol.cpp`.
const List<GadgetSampleConfig> kGadgetSampleConfigs = [
  GadgetSampleConfig(
    name: 'T_RH_V3',
    downloadType: 0,
    sampleType: 4,
    sampleSizeBytes: 4,
    sampleCountPerPacket: 4,
    slots: [
      GadgetSampleSlot(GadgetSignal.temperature, 0, _decodeTemperatureV1),
      GadgetSampleSlot(GadgetSignal.humidity, 2, _decodeHumidityV1),
    ],
  ),
  GadgetSampleConfig(
    name: 'T_RH_V4',
    downloadType: 5,
    sampleType: 6,
    sampleSizeBytes: 4,
    sampleCountPerPacket: 4,
    slots: [
      GadgetSampleSlot(GadgetSignal.temperature, 0, _decodeTemperatureV1),
      GadgetSampleSlot(GadgetSignal.humidity, 2, _decodeHumidityV2),
    ],
  ),
  GadgetSampleConfig(
    name: 'T_RH_VOC',
    downloadType: 1,
    sampleType: 3,
    sampleSizeBytes: 6,
    sampleCountPerPacket: 3,
    slots: [
      GadgetSampleSlot(GadgetSignal.temperature, 0, _decodeTemperatureV1),
      GadgetSampleSlot(GadgetSignal.humidity, 2, _decodeHumidityV1),
      GadgetSampleSlot(GadgetSignal.vocIndex, 4, _decodeSimple),
    ],
  ),
  // SCD4x / SCD41 with RHT — arduino-ble-gadget Example8.
  GadgetSampleConfig(
    name: 'T_RH_CO2',
    downloadType: 9,
    sampleType: 10,
    sampleSizeBytes: 6,
    sampleCountPerPacket: 3,
    slots: [
      GadgetSampleSlot(GadgetSignal.temperature, 0, _decodeTemperatureV1),
      GadgetSampleSlot(GadgetSignal.humidity, 2, _decodeHumidityV1),
      GadgetSampleSlot(GadgetSignal.co2, 4, _decodeSimple),
    ],
  ),
  // Same signals as T_RH_CO2 but 8-byte samples: 2 trailing reserved bytes.
  GadgetSampleConfig(
    name: 'T_RH_CO2_ALT',
    downloadType: 7,
    sampleType: 8,
    sampleSizeBytes: 8,
    sampleCountPerPacket: 2,
    slots: [
      GadgetSampleSlot(GadgetSignal.temperature, 0, _decodeTemperatureV1),
      GadgetSampleSlot(GadgetSignal.humidity, 2, _decodeHumidityV1),
      GadgetSampleSlot(GadgetSignal.co2, 4, _decodeSimple),
    ],
  ),
  GadgetSampleConfig(
    name: 'T_RH_CO2_PM25',
    downloadType: 11,
    sampleType: 12,
    sampleSizeBytes: 8,
    sampleCountPerPacket: 2,
    slots: [
      GadgetSampleSlot(GadgetSignal.temperature, 0, _decodeTemperatureV1),
      GadgetSampleSlot(GadgetSignal.humidity, 2, _decodeHumidityV1),
      GadgetSampleSlot(GadgetSignal.co2, 4, _decodeSimple),
      GadgetSampleSlot(GadgetSignal.pm2p5, 6, _decodePm2p5V1),
    ],
  ),
  GadgetSampleConfig(
    name: 'T_RH_VOC_PM25',
    downloadType: 15,
    sampleType: 16,
    sampleSizeBytes: 8,
    sampleCountPerPacket: 2,
    slots: [
      GadgetSampleSlot(GadgetSignal.temperature, 0, _decodeTemperatureV1),
      GadgetSampleSlot(GadgetSignal.humidity, 2, _decodeHumidityV1),
      GadgetSampleSlot(GadgetSignal.vocIndex, 4, _decodeSimple),
      GadgetSampleSlot(GadgetSignal.pm2p5, 6, _decodePm2p5V1),
    ],
  ),
  GadgetSampleConfig(
    name: 'T_RH_VOC_NOX',
    downloadType: 21,
    sampleType: 22,
    sampleSizeBytes: 8,
    sampleCountPerPacket: 2,
    slots: [
      GadgetSampleSlot(GadgetSignal.temperature, 0, _decodeTemperatureV1),
      GadgetSampleSlot(GadgetSignal.humidity, 2, _decodeHumidityV1),
      GadgetSampleSlot(GadgetSignal.vocIndex, 4, _decodeSimple),
      GadgetSampleSlot(GadgetSignal.noxIndex, 6, _decodeSimple),
    ],
  ),
  GadgetSampleConfig(
    name: 'T_RH_VOC_NOX_PM25',
    downloadType: 23,
    sampleType: 24,
    sampleSizeBytes: 10,
    sampleCountPerPacket: 1,
    slots: [
      GadgetSampleSlot(GadgetSignal.temperature, 0, _decodeTemperatureV1),
      GadgetSampleSlot(GadgetSignal.humidity, 2, _decodeHumidityV1),
      GadgetSampleSlot(GadgetSignal.vocIndex, 4, _decodeSimple),
      GadgetSampleSlot(GadgetSignal.noxIndex, 6, _decodeSimple),
      GadgetSampleSlot(GadgetSignal.pm2p5, 8, _decodePmV2),
    ],
  ),
  GadgetSampleConfig(
    name: 'T_RH_HCHO',
    downloadType: 13,
    sampleType: 14,
    sampleSizeBytes: 6,
    sampleCountPerPacket: 3,
    slots: [
      GadgetSampleSlot(GadgetSignal.temperature, 0, _decodeTemperatureV1),
      GadgetSampleSlot(GadgetSignal.humidity, 2, _decodeHumidityV1),
      GadgetSampleSlot(GadgetSignal.hcho, 4, _decodeHchoV1),
    ],
  ),
  GadgetSampleConfig(
    name: 'T_RH_CO2_VOC_PM25_HCHO',
    downloadType: 19,
    sampleType: 20,
    sampleSizeBytes: 12,
    sampleCountPerPacket: 1,
    slots: [
      GadgetSampleSlot(GadgetSignal.temperature, 0, _decodeTemperatureV1),
      GadgetSampleSlot(GadgetSignal.humidity, 2, _decodeHumidityV1),
      GadgetSampleSlot(GadgetSignal.co2, 4, _decodeSimple),
      GadgetSampleSlot(GadgetSignal.vocIndex, 6, _decodeSimple),
      GadgetSampleSlot(GadgetSignal.pm2p5, 8, _decodePm2p5V1),
      GadgetSampleSlot(GadgetSignal.hcho, 10, _decodeHchoV1),
    ],
  ),
  GadgetSampleConfig(
    name: 'T_RH_CO2_VOC_NOX_PM25',
    downloadType: 25,
    sampleType: 26,
    sampleSizeBytes: 12,
    sampleCountPerPacket: 1,
    slots: [
      GadgetSampleSlot(GadgetSignal.temperature, 0, _decodeTemperatureV1),
      GadgetSampleSlot(GadgetSignal.humidity, 2, _decodeHumidityV1),
      GadgetSampleSlot(GadgetSignal.co2, 4, _decodeSimple),
      GadgetSampleSlot(GadgetSignal.vocIndex, 6, _decodeSimple),
      GadgetSampleSlot(GadgetSignal.noxIndex, 8, _decodeSimple),
      GadgetSampleSlot(GadgetSignal.pm2p5, 10, _decodePmV2),
    ],
  ),
  GadgetSampleConfig(
    name: 'T_RH_CO2_PM25_V2',
    downloadType: 27,
    sampleType: 28,
    sampleSizeBytes: 8,
    sampleCountPerPacket: 2,
    slots: [
      GadgetSampleSlot(GadgetSignal.temperature, 0, _decodeTemperatureV1),
      GadgetSampleSlot(GadgetSignal.humidity, 2, _decodeHumidityV1),
      GadgetSampleSlot(GadgetSignal.co2, 4, _decodeSimple),
      GadgetSampleSlot(GadgetSignal.pm2p5, 6, _decodePmV2),
    ],
  ),
  GadgetSampleConfig(
    name: 'T_RH_VOC_PM25_V2',
    downloadType: 29,
    sampleType: 30,
    sampleSizeBytes: 8,
    sampleCountPerPacket: 2,
    slots: [
      GadgetSampleSlot(GadgetSignal.temperature, 0, _decodeTemperatureV1),
      GadgetSampleSlot(GadgetSignal.humidity, 2, _decodeHumidityV1),
      GadgetSampleSlot(GadgetSignal.vocIndex, 4, _decodeSimple),
      GadgetSampleSlot(GadgetSignal.pm2p5, 6, _decodePmV2),
    ],
  ),
  GadgetSampleConfig(
    name: 'T_RH_CO2_VOC_PM25_HCHO_V2',
    downloadType: 30,
    sampleType: 31,
    sampleSizeBytes: 12,
    sampleCountPerPacket: 1,
    slots: [
      GadgetSampleSlot(GadgetSignal.temperature, 0, _decodeTemperatureV1),
      GadgetSampleSlot(GadgetSignal.humidity, 2, _decodeHumidityV1),
      GadgetSampleSlot(GadgetSignal.co2, 4, _decodeSimple),
      GadgetSampleSlot(GadgetSignal.vocIndex, 6, _decodeSimple),
      GadgetSampleSlot(GadgetSignal.pm2p5, 8, _decodePmV2),
      GadgetSampleSlot(GadgetSignal.hcho, 10, _decodeHchoV1),
    ],
  ),
  GadgetSampleConfig(
    name: 'PM10_PM25_PM40_PM100',
    downloadType: 33,
    sampleType: 34,
    sampleSizeBytes: 8,
    sampleCountPerPacket: 1,
    slots: [
      GadgetSampleSlot(GadgetSignal.pm1p0, 0, _decodePmV2),
      GadgetSampleSlot(GadgetSignal.pm2p5, 2, _decodePmV2),
      GadgetSampleSlot(GadgetSignal.pm4p0, 4, _decodePmV2),
      GadgetSampleSlot(GadgetSignal.pm10p0, 6, _decodePmV2),
    ],
  ),
  GadgetSampleConfig(
    name: 'CO2_DataType',
    downloadType: 35,
    sampleType: 36,
    sampleSizeBytes: 2,
    sampleCountPerPacket: 1,
    slots: [GadgetSampleSlot(GadgetSignal.co2, 0, _decodeSimple)],
  ),
  GadgetSampleConfig(
    name: 'AV_T',
    downloadType: 37,
    sampleType: 38,
    sampleSizeBytes: 4,
    sampleCountPerPacket: 4,
    slots: [
      GadgetSampleSlot(GadgetSignal.velocity, 0, _decodeVelocityV1),
      GadgetSampleSlot(GadgetSignal.temperature, 2, _decodeTemperatureV1),
    ],
  ),
  GadgetSampleConfig(
    name: 'T_RH_H2_P',
    downloadType: 39,
    sampleType: 40,
    sampleSizeBytes: 8,
    sampleCountPerPacket: 2,
    slots: [
      GadgetSampleSlot(GadgetSignal.temperature, 0, _decodeTemperatureV1),
      GadgetSampleSlot(GadgetSignal.humidity, 2, _decodeHumidityV1),
      GadgetSampleSlot(GadgetSignal.h2, 4, _decodeH2V1),
      GadgetSampleSlot(GadgetSignal.pressure, 6, _decodeSimple),
    ],
  ),
  GadgetSampleConfig(
    name: 'T_RH_PM25',
    downloadType: 41,
    sampleType: 42,
    sampleSizeBytes: 6,
    sampleCountPerPacket: 2,
    slots: [
      GadgetSampleSlot(GadgetSignal.temperature, 0, _decodeTemperatureV1),
      GadgetSampleSlot(GadgetSignal.humidity, 2, _decodeHumidityV1),
      GadgetSampleSlot(GadgetSignal.pm2p5, 4, _decodePm2p5V1),
    ],
  ),
  GadgetSampleConfig(
    name: 'T_RH_HCHO_VOC_NOX_PM25',
    downloadType: 43,
    sampleType: 44,
    sampleSizeBytes: 12,
    sampleCountPerPacket: 2,
    slots: [
      GadgetSampleSlot(GadgetSignal.temperature, 0, _decodeTemperatureV1),
      GadgetSampleSlot(GadgetSignal.humidity, 2, _decodeHumidityV1),
      GadgetSampleSlot(GadgetSignal.hcho, 4, _decodeHchoV1),
      GadgetSampleSlot(GadgetSignal.vocIndex, 6, _decodeSimple),
      GadgetSampleSlot(GadgetSignal.noxIndex, 8, _decodeSimple),
      GadgetSampleSlot(GadgetSignal.pm2p5, 10, _decodePm2p5V1),
    ],
  ),
];

/// The SCD4x layout used by Example8 (temperature, humidity, CO2).
final GadgetSampleConfig kScd4xSampleConfig = configForSampleType(10)!;

/// Look up a layout by advertisement sample type.
GadgetSampleConfig? configForSampleType(int sampleType) {
  for (final c in kGadgetSampleConfigs) {
    if (c.sampleType == sampleType) return c;
  }
  return null;
}

/// Look up a layout by download header sample type.
GadgetSampleConfig? configForDownloadType(int downloadType) {
  for (final c in kGadgetSampleConfigs) {
    if (c.downloadType == downloadType) return c;
  }
  return null;
}

// ---------------------------------------------------------------------------
// Advertisements
// ---------------------------------------------------------------------------

/// Live values broadcast in a gadget's manufacturer-specific advertisement
/// data. No connection is required to read these.
///
/// BlueZ strips the 2-byte company identifier into the map key, so the bytes
/// handed to [parse] start at the Sensirion advertisement type:
///
/// ```text
/// byte  0     advertisement type (0x00)
/// byte  1     sample type -> GadgetSampleConfig
/// bytes 2..3  device id (high, low) — last two bytes of the MAC
/// bytes 4..   current sample, laid out per the sample config
/// ```
class GadgetAdvertisement {
  const GadgetAdvertisement({
    required this.advertisementType,
    required this.sampleType,
    required this.deviceId,
    required this.config,
    required this.values,
  });

  final int advertisementType;
  final int sampleType;

  /// 16-bit device id built from the last two bytes of the gadget's MAC.
  final int deviceId;

  /// Layout for [sampleType], or `null` if this build doesn't know it.
  final GadgetSampleConfig? config;

  /// Decoded live values, empty when [config] is `null`.
  final Map<GadgetSignal, double> values;

  /// Device id as the firmware's `getDeviceIdString()` renders it, e.g. `A4:F2`.
  String get deviceIdString {
    final hi = (deviceId >> 8) & 0xFF;
    final lo = deviceId & 0xFF;
    return '${_hex2(hi)}:${_hex2(lo)}';
  }

  static String _hex2(int v) =>
      v.toRadixString(16).toUpperCase().padLeft(2, '0');

  /// Decode Sensirion manufacturer data, or `null` if it isn't a gadget
  /// advertisement.
  static GadgetAdvertisement? parse(List<int> data) {
    // Need advertisement type, sample type and the device id at minimum.
    if (data.length < 4) return null;
    if (data[0] != kSensirionAdvertisementType) return null;

    final sampleType = data[1];
    final config = configForSampleType(sampleType);
    return GadgetAdvertisement(
      advertisementType: data[0],
      sampleType: sampleType,
      deviceId: (data[2] << 8) | data[3],
      config: config,
      values: config?.decodeSample(data, 4) ?? const {},
    );
  }

  /// Decode the first Sensirion advertisement present on [device], if any.
  static GadgetAdvertisement? fromDevice(BlueZDevice device) {
    for (final md in device.manufacturerData) {
      if (md.companyId != kSensirionCompanyId) continue;
      final adv = parse(md.data);
      if (adv != null) return adv;
    }
    return null;
  }

  @override
  String toString() {
    final name = config?.name ?? 'unknown(sampleType $sampleType)';
    final rendered = values.entries
        .map((e) => '${e.key.label} ${e.key.format(e.value)}')
        .join('  ');
    return '[$deviceIdString] $name  $rendered';
  }
}

// ---------------------------------------------------------------------------
// History download
// ---------------------------------------------------------------------------

/// One logged sample with its reconstructed wall-clock timestamp.
class GadgetHistorySample {
  const GadgetHistorySample(this.timestamp, this.values);

  /// Reconstructed timestamp. The gadget has no real-time clock, so this is
  /// derived from the host clock and the age reported in the download header.
  final DateTime timestamp;

  final Map<GadgetSignal, double> values;

  @override
  String toString() {
    final rendered = values.entries
        .map((e) => '${e.key.label}=${e.key.format(e.value)}')
        .join('  ');
    return '${timestamp.toIso8601String()}  $rendered';
  }
}

/// Header of a history download, sent as the packet with sequence number 0.
///
/// ```text
/// bytes 0..1   sequence number (0)
/// bytes 2..3   unused
/// bytes 4..5   download sample type -> GadgetSampleConfig
/// bytes 6..9   logging interval in milliseconds
/// bytes 10..13 age of the newest sample in milliseconds
/// bytes 14..15 number of samples that will follow
/// ```
class GadgetDownloadHeader {
  const GadgetDownloadHeader({
    required this.downloadType,
    required this.config,
    required this.interval,
    required this.ageOfNewestSample,
    required this.sampleCount,
  });

  final int downloadType;
  final GadgetSampleConfig? config;
  final Duration interval;
  final Duration ageOfNewestSample;
  final int sampleCount;

  static GadgetDownloadHeader? parse(List<int> d) {
    if (d.length < 16) return null;
    final downloadType = d[4] | (d[5] << 8);
    return GadgetDownloadHeader(
      downloadType: downloadType,
      config: configForDownloadType(downloadType),
      interval: Duration(milliseconds: _u32(d, 6)),
      ageOfNewestSample: Duration(milliseconds: _u32(d, 10)),
      sampleCount: d[14] | (d[15] << 8),
    );
  }

  @override
  String toString() =>
      'GadgetDownloadHeader(${config?.name ?? 'unknown($downloadType)'}, '
      '$sampleCount samples, interval ${interval.inSeconds}s, '
      'newest ${ageOfNewestSample.inSeconds}s old)';
}

/// A completed history download.
class GadgetHistory {
  const GadgetHistory(this.header, this.samples);

  final GadgetDownloadHeader header;

  /// Samples oldest-first, matching the gadget's readout order.
  final List<GadgetHistorySample> samples;

  /// Signals present in this history.
  List<GadgetSignal> get signals => header.config?.signals ?? const [];

  /// Render as CSV with an ISO-8601 timestamp column plus one column per
  /// signal.
  String toCsv() {
    final cols = signals;
    final out = StringBuffer()
      ..writeln(
        [
          'timestamp',
          for (final s in cols)
            s.unit.isEmpty ? s.label : '${s.label} (${s.unit})',
        ].join(','),
      );
    for (final sample in samples) {
      out.writeln(
        [
          sample.timestamp.toIso8601String(),
          for (final s in cols)
            sample.values[s]?.toStringAsFixed(s.precision) ?? '',
        ].join(','),
      );
    }
    return out.toString();
  }
}

/// Decode a little-endian IEEE-754 float32, the form the legacy Smart Gadget
/// temperature and humidity characteristics carry. Returns NaN if [bytes] is
/// too short.
double decodeLegacyFloat32(List<int> bytes) {
  if (bytes.length < 4) return double.nan;
  final b = ByteData(4);
  for (var i = 0; i < 4; i++) {
    b.setUint8(i, bytes[i]);
  }
  return b.getFloat32(0, Endian.little);
}

int _u32(List<int> d, int i) =>
    d[i] | (d[i + 1] << 8) | (d[i + 2] << 16) | (d[i + 3] << 24);

Uint8List _u32le(int value) =>
    Uint8List(4)..buffer.asByteData().setUint32(0, value, Endian.little);

/// Decodes an integer characteristic value. The firmware writes these with
/// NimBLE's `setValue(int)`, which emits 4 little-endian bytes, but accept any
/// width up to 8 bytes so this also works against other gadget builds.
int _decodeUintLe(List<int> bytes) {
  var value = 0;
  for (var i = bytes.length - 1; i >= 0; i--) {
    value = (value << 8) | (bytes[i] & 0xFF);
  }
  return value;
}

// ---------------------------------------------------------------------------
// Gadget client
// ---------------------------------------------------------------------------

/// Thrown when a gadget does not expose an expected characteristic.
class GadgetProtocolException implements Exception {
  GadgetProtocolException(this.message);
  final String message;
  @override
  String toString() => 'GadgetProtocolException: $message';
}

/// Connected-mode access to a Sensirion gadget: history download, logging
/// interval, device name, battery, and SCD4x forced recalibration.
///
/// The device must already be connected with services resolved.
class SensirionGadget {
  SensirionGadget(this.device);

  final BlueZDevice device;

  BlueZGattCharacteristic? _char(String uuid) {
    final target = BlueZUUID(uuid);
    for (final c in device.gattCharacteristics) {
      if (c.uuid == target) return c;
    }
    return null;
  }

  BlueZGattCharacteristic _require(String uuid, String what) {
    final c = _char(uuid);
    if (c == null) {
      throw GadgetProtocolException('$what characteristic ($uuid) not found');
    }
    return c;
  }

  /// Whether this device exposes the gadget download service.
  bool get hasDownloadService => _char(kDownloadPacketUuid) != null;

  /// Whether this device exposes the SCD4x forced-recalibration service.
  bool get hasFrcService => _char(kScdFrcRequestUuid) != null;

  /// Number of samples currently held in the gadget's ring buffer.
  Future<int> readSampleCount() async => _decodeUintLe(
    await _require(kNumberOfSamplesUuid, 'sample count').readValue(),
  );

  /// Interval at which the gadget commits samples to its history.
  Future<Duration> readLoggingInterval() async => Duration(
    milliseconds: _decodeUintLe(
      await _require(
        kSampleHistoryIntervalUuid,
        'logging interval',
      ).readValue(),
    ),
  );

  /// Set the logging interval.
  ///
  /// This **erases the gadget's stored history** — the firmware resets its
  /// ring buffer whenever the interval changes.
  Future<void> writeLoggingInterval(Duration interval) async {
    final ms = interval.inMilliseconds;
    if (ms <= 0) {
      throw ArgumentError.value(ms, 'interval', 'must be positive');
    }
    await _require(
      kSampleHistoryIntervalUuid,
      'logging interval',
    ).writeValue(_u32le(ms));
  }

  /// Battery level in percent, or `null` if the gadget has no battery service.
  Future<int?> readBatteryLevel() async {
    final c = _char(kBatteryLevelUuid);
    if (c == null) return null;
    final v = await c.readValue();
    return v.isEmpty ? null : v[0];
  }

  /// Read a UTF-8 string characteristic, or `null` if absent.
  Future<String?> _readString(String uuid) async {
    final c = _char(uuid);
    if (c == null) return null;
    return utf8.decode(await c.readValue(), allowMalformed: true).trim();
  }

  /// Manufacturer name from the Device Information service, if present.
  ///
  /// This is characteristic 0x2A29. Note 0x2A26 is *Firmware Revision*, not
  /// the manufacturer — a MyCO2 reports `Sensirion AG` and `1.5` respectively.
  Future<String?> readManufacturerName() => _readString(kManufacturerNameUuid);

  /// Model number, e.g. `Sensirion MyCO2`.
  Future<String?> readModelNumber() => _readString(kModelNumberUuid);

  /// Hardware revision.
  Future<String?> readHardwareRevision() => _readString(kHardwareRevisionUuid);

  /// Firmware revision.
  Future<String?> readFirmwareRevision() => _readString(kFirmwareRevisionUuid);

  /// SCD4x sensor serial number, if the gadget exposes it.
  Future<String?> readScdSerial() async {
    final c = _char(kScdSerialUuid);
    if (c == null) return null;
    final v = await c.readValue();
    return v.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// SCD4x feature set word, if the gadget exposes it.
  Future<int?> readScdFeatureSet() async {
    final c = _char(kScdFeatureSetUuid);
    if (c == null) return null;
    return _decodeUintLe(await c.readValue());
  }

  /// The gadget's advertised name.
  ///
  /// Prefers the gadget's own alternative-name characteristic when present
  /// (arduino builds) and otherwise falls back to the standard GAP Device
  /// Name, which is what a MyCO2 uses.
  Future<String?> readDeviceName() async {
    final alt = _char(kAltDeviceNameUuid);
    if (alt != null) {
      return utf8.decode(await alt.readValue(), allowMalformed: true);
    }
    return _readString(kDeviceNameUuid);
  }

  /// Whether the gadget's name can be changed.
  bool get canRename =>
      _char(kAltDeviceNameUuid) != null ||
      (_char(
            kDeviceNameUuid,
          )?.flags.contains(BlueZGattCharacteristicFlag.write) ??
          false);

  /// Rename the gadget, via whichever characteristic this build exposes.
  Future<void> writeDeviceName(String name) async {
    final alt = _char(kAltDeviceNameUuid);
    if (alt != null) {
      await alt.writeValue(utf8.encode(name));
      return;
    }
    final gap = _char(kDeviceNameUuid);
    if (gap == null || !gap.flags.contains(BlueZGattCharacteristicFlag.write)) {
      throw GadgetProtocolException(
        'this gadget exposes no writable name characteristic',
      );
    }
    await gap.writeValue(utf8.encode(name));
  }

  /// LED brightness, or `null` if the gadget has no LED setting.
  ///
  /// Read-only here on purpose. The characteristic is declared writable and a
  /// MyCO2 accepts both a 1-byte and a 4-byte write without error, but the
  /// value reads back unchanged as `ff 00 00 00` either way, so the write has
  /// no observable effect and the encoding is unconfirmed. Rather than ship a
  /// setter that silently does nothing, this exposes only the reading.
  Future<int?> readLedBrightness() async {
    final c = _char(kLedBrightnessUuid);
    if (c == null) return null;
    return _decodeUintLe(await c.readValue());
  }

  /// Set Wi-Fi credentials on gadgets built with the Wi-Fi settings service.
  Future<void> writeWifiCredentials(String ssid, String password) async {
    await _require(kWifiSsidUuid, 'Wi-Fi SSID').writeValue(utf8.encode(ssid));
    await _require(
      kWifiPasswordUuid,
      'Wi-Fi password',
    ).writeValue(utf8.encode(password));
  }

  /// Which signals this gadget can stream while connected.
  List<GadgetSignal> get liveSignals => [
    for (final entry in _liveChars.entries)
      if (_char(entry.key) != null) entry.value.$1,
  ];

  /// Connected live-value characteristics: uuid -> (signal, decoder).
  static final Map<String, (GadgetSignal, double Function(List<int>))>
  _liveChars = {
    kLegacyTemperatureUuid: (GadgetSignal.temperature, decodeLegacyFloat32),
    kLegacyHumidityUuid: (GadgetSignal.humidity, decodeLegacyFloat32),
    kScdCo2Uuid: (GadgetSignal.co2, (bytes) => _decodeUintLe(bytes).toDouble()),
  };

  /// Subscribe to the gadget's live-value characteristics and emit each
  /// reading as it arrives.
  ///
  /// This is the connected path to live data, distinct from the advertisement
  /// path — it updates faster and does not depend on catching broadcasts.
  /// Temperature and humidity come from the legacy Smart Gadget
  /// characteristics as float32; CO2 comes from the SCD4x service as a 16-bit
  /// ppm value. Cancelling the returned stream's subscription unsubscribes.
  Stream<(GadgetSignal, double)> liveValues() {
    final controller = StreamController<(GadgetSignal, double)>();
    final subs = <StreamSubscription<List<int>>>[];
    final started = <BlueZGattCharacteristic>[];

    controller.onListen = () async {
      try {
        for (final entry in _liveChars.entries) {
          final char = _char(entry.key);
          if (char == null) continue;
          if (!char.flags.contains(BlueZGattCharacteristicFlag.notify)) {
            continue;
          }
          final (signal, decode) = entry.value;
          subs.add(
            char.value.listen((bytes) {
              if (bytes.isEmpty) return;
              controller.add((signal, decode(bytes)));
            }),
          );
          await char.startNotify();
          started.add(char);
        }
        if (started.isEmpty) {
          controller.addError(
            GadgetProtocolException(
              'this gadget exposes no live-value characteristics',
            ),
          );
          await controller.close();
        }
      } on Object catch (e, st) {
        controller.addError(e, st);
        await controller.close();
      }
    };

    controller.onCancel = () async {
      for (final s in subs) {
        await s.cancel();
      }
      for (final c in started) {
        if (c.notifying) await c.stopNotify();
      }
    };

    return controller.stream;
  }

  /// Request an SCD4x forced recalibration against a known ambient CO2
  /// concentration in ppm (outdoor air is ~400-420 ppm).
  ///
  /// The reference level goes in the low two bytes; the firmware ignores the
  /// leading two bytes, which exist only as obfuscation.
  Future<void> requestForcedRecalibration(int referenceCo2Ppm) async {
    if (referenceCo2Ppm < 0 || referenceCo2Ppm > 0xFFFF) {
      throw ArgumentError.value(
        referenceCo2Ppm,
        'referenceCo2Ppm',
        'must fit in 16 bits',
      );
    }
    await _require(kScdFrcRequestUuid, 'SCD4x FRC request').writeValue([
      0x00,
      0x00,
      referenceCo2Ppm & 0xFF,
      (referenceCo2Ppm >> 8) & 0xFF,
    ]);
  }

  /// Write the sample limit, tolerating gadgets that declare a narrower
  /// characteristic.
  ///
  /// The arduino firmware reads this as a 32-bit little-endian value, but a
  /// production MyCO2 rejects a 4-byte write with `Invalid Length`, so fall
  /// back to 16-bit. The low bytes carry the count either way.
  Future<void> _writeRequestedSamples(int count) async {
    final char = _require(kRequestedSamplesUuid, 'requested samples');
    try {
      await char.writeValue(_u32le(count));
      return;
    } on BlueZOperationException {
      if (count > 0xFFFF) rethrow;
    }
    await char.writeValue([count & 0xFF, (count >> 8) & 0xFF]);
  }

  /// Download logged samples from the gadget.
  ///
  /// Set [maxSamples] to limit the download; 0 (the default) fetches
  /// everything in the ring buffer. Note the firmware only honors a limit
  /// that is strictly less than the number of stored samples.
  ///
  /// The download is driven by subscribing to the download packet
  /// characteristic — that subscription *is* the request, so the sample limit
  /// must be written first. [onProgress] reports `(received, total)` as
  /// packets arrive. [idleTimeout] bounds the wait for each packet; the
  /// gadget pushes them from its main loop, so a stalled or disconnected
  /// gadget surfaces as a [TimeoutException] rather than hanging.
  Future<GadgetHistory> downloadHistory({
    int maxSamples = 0,
    void Function(int received, int total)? onProgress,
    Duration idleTimeout = const Duration(seconds: 15),
  }) async {
    final packetChar = _require(kDownloadPacketUuid, 'download packet');

    // Announce the limit before subscribing: subscribing starts the transfer.
    // A limit of 0 is already the gadget's default ("send everything"), so
    // skip the write entirely — not every gadget accepts one.
    if (maxSamples > 0) {
      await _writeRequestedSamples(maxSamples);
    }

    // A stale subscription would not re-trigger the gadget's download request,
    // so always start from an unsubscribed state.
    if (packetChar.notifying) {
      await packetChar.stopNotify();
    }

    final packets = StreamQueue<List<int>>(packetChar.value);
    await packetChar.startNotify();

    try {
      // The header is the packet with sequence number 0. Subscribing can
      // surface a cached value left over from an earlier transfer, so skip
      // anything that is not a header rather than mis-parsing it as one.
      GadgetDownloadHeader? header;
      for (var skipped = 0; skipped < 4 && header == null; skipped++) {
        final bytes = await packets.next.timeout(idleTimeout);
        if (bytes.length < 16) continue;
        final sequence = bytes[0] | (bytes[1] << 8);
        if (sequence != 0) continue;
        header = GadgetDownloadHeader.parse(bytes);
      }
      if (header == null) {
        throw GadgetProtocolException(
          'no download header received; the gadget may not have started the '
          'transfer',
        );
      }
      final config = header.config;
      if (config == null) {
        throw GadgetProtocolException(
          'unknown download sample type ${header.downloadType}',
        );
      }

      // The gadget has no clock, so anchor the series on the host clock using
      // the age of the newest sample as reported at download start.
      final newest = DateTime.now().subtract(header.ageOfNewestSample);

      final raw = <Map<GadgetSignal, double>>[];
      onProgress?.call(0, header.sampleCount);

      while (raw.length < header.sampleCount) {
        final packet = await packets.next.timeout(idleTimeout);
        // Derive the per-packet sample count from the payload actually
        // received rather than the declared sampleCountPerPacket, which
        // overflows a 20-byte packet for one upstream config.
        final payload = packet.length - kDownloadPacketHeaderBytes;
        if (payload < config.sampleSizeBytes) continue;
        final perPacket = payload ~/ config.sampleSizeBytes;

        for (var i = 0; i < perPacket && raw.length < header.sampleCount; i++) {
          final values = config.decodeSample(
            packet,
            kDownloadPacketHeaderBytes + i * config.sampleSizeBytes,
          );
          if (values.isEmpty) break;
          raw.add(values);
        }
        onProgress?.call(raw.length, header.sampleCount);
      }

      // Readout is oldest-first, so the last sample is the newest.
      final intervalMs = header.interval.inMilliseconds;
      final samples = <GadgetHistorySample>[];
      for (var i = 0; i < raw.length; i++) {
        final stepsBack = raw.length - 1 - i;
        samples.add(
          GadgetHistorySample(
            newest.subtract(Duration(milliseconds: stepsBack * intervalMs)),
            raw[i],
          ),
        );
      }

      return GadgetHistory(header, samples);
    } finally {
      await packets.cancel();
      if (packetChar.notifying) {
        await packetChar.stopNotify();
      }
    }
  }
}

/// Minimal pull-based adapter over a broadcast-free stream, so the download
/// loop can await packets one at a time without racing the subscription.
class StreamQueue<T> {
  StreamQueue(Stream<T> source) {
    _sub = source.listen(
      (event) {
        if (_waiting.isNotEmpty) {
          _waiting.removeAt(0).complete(event);
        } else {
          _buffered.add(event);
        }
      },
      onError: (Object e, StackTrace st) {
        if (_waiting.isNotEmpty) _waiting.removeAt(0).completeError(e, st);
      },
      onDone: () {
        _done = true;
        for (final c in _waiting) {
          c.completeError(StateError('stream closed before next event'));
        }
        _waiting.clear();
      },
    );
  }

  late final StreamSubscription<T> _sub;
  final List<T> _buffered = [];
  final List<Completer<T>> _waiting = [];
  bool _done = false;

  /// The next event, buffering events that arrive before they are awaited.
  Future<T> get next {
    if (_buffered.isNotEmpty) return Future.value(_buffered.removeAt(0));
    if (_done) return Future.error(StateError('stream closed'));
    final c = Completer<T>();
    _waiting.add(c);
    return c.future;
  }

  Future<void> cancel() => _sub.cancel();
}
