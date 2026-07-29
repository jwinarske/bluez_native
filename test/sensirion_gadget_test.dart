// Protocol tests for the Sensirion gadget example.
//
// Vectors are built with the *encoding* functions from Sensirion's firmware
// (arduino-upt-core/src/BLEProtocol.cpp) and decoded with the example's
// decoders, so a round trip catches any drift in offsets or scaling. The
// advertisement vector is a real capture from a MyCO2 (SCD41) gadget.

import 'package:test/test.dart';

import '../example/sensirion_gadget.dart';

// Encoding functions from arduino-upt-core/src/BLEProtocol.cpp.
int encodeTemperatureV1(double t) =>
    (((t + 45) * 65535) / 175).round().clamp(0, 65535);
int encodeHumidityV1(double rh) => ((rh * 65535) / 100).round().clamp(0, 65535);
int encodeHumidityV2(double rh) =>
    (((rh + 6) * 65535) / 125).round().clamp(0, 65535);
int encodePm2p5V1(double pm) => ((pm * 65535) / 1000).round().clamp(0, 65535);
int encodePmV2(double pm) => (pm * 10).round().clamp(0, 65535);
int encodeHchoV1(double v) => (v * 5).round().clamp(0, 65535);
int encodeSimple(double v) => v.round().clamp(0, 65535);

void _put16(List<int> buf, int offset, int value) {
  buf[offset] = value & 0xFF;
  buf[offset + 1] = (value >> 8) & 0xFF;
}

void _put32(List<int> buf, int offset, int value) {
  for (var i = 0; i < 4; i++) {
    buf[offset + i] = (value >> (8 * i)) & 0xFF;
  }
}

/// Build a download header packet as DataProvider::_buildDownloadHeader does.
List<int> buildHeader({
  required int downloadType,
  required int intervalMs,
  required int ageMs,
  required int count,
}) {
  final b = List<int>.filled(kDownloadPacketSizeBytes, 0);
  _put16(b, 4, downloadType);
  _put32(b, 6, intervalMs);
  _put32(b, 10, ageMs);
  _put16(b, 14, count);
  return b;
}

/// Build a download packet carrying [samples], each a list of raw 16-bit
/// values in slot order.
List<int> buildPacket(
  int sequence,
  GadgetSampleConfig config,
  List<List<int>> samples,
) {
  final b = List<int>.filled(kDownloadPacketSizeBytes, 0);
  _put16(b, 0, sequence);
  for (var s = 0; s < samples.length; s++) {
    final base = kDownloadPacketHeaderBytes + s * config.sampleSizeBytes;
    for (var i = 0; i < config.slots.length; i++) {
      _put16(b, base + config.slots[i].offset, samples[s][i]);
    }
  }
  return b;
}

