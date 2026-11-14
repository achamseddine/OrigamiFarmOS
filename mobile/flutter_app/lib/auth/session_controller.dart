import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../api/api_client.dart';
import '../app/build_info.dart';
import '../app/install_id.dart';
import '../data/local/demo_mode.dart';
import '../data/local/local_store.dart';
import '../domain/entities/user_profile.dart';

enum SessionStatus { checking, loggedOut, loggedIn }

/// Default backend for local development. Android emulators can reach the
/// development host through 10.0.2.2; real tablets cannot. A real deployment
/// can supply --dart-define=FARMOS_API_BASE_URL=https://<verified-host>/api/v1
/// at build time, or the user can select "Connecting to a different server?"
/// on the login screen. Never put DATABASE_URL/credentials in this setting.
/// A previously saved server URL in SharedPreferences takes precedence.
const String kDefaultApiBaseUrl = String.fromEnvironment(
  'FARMOS_API_BASE_URL',
  defaultValue: 'http://10.0.2.2:8000/api/v1',
);

const _tokenPrefsKey = 'auth_token';
const _baseUrlPrefsKey = 'api_base_url';

/// Owns the single login, in either of the two modes this app runs in.
///
/// **Against a server: online the first time, offline afterwards.**
/// Signing in needs a reachable server — there is no way to verify a
/// password or issue a token without one, and a tablet that let anyone
/// in offline would be a hole, not a feature. Everything after that is
/// designed to work in a field with no signal: the token is persisted,
/// the profile and the permission set are cached by [ApiClient], and a
/// launch with no connection restores the session from that cache
/// instead of throwing the worker back to a login screen they cannot
/// get past.
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

  /// True when this tablet is running on its own bundled farm with no
  /// server behind it. Screens use it to say so rather than pretending
  /// there is a farm office to sync with.
  bool get standalone => apiClient.standalone;

  // A worker must always be able to reach the credentials form if an old
  // server is asleep or the saved session is corrupt. This only cancels
  // automatic restoration; it never deletes the token, offline farm or outbox.
  bool _restoreCancelled = false;

  void showLoginInstead() {
    _restoreCancelled = true;
    status = SessionStatus.loggedOut;
    notifyListeners();
  }

  Future<void> restore() async {
    SharedPreferences? prefs;
    try {
      prefs = await _prefs();
      if (_restoreCancelled) return;
      final savedBaseUrl = prefs?.getString(_baseUrlPrefsKey);
      if (savedBaseUrl != null && savedBaseUrl.isNotEmpty) {
        apiClient.updateBaseUrl(savedBaseUrl);
      }

      // A standalone farm's open session takes priority over the server.
      final store = _store;
      if (store != null && await DemoMode.hasOpenSession(store)) {
        if (_restoreCancelled) return;
        final profile = await DemoMode.storedProfile(store);
        if (_restoreCancelled) return;
        if (profile != null) {
          _enterStandalone(store, profile);
          notifyListeners();
          return;
        }
      }
      if (_restoreCancelled) return;
      final token = prefs?.getString(_tokenPrefsKey);
      if (token == null || token.isEmpty) {
        status = SessionStatus.loggedOut;
        notifyListeners();
        return;
      }
      apiClient.token = token;

      // Served from the network when reachable, or cached when offline.
      // ApiClient.send has a finite timeout; a failed restore must never
      // leave the sign-in screen hidden behind the boot spinner forever.
      final json = await apiClient.get('/auth/me') as Map<String, dynamic>;
      if (_restoreCancelled) return;
      final profile = UserProfile.fromJson(json);
      await _store?.setActiveUser(profile.id);
      if (_restoreCancelled) return;
      user = profile;
      restoredOffline = apiClient.monitor.offline;
      status = SessionStatus.loggedIn;
    } on ApiException catch (e) {
      if (_restoreCancelled) return;
      if (e.isOffline) {
        // Keep the token and offline outbox; the worker can retry login
        // or choose another server, instead of being trapped at boot.
        needsFirstOnlineLogin = true;
      } else if (e.statusCode == 401 || e.statusCode == 403) {
        // Truly rejected credentials should not be automatically retried
        // on every startup. Keep cached farm records and the outbox, but
        // require a fresh sign-in; setActiveUser isolates a different farm
        // user if they log in.
        apiClient.token = null;
        await prefs?.remove(_tokenPrefsKey);
      } else {
        // A wrong server, 404 or temporary 500 is not an auth rejection:
        // never erase a cached farm because of a deployment problem.
        error = e.message;
      }
      if (_restoreCancelled) return;
      status = SessionStatus.loggedOut;
    } catch (e) {
      if (_restoreCancelled) return;
      // Invalid cached JSON, corrupt saved profile or a storage exception
      // must not strand the user at SessionStatus.checking.
      error = 'Could not restore the saved session: $e';
      status = SessionStatus.loggedOut;
    }
    if (!_restoreCancelled) notifyListeners();
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
      final install = await installId();
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
      final token = json['access_token'];
      if (token is! String || token.isEmpty) {
        error = 'Signed in, but the server sent no token. It may be running an older build.';
        return false;
      }
      final profile = json['user'];
      if (profile is! Map<String, dynamic>) {
        error = 'Signed in, but the server sent no user profile — it is running a build older '
            'than this app. Check ${apiClient.baseUrl}/health for its version.';
        return false;
      }

      apiClient.token = token;
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
    } catch (e) {
      // Anything that is not an ApiException — a malformed response, a
      // type error, a bug in here. Previously these escaped this method
      // entirely and the screen simply did nothing, which is the hardest
      // failure there is to report or diagnose. A sign-in that does not
      // work must always say something, even if all it can say is this.
      error = 'Sign-in failed unexpectedly: $e';
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
