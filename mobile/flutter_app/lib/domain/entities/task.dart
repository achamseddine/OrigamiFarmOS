enum TaskPriority { high, medium, low }

enum TaskStatus { open, inProgress, done }

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
