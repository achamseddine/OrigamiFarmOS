/// Persisted mirror of the backend `sync_queue` table (tech spec §9).
/// Written locally by every repository write; consumed by the (future)
/// push/pull sync worker. See `data/local/database.dart`.
class SyncQueueRecord {
  const SyncQueueRecord({
    required this.id,
    required this.localEventId,
    required this.operation,
    required this.entityType,
    required this.entityId,
    required this.payloadJson,
    this.status = 'pending',
    this.retryCount = 0,
    this.lastError,
  });

  final String id;
  final String localEventId;
  final String operation;
  final String entityType;
  final String entityId;
  final String payloadJson;
  final String status;
  final int retryCount;
  final String? lastError;

  Map<String, Object?> toMap() => {
        'id': id,
        'local_event_id': localEventId,
        'operation': operation,
        'entity_type': entityType,
        'entity_id': entityId,
        'payload_json': payloadJson,
        'status': status,
        'retry_count': retryCount,
        'last_error': lastError,
      };
}

class AuditLogRecord {
  const AuditLogRecord({
    required this.id,
    required this.farmId,
    required this.userId,
    required this.action,
    required this.entityType,
    required this.entityId,
    required this.timestamp,
  });

  final String id;
  final String farmId;
  final String userId;
  final String action;
  final String entityType;
  final String entityId;
  final DateTime timestamp;

  Map<String, Object?> toMap() => {
        'id': id,
        'farm_id': farmId,
        'user_id': userId,
        'action': action,
        'entity_type': entityType,
        'entity_id': entityId,
        'timestamp': timestamp.toIso8601String(),
      };
}
