import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../api/api_client.dart';
import '../data/local/local_store.dart';
import '../domain/entities/user_profile.dart';

enum SessionStatus { checking, loggedOut, loggedIn }

/// Default backend for local development. A real deployment must change
/// this to a reachable host (tablet hardware can't reach `localhost`) —
/// use the "Server" field on the login screen, which persists whatever
/// URL is entered.
const String kDefaultApiBaseUrl = 'http://10.0.2.2:8000/api/v1';

const _tokenPrefsKey = 'auth_token';
const _baseUrlPrefsKey = 'api_base_url';

/// Owns the single login.
///
/// **Online the first time, offline afterwards.** Signing in needs a
/// reachable server — there is no way to verify a password or issue a
/// token without one, and a tablet that let anyone in offline would be a
/// hole, not a feature. Everything after that is designed to work in a
/// field with no signal: the token is persisted, the profile and the
/// permission set are cached by [ApiClient], and a launch with no
/// connection restores the session from that cache instead of throwing
/// the worker back to a login screen they cannot get past.
class SessionController extends ChangeNotifier {
  SessionController({LocalStore? store})
      : _store = store,
        apiClient = ApiClient(baseUrl: kDefaultApiBaseUrl, store: store);

  final ApiClient apiClient;
  final LocalStore? _store;
  SessionStatus status = SessionStatus.checking;
  UserProfile? user;
  String? error;
  bool busy = false;

  /// True when a session exists but is running on cached credentials
  /// because the server could not be reached at launch.
  bool restoredOffline = false;

  /// Set when the tablet has never been online with this install: there
  /// is nothing cached to fall back on, and the login screen has to say
  /// so rather than showing "wrong password".
  bool needsFirstOnlineLogin = false;

  String get baseUrl => apiClient.baseUrl;
  bool get online => apiClient.monitor.online;

  Future<void> restore() async {
    final prefs = await _prefs();
    final savedBaseUrl = prefs?.getString(_baseUrlPrefsKey);
    if (savedBaseUrl != null && savedBaseUrl.isNotEmpty) {
      apiClient.updateBaseUrl(savedBaseUrl);
    }
    final token = prefs?.getString(_tokenPrefsKey);
    if (token == null || token.isEmpty) {
      status = SessionStatus.loggedOut;
      notifyListeners();
      return;
    }
    apiClient.token = token;
    try {
      // Served from the network when there is one, from the cache written
      // at the last successful launch when there isn't.
      final json = await apiClient.get('/auth/me') as Map<String, dynamic>;
      user = UserProfile.fromJson(json);
      await _store?.setActiveUser(user!.id);
      restoredOffline = apiClient.monitor.offline;
      status = SessionStatus.loggedIn;
    } on ApiException catch (e) {
      if (e.isOffline) {
        // No route to the server *and* nothing cached — this install has
        // never completed a sign-in. Keep the token (it may still be
        // valid) and let the login screen explain what is needed.
        needsFirstOnlineLogin = true;
        status = SessionStatus.loggedOut;
      } else {
        // The server answered and rejected the token: genuinely signed out.
        apiClient.token = null;
        await prefs?.remove(_tokenPrefsKey);
        await _store?.clearCachedFarmData();
        status = SessionStatus.loggedOut;
      }
    }
    notifyListeners();
  }

  Future<void> setBaseUrl(String url) async {
    apiClient.updateBaseUrl(url);
    final prefs = await _prefs();
    await prefs?.setString(_baseUrlPrefsKey, apiClient.baseUrl);
  }

  Future<bool> login({required String email, required String password, String? serverUrl}) async {
    if (serverUrl != null && serverUrl.trim().isNotEmpty) {
      await setBaseUrl(serverUrl.trim());
    }
    busy = true;
    error = null;
    notifyListeners();
    try {
      // Never queued: a sign-in that "succeeded" offline would hand out a
      // session nobody authenticated.
      final json =
          await apiClient.authenticate('/auth/login', body: {'email': email.trim(), 'password': password}) as Map<String, dynamic>;
      apiClient.token = json['access_token'] as String;
      final profile = json['user'] as Map<String, dynamic>;
      user = UserProfile.fromJson(profile);
      final prefs = await _prefs();
      await prefs?.setString(_tokenPrefsKey, apiClient.token!);
      await _store?.setActiveUser(user!.id);
      // Seed the profile cache so the very next launch works offline even
      // if the tablet never gets another chance to call `/auth/me`.
      await _store?.writeCache(LocalStore.cacheKey('/auth/me', null), profile);
      needsFirstOnlineLogin = false;
      restoredOffline = false;
      status = SessionStatus.loggedIn;
      return true;
    } on ApiException catch (e) {
      error = e.isOffline
          ? "Signing in needs the farm network. Connect once and the tablet will work offline afterwards."
          : e.message;
      needsFirstOnlineLogin = e.isOffline;
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// How many of this user's records are still waiting to be sent — what
  /// the sign-out confirmation is built on, so nobody hands the tablet
  /// over with a morning's work still on it.
  Future<int> unsyncedCount() async => await _store?.pendingCount() ?? 0;

  Future<void> logout() async {
    apiClient.token = null;
    user = null;
    status = SessionStatus.loggedOut;
    restoredOffline = false;
    final prefs = await _prefs();
    await prefs?.remove(_tokenPrefsKey);
    // Cached farm data goes; the outbox stays, tagged with the user who
    // recorded it, and syncs when they sign back in.
    await _store?.clearCachedFarmData();
    notifyListeners();
  }

  /// `shared_preferences` has no platform channel in the `flutter test`
  /// VM. Returning null there keeps the app renderable in tests.
  Future<SharedPreferences?> _prefs() async {
    try {
      return await SharedPreferences.getInstance();
    } catch (_) {
      return null;
    }
  }
}
