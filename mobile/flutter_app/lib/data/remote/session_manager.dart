import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/config/app_config.dart';

/// Holds the FarmOS tablet contract's own auth session (`POST /auth/login`
/// — see docs/FARMOS_API.md "Auth: a second, independent system") and the
/// configurable server base URL, persisted across restarts.
///
/// No saved session = demo mode: every repository falls back to the local
/// SQLite demo seed / in-memory [DemoData](../demo/demo_data.dart), exactly
/// as this app worked before it could reach a real server. A saved session
/// is what turns bootstrap-from-API and background sync on.
class SessionManager extends ChangeNotifier {
  static const _kToken = 'farmos.session.token';
  static const _kFarmId = 'farmos.session.farmId';
  static const _kUserId = 'farmos.session.userId';
  static const _kDisplayName = 'farmos.session.displayName';
  static const _kRole = 'farmos.session.role';
  static const _kBaseUrl = 'farmos.session.baseUrl';

  String? _token;
  String? _farmId;
  String? _userId;
  String? _displayName;
  String? _role;
  String _baseUrl = AppConfig.defaultApiBaseUrl;
  bool _loaded = false;

  /// The farm every local row is written under and read back by when
  /// nobody is signed in — the demo dataset's own farm (see
  /// `data/demo/demo_data.dart` and `data/local/demo_seed.dart`). Demo mode
  /// is treated as just another farm id rather than "no farm", so the same
  /// scoping rules apply to it and there is no unscoped code path.
  static const String demoFarmId = 'farm-origami';

  String? get token => _token;
  String? get farmId => _farmId;
  String? get userId => _userId;
  String? get displayName => _displayName;
  String? get role => _role;
  String get baseUrl => _baseUrl;
  bool get loaded => _loaded;
  bool get isLoggedIn => _token != null && _farmId != null;

  /// The farm whose data this device may currently read and write.
  ///
  /// Every local SQLite read/write and every sync push is scoped to this,
  /// so one farmer's data can never surface for another on a shared
  /// tablet: signed in, it's their own farm; signed out, it's the demo
  /// farm and nothing else.
  String get activeFarmId => _farmId ?? demoFarmId;

  /// Reads any previously-saved session. Safe to call once at startup
  /// before the first frame that needs [isLoggedIn] — see `app/app.dart`.
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _token = prefs.getString(_kToken);
    _farmId = prefs.getString(_kFarmId);
    _userId = prefs.getString(_kUserId);
    _displayName = prefs.getString(_kDisplayName);
    _role = prefs.getString(_kRole);
    _baseUrl = prefs.getString(_kBaseUrl) ?? AppConfig.defaultApiBaseUrl;
    _loaded = true;
    notifyListeners();
  }

  Future<void> setBaseUrl(String url) async {
    _baseUrl = url.trim().isEmpty ? AppConfig.defaultApiBaseUrl : url.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kBaseUrl, _baseUrl);
    notifyListeners();
  }

  Future<void> saveSession({
    required String token,
    required String farmId,
    required String userId,
    required String displayName,
    required String role,
  }) async {
    _token = token;
    _farmId = farmId;
    _userId = userId;
    _displayName = displayName;
    _role = role;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kToken, token);
    await prefs.setString(_kFarmId, farmId);
    await prefs.setString(_kUserId, userId);
    await prefs.setString(_kDisplayName, displayName);
    await prefs.setString(_kRole, role);
    notifyListeners();
  }

  Future<void> signOut() async {
    _token = null;
    _farmId = null;
    _userId = null;
    _displayName = null;
    _role = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kToken);
    await prefs.remove(_kFarmId);
    await prefs.remove(_kUserId);
    await prefs.remove(_kDisplayName);
    await prefs.remove(_kRole);
    notifyListeners();
  }
}
