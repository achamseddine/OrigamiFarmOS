import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Signing in on a tablet that cannot reach the farm server (audit I-10,
/// architecture/ADR-007-OFFLINE-SIGN-IN.md).
///
/// After a sign-in the server accepted, the tablet keeps — for that server
/// and that email only — a salted PBKDF2-HMAC-SHA256 check of the password
/// and the profile the server returned. Never the password, never the
/// server's token: an offline session can read this user's cached farm and
/// queue records, and nothing it holds can reach the server. Its records
/// are sent after the next sign-in the server accepts.
///
/// The check expires [validity] after the last sign-in the server
/// accepted; a refused sign-in (password changed, account revoked) or a
/// sign-out forgets it. Not used in a browser (no device-private storage).
class OfflineCredentials {
  OfflineCredentials({
    Future<SharedPreferences?> Function()? prefs,
    DateTime Function()? clock,
    this.validity = const Duration(days: 7),
    this.iterations = 20000,
  })  : _prefs = prefs ?? _defaultPrefs,
        _clock = clock ?? DateTime.now;

  final Future<SharedPreferences?> Function() _prefs;
  final DateTime Function() _clock;
  final Duration validity;
  final int iterations;

  static const _key = 'offline_credentials_v1';

  static Future<SharedPreferences?> _defaultPrefs() async {
    try {
      return await SharedPreferences.getInstance();
    } catch (_) {
      return null;
    }
  }

  static String _id(String server, String email) => '${server.trim().toLowerCase()}|${email.trim().toLowerCase()}';

  Future<Map<String, dynamic>> _all() async {
    final raw = (await _prefs())?.getString(_key);
    if (raw == null) return {};
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> ? decoded : {};
    } catch (_) {
      return {};
    }
  }

  Future<void> _save(Map<String, dynamic> all) async {
    final prefs = await _prefs();
    if (prefs == null) return;
    if (all.isEmpty) {
      await prefs.remove(_key);
    } else {
      await prefs.setString(_key, jsonEncode(all));
    }
  }

  /// After a sign-in the server accepted: what lets this user back in
  /// offline on this tablet, until [validity] has passed.
  Future<void> remember({required String server, required String email, required String password, required Map<String, dynamic> profile}) async {
    final salt = _salt();
    final all = await _all();
    all[_id(server, email)] = {
      'salt': base64Encode(salt),
      'verifier': base64Encode(pbkdf2(utf8.encode(password), salt, iterations)),
      'iterations': iterations,
      'profile': profile,
      'user_id': profile['id'],
      'verified_at': _clock().toUtc().toIso8601String(),
    };
    await _save(all);
  }

  /// The profile to open offline, or why not.
  Future<OfflineUnlock> unlock({required String server, required String email, required String password}) async {
    final entry = (await _all())[_id(server, email)];
    if (entry is! Map) return const OfflineUnlock(OfflineUnlockResult.unknown);
    final verifiedAt = DateTime.tryParse('${entry['verified_at']}');
    if (verifiedAt == null || _clock().toUtc().difference(verifiedAt) > validity) {
      return OfflineUnlock(OfflineUnlockResult.expired, verifiedAt: verifiedAt);
    }
    try {
      final salt = base64Decode('${entry['salt']}');
      final expected = base64Decode('${entry['verifier']}');
      final given = pbkdf2(utf8.encode(password), salt, (entry['iterations'] as num?)?.toInt() ?? iterations);
      if (!_same(given, expected)) return OfflineUnlock(OfflineUnlockResult.wrongPassword, verifiedAt: verifiedAt);
    } catch (_) {
      return const OfflineUnlock(OfflineUnlockResult.unknown);
    }
    final profile = entry['profile'];
    if (profile is! Map) return const OfflineUnlock(OfflineUnlockResult.unknown);
    return OfflineUnlock(OfflineUnlockResult.ok, profile: profile.cast<String, dynamic>(), verifiedAt: verifiedAt);
  }

  /// The server refused this email (password changed, account revoked).
  Future<void> forget({required String server, required String email}) async {
    final all = await _all();
    if (all.remove(_id(server, email)) != null) await _save(all);
  }

  /// Signed out: this user can no longer open the tablet offline.
  Future<void> forgetUser(String userId) async {
    final all = await _all();
    final before = all.length;
    all.removeWhere((_, v) => v is Map && v['user_id'] == userId);
    if (all.length != before) await _save(all);
  }

  static Uint8List _salt() {
    final r = Random.secure();
    return Uint8List.fromList(List<int>.generate(16, (_) => r.nextInt(256)));
  }

  /// PBKDF2-HMAC-SHA256, one 32-byte block (RFC 8018).
  static Uint8List pbkdf2(List<int> password, List<int> salt, int iterations) {
    final hmac = Hmac(sha256, password);
    var u = hmac.convert([...salt, 0, 0, 0, 1]).bytes;
    final out = Uint8List.fromList(u);
    for (var i = 1; i < iterations; i++) {
      u = hmac.convert(u).bytes;
      for (var j = 0; j < out.length; j++) {
        out[j] ^= u[j];
      }
    }
    return out;
  }

  static bool _same(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}

enum OfflineUnlockResult { ok, unknown, wrongPassword, expired }

class OfflineUnlock {
  const OfflineUnlock(this.result, {this.profile, this.verifiedAt});
  final OfflineUnlockResult result;
  final Map<String, dynamic>? profile;

  /// The last sign-in the server accepted.
  final DateTime? verifiedAt;
}
