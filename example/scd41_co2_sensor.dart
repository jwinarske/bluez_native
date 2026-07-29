// example/scd41_co2_sensor.dart
// Full-featured client for a Sensirion SCD41 CO2 gadget: advertisement
// decoding, live monitoring, history download with CSV export and terminal
// plots, logging interval, device naming, battery, Wi-Fi provisioning, and
// SCD4x forced recalibration.
//
// The wire protocol lives in sensirion_gadget.dart.
//
//   dart run example/scd41_co2_sensor.dart scan
//   dart run example/scd41_co2_sensor.dart history AA:BB:CC:DD:EE:FF --plot
//
// Works against any gadget built on Sensirion's arduino-ble-gadget library;
// the SCD4x build is arduino-ble-gadget Example8.

import 'dart:async';
import 'dart:io';

import 'package:bluez_native/bluez_native.dart';

import 'example_utils.dart';
import 'sensirion_gadget.dart';

const String _usage = '''
Sensirion SCD41 CO2 gadget client.

Usage: dart run example/scd41_co2_sensor.dart <command> [arguments]

Commands:
  scan                            Discover gadgets and decode advertised values
  monitor <addr>                  Stream live values from advertisements
  live <addr>                     Stream live values over a connection
  info <addr>                     Connect and report gadget state
  history <addr>                  Download logged samples
  interval <addr> [<seconds>]     Show or set the logging interval
  name <addr> [<new-name>]        Show or set the gadget name
  led <addr>                      Show LED brightness
  frc <addr> <ppm>                SCD4x forced recalibration to a reference
  wifi <addr> <ssid> <password>   Provision Wi-Fi credentials

Options:
  --timeout <seconds>   Scan / discovery timeout (default 15)
  --max <n>             history: fetch at most n samples (default: all)
  --csv <path>          history: write samples to a CSV file
  --plot                history: draw a terminal plot per signal
  --yes                 Confirm an operation that erases gadget data

There are two paths to live values: monitor decodes the gadget's
advertisements and needs no connection, while live connects and subscribes,
which updates faster. History and settings require connecting.
''';

Future<void> main(List<String> args) async {
  if (args.isEmpty || args.first == '--help' || args.first == '-h') {
    stdout.write(_usage);
    return;
  }

  final command = args.first;
  final rest = args.skip(1).toList();

  final client = BlueZClient();
  await client.connect();

  final adapter = client.adapters.firstOrNull;
  if (adapter == null) {
    print('No Bluetooth adapter found.');
    await client.close();
    exitCode = 1;
    return;
  }

  if (!adapter.powered) {
    print('Powering on adapter...');
    await adapter.setPowered(true);
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }

  try {
    switch (command) {
      case 'scan':
        await _scan(client, adapter, args);
      case 'monitor':
        await _requireAddress(rest, 'monitor', (addr) async {
          await _monitor(client, adapter, addr, args);
        });
      case 'live':
        await _withGadget(
          client,
          adapter,
          rest,
          args,
          'live',
          (gadget) => _live(gadget, args),
        );
      case 'info':
        await _withGadget(client, adapter, rest, args, 'info', _info);
      case 'led':
        await _withGadget(client, adapter, rest, args, 'led', _led);
      case 'history':
        await _withGadget(
          client,
          adapter,
          rest,
          args,
          'history',
          (gadget) => _history(gadget, args),
        );
      case 'interval':
        await _withGadget(
          client,
          adapter,
          rest,
          args,
          'interval',
          (gadget) => _interval(gadget, rest, args),
        );
      case 'name':
        await _withGadget(
          client,
          adapter,
          rest,
          args,
          'name',
          (gadget) => _name(gadget, rest),
        );
      case 'frc':
        await _withGadget(
          client,
          adapter,
          rest,
          args,
          'frc',
          (gadget) => _frc(gadget, rest),
        );
      case 'wifi':
        await _withGadget(
          client,
          adapter,
          rest,
          args,
          'wifi',
          (gadget) => _wifi(gadget, rest),
        );
      default:
        print('Unknown command: $command\n');
        stdout.write(_usage);
        exitCode = 2;
    }
  } on GadgetProtocolException catch (e) {
    // Expected outcomes against varying firmware -- report them as messages
    // rather than as an unhandled exception with a stack trace.
    print(e.message);
    exitCode = 1;
  } on BlueZOperationException catch (e) {
    print('Bluetooth operation failed: $e');
    exitCode = 1;
  } finally {
    await client.close();
  }
}

