enum TaskPriority { high, medium, low }

TaskPriority _priorityFromApi(String v) => switch (v) {
      'high' => TaskPriority.high,
      'low' => TaskPriority.low,
      _ => TaskPriority.medium,
    };

enum TaskStatus { open, inProgress, done }

TaskStatus _statusFromApi(String v) => switch (v) {
      'in_progress' => TaskStatus.inProgress,
      'completed' || 'done' => TaskStatus.done,
      _ => TaskStatus.open,
    };

String taskStatusToApi(TaskStatus s) => switch (s) {
      TaskStatus.open => 'open',
      TaskStatus.inProgress => 'in_progress',
      TaskStatus.done => 'completed',
    };

class FarmTask {
  const FarmTask({
    required this.id,
    required this.title,
    required this.category,
    required this.dueAt,
    this.priority = TaskPriority.medium,
    this.status = TaskStatus.open,
    this.sourceType,
    this.sourceId,
    this.assignedTo,
  });

  final String id;
  final String title;
  final String category;
  final DateTime dueAt;
  final TaskPriority priority;
  final TaskStatus status;
  final String? sourceType; // e.g. 'recommendation'
  final String? sourceId;
  final String? assignedTo;

  /// Backend `TaskOut` shape (schemas/tasks.py). `description` doubles as
  /// this app's "category" label since the API has no separate field for
  /// it — a task created without one just shows "Task".
  factory FarmTask.fromJson(Map<String, dynamic> json) => FarmTask(
        id: json['id'] as String,
        title: json['title'] as String,
        category: (json['description'] as String?) ?? (json['source_type'] as String?) ?? 'Task',
        dueAt: json['due_at'] != null ? DateTime.parse(json['due_at'] as String) : DateTime.now(),
        priority: _priorityFromApi(json['priority'] as String? ?? 'medium'),
        status: _statusFromApi(json['status'] as String? ?? 'open'),
        sourceType: json['source_type'] as String?,
        sourceId: json['source_id'] as String?,
        assignedTo: json['assigned_to'] as String?,
      );

  FarmTask copyWith({TaskStatus? status}) => FarmTask(
        id: id,
        title: title,
        category: category,
        dueAt: dueAt,
        priority: priority,
        status: status ?? this.status,
        sourceType: sourceType,
        sourceId: sourceId,
        assignedTo: assignedTo,
      );
}
