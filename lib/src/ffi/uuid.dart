/// UUID normalisation for strings handed to BlueZ.
library;

const _baseSuffix = '-0000-1000-8000-00805f9b34fb';
final _hex = RegExp(r'^[0-9a-f]+$');

/// The lower case, 128-bit form BlueZ uses for [uuid].
///
/// BlueZ compares UUID arguments (ConnectProfile, for one) against its own
/// lower case 128-bit strings, so 'AABB' or '111E' would not match even
/// though BlueZUUID treats them as equal. 16- and 32-bit short forms are
/// expanded with the Bluetooth base UUID. Anything else is only lower-cased
/// and left for BlueZ to accept or reject.
String canonicalUuid(String uuid) {
  final lower = uuid.trim().toLowerCase();
  final short = lower.startsWith('0x') ? lower.substring(2) : lower;
  if (_hex.hasMatch(short)) {
    if (short.length == 4) return '0000$short$_baseSuffix';
    if (short.length == 8) return '$short$_baseSuffix';
  }
  return lower;
}
