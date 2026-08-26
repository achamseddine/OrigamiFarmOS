/// Employee records and their module responsibilities (backend
/// `app/schemas/employees.py`).
library;

/// One module an employee is responsible for, and what they may do in it.
class ModulePermission {
  const ModulePermission({
    required this.moduleCode,
    this.canView = true,
    this.canCreate = false,
    this.canEdit = false,
    this.canDelete = false,
    this.canApprove = false,
    this.canExport = false,
    this.canAssign = false,
    this.canConfigure = false,
  });

  final String moduleCode;
  final bool canView;
  final bool canCreate;
  final bool canEdit;
  final bool canDelete;
  final bool canApprove;
  final bool canExport;
  final bool canAssign;
  final bool canConfigure;

  /// The day-to-day grant a new responsibility starts at: do the work,
  /// but not delete history, approve, or reconfigure the module.
  static ModulePermission defaultFor(String moduleCode) =>
      ModulePermission(moduleCode: moduleCode, canView: true, canCreate: true, canEdit: true);

  bool byAction(String action) => switch (action) {
        'view' => canView,
        'create' => canCreate,
        'edit' => canEdit,
        'delete' => canDelete,
        'approve' => canApprove,
        'export' => canExport,
        'assign' => canAssign,
        'configure' => canConfigure,
        _ => false,
      };

  ModulePermission withAction(String action, bool value) => ModulePermission(
        moduleCode: moduleCode,
        canView: action == 'view' ? value : canView,
        canCreate: action == 'create' ? value : canCreate,
        canEdit: action == 'edit' ? value : canEdit,
        canDelete: action == 'delete' ? value : canDelete,
        canApprove: action == 'approve' ? value : canApprove,
        canExport: action == 'export' ? value : canExport,
        canAssign: action == 'assign' ? value : canAssign,
        canConfigure: action == 'configure' ? value : canConfigure,
      );

  Map<String, dynamic> toJson() => {
        'module_code': moduleCode,
        'can_view': canView,
        'can_create': canCreate,
        'can_edit': canEdit,
        'can_delete': canDelete,
        'can_approve': canApprove,
        'can_export': canExport,
        'can_assign': canAssign,
        'can_configure': canConfigure,
      };

  factory ModulePermission.fromJson(Map<String, dynamic> json) => ModulePermission(
        moduleCode: json['module_code'] as String,
        canView: json['can_view'] as bool? ?? false,
        canCreate: json['can_create'] as bool? ?? false,
        canEdit: json['can_edit'] as bool? ?? false,
        canDelete: json['can_delete'] as bool? ?? false,
        canApprove: json['can_approve'] as bool? ?? false,
        canExport: json['can_export'] as bool? ?? false,
        canAssign: json['can_assign'] as bool? ?? false,
        canConfigure: json['can_configure'] as bool? ?? false,
      );
}

class Employee {
  const Employee({
    required this.id,
    required this.farmId,
    required this.name,
    this.email,
    this.phone,
    required this.role,
    this.department,
    required this.language,
    required this.active,
    this.jobTitle,
    required this.employmentStatus,
    this.startDate,
    this.photoPath,
    this.workingDays,
    this.workingHours,
    this.notes,
    this.permissions = const [],
    this.fullAccess = false,
  });

  final String id;
  final String farmId;
  final String name;
  final String? email;
  final String? phone;
  final String role;
  final String? department;
  final String language;
  final bool active;
  final String? jobTitle;
  final String employmentStatus;
  final DateTime? startDate;
  final String? photoPath;
  final List<String>? workingDays;
  final String? workingHours;
  final String? notes;
  final List<ModulePermission> permissions;

  /// True for owner/manager — they hold every module implicitly, so their
  /// permission list is empty by design rather than by omission.
  final bool fullAccess;

  String get initials => name.trim().isEmpty ? '?' : name.trim().characters.first.toUpperCase();

  ModulePermission? permissionFor(String moduleCode) {
    for (final p in permissions) {
      if (p.moduleCode == moduleCode) return p;
    }
    return null;
  }

  factory Employee.fromJson(Map<String, dynamic> json) => Employee(
        id: json['id'] as String,
        farmId: json['farm_id'] as String,
        name: json['name'] as String,
        email: json['email'] as String?,
        phone: json['phone'] as String?,
        role: json['role'] as String,
        department: json['department'] as String?,
        language: json['language'] as String? ?? 'en',
        active: json['active'] as bool? ?? true,
        jobTitle: json['job_title'] as String?,
        employmentStatus: json['employment_status'] as String? ?? 'active',
        startDate: json['start_date'] != null ? DateTime.tryParse(json['start_date'] as String) : null,
        photoPath: json['photo_path'] as String?,
        workingDays: (json['working_days'] as List<dynamic>?)?.map((e) => e as String).toList(),
        workingHours: json['working_hours'] as String?,
        notes: json['notes'] as String?,
        permissions: (json['permissions'] as List<dynamic>? ?? [])
            .map((e) => ModulePermission.fromJson(e as Map<String, dynamic>))
            .toList(),
        fullAccess: json['full_access'] as bool? ?? false,
      );
}

/// Roles an employee account can hold. `owner`/`manager` carry full farm
/// access; the rest are scoped by their module grants.
const List<String> kAssignableRoles = [
  'manager',
  'worker',
  'veterinarian',
  'accountant',
  'mouneh_operator',
  'visitor_coordinator',
  'activity_staff',
  'cashier',
  'read_only',
];

const List<String> kEmploymentStatuses = ['active', 'on_leave', 'seasonal', 'suspended', 'ended'];

const List<String> kWeekdays = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
