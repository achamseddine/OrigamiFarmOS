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

  /// Modules this user holds — what the navigation is built from.
  ///
  /// This used to also require the farm to have licensed the module.
  /// Origami is one subscription covering every module now, so that half
  /// of the test could only ever pass — and worse, a tablet still holding
  /// a catalog it cached under the old model would keep hiding screens
  /// the farm had paid for until it managed to fetch a fresh one.
  List<ModuleCatalogEntry> get availableModules =>
      _catalog.where((m) => _access.canView(m.code)).toList();

  ModuleCatalogEntry? moduleByCode(String code) {
    for (final m in _catalog) {
      if (m.code == code) return m;
    }
    return null;
  }

  String moduleLabel(String code, String languageCode) => moduleByCode(code)?.label(languageCode) ?? code.replaceAll('_', ' ');

  /// True when this user holds the module. Nothing else: every farm has
  /// every module, including what used to be the Mouneh and Visits paid
  /// add-ons.
  bool isModuleAvailable(String code) => _access.canView(code);

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
