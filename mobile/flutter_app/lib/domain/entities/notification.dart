/// Notification bell + Today's Priorities items (backend
/// `app/schemas/notifications.py`).
///
/// Both carry `entityType`/`entityId`: that pair is what turns a card into
/// a working link. "A displayed alert must navigate to the object that
/// caused it" — `features/navigation/entity_router.dart` does the opening.
library;

class FarmNotification {
  const FarmNotification({
    required this.id,
    required this.moduleCode,
    required this.notificationType,
    required this.title,
    this.description,
    required this.priority,
    this.entityType,
    this.entityId,
    this.readAt,
    required this.createdAt,
  });

  final String id;
  final String moduleCode;
  final String notificationType;
  final String title;
  final String? description;
  final String priority; // critical | high | medium | low | info
  final String? entityType;
  final String? entityId;
  final DateTime? readAt;
  final DateTime createdAt;

  bool get isRead => readAt != null;

  FarmNotification copyWith({DateTime? readAt}) => FarmNotification(
        id: id,
        moduleCode: moduleCode,
        notificationType: notificationType,
        title: title,
        description: description,
        priority: priority,
        entityType: entityType,
        entityId: entityId,
        readAt: readAt ?? this.readAt,
        createdAt: createdAt,
      );

  factory FarmNotification.fromJson(Map<String, dynamic> json) => FarmNotification(
        id: json['id'] as String,
        moduleCode: json['module_code'] as String,
        notificationType: json['notification_type'] as String,
        title: json['title'] as String,
        description: json['description'] as String?,
        priority: json['priority'] as String? ?? 'medium',
        entityType: json['entity_type'] as String?,
        entityId: json['entity_id'] as String?,
        readAt: json['read_at'] != null ? DateTime.parse(json['read_at'] as String) : null,
        createdAt: DateTime.parse(json['created_at'] as String),
      );
}

/// One card in Today's Priorities. `kind` separates an alert the farm
/// raised from a task someone was given — both belong in the same list
/// (tech spec §5) but they read and act differently.
class FarmPriority {
  const FarmPriority({
    required this.id,
    required this.kind,
    required this.moduleCode,
    required this.notificationType,
    required this.title,
    this.description,
    required this.priority,
    required this.status,
    required this.entityType,
    required this.entityId,
    required this.sourceType,
    required this.sourceId,
    this.dueAt,
    this.assignedTo,
    this.assignedToName,
    this.metadata = const {},
  });

  final String id;
  final String kind; // alert | task
  final String moduleCode;
  final String notificationType;
  final String title;
  final String? description;
  final String priority;
  final String status;
  final String entityType;
  final String entityId;
  final String sourceType;
  final String sourceId;
  final DateTime? dueAt;
  final String? assignedTo;
  final String? assignedToName;
  final Map<String, dynamic> metadata;

  bool get isTask => kind == 'task';

  /// The underlying task id, when this priority is one — used to complete
  /// it straight from the card.
  String? get taskId => entityType == 'task' ? entityId : null;

  factory FarmPriority.fromJson(Map<String, dynamic> json) => FarmPriority(
        id: json['id'] as String,
        kind: json['kind'] as String? ?? 'alert',
        moduleCode: json['module_code'] as String,
        notificationType: json['notification_type'] as String? ?? 'alert',
        title: json['title'] as String,
        description: json['description'] as String?,
        priority: json['priority'] as String? ?? 'medium',
        status: json['status'] as String? ?? 'pending',
        entityType: json['entity_type'] as String,
        entityId: json['entity_id'] as String,
        sourceType: json['source_type'] as String,
        sourceId: json['source_id'] as String,
        dueAt: json['due_at'] != null ? DateTime.tryParse(json['due_at'] as String) : null,
        assignedTo: json['assigned_to'] as String?,
        assignedToName: json['assigned_to_name'] as String?,
        metadata: Map<String, dynamic>.from(json['metadata'] as Map? ?? {}),
      );
}

/// One entry in the Audit History (tech spec §23).
class AuditEvent {
  const AuditEvent({
    required this.id,
    required this.userId,
    this.userName,
    required this.action,
    required this.entityType,
    required this.entityId,
    this.moduleCode,
    this.summary,
    this.changes = const {},
    required this.timestamp,
  });

  final String id;
  final String userId;
  final String? userName;
  final String action;
  final String entityType;
  final String entityId;
  final String? moduleCode;
  final String? summary;

  /// `{field: {"from": x, "to": y}}` — the actual before/after values.
  final Map<String, dynamic> changes;
  final DateTime timestamp;

  factory AuditEvent.fromJson(Map<String, dynamic> json) => AuditEvent(
        id: json['id'] as String,
        userId: json['user_id'] as String,
        userName: json['user_name'] as String?,
        action: json['action'] as String,
        entityType: json['entity_type'] as String,
        entityId: json['entity_id'] as String,
        moduleCode: json['module_code'] as String?,
        summary: json['summary'] as String?,
        changes: Map<String, dynamic>.from(json['changes_json'] as Map? ?? {}),
        timestamp: DateTime.parse(json['timestamp'] as String),
      );
}
