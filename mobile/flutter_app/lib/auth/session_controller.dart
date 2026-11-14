import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../api/api_client.dart';
import '../app/build_info.dart';
import '../app/install_id.dart';
import '../data/local/demo_mode.dart';
import '../data/local/local_store.dart';
import '../domain/entities/user_profile.dart';

enum SessionStatus { checking, loggedOut, loggedIn }

/// Default staging API as explicitly requested for the 2026-11-14
/// on-farm tablet test. This is a *website API endpoint*, not DATABASE_URL.
/// The tablet always starts at the credentials form and never restores
/// a previously cached server address or authorization token on boot.
/// An operator can still choose a different server on the sign-in screen.
/// Server ownership/health must be verified before entering live credentials.
const String kDefaultApiBaseUrl = String.fromEnvironment(
  'FARMOS_API_BASE_URL',
  defaultValue: 'https://leb-container-test-staging.azurewebsites.net/api/v1',
);

const _tokenPrefsKey = 'auth_token';
const _baseUrlPrefsKey = 'api_base_url'; // Saved only after explicit user edits; never loaded on startup.

/// Owns the single login, in either of the two modes this app runs in.
///
/// **Against a server: explicit sign-in every time; offline farm data
/// remains available after sign-in.** This temporary recovery policy
/// deliberately ignores old saved tokens and base URLs at launch so a
/// failed server request can never hide the credential form. Successful
/// sign-in still initializes cached farm data and the offline outbox.
/// Signing in requires a reachable authorized backend.
///
/// **Standalone: no server at all.** There is no deployment yet, so this
/// build also ships a farm inside it (see `data/local/demo_mode.dart`).
/// The demo credential is checked here on the device — not a security
/// boundary, just the way in when there is nothing to ask.
class SessionController extends ChangeNotifier {
  SessionController({LocalStore? store})
      : _store = store,
        apiClient = ApiClient(baseUrl: kDefaultApiBaseUrl, store: store);

  final ApiClient apiClient;
  final LocalStore? _store;
  SessionStatus status = SessionStatus.loggedOut;
  UserProfile? user;
  String? error;
  bool busy = false;

  /// Legacy status flag, always false at launch because sessions are not restored.
  bool restoredOffline = false;

  /// Set when the tablet has never been online with this install: there
  /// is nothing cached to fall back on, and the login screen has to say
  /// so rather than showing "wrong password".
  bool needsFirstOnlineLogin = false;

  String get baseUrl => apiClient.baseUrl;
  bool get online => apiClient.monitor.online;

  /// True when this tablet is running on its own bundled farm with no
  /// server behind it. Screens use it to say so rather than pretending
  /// there is a farm office to sync with.
  bool get standalone => apiClient.standalone;

  // This recovery build intentionally does not restore previous sessions.
  // The credential form must be visible immediately on *every* launch.
  // Existing SQLite response caches, demo data and the offline outbox are
  // retained on disk; only the automatic sign-in behavior is disabled.
  // Keep this method for callers upgrading from the previous API surface.
  void showLoginInstead() {
    status = SessionStatus.loggedOut;
    notifyListeners();
  }

  /// Leave a failed startup without wiping cached farm data, the offline
  /// outbox or any stored demo edits. This is different from explicit logout,
  /// whose existing farm-data clearing semantics are deliberately unchanged.
  void returnToLoginPreservingData() {
    apiClient.token = null;
    apiClient.standalone = false;
    user = null;
    error = null;
    busy = false;
    status = SessionStatus.loggedOut;
    notifyListeners();
  }

  Future<void> restore() async {
    // No preference lookups, saved tokens or network calls on startup.
    // Crucially, do not clear SQLite or delete any pending offline writes.
    apiClient.token = null;
    apiClient.standalone = false;
    user = null;
    status = SessionStatus.loggedOut;
    notifyListeners();
  }

  Future<void> setBaseUrl(String url) async {
    apiClient.updateBaseUrl(url);
    final prefs = await _prefs();
    await prefs?.setString(_baseUrlPrefsKey, apiClient.baseUrl);
  }

  /// Read-only server check; no login credentials or farm records are sent.
  Future<BackendCheck> checkBackend({String? serverUrl}) =>
      apiClient.checkBackend(serverUrl: serverUrl);

