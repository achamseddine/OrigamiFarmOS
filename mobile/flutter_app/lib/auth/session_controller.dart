import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../api/api_client.dart';
import '../domain/entities/user_profile.dart';

enum SessionStatus { checking, loggedOut, loggedIn }

/// Default backend for local development. A real deployment must change
/// this to a reachable host (tablet hardware can't reach `localhost`) —
/// use the "Server" field on the login screen, which persists whatever
/// URL is entered.
const String kDefaultApiBaseUrl = 'http://10.0.2.2:8000/api/v1';

const _tokenPrefsKey = 'auth_token';
const _baseUrlPrefsKey = 'api_base_url';

/// Owns the single login: this app has no offline mode and no demo data,
/// so every screen is empty/locked until this reports [SessionStatus.loggedIn].
/// "Log in once, stay logged in" — the bearer token is persisted and
/// silently re-validated against `/auth/me` on the next launch, so a
/// farm worker only sees the login screen once per install (until they
/// explicitly log out).
class SessionController extends ChangeNotifier {
  SessionController() : apiClient = ApiClient(baseUrl: kDefaultApiBaseUrl);

  final ApiClient apiClient;
  SessionStatus status = SessionStatus.checking;
  UserProfile? user;
  String? error;
  bool busy = false;

  String get baseUrl => apiClient.baseUrl;

  Future<void> restore() async {
    final prefs = await SharedPreferences.getInstance();
    final savedBaseUrl = prefs.getString(_baseUrlPrefsKey);
    if (savedBaseUrl != null && savedBaseUrl.isNotEmpty) {
      apiClient.updateBaseUrl(savedBaseUrl);
    }
    final token = prefs.getString(_tokenPrefsKey);
    if (token == null || token.isEmpty) {
      status = SessionStatus.loggedOut;
      notifyListeners();
      return;
    }
    apiClient.token = token;
    try {
      final json = await apiClient.get('/auth/me') as Map<String, dynamic>;
      user = UserProfile.fromJson(json);
      status = SessionStatus.loggedIn;
    } on ApiException {
      apiClient.token = null;
      await prefs.remove(_tokenPrefsKey);
      status = SessionStatus.loggedOut;
    }
    notifyListeners();
  }

  Future<void> setBaseUrl(String url) async {
    apiClient.updateBaseUrl(url);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_baseUrlPrefsKey, apiClient.baseUrl);
  }

  Future<bool> login({required String email, required String password, String? serverUrl}) async {
    if (serverUrl != null && serverUrl.trim().isNotEmpty) {
      await setBaseUrl(serverUrl.trim());
    }
    busy = true;
    error = null;
    notifyListeners();
    try {
      final json = await apiClient.post('/auth/login', body: {'email': email.trim(), 'password': password}) as Map<String, dynamic>;
      apiClient.token = json['access_token'] as String;
      user = UserProfile.fromJson(json['user'] as Map<String, dynamic>);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_tokenPrefsKey, apiClient.token!);
      status = SessionStatus.loggedIn;
      return true;
    } on ApiException catch (e) {
      error = e.message;
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> logout() async {
    apiClient.token = null;
    user = null;
    status = SessionStatus.loggedOut;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenPrefsKey);
    notifyListeners();
  }
}
