import 'package:bluez_native/bluez_native.dart';
import 'package:flutter/material.dart';

/// Show the appropriate pairing dialog for an agent request.
void showPairingDialog(
    BuildContext context, BlueZClient client, BlueZAgentRequest req) {
  switch (req.requestType) {
    case AgentRequestType.requestConfirmation:
      _showConfirmDialog(context, client, req);
    case AgentRequestType.requestPinCode:
      _showPinCodeDialog(context, client, req);
    case AgentRequestType.requestPasskey:
      _showPasskeyDialog(context, client, req);
    case AgentRequestType.requestAuthorization:
      _showAuthorizationDialog(context, client, req);
    case AgentRequestType.authorizeService:
      _showServiceAuthDialog(context, client, req);
    case AgentRequestType.displayPinCode:
      _showDisplayDialog(context, 'PIN Code', req.pinCode, req.devicePath);
    case AgentRequestType.displayPasskey:
      _showDisplayDialog(context, 'Passkey',
          req.passkey.toString().padLeft(6, '0'), req.devicePath);
    case AgentRequestType.cancel:
      // Dismiss any open pairing dialog.
      Navigator.of(context, rootNavigator: true).popUntil((route) {
        return route is! DialogRoute;
      });
    case AgentRequestType.release:
      break;
  }
}

String _deviceName(String devicePath) {
  // Extract address from path: /org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF
  final parts = devicePath.split('/');
  if (parts.isEmpty) return devicePath;
  return parts.last.replaceAll('dev_', '').replaceAll('_', ':');
}

// ── Confirm passkey ─────────────────────────────────────────────────────────

void _showConfirmDialog(
    BuildContext context, BlueZClient client, BlueZAgentRequest req) {
  final passkey = req.passkey.toString().padLeft(6, '0');
  final device = _deviceName(req.devicePath);

  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      title: const Text('Confirm Pairing'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Device: $device'),
          const SizedBox(height: 16),
          Text(
            passkey,
            style: Theme.of(ctx).textTheme.headlineLarge?.copyWith(
                  fontFamily: 'monospace',
                  letterSpacing: 8,
                ),
          ),
          const SizedBox(height: 8),
          const Text('Does this passkey match the device?'),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () {
            client.agentRespond(req.requestId, accepted: false);
            Navigator.of(ctx).pop();
          },
          child: const Text('Reject'),
        ),
        FilledButton(
          onPressed: () {
            client.agentRespond(req.requestId);
            Navigator.of(ctx).pop();
          },
          child: const Text('Confirm'),
        ),
      ],
    ),
  );
}

// ── Enter PIN code ──────────────────────────────────────────────────────────

void _showPinCodeDialog(
    BuildContext context, BlueZClient client, BlueZAgentRequest req) {
  final controller = TextEditingController();
  final device = _deviceName(req.devicePath);

  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      title: const Text('Enter PIN Code'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Device: $device'),
          const SizedBox(height: 16),
          TextField(
            controller: controller,
            decoration: const InputDecoration(
              labelText: 'PIN Code',
              border: OutlineInputBorder(),
            ),
            autofocus: true,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () {
            client.agentRespond(req.requestId, accepted: false);
            Navigator.of(ctx).pop();
          },
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            client.agentRespond(req.requestId, response: controller.text);
            Navigator.of(ctx).pop();
          },
          child: const Text('Pair'),
        ),
      ],
    ),
  );
}

// ── Enter passkey ───────────────────────────────────────────────────────────

void _showPasskeyDialog(
    BuildContext context, BlueZClient client, BlueZAgentRequest req) {
  final controller = TextEditingController();
  final device = _deviceName(req.devicePath);

  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      title: const Text('Enter Passkey'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Device: $device'),
          const SizedBox(height: 16),
          TextField(
            controller: controller,
            decoration: const InputDecoration(
              labelText: 'Passkey (6 digits)',
              border: OutlineInputBorder(),
            ),
            keyboardType: TextInputType.number,
            maxLength: 6,
            autofocus: true,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () {
            client.agentRespond(req.requestId, accepted: false);
            Navigator.of(ctx).pop();
          },
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            client.agentRespond(req.requestId, response: controller.text);
            Navigator.of(ctx).pop();
          },
          child: const Text('Pair'),
        ),
      ],
    ),
  );
}

// ── Authorization request ───────────────────────────────────────────────────

void _showAuthorizationDialog(
    BuildContext context, BlueZClient client, BlueZAgentRequest req) {
  final device = _deviceName(req.devicePath);

  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      title: const Text('Authorize Device'),
      content: Text('Allow $device to pair?'),
      actions: [
        TextButton(
          onPressed: () {
            client.agentRespond(req.requestId, accepted: false);
            Navigator.of(ctx).pop();
          },
          child: const Text('Deny'),
        ),
        FilledButton(
          onPressed: () {
            client.agentRespond(req.requestId);
            Navigator.of(ctx).pop();
          },
          child: const Text('Allow'),
        ),
      ],
    ),
  );
}

// ── Service authorization ───────────────────────────────────────────────────

void _showServiceAuthDialog(
    BuildContext context, BlueZClient client, BlueZAgentRequest req) {
  final device = _deviceName(req.devicePath);

  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      title: const Text('Authorize Service'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Device: $device'),
          const SizedBox(height: 8),
          Text('Service: ${req.uuid}'),
          const SizedBox(height: 16),
          const Text('Allow this device to use this service?'),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () {
            client.agentRespond(req.requestId, accepted: false);
            Navigator.of(ctx).pop();
          },
          child: const Text('Deny'),
        ),
        FilledButton(
          onPressed: () {
            client.agentRespond(req.requestId);
            Navigator.of(ctx).pop();
          },
          child: const Text('Allow'),
        ),
      ],
    ),
  );
}

// ── Display-only (informational) ────────────────────────────────────────────

void _showDisplayDialog(
    BuildContext context, String label, String value, String devicePath) {
  final device = _deviceName(devicePath);

  showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('$label for Pairing'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Device: $device'),
          const SizedBox(height: 16),
          Text(
            value,
            style: Theme.of(ctx).textTheme.headlineLarge?.copyWith(
                  fontFamily: 'monospace',
                  letterSpacing: 8,
                ),
          ),
          const SizedBox(height: 8),
          const Text('Enter this on the remote device.'),
        ],
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}
