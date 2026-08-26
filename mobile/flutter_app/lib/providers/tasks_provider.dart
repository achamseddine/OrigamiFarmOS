import 'package:flutter/foundation.dart';
import '../api/api_client.dart';
import '../domain/entities/task.dart';
import '../domain/entities/user_profile.dart';

/// Tasks are always-online: [load] fetches the farm's tasks (and, for a
/// manager, the staff roster used to assign one) from the backend;
/// [toggle]/[create]/[assign]/[remove] all post straight through and let
/// the backend's own RBAC decide who can do what (an employee assigning
/// a task to someone else gets a 403 surfaced as [WriteResult.error] —
/// see api/deps.py's task-assignment rule).
class TasksProvider extends ChangeNotifier {
  TasksProvider({required ApiClient apiClient, required String farmId, required String currentUserId})
      : _api = apiClient,
        _farmId = farmId,
        _currentUserId = currentUserId;

  final ApiClient _api;
  final String _farmId;
  final String _currentUserId;
  List<FarmTask> _tasks = [];
  List<UserProfile> _roster = [];
  bool loading = false;

  List<FarmTask> get tasks => List.unmodifiable(_tasks);
  List<FarmTask> get myTasks => _tasks.where((t) => t.assignedTo == _currentUserId).toList();
  List<UserProfile> get roster => List.unmodifiable(_roster);
  int get openCount => _tasks.where((t) => t.status != TaskStatus.done).length;

  Future<void> load({bool includeRoster = false}) async {
    loading = true;
    notifyListeners();
    try {
      final json = await _api.get('/tasks', query: {'farm_id': _farmId}) as List<dynamic>;
      _tasks = json.map((e) => FarmTask.fromJson(e as Map<String, dynamic>)).toList();
      if (includeRoster) {
        final users = await _api.get('/users') as List<dynamic>;
        _roster = users.map((e) => UserProfile.fromJson(e as Map<String, dynamic>)).toList();
      }
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> toggle(String taskId) async {
    final index = _tasks.indexWhere((t) => t.id == taskId);
    if (index == -1) return;
    final current = _tasks[index];
    final nextStatus = current.status == TaskStatus.done ? TaskStatus.open : TaskStatus.done;
    final result = await _api.write(() => _api.patch('/tasks/$taskId', body: {'status': taskStatusToApi(nextStatus)}));
    if (result.success) {
      _tasks[index] = current.copyWith(status: nextStatus);
      notifyListeners();
    }
  }

  /// A manager assigning a task to someone else; an employee creating
  /// their own reminder passes no [assignedTo] (or their own id).
  Future<WriteResult> createTask({
    required String title,
    String? description,
    String? assignedTo,
    DateTime? dueAt,
    String priority = 'medium',
    String? sourceType,
    String? sourceId,
  }) async {
    final result = await _api.write(() => _api.post('/tasks', body: {
          'farm_id': _farmId,
          'title': title,
          'description': description,
          'assigned_to': assignedTo,
          'due_at': dueAt?.toIso8601String(),
          'priority': priority,
          'source_type': sourceType,
          'source_id': sourceId,
        }));
    if (result.success) await load();
    return result;
  }

  /// Used by recommendation "Create Task" actions (Health Intelligence).
  Future<void> addFromRecommendation({required String title, required String category, required String sourceId}) async {
    if (_tasks.any((t) => t.sourceId == sourceId)) return;
    await createTask(title: title, description: category, assignedTo: _currentUserId, dueAt: DateTime.now().add(const Duration(hours: 2)), priority: 'high', sourceType: 'recommendation', sourceId: sourceId);
  }

  Future<WriteResult> reassign({required String taskId, required String assignedTo}) async {
    final result = await _api.write(() => _api.patch('/tasks/$taskId', body: {'assigned_to': assignedTo}));
    if (result.success) await load();
    return result;
  }

  Future<WriteResult> remove(String taskId) async {
    final result = await _api.write(() => _api.delete('/tasks/$taskId'));
    if (result.success) {
      _tasks.removeWhere((t) => t.id == taskId);
      notifyListeners();
    }
    return result;
  }
}
