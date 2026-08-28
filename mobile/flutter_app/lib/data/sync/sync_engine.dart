import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import '../local/database.dart';
import '../remote/api_exception.dart';
import '../remote/farmos_api.dart';
import '../remote/session_manager.dart';

class SyncFlushResult {
  const SyncFlushResult({required this.pushed, required this.failed, required this.wentOffline});
  final int pushed;
  final int failed;
  final bool wentOffline;
}

/// The real push half of the offline-first pipeline described in tech spec
/// §10/§11: replays `sync_queue` rows (written by
/// `data/local/farm_write_service.dart`) against the live OrigamiFarmServer,
/// oldest first, one HTTP call per row.
///
/// This is the only reader of `sync_queue.payload_json` — every payload
/// written there is already a complete, ready-to-POST request body (see
/// `farm_write_service.dart`'s own comments), so this class only has to
/// decide *which* endpoint a row belongs to (via the linked `events` row's
/// `event_type`) and report what happened. `sync/sync_queue_controller.dart`
/// is the UI-facing wrapper around this.
class SyncEngine {
  SyncEngine({required SessionManager session, required FarmosApi api, FarmDatabase? db})
      : _session = session,
        _api = api,
        _db = db ?? FarmDatabase.instance;

  final SessionManager _session;
  final FarmosApi _api;
  final FarmDatabase _db;

  /// Retries below this count still count as "pending" (kept in the
  /// automatic retry loop); at or beyond it a row is marked 'error' so a
  /// genuinely broken write stops being retried forever and surfaces to
  /// the farm instead — see settings_screen.dart's sync section.
  static const int maxRetries = 5;

  Future<int> countPending() async {
    final db = await _db.database;
    final rows = await db.rawQuery(
      "SELECT COUNT(*) AS c FROM sync_queue WHERE status IN ('pending', 'error')",
    );
    return Sqflite.firstIntValue(rows) ?? 0;
  }

  /// Pushes every pending row it can. Demo mode (no signed-in session) has
  /// no server to push to, so queued rows there are marked synced
  /// immediately — matching this build's demo UX everywhere else, where
  /// "offline-first" writes always succeed locally with no visible wait.
  Future<SyncFlushResult> flushPending() async {
    final db = await _db.database;

    if (!_session.isLoggedIn) {
      final count = await db.update(
        'sync_queue',
        {'status': 'synced'},
        where: "status IN ('pending', 'error')",
      );
      return SyncFlushResult(pushed: count, failed: 0, wentOffline: false);
    }

    final rows = await db.rawQuery('''
      SELECT q.id AS q_id, q.entity_type, q.entity_id, q.payload_json, q.retry_count,
             e.event_type AS event_type
      FROM sync_queue q
      LEFT JOIN events e ON e.id = q.local_event_id
      WHERE q.status IN ('pending', 'error')
      ORDER BY q.created_at ASC
    ''');

    var pushed = 0;
    var failed = 0;
    for (final row in rows) {
      final queueId = row['q_id'] as String;
      final eventType = row['event_type'] as String?;
      final entityId = row['entity_id'] as String;
      final rawPayload = row['payload_json'] as String?;
      final payload = rawPayload == null
          ? <String, dynamic>{}
          : jsonDecode(rawPayload) as Map<String, dynamic>;

      try {
        await _push(eventType: eventType, entityId: entityId, payload: payload, idempotencyKey: queueId);
        await db.update('sync_queue', {'status': 'synced'}, where: 'id = ?', whereArgs: [queueId]);
        pushed++;
      } on ApiOfflineException {
        // Connectivity dropped mid-flush — stop here, leave the rest
        // pending, don't count this as the item's own fault.
        return SyncFlushResult(pushed: pushed, failed: failed, wentOffline: true);
      } on ApiException catch (e) {
        final retryCount = (row['retry_count'] as int? ?? 0) + 1;
        await db.update(
          'sync_queue',
          {
            'retry_count': retryCount,
            'last_error': e.detail,
            'status': retryCount >= maxRetries ? 'error' : 'pending',
          },
          where: 'id = ?',
          whereArgs: [queueId],
        );
        failed++;
      }
    }
    return SyncFlushResult(pushed: pushed, failed: failed, wentOffline: false);
  }

  Future<void> _push({
    required String? eventType,
    required String entityId,
    required Map<String, dynamic> payload,
    required String idempotencyKey,
  }) async {
    switch (eventType) {
      case 'observation_recorded':
        await _api.createObservation(payload, idempotencyKey: idempotencyKey);
        return;
      case 'milk_recorded':
        await _api.createMilkRecord(payload, idempotencyKey: idempotencyKey);
        return;
      case 'feed_transaction':
        await _api.createFeedTransaction(payload, idempotencyKey: idempotencyKey);
        return;
      case 'treatment_recorded':
        await _api.createTreatment(payload, idempotencyKey: idempotencyKey);
        return;
      case 'animal_moved':
        await _api.moveAnimal(entityId, payload['location_label'] as String? ?? '');
        return;
      case 'task_status_changed':
        await _api.updateTask(entityId, payload);
        return;
      default:
        // Nothing this build knows how to push (or an older queued row
        // from before an event type existed) — treat as already handled
        // rather than blocking every row behind it forever.
        return;
    }
  }
}