// ---------------------------------------------------------------------------
// scan / monitor — advertisement only, no connection
// ---------------------------------------------------------------------------

Future<void> _scan(
  BlueZClient client,
  BlueZAdapter adapter,
  List<String> args,
) async {
  final timeout = parseScanTimeout(args);
  print('Scanning for Sensirion gadgets for ${timeout.inSeconds}s...\n');

  final seen = <String, String>{};

  void report(BlueZDevice d) {
    final adv = GadgetAdvertisement.fromDevice(d);
    if (adv == null) return;
    final line = adv.toString();
    if (seen[d.address] == line) return;
    final first = !seen.containsKey(d.address);
    seen[d.address] = line;
    final rssi = d.rssi != 0 ? '${d.rssi} dBm' : '?';
    final label = d.name.isEmpty ? '(no name)' : d.name;
    print('${first ? '+' : ' '} ${d.address}  $label  $rssi');
    print('    $line');
  }

  final sub = client.deviceAdded.listen(report);
  final subChanged = client.deviceChanged.listen(report);

  await adapter.startDiscovery();
  for (final d in client.devices) {
    report(d);
  }
  await Future<void>.delayed(timeout);
  await adapter.stopDiscovery();
  await sub.cancel();
  await subChanged.cancel();

  print('');
  if (seen.isEmpty) {
    print('No Sensirion gadgets found.');
    print(
      'The gadget advertises about once a second — try moving closer or '
      'increasing --timeout.',
    );
  } else {
    print('${seen.length} gadget(s) found.');
  }
}

Future<void> _monitor(
  BlueZClient client,
  BlueZAdapter adapter,
  String addr,
  List<String> args,
) async {
  final want = addr.toUpperCase();
  print('Monitoring $want advertisements. Press Ctrl-C to stop.\n');

  var last = '';
  void report(BlueZDevice d) {
    if (d.address.toUpperCase() != want) return;
    final adv = GadgetAdvertisement.fromDevice(d);
    if (adv == null) return;
    final values = adv.values.entries
        .map((e) => '${e.key.label} ${e.key.format(e.value)}')
        .join('   ');
    if (values == last) return;
    last = values;
    final now = DateTime.now().toIso8601String().substring(11, 19);
    print('$now  $values   (${d.rssi} dBm)');
  }

  final sub = client.deviceAdded.listen(report);
  final subChanged = client.deviceChanged.listen(report);
  await adapter.startDiscovery();
  for (final d in client.devices) {
    report(d);
  }

  // Run until interrupted.
  final done = Completer<void>();
  late StreamSubscription<ProcessSignal> sigint;
  sigint = ProcessSignal.sigint.watch().listen((_) {
    if (!done.isCompleted) done.complete();
  });
  await done.future;

  await sigint.cancel();
  await sub.cancel();
  await subChanged.cancel();
  await adapter.stopDiscovery();
  print('\nStopped.');
}

// ---------------------------------------------------------------------------
// Connected commands
// ---------------------------------------------------------------------------

Future<void> _requireAddress(
  List<String> rest,
  String command,
  Future<void> Function(String addr) body,
) async {
  final addr = rest.where((a) => !a.startsWith('--')).firstOrNull;
  if (addr == null) {
    print('Usage: dart run example/scd41_co2_sensor.dart $command <address>');
    exitCode = 2;
    return;
  }
  await body(addr);
}