void main() {
  group('sample config table', () {
    test('SCD4x layout matches the firmware', () {
      final c = kScd4xSampleConfig;
      expect(c.name, 'T_RH_CO2');
      expect(c.sampleType, 10);
      expect(c.downloadType, 9);
      expect(c.sampleSizeBytes, 6);
      expect(c.sampleCountPerPacket, 3);
      expect(c.signals, [
        GadgetSignal.temperature,
        GadgetSignal.humidity,
        GadgetSignal.co2,
      ]);
    });

    test('sample types and download types are each unique', () {
      final sampleTypes = kGadgetSampleConfigs
          .map((c) => c.sampleType)
          .toList();
      final downloadTypes = kGadgetSampleConfigs
          .map((c) => c.downloadType)
          .toList();
      expect(sampleTypes.toSet().length, sampleTypes.length);
      expect(downloadTypes.toSet().length, downloadTypes.length);
    });

    test('lookups resolve both namespaces independently', () {
      expect(configForSampleType(10)?.name, 'T_RH_CO2');
      expect(configForDownloadType(9)?.name, 'T_RH_CO2');
      // sampleType 8 and downloadType 8 are different layouts.
      expect(configForSampleType(8)?.name, 'T_RH_CO2_ALT');
      expect(configForDownloadType(8), isNull);
      expect(configForSampleType(999), isNull);
    });

    test('slots fit within the declared sample size', () {
      for (final c in kGadgetSampleConfigs) {
        for (final slot in c.slots) {
          expect(
            slot.offset + 2,
            lessThanOrEqualTo(c.sampleSizeBytes),
            reason: '${c.name}/${slot.signal.name} overruns the sample',
          );
        }
      }
    });
  });

  group('advertisement', () {
    test('decodes a real MyCO2 (SCD41) capture', () {
      // Captured from E6:63:16:BE:3E:14, company id 0x06d5.
      final adv = GadgetAdvertisement.parse([
        0x00, 0x08, 0x3e, 0x14, //
        0x72, 0x67, 0x59, 0x82, 0xd1, 0x04,
      ]);

      expect(adv, isNotNull);
      expect(adv!.config?.name, 'T_RH_CO2_ALT');
      expect(adv.deviceIdString, '3E:14');
      expect(adv.values[GadgetSignal.temperature], closeTo(25.71, 0.01));
      expect(adv.values[GadgetSignal.humidity], closeTo(50.92, 0.01));
      expect(adv.values[GadgetSignal.co2], closeTo(1233, 0.5));
    });

    test('decodes available slots when the payload is truncated', () {
      // T_RH_CO2_ALT declares 8-byte samples; the real device sends 6.
      final adv = GadgetAdvertisement.parse([
        0x00, 0x08, 0x3e, 0x14, //
        0x72, 0x67, 0x59, 0x82, 0xd1, 0x04,
      ])!;
      expect(adv.values.length, 3);

      // Drop CO2: temperature and humidity must still decode.
      final short = GadgetAdvertisement.parse([
        0x00, 0x08, 0x3e, 0x14, //
        0x72, 0x67, 0x59, 0x82,
      ])!;
      expect(short.values.keys, [
        GadgetSignal.temperature,
        GadgetSignal.humidity,
      ]);
    });

    test('rejects non-gadget manufacturer data', () {
      expect(GadgetAdvertisement.parse([]), isNull);
      expect(GadgetAdvertisement.parse([0x00, 0x08]), isNull);
      // Advertisement type must be 0x00.
      expect(GadgetAdvertisement.parse([0x01, 0x08, 0x3e, 0x14]), isNull);
    });

    test('unknown sample type yields no values but still parses', () {
      final adv = GadgetAdvertisement.parse([0x00, 0xfe, 0x12, 0x34, 0, 0])!;
      expect(adv.config, isNull);
      expect(adv.values, isEmpty);
      expect(adv.deviceIdString, '12:34');
    });
  });

  group('legacy live values', () {
    test('decodes captured MyCO2 float32 readings', () {
      // Real reads from E6:63:16:BE:3E:14: humidity 0x1235, temperature 0x2235.
      expect(
        decodeLegacyFloat32([0xda, 0x99, 0x29, 0x42]),
        closeTo(42.4, 0.05),
      );
      expect(
        decodeLegacyFloat32([0x7c, 0x74, 0xe4, 0x41]),
        closeTo(28.56, 0.05),
      );
    });

    test('returns NaN for a short payload', () {
      expect(decodeLegacyFloat32([0x00, 0x01]), isNaN);
      expect(decodeLegacyFloat32(const []), isNaN);
    });
  });

  group('download header', () {
    test('parses the firmware byte layout', () {
      final header = GadgetDownloadHeader.parse(
        buildHeader(
          downloadType: 9,
          intervalMs: 600000,
          ageMs: 12345,
          count: 42,
        ),
      );

      expect(header, isNotNull);
      expect(header!.config?.name, 'T_RH_CO2');
      expect(header.interval, const Duration(minutes: 10));
      expect(header.ageOfNewestSample, const Duration(milliseconds: 12345));
      expect(header.sampleCount, 42);
    });

    test('handles a 32-bit interval without sign error', () {
      final header = GadgetDownloadHeader.parse(
        buildHeader(
          downloadType: 9,
          intervalMs: 0xF0000000,
          ageMs: 0xFFFFFFFF,
          count: 1,
        ),
      )!;
      expect(header.interval.inMilliseconds, 0xF0000000);
      expect(header.ageOfNewestSample.inMilliseconds, 0xFFFFFFFF);
    });

    test('rejects a short header', () {
      expect(GadgetDownloadHeader.parse(List.filled(8, 0)), isNull);
    });
  });

  group('sample round trip', () {
    test('SCD4x values survive encode/decode', () {
      final config = kScd4xSampleConfig;
      const temperature = 21.5;
      const humidity = 44.25;
      const co2 = 812.0;

      final packet = buildPacket(1, config, [
        [
          encodeTemperatureV1(temperature),
          encodeHumidityV1(humidity),
          encodeSimple(co2),
        ],
      ]);

      final values = config.decodeSample(packet, kDownloadPacketHeaderBytes);
      expect(values[GadgetSignal.temperature], closeTo(temperature, 0.01));
      expect(values[GadgetSignal.humidity], closeTo(humidity, 0.01));
      expect(values[GadgetSignal.co2], closeTo(co2, 0.5));
    });

    test('every layout round-trips through its own encoders', () {
      // One representative value per signal, chosen inside each encoder's range.
      const inputs = <GadgetSignal, double>{
        GadgetSignal.temperature: 22.5,
        GadgetSignal.humidity: 48.0,
        GadgetSignal.co2: 615.0,
        GadgetSignal.hcho: 33.4,
        GadgetSignal.pm1p0: 5.3,
        GadgetSignal.pm2p5: 12.7,
        GadgetSignal.pm4p0: 18.2,
        GadgetSignal.pm10p0: 25.1,
        GadgetSignal.vocIndex: 101.0,
        GadgetSignal.noxIndex: 3.0,
        GadgetSignal.velocity: 2.5,
        GadgetSignal.h2: 1.25,
        GadgetSignal.pressure: 1013.0,
      };

      // Which encoder pairs with each decoder, per BLEProtocol.cpp.
      int encodeFor(GadgetSampleConfig c, GadgetSampleSlot slot, double v) {
        return switch (slot.signal) {
          GadgetSignal.temperature => encodeTemperatureV1(v),
          GadgetSignal.humidity =>
            c.name == 'T_RH_V4' ? encodeHumidityV2(v) : encodeHumidityV1(v),
          GadgetSignal.hcho => encodeHchoV1(v),
          GadgetSignal.h2 => (v * 100).round(),
          GadgetSignal.velocity => ((v * 65535) / 1024).round(),
          GadgetSignal.pm1p0 ||
          GadgetSignal.pm2p5 ||
          GadgetSignal.pm4p0 ||
          GadgetSignal.pm10p0 =>
            _pmUsesV2(c, slot) ? encodePmV2(v) : encodePm2p5V1(v),
          _ => encodeSimple(v),
        };
      }

      for (final config in kGadgetSampleConfigs) {
        final raw = [
          for (final slot in config.slots)
            encodeFor(config, slot, inputs[slot.signal]!),
        ];
        final packet = buildPacket(1, config, [raw]);
        final values = config.decodeSample(packet, kDownloadPacketHeaderBytes);

        expect(
          values.keys.toSet(),
          config.signals.toSet(),
          reason: '${config.name} lost a signal',
        );
        for (final slot in config.slots) {
          final want = inputs[slot.signal]!;
          expect(
            values[slot.signal],
            closeTo(want, want.abs() * 0.02 + 0.15),
            reason: '${config.name}/${slot.signal.name} did not round-trip',
          );
        }
      }
    });
  });

  group('history', () {
    /// Timestamps are reconstructed backwards from the newest sample, so the
    /// series must be strictly increasing and spaced by the logging interval.
    test('CSV export lists signals in byte order with a timestamp column', () {
      final config = kScd4xSampleConfig;
      final header = GadgetDownloadHeader.parse(
        buildHeader(downloadType: 9, intervalMs: 60000, ageMs: 0, count: 2),
      )!;
      final t0 = DateTime.utc(2026, 7, 29, 12);
      final history = GadgetHistory(header, [
        GadgetHistorySample(t0, {
          GadgetSignal.temperature: 21.0,
          GadgetSignal.humidity: 40.0,
          GadgetSignal.co2: 500.0,
        }),
        GadgetHistorySample(t0.add(const Duration(minutes: 1)), {
          GadgetSignal.temperature: 21.5,
          GadgetSignal.humidity: 41.0,
          GadgetSignal.co2: 650.0,
        }),
      ]);

      expect(history.signals, config.signals);

      final lines = history.toCsv().trim().split('\n');
      expect(lines.first, 'timestamp,T (°C),RH (%),CO2 (ppm)');
      expect(lines[1], '2026-07-29T12:00:00.000Z,21.0,40.0,500');
      expect(lines[2], '2026-07-29T12:01:00.000Z,21.5,41.0,650');
    });

    test('a layout with no known config exposes no signals', () {
      final header = GadgetDownloadHeader.parse(
        buildHeader(downloadType: 254, intervalMs: 1000, ageMs: 0, count: 0),
      )!;
      expect(header.config, isNull);
      expect(GadgetHistory(header, const []).signals, isEmpty);
    });
  });
}

/// PM slots decode with PMV2 in the newer layouts and PM2p5V1 in the older
/// ones; mirror that split so the round-trip test pairs the right encoder.
bool _pmUsesV2(GadgetSampleConfig c, GadgetSampleSlot slot) {
  final decoded = slot.decode(100);
  // decodePMV2(100) == 10.0, decodePM2p5V1(100) == ~1.526.
  return decoded > 5;
}