  Future<bool> login({required String email, required String password, String? serverUrl}) async {
    busy = true;
    error = null;
    notifyListeners();
    var phase = 'Preparing sign-in';
    try {
      if (serverUrl != null && serverUrl.trim().isNotEmpty) {
        phase = 'Selecting server';
        await setBaseUrl(serverUrl.trim());
      }
      // The standalone demo account. Checked on the device because there
      // is no server to check it against — it opens the bundled farm, it
      // does not protect anything.
      final store = _store;
      if (DemoMode.matches(email, password)) {
        if (store == null || !store.available) {
          error = 'This device has no local storage, so the demo farm cannot be loaded.';
          return false;
        }
        final profile = await DemoMode.activate(store);
        if (profile == null) {
          error = 'The demo farm could not be loaded from this build.';
          return false;
        }
        _enterStandalone(store, profile);
        return true;
      }

      // Never queued: a sign-in that "succeeded" offline would hand out a
      // session nobody authenticated.
      //
      // The three extra fields put this tablet on its farm's device list,
      // which is how an operator sees it at all now that tablets are not
      // paired. All optional, server-side and here: a sign-in must not
      // depend on them, so a device with no readable preferences simply
      // sends nothing and is not listed.
      phase = 'Reading tablet installation ID';
      final install = await installId();
      phase = 'Sending credentials to ${apiClient.baseUrl}/auth/login';
      final json = await apiClient.authenticate('/auth/login', body: {
        'email': email.trim(),
        'password': password,
        if (install != null) 'installation_id': install,
        if (install != null) 'device_name': 'Origami tablet',
        if (install != null) 'app_version': kAppVersion,
      }) as Map<String, dynamic>;

      // Checked rather than cast. A server that answers 200 without one
      // of these fields is running a build this app does not match — a
      // deployment problem, not a sign-in failure, and it has to say so.
      // `json['user'] as Map<String, dynamic>` on a missing field throws
      // a TypeError, which the ApiException handler below does not catch,
      // so the button went dead with a clean 200 in the server log and
      // nothing anywhere to read. That cost about a week.
      phase = 'Checking response from the login endpoint';
      final token = json['access_token'];
      if (token is! String || token.isEmpty) {
        error = 'LOGIN RESPONSE ERROR at ${apiClient.baseUrl}/auth/login: HTTP 200 but response has no access_token. The Azure host may be an unrelated or outdated backend.';
        return false;
      }
      final profile = json['user'];
      if (profile is! Map<String, dynamic>) {
        error = 'LOGIN RESPONSE ERROR at ${apiClient.baseUrl}/auth/login: HTTP 200 but no compatible user object was returned. Check the backend deployment.';
        return false;
      }

      phase = 'Reading returned user profile';
      apiClient.token = token;
      user = UserProfile.fromJson(profile);
      phase = 'Saving the signed-in session';
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
      // Preserve the HTTP code and exact failing endpoint: 401/403 means
      // rejected credentials; 404/405 means wrong/old API; zero means DNS,
      // TLS, timeout or device connectivity. Never include the password.
      error = e.isOffline
          ? 'NETWORK ERROR (HTTP 0) at ${apiClient.baseUrl}/auth/login: ${e.message} '
              'Use "Check API" below to diagnose the server without sending a password.'
          : 'LOGIN ERROR (HTTP ${e.statusCode}) at ${apiClient.baseUrl}/auth/login: ${e.message}';
      needsFirstOnlineLogin = e.isOffline;
      return false;
    } catch (e) {
      // Includes malformed JSON, unexpected user profiles and local
      // storage problems after the server has accepted the credentials.
      error = 'SIGN-IN ERROR at "$phase": ${e.runtimeType}: $e. '
          'Server: ${apiClient.baseUrl}. No password is included in this report.';
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Puts the client into standalone mode and signs the demo user in.
  /// Synchronous on purpose — every caller has already done the awaiting.
  void _enterStandalone(LocalStore store, Map<String, dynamic> profile) {
    apiClient.standalone = true;
    apiClient.token = null;
    user = UserProfile.fromJson(profile);
    store.activeUserId = user!.id;
    needsFirstOnlineLogin = false;
    restoredOffline = false;
    status = SessionStatus.loggedIn;
  }

  /// Throws away everything entered on the demo farm and reloads the
  /// bundled one — for handing the tablet to the next person.
  Future<bool> resetDemoData() async {
    final store = _store;
    if (store == null || !standalone) return false;
    final profile = await DemoMode.reset(store);
    if (profile == null) return false;
    user = UserProfile.fromJson(profile);
    notifyListeners();
    return true;
  }

  /// How many of this user's records are still waiting to be sent — what
  /// the sign-out confirmation is built on, so nobody hands the tablet
  /// over with a morning's work still on it.
  Future<int> unsyncedCount() async => await _store?.pendingCount() ?? 0;

  Future<void> logout() async {
    final wasStandalone = standalone;
    apiClient.token = null;
    apiClient.standalone = false;
    user = null;
    status = SessionStatus.loggedOut;
    restoredOffline = false;
    final prefs = await _prefs();
    await prefs?.remove(_tokenPrefsKey);
    if (wasStandalone) {
      // In standalone the local data *is* the farm, not a cached copy of
      // one. Signing out must not delete it — use "Reset demo data" for
      // that, deliberately.
      await DemoMode.endSession(_store);
      _store?.activeUserId = null;
      notifyListeners();
      return;
    }
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
