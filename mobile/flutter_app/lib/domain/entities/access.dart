/// What the signed-in user is allowed to do (backend `MyAccessOut`, see
/// `app/schemas/employees.py`). The tablet builds its navigation and hides
/// its action buttons from this — the backend enforces the same rules on
/// every request, so hiding a button is a courtesy, never the only guard.
library;

/// Action names, matching `app/core/permissions.py`.
class PermissionAction {
  static const view = 'view';
  static const create = 'create';
  static const edit = 'edit';
  static const delete = 'delete';
  static const approve = 'approve';
  static const export = 'export';
  static const assign = 'assign';
  static const configure = 'configure';

  static const all = [view, create, edit, delete, approve, export, assign, configure];
}

/// Module codes, matching `app/core/permissions.py`. Kept as constants
/// rather than an enum so an unknown module coming back from a newer
/// backend degrades to "not held" instead of throwing.
class FarmModule {
  static const morningOperations = 'morning_operations';
  static const animals = 'animals';
  static const animalHealth = 'animal_health';
  static const feedNutrition = 'feed_nutrition';
  static const inventory = 'inventory';
  static const milkProduction = 'milk_production';
  static const eggProduction = 'egg_production';
  static const agriculture = 'agriculture';
  static const produceHarvest = 'produce_harvest';
  static const mounehProduction = 'mouneh_production';
  static const mounehInventory = 'mouneh_inventory';
  static const sales = 'sales';
  static const expenses = 'expenses';
  static const finance = 'finance';
  static const farmVisits = 'farm_visits';
  static const employees = 'employees';
  static const tasks = 'tasks';
  static const reports = 'reports';
  static const aiIntelligence = 'ai_intelligence';
  static const settings = 'settings';
}

/// One module in the product catalog, with this farm's licence state.
class ModuleCatalogEntry {
  const ModuleCatalogEntry({
    required this.code,
    required this.labelEn,
    required this.labelAr,
    required this.group,
    this.licenseCode,
    this.licensedActive = true,
  });

  final String code;
  final String labelEn;
  final String labelAr;
  final String group;
  final String? licenseCode;
  final bool licensedActive;

  String label(String languageCode) => languageCode == 'ar' ? labelAr : labelEn;

  factory ModuleCatalogEntry.fromJson(Map<String, dynamic> json) => ModuleCatalogEntry(
        code: json['code'] as String,
        labelEn: json['label_en'] as String,
        labelAr: json['label_ar'] as String,
        group: json['group'] as String? ?? 'other',
        licenseCode: json['license_code'] as String?,
        licensedActive: json['licensed_active'] as bool? ?? true,
      );
}

/// The signed-in user's effective permissions.
class UserAccess {
  const UserAccess({required this.userId, required this.role, required this.fullAccess, required this.modules});

  final String userId;
  final String role;

  /// True for owner/manager — every module, every action, no rows needed
  /// (tech spec §7: the manager can always act personally).
  final bool fullAccess;

  /// module code -> {action -> allowed}.
  final Map<String, Map<String, bool>> modules;

  /// Nothing granted yet — what every screen sees before [load] returns.
  static const empty = UserAccess(userId: '', role: '', fullAccess: false, modules: {});

  bool can(String moduleCode, String action) {
    if (fullAccess) return true;
    return modules[moduleCode]?[action] ?? false;
  }

  bool canView(String moduleCode) => can(moduleCode, PermissionAction.view);
  bool canCreate(String moduleCode) => can(moduleCode, PermissionAction.create);
  bool canEdit(String moduleCode) => can(moduleCode, PermissionAction.edit);
  bool canDelete(String moduleCode) => can(moduleCode, PermissionAction.delete);
  bool canAssign(String moduleCode) => can(moduleCode, PermissionAction.assign);

  /// True when the user holds *any* of these modules — for a screen that
  /// several modules can reach (the Animals screen serves Animals, Health
  /// and Milk, for instance).
  bool canViewAny(List<String> moduleCodes) => moduleCodes.any(canView);

  List<String> get heldModules => fullAccess ? const [] : modules.keys.toList();

  factory UserAccess.fromJson(Map<String, dynamic> json) {
    final raw = (json['modules'] as Map<String, dynamic>? ?? {});
    return UserAccess(
      userId: json['user_id'] as String? ?? '',
      role: json['role'] as String? ?? '',
      fullAccess: json['full_access'] as bool? ?? false,
      modules: {
        for (final entry in raw.entries)
          entry.key: {
            for (final action in (entry.value as Map<String, dynamic>).entries) action.key: action.value as bool? ?? false,
          },
      },
    );
  }
}
