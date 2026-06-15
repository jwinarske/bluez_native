import 'dart:async';

import 'package:bluez_native/bluez_native.dart';
import 'package:flutter/material.dart';

class CharacteristicScreen extends StatefulWidget {
  final BlueZGattCharacteristic characteristic;

  const CharacteristicScreen({super.key, required this.characteristic});

  @override
  State<CharacteristicScreen> createState() => _CharacteristicScreenState();
}

class _CharacteristicScreenState extends State<CharacteristicScreen> {
  List<int>? _lastValue;
  StreamSubscription<List<int>>? _notifySub;
  bool _notifying = false;

  BlueZGattCharacteristic get _char => widget.characteristic;

  Future<void> _read() async {
    try {
      final value = await _char.readValue();
      setState(() => _lastValue = value);
    } on BlueZOperationException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Read failed: ${e.message}')),
        );
      }
    }
  }

  Future<void> _toggleNotify() async {
    try {
      if (_notifying) {
        await _char.stopNotify();
        _notifySub?.cancel();
        _notifySub = null;
      } else {
        await _char.startNotify();
        _notifySub = _char.value.listen((bytes) {
          setState(() => _lastValue = bytes);
        });
      }
      setState(() => _notifying = !_notifying);
    } on BlueZOperationException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Notify failed: ${e.message}')),
        );
      }
    }
  }

  @override
  void dispose() {
    _notifySub?.cancel();
    super.dispose();
  }

  String _formatHex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_char.uuid.toString())),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Service: ${_char.servicePath}',
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8),
            Text('Flags: ${_char.flags.map((f) => f.name).join(', ')}'),
            Text('MTU: ${_char.mtu}'),
            const Divider(height: 32),
            if (_lastValue != null) ...[
              Text('Value (hex): ${_formatHex(_lastValue!)}'),
              Text('Value (raw): $_lastValue'),
              const SizedBox(height: 16),
            ],
            Row(
              children: [
                ElevatedButton(
                  onPressed: _read,
                  child: const Text('Read'),
                ),
                const SizedBox(width: 16),
                ElevatedButton(
                  onPressed: _toggleNotify,
                  child: Text(_notifying ? 'Stop Notify' : 'Start Notify'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
