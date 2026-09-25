import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

/// A stable name for this installation of the app on this tablet.
///
/// The server keeps a device list so an operator can answer "which
/// tablets is this customer using" and revoke one that has been lost.
/// Tablets used to arrive on that list by being paired — an admin
/// generated a key and somebody typed it in. With device licences gone
/// nothing was left to create one, so the app puts itself there instead:
/// it sends this id with every sign-in and the server records what it
/// sees.
///
/// Deliberately *not* a hardware identifier. A serial or an Android ID
/// would be a durable handle on a real device that outlives the app, and
/// nothing here needs one — the only question being asked is "is this the
/// same install as last time". Generated once, kept in the same
/// preferences store as the token, and gone when the app is uninstalled.
/// A tablet wiped and set up again is honestly a new one.
const _installIdPrefsKey = 'install_id';

/// Returns this install's id, creating it on first use.
///
/// Returns null rather than throwing when preferences are unavailable:
/// a device list is worth having, and it is not worth failing a farm
/// worker's sign-in over. The server treats a login with no id the same
/// way — it signs them in and records nothing.
Future<String?> installId() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getString(_installIdPrefsKey);
    if (existing != null && existing.isNotEmpty) return existing;

    final fresh = _generate();
    await prefs.setString(_installIdPrefsKey, fresh);
    return fresh;
  } catch (_) {
    return null;
  }
}

/// 128 bits of randomness, hex, prefixed so it is recognisable in a log
/// or a console column as an install rather than a row id.
String _generate() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return 'ins-$hex';
}
