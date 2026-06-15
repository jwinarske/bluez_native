import 'dart:async';

import 'package:bluez_native/bluez_native.dart';
import 'package:flutter/material.dart';

import 'characteristic_screen.dart';

class DeviceScreen extends StatefulWidget {
  final BlueZClient client;
  final BlueZDevice device;

  const DeviceScreen({
    super.key,
    required this.client,
    required this.device,
  });

  @override
  State<DeviceScreen> createState() => _DeviceScreenState();
}

class _DeviceScreenState extends State<DeviceScreen> {
  bool _busy = false;
  StreamSubscription<List<String>>? _propsSub;
  StreamSubscription<BlueZAdapter>? _adapterSub;

  @override
  void initState() {
    super.initState();
    _propsSub = widget.device.propertiesChanged.listen(_onDeviceChanged);
    _adapterSub = widget.client.adapterChanged.listen(_onAdapterChanged);
  }

  void _onDeviceChanged(List<String> changed) {
    if (!mounted) return;
    if (changed.contains('Connected') && !widget.device.connected && !_busy) {
      Navigator.of(context).popUntil((route) => route.isFirst);
      return;
    }
    setState(() {});
  }

  void _onAdapterChanged(BlueZAdapter adapter) {
    if (!mounted) return;
    if (!adapter.powered) {
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
  }

  Future<void> _connect() async {
    setState(() => _busy = true);
    try {
      await widget.device.connect();
      await widget.device.waitForServicesResolved();
    } on Exception catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Connection failed: $e')),
        );
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _disconnect() async {
    await widget.device.disconnect();
  }

  Future<void> _pair() async {
    setState(() => _busy = true);
    try {
      await widget.device.pair();
      // pair() completes while still connected — just update UI.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Pairing successful')),
        );
      }
    } on Exception catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Pairing failed: $e')),
        );
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  void dispose() {
    _propsSub?.cancel();
    _adapterSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final device = widget.device;
    final services = device.gattServices;

    return Scaffold(
      appBar: AppBar(
        title: Text(device.name.isNotEmpty ? device.name : device.address),
        actions: [
          if (_busy)
            const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else ...[
            if (device.connected && !device.paired)
              TextButton(onPressed: _pair, child: const Text('Pair')),
            TextButton(
              onPressed: device.connected ? _disconnect : _connect,
              child: Text(device.connected ? 'Disconnect' : 'Connect'),
            ),
          ],
        ],
      ),
      body: _buildBody(device, services),
    );
  }

  Widget _buildBody(BlueZDevice device, List<BlueZGattService> services) {
    if (!device.connected) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(device.paired ? 'Paired' : 'Not paired',
                style: TextStyle(
                    color: device.paired ? Colors.green : Colors.grey)),
            const SizedBox(height: 8),
            const Text('Tap Connect to discover services.'),
          ],
        ),
      );
    }

    if (services.isEmpty) {
      if (_busy) {
        return const Center(child: CircularProgressIndicator());
      }
      return const Center(child: Text('No GATT services available.'));
    }

    return ListView.builder(
      itemCount: services.length,
      itemBuilder: (context, index) {
        final service = services[index];
        return ExpansionTile(
          title: Text(service.uuid.toString()),
          subtitle: Text(service.primary ? 'Primary' : 'Secondary'),
          children: service.characteristics.map((char) {
            return ListTile(
              title: Text(char.uuid.toString()),
              subtitle:
                  Text('Flags: ${char.flags.map((f) => f.name).join(', ')}'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => CharacteristicScreen(characteristic: char),
                ),
              ),
            );
          }).toList(),
        );
      },
    );
  }
}