/// Find, connect, resolve services and hand a [SensirionGadget] to [body].
Future<void> _withGadget(
  BlueZClient client,
  BlueZAdapter adapter,
  List<String> rest,
  List<String> args,
  String command,
  Future<void> Function(SensirionGadget gadget) body,
) async {
  await _requireAddress(rest, command, (addr) async {
    final timeout = parseScanTimeout(args);
    final device = await findDevice(client, adapter, addr, timeout: timeout);
    if (device == null) {
      exitCode = 1;
      return;
    }

    final wasConnected = device.connected;
    if (!wasConnected) {
      print('Connecting to ${device.address}...');
      if (!await _connectWithRetry(device)) {
        exitCode = 1;
        return;
      }
    }

    try {
      await device.waitForServicesResolved();
      final gadget = SensirionGadget(device);
      if (!gadget.hasDownloadService) {
        print(
          'Warning: ${device.address} does not expose the Sensirion gadget '
          'download service. It may not be a Sensirion gadget.',
        );
      }
      await body(gadget);
    } finally {
      if (!wasConnected) {
        await device.disconnect();
      }
    }
  });
}

Future<bool> _connectWithRetry(BlueZDevice device, {int attempts = 3}) async {
  for (var attempt = 1; attempt <= attempts; attempt++) {
    try {
      await device.connect();
      return true;
    } on BlueZOperationException catch (e) {
      print('Attempt $attempt failed: $e');
      if (attempt == attempts) {
        print('Giving up after $attempts attempts.');
        return false;
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    }
  }
  return false;
}

Future<void> _info(SensirionGadget gadget) async {
  final device = gadget.device;
  print('');
  print('Device');
  print('  Address          ${device.address}');
  print('  Name             ${device.name.isEmpty ? '(none)' : device.name}');
  print('  RSSI             ${device.rssi} dBm');
  print('  Paired           ${device.paired}');
  print('  Services         ${device.gattServices.length}');

  for (final (label, value) in [
    ('Manufacturer', await gadget.readManufacturerName()),
    ('Model', await gadget.readModelNumber()),
    ('Hardware rev', await gadget.readHardwareRevision()),
    ('Firmware rev', await gadget.readFirmwareRevision()),
  ]) {
    if (value != null && value.isNotEmpty) {
      print('  ${label.padRight(16)} $value');
    }
  }
  final gadgetName = await gadget.readDeviceName();
  if (gadgetName != null) {
    print('  Gadget name      ${gadgetName.isEmpty ? '(unset)' : gadgetName}');
  }
  final battery = await gadget.readBatteryLevel();
  if (battery != null) {
    print('  Battery          $battery%');
  }
  final led = await gadget.readLedBrightness();
  if (led != null) {
    print('  LED brightness   $led / 255');
  }

  final serial = await gadget.readScdSerial();
  final featureSet = await gadget.readScdFeatureSet();
  if (serial != null || featureSet != null) {
    print('');
    print('SCD4x sensor');
    if (serial != null) print('  Serial           $serial');
    if (featureSet != null) {
      print('  Feature set      0x${featureSet.toRadixString(16)}');
    }
  }

  print('');
  print('Advertised live values');
  final adv = GadgetAdvertisement.fromDevice(device);
  if (adv == null) {
    print('  (no Sensirion advertisement seen yet)');
  } else {
    print('  Data type        ${adv.config?.name ?? 'unknown'}');
    print('  Device id        ${adv.deviceIdString}');
    for (final e in adv.values.entries) {
      print('  ${e.key.label.padRight(16)} ${e.key.format(e.value)}');
    }
  }

  if (gadget.hasDownloadService) {
    print('');
    print('History');
    final interval = await gadget.readLoggingInterval();
    final count = await gadget.readSampleCount();
    print('  Logging interval ${_formatDuration(interval)}');
    print('  Stored samples   $count');
    if (count > 0 && interval.inMilliseconds > 0) {
      print('  Covers           ${_formatDuration(interval * count)}');
    }
  }

  print('');
  print('Capabilities');
  print('  History download ${gadget.hasDownloadService ? 'yes' : 'no'}');
  print('  SCD4x FRC        ${gadget.hasFrcService ? 'yes' : 'no'}');
  print('  Rename           ${gadget.canRename ? 'yes' : 'no'}');
  final live = gadget.liveSignals;
  print(
    '  Live (connected) '
    '${live.isEmpty ? 'no' : live.map((s) => s.label).join(', ')}',
  );
}

Future<void> _live(SensirionGadget gadget, List<String> args) async {
  final signals = gadget.liveSignals;
  if (signals.isEmpty) {
    print('This gadget exposes no live-value characteristics.');
    exitCode = 1;
    return;
  }

  print(
    'Streaming ${signals.map((s) => s.label).join(', ')} while connected. '
    'Press Ctrl-C to stop.',
  );
  print('');

  // Print a line whenever any signal updates, carrying the latest of each.
  final latest = <GadgetSignal, double>{};
  final done = Completer<void>();
  final sub = gadget.liveValues().listen(
    (event) {
      final (signal, value) = event;
      latest[signal] = value;
      final now = DateTime.now().toIso8601String().substring(11, 19);
      final rendered = signals
          .where(latest.containsKey)
          .map((s) => '${s.label} ${s.format(latest[s]!)}')
          .join('   ');
      stdout.write('\r$now  $rendered      ');
    },
    onError: (Object e) {
      print('$e');
      if (!done.isCompleted) done.complete();
    },
    onDone: () {
      if (!done.isCompleted) done.complete();
    },
  );

  final sigint = ProcessSignal.sigint.watch().listen((_) {
    if (!done.isCompleted) done.complete();
  });

  await done.future;
  await sub.cancel();
  await sigint.cancel();
  print('');
  print('Stopped.');
}

Future<void> _led(SensirionGadget gadget) async {
  final current = await gadget.readLedBrightness();
  if (current == null) {
    print('This gadget has no LED brightness setting.');
    exitCode = 1;
    return;
  }
  print('LED brightness: $current');
  print(
    'Read-only: the characteristic accepts a write but the value reads back '
    'unchanged, so its write encoding is unconfirmed.',
  );
}

Future<void> _history(SensirionGadget gadget, List<String> args) async {
  if (!gadget.hasDownloadService) {
    print('This device has no gadget download service.');
    exitCode = 1;
    return;
  }

  final maxSamples = _intOption(args, '--max') ?? 0;
  final csvPath = _stringOption(args, '--csv');

  final stored = await gadget.readSampleCount();
  final interval = await gadget.readLoggingInterval();
  print(
    'Gadget holds $stored sample(s) at ${_formatDuration(interval)} interval.',
  );
  if (stored == 0) {
    print('Nothing to download yet.');
    return;
  }

  // The firmware only honors a limit strictly below the stored count.
  if (maxSamples > 0 && maxSamples >= stored) {
    print(
      'Requested --max $maxSamples covers the whole history; '
      'downloading all $stored.',
    );
  }

  print('Downloading...');
  final history = await gadget.downloadHistory(
    maxSamples: maxSamples,
    onProgress: (received, total) {
      stdout.write('\r  $received / $total samples');
      if (received == total) stdout.write('\n');
    },
  );

  final h = history.header;
  print('');
  print('Data type         ${h.config?.name ?? 'unknown'}');
  print('Logging interval  ${_formatDuration(h.interval)}');
  print('Samples           ${history.samples.length} of ${h.sampleCount}');
  if (history.samples.isNotEmpty) {
    print('Oldest            ${history.samples.first.timestamp}');
    print('Newest            ${history.samples.last.timestamp}');
  }
  print(
    'Newest sample age ${_formatDuration(h.ageOfNewestSample)} '
    '(timestamps are reconstructed from the host clock; the gadget has no RTC)',
  );

  if (history.samples.isEmpty) return;

  _printStatistics(history);

  if (args.contains('--plot')) {
    _printPlots(history);
  } else {
    print('');
    print('Last 10 samples');
    for (final s in history.samples.reversed.take(10).toList().reversed) {
      print('  $s');
    }
  }

  if (csvPath != null) {
    await File(csvPath).writeAsString(history.toCsv());
    print('');
    print('Wrote ${history.samples.length} samples to $csvPath');
  }
}

Future<void> _interval(
  SensirionGadget gadget,
  List<String> rest,
  List<String> args,
) async {
  final positional = rest.where((a) => !a.startsWith('--')).toList();
  final current = await gadget.readLoggingInterval();

  if (positional.length < 2) {
    final count = await gadget.readSampleCount();
    print('Logging interval: ${_formatDuration(current)}');
    print('Stored samples:   $count');
    print('');
    print(
      'To change it: dart run example/scd41_co2_sensor.dart interval '
      '${gadget.device.address} <seconds> --yes',
    );
    return;
  }

  final seconds = int.tryParse(positional[1]);
  if (seconds == null || seconds <= 0) {
    print('Interval must be a positive number of seconds.');
    exitCode = 2;
    return;
  }

  // Changing the interval resets the gadget's ring buffer, so make the data
  // loss explicit rather than discovering it afterwards.
  final stored = await gadget.readSampleCount();
  if (!args.contains('--yes')) {
    print('Changing the logging interval ERASES the gadget\'s stored history.');
    print('  Current interval  ${_formatDuration(current)}');
    print('  New interval      ${_formatDuration(Duration(seconds: seconds))}');
    print('  Samples to lose   $stored');
    print('');
    print('Re-run with --yes to proceed.');
    exitCode = 1;
    return;
  }

  await gadget.writeLoggingInterval(Duration(seconds: seconds));
  final readback = await gadget.readLoggingInterval();
  print(
    'Logging interval set to ${_formatDuration(readback)} '
    '($stored sample(s) erased).',
  );
}

Future<void> _name(SensirionGadget gadget, List<String> rest) async {
  final positional = rest.where((a) => !a.startsWith('--')).toList();
  final current = await gadget.readDeviceName();

  if (current == null) {
    print('This gadget exposes no readable name characteristic.');
    exitCode = 1;
    return;
  }

  if (positional.length < 2) {
    print('Gadget name: ${current.isEmpty ? '(unset)' : current}');
    if (!gadget.canRename) {
      print('This gadget does not allow renaming over BLE.');
    }
    return;
  }

  if (!gadget.canRename) {
    print('This gadget does not allow renaming over BLE.');
    exitCode = 1;
    return;
  }

  try {
    await gadget.writeDeviceName(positional[1]);
  } on BlueZOperationException catch (e) {
    // A MyCO2 advertises GAP Device Name as writable but rejects the write on
    // an unencrypted link, so the characteristic flags alone cannot tell you
    // whether a rename will be accepted.
    if (e.toString().contains('NotAuthorized')) {
      print(
        'The gadget refused the rename: writing GAP Device Name needs an '
        'encrypted link, so the device would have to be bonded first.',
      );
      print(
        'A MyCO2 does not accept pairing -- both this library and bluetoothctl '
        'time out with no SMP response -- so its name cannot be changed over '
        'BLE at all. The vendor app keeps its own label per device rather than '
        'writing one to the gadget.',
      );
      exitCode = 1;
      return;
    }
    rethrow;
  }

  print('Gadget name set to "${await gadget.readDeviceName()}".');
  print(
    'BlueZ caches the old name until it sees a fresh advertisement; '
    'run scan if it still shows the previous name.',
  );
}

Future<void> _frc(SensirionGadget gadget, List<String> rest) async {
  final positional = rest.where((a) => !a.startsWith('--')).toList();
  if (positional.length < 2) {
    print(
      'Usage: dart run example/scd41_co2_sensor.dart frc <address> '
      '<reference-ppm>',
    );
    print('Outdoor air is roughly 400-420 ppm.');
    exitCode = 2;
    return;
  }

  if (!gadget.hasFrcService) {
    print(
      'This gadget does not expose the SCD4x FRC service. It must be built '
      'with the FRC service enabled, as in arduino-ble-gadget Example8.',
    );
    exitCode = 1;
    return;
  }

  final ppm = int.tryParse(positional[1]);
  if (ppm == null || ppm <= 0 || ppm > 0xFFFF) {
    print('Reference CO2 level must be between 1 and 65535 ppm.');
    exitCode = 2;
    return;
  }

  await gadget.requestForcedRecalibration(ppm);
  print('Forced recalibration requested against $ppm ppm.');
  print(
    'The gadget performs the FRC in its own loop: it stops measuring, applies '
    'the correction, and restarts. Readings settle after a few seconds.',
  );
}

Future<void> _wifi(SensirionGadget gadget, List<String> rest) async {
  final positional = rest.where((a) => !a.startsWith('--')).toList();
  if (positional.length < 3) {
    print(
      'Usage: dart run example/scd41_co2_sensor.dart wifi <address> '
      '<ssid> <password>',
    );
    exitCode = 2;
    return;
  }
  await gadget.writeWifiCredentials(positional[1], positional[2]);
  print('Wi-Fi credentials written for SSID "${positional[1]}".');
}

// ---------------------------------------------------------------------------
// History presentation
// ---------------------------------------------------------------------------

void _printStatistics(GadgetHistory history) {
  print('');
  print('Signal          Min        Max        Mean       Latest');
  for (final signal in history.signals) {
    final values = [
      for (final s in history.samples)
        if (s.values[signal] != null) s.values[signal]!,
    ];
    if (values.isEmpty) continue;
    final min = values.reduce((a, b) => a < b ? a : b);
    final max = values.reduce((a, b) => a > b ? a : b);
    final mean = values.reduce((a, b) => a + b) / values.length;
    String col(double v) => signal.format(v).padRight(11);
    print(
      '${signal.label.padRight(15)}${col(min)}${col(max)}${col(mean)}'
      '${signal.format(values.last)}',
    );
  }
}

const String _blocks = ' ▁▂▃▄▅▆▇█';

void _printPlots(GadgetHistory history) {
  final width = _plotWidth();
  for (final signal in history.signals) {
    final values = [
      for (final s in history.samples) s.values[signal] ?? double.nan,
    ];
    final finite = values.where((v) => !v.isNaN).toList();
    if (finite.isEmpty) continue;

    var min = finite.reduce((a, b) => a < b ? a : b);
    var max = finite.reduce((a, b) => a > b ? a : b);
    if (max - min < 1e-9) {
      // Flat series: give it a visible band so the sparkline is not all zeros.
      min -= 0.5;
      max += 0.5;
    }

    final buckets = _downsample(values, width);
    final bar = buckets.map((v) {
      if (v.isNaN) return ' ';
      final t = ((v - min) / (max - min)).clamp(0.0, 1.0);
      return _blocks[(t * (_blocks.length - 1)).round()];
    }).join();

    final unit = signal.unit.isEmpty ? '' : ' ${signal.unit}';
    print('');
    print(
      '${signal.label}  ${min.toStringAsFixed(signal.precision)} .. '
      '${max.toStringAsFixed(signal.precision)}$unit',
    );
    print('  $bar');
  }
  print('');
  print(
    '  ${history.samples.first.timestamp.toIso8601String().substring(0, 16)}'
    '  ->  '
    '${history.samples.last.timestamp.toIso8601String().substring(0, 16)}',
  );
}

/// Average [values] into at most [width] buckets, preserving gaps as NaN.
List<double> _downsample(List<double> values, int width) {
  if (values.length <= width) return values;
  final out = <double>[];
  for (var i = 0; i < width; i++) {
    final start = (i * values.length) ~/ width;
    final end = ((i + 1) * values.length) ~/ width;
    final slice = [
      for (var j = start; j < end; j++)
        if (!values[j].isNaN) values[j],
    ];
    out.add(
      slice.isEmpty ? double.nan : slice.reduce((a, b) => a + b) / slice.length,
    );
  }
  return out;
}

int _plotWidth() {
  try {
    if (stdout.hasTerminal) return (stdout.terminalColumns - 4).clamp(20, 200);
  } on StdoutException {
    // Not a terminal; fall through to the default.
  }
  return 76;
}

// ---------------------------------------------------------------------------
// Option parsing and formatting
// ---------------------------------------------------------------------------

String? _stringOption(List<String> args, String name) {
  final i = args.indexOf(name);
  if (i == -1 || i + 1 >= args.length) return null;
  return args[i + 1];
}

int? _intOption(List<String> args, String name) {
  final raw = _stringOption(args, name);
  return raw == null ? null : int.tryParse(raw);
}

String _formatDuration(Duration d) {
  if (d.inMilliseconds == 0) return '0s';
  if (d.inMilliseconds < 1000) return '${d.inMilliseconds}ms';
  final parts = <String>[];
  final days = d.inDays;
  final hours = d.inHours % 24;
  final minutes = d.inMinutes % 60;
  final seconds = d.inSeconds % 60;
  if (days > 0) parts.add('${days}d');
  if (hours > 0) parts.add('${hours}h');
  if (minutes > 0) parts.add('${minutes}m');
  if (seconds > 0) parts.add('${seconds}s');
  return parts.join(' ');
}
