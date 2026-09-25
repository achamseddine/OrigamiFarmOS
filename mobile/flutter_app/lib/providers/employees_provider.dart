import 'package:flutter/foundation.dart';
import '../api/api_client.dart';
import '../domain/entities/employee.dart';
import '../domain/entities/notification.dart';

/// Employees & Responsibilities (tech spec §8/§9/§11) plus the Audit
/// History (§23) — both manager-facing, both driven by the same screen.
class EmployeesProvider extends ChangeNotifier {
  EmployeesProvider({required ApiClient apiClient}) : _api = apiClient;

  final ApiClient _api;
  List<Employee> _employees = [];
  List<AuditEvent> _audit = [];
  bool loading = false;
  String? error;

  List<Employee> get employees => List.unmodifiable(_employees);
  List<Employee> get activeEmployees => _employees.where((e) => e.active).toList();
  List<AuditEvent> get auditEvents => List.unmodifiable(_audit);

  Employee? byId(String id) {
    for (final e in _employees) {
      if (e.id == id) return e;
    }
    return null;
  }

  Future<void> load({bool includeInactive = false}) async {
    loading = true;
    error = null;
    notifyListeners();
    try {
      final json = await _api.get('/employees', query: {'include_inactive': includeInactive}) as List<dynamic>;
      _employees = json.map((e) => Employee.fromJson(e as Map<String, dynamic>)).toList();
    } on ApiException catch (e) {
      error = e.message;
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<WriteResult> createEmployee({
    required String name,
    required String password,
    String? email,
    String? phone,
    String role = 'worker',
    String? department,
    String? jobTitle,
    String employmentStatus = 'active',
    DateTime? startDate,
    List<String>? workingDays,
    String? workingHours,
    String? notes,
    List<ModulePermission>? permissions,
  }) async {
    final result = await _api.write(() => _api.post('/employees', body: {
          'name': name,
          'password': password,
          'email': email,
          'phone': phone,
          'role': role,
          'department': department,
          'job_title': jobTitle,
          'employment_status': employmentStatus,
          'start_date': startDate?.toIso8601String(),
          'working_days': workingDays,
          'working_hours': workingHours,
          'notes': notes,
          if (permissions != null) 'permissions': [for (final p in permissions) p.toJson()],
        }));
    if (result.success) await load();
    return result;
  }

  Future<WriteResult> updateEmployee(String id, Map<String, dynamic> changes) async {
    final result = await _api.write(() => _api.patch('/employees/$id', body: changes));
    if (result.success) await load();
    return result;
  }

  Future<WriteResult> deactivate(String id) async {
    final result = await _api.write(() => _api.delete('/employees/$id'));
    if (result.success) await load();
    return result;
  }

  /// Replaces the employee's whole responsibility set — anything not sent
  /// is revoked, which is what the permission matrix means when it saves.
  Future<WriteResult> setPermissions(String id, List<ModulePermission> permissions) async {
    final result = await _api.write(() => _api.put('/employees/$id/permissions', body: {
          'permissions': [for (final p in permissions) p.toJson()],
        }));
    if (result.success) await load();
    return result;
  }

  Future<void> loadAudit({String? entityType, String? entityId, String? module, String? userId}) async {
    try {
      final json = await _api.get('/audit', query: {
        if (entityType != null) 'entity_type': entityType,
        if (entityId != null) 'entity_id': entityId,
        if (module != null) 'module': module,
        if (userId != null) 'user_id': userId,
      }) as List<dynamic>;
      _audit = json.map((e) => AuditEvent.fromJson(e as Map<String, dynamic>)).toList();
      notifyListeners();
    } on ApiException catch (e) {
      error = e.message;
      notifyListeners();
    }
  }
}
