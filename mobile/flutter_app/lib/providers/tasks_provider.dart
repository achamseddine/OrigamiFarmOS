import 'dart:async';
import 'package:flutter/foundation.dart';
import '../data/demo/demo_data.dart';
import '../data/local/farm_write_service.dart';
import '../data/local/local_repository.dart';
import '../domain/entities/task.dart';
import '../sync/sync_queue_controller.dart';

/// Tasks are wired to the real local-first write pipeline: toggling a task
/// updates SQLite, writes an event, and queues a sync item (tech spec
/// milestone M5 "core actions write events").
class TasksProvider extends ChangeNotifier {
  TasksProvider({
    required FarmWriteService writeService,
    required SyncQueueController syncQueue,
    LocalRepository? localRepository,
  })  : _writeService = writeService,
        _syncQueue = syncQueue,
        _localRepository = localRepository ?? LocalRepository(),
        _tasks = List.of(DemoData.todaysTasks) {
    unawaited(reload());
  }

  final FarmWriteService _writeService;
  final SyncQueueController _syncQueue;
  final LocalRepository _localRepository;
  List<FarmTask> _tasks;

  List<FarmTask> get tasks => List.unmodifiable(_tasks);
  int get openCount => _tasks.where((t) => t.status != TaskStatus.done).length;

  /// Re-reads the local SQLite cache (demo-seeded, or server-synced) and
  /// replaces the in-memory list with it — see `AnimalsProvider.reload`.
  Future<void> reload() async {
    try {
      final loaded = await _localRepository.loadTasks();
      if (loaded.isNotEmpty) {
        _tasks = loaded;
        notifyListeners();
      }
    } catch (_) {
      // SQLite unavailable on this platform/target — keep the demo list.
    }
  }

  Future<void> toggle(String taskId) async {
    final index = _tasks.indexWhere((t) => t.id == taskId);
    if (index == -1) return;
    final current = _tasks[index];
    final nextStatus = current.status == TaskStatus.done ? TaskStatus.open : TaskStatus.done;
    _tasks[index] = current.copyWith(status: nextStatus);
    notifyListeners();

    await _writeService.updateTaskStatus(taskId: taskId, status: nextStatus.name);
    _syncQueue.enqueue(entityType: 'task', entityId: taskId, operation: 'update');
  }

  /// Used by recommendation "Create Task" actions (Health Intelligence).
  void addFromRecommendation({required String id, required String title, required String category, required String sourceId}) {
    if (_tasks.any((t) => t.sourceId == sourceId)) return;
    _tasks.insert(
      0,
      FarmTask(
        id: id,
        title: title,
        category: category,
        dueAt: DateTime.now().add(const Duration(hours: 2)),
        priority: TaskPriority.high,
        sourceType: 'recommendation',
        sourceId: sourceId,
      ),
    );
    notifyListeners();
    _syncQueue.enqueue(entityType: 'task', entityId: id, operation: 'create');
  }
}
