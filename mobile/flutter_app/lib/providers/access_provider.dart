import 'package:flutter/foundation.dart';
import '../api/api_client.dart';
import '../domain/entities/access.dart';

/// The signed-in user's module responsibilities and permissions.
///
/// Loaded once at sign-in and read synchronously everywhere else, so a
/// screen can ask `access.canCreate(FarmModule.animals)` while building
/// without awaiting anything. The backend re-checks every request, so this
/// only decides what to *show*.
class AccessProvider extends ChangeNotifier {
  AccessProvider({required ApiClient apiClient}) : _api = apiClient;

  final ApiClient _api;
  UserAccess _access = UserAccess.empty;
  List<ModuleCatalogEntry> _catalog = [];
  bool loading = false;

  UserAccess get access => _access;
  List<ModuleCatalogEntry> get catalog => List.unmodifiable(_catalog);

  /// Modules this farm has licensed and this user holds — what the
  /// navigation is built from.
  List<ModuleCatalogEntry> get availableModules =>
      _catalog.where((m) => m.licensedActive && _access.canView(m.code)).toList();

  ModuleCatalogEntry? moduleByCode(String code) {
    for (final m in _catalog) {
      if (m.code == code) return m;
    }
    return null;
  }

  String moduleLabel(String code, String languageCode) => moduleByCode(code)?.label(languageCode) ?? code.replaceAll('_', ' ');

  /// True when the farm has licensed the module *and* the user holds it —
  /// the Mouneh and Visits add-ons need both.
  bool isModuleAvailable(String code) {
    final entry = moduleByCode(code);
    if (entry != null && !entry.licensedActive) return false;
    return _access.canView(code);
  }

  bool can(String moduleCode, String action) => _access.can(moduleCode, action);
  bool canView(String moduleCode) => _access.canView(moduleCode);
  bool canCreate(String moduleCode) => _access.canCreate(moduleCode);
  bool canEdit(String moduleCode) => _access.canEdit(moduleCode);
  bool canDelete(String moduleCode) => _access.canDelete(moduleCode);
  bool canAssign(String moduleCode) => _access.canAssign(moduleCode);
  bool get isFullAccess => _access.fullAccess;

  Future<void> load() async {
    loading = true;
    notifyListeners();
    try {
      final results = await Future.wait([
        _api.get('/me/access'),
        _api.get('/modules/catalog'),
      ]);
      _access = UserAccess.fromJson(results[0] as Map<String, dynamic>);
      _catalog = (results[1] as List<dynamic>).map((e) => ModuleCatalogEntry.fromJson(e as Map<String, dynamic>)).toList();
    } finally {
      loading = false;
      notifyListeners();
    }
  }
}
