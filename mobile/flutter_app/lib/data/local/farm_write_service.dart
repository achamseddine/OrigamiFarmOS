import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
import 'database.dart';

class WriteResult {
  const WriteResult.ok() : error = null;
  const WriteResult.fail(this.error);
  final String? error;
  bool get success => error == null;
}

/// Implements the offline-first write pipeline from tech spec §10:
/// local validation → save domain record → write immutable event →
/// add sync_queue item → (UI updates immediately; background sync later).
///
/// Every public method here is one CONSTITUTION.md-mandated "important
/// change" and therefore always writes both the domain row *and* an
/// [FarmEvent] row in the same transaction — never one without the other.
class FarmWriteService {
  FarmWriteService({FarmDatabase? db, String farmId = 'farm-origami', String userId = 'user-rami'})
      : _db = db ?? FarmDatabase.instance,
        _farmId = farmId,
        _userId = userId;

  final FarmDatabase _db;
  final String _farmId;
  final String _userId;
  static const _uuid = Uuid();

  Future<Database> get _database => _db.database;

  Future<void> _writeEventAndQueue(
    DatabaseExecutor txn, {
    required String entityType,
    required String entityId,
    required String eventType,
    required Map<String, Object?> payload,
  }) async {
    final eventId = _uuid.v4();
    await txn.insert('events', {
      'id': eventId,
      'farm_id': _farmId,
      'entity_type': entityType,
      'entity_id': entityId,
      'event_type': eventType,
      'payload_json': jsonEncode(payload),
      'created_by': _userId,
      'created_at': DateTime.now().toIso8601String(),
    });
    await txn.insert('sync_queue', {
      'id': _uuid.v4(),
      'local_event_id': eventId,
      'operation': 'create',
      'entity_type': entityType,
      'entity_id': entityId,
      'payload_json': jsonEncode(payload),
      'status': 'pending',
      'retry_count': 0,
      'created_at': DateTime.now().toIso8601String(),
    });
  }

  // ------------------------------------------------------------ Observation

  /// Worker-facing capture. Constitution: "Workers record observations.
  /// Workers do not diagnose." There is deliberately no `diagnosis`
  /// parameter — see [recordTreatment] for the manager/vet-gated path.
  Future<WriteResult> recordObservation({
    required String entityType,
    required String entityId,
    required String observationType,
    required String quality,
    required String observerId,
    double? valueNumeric,
    String? valueText,
    String? unit,
    String? severity,
    String? notes,
  }) async {
    if (entityId.isEmpty) {
      return const WriteResult.fail('entityRequired');
    }
    final db = await _database;
    final id = _uuid.v4();
    final now = DateTime.now().toIso8601String();
    await db.transaction((txn) async {
      await txn.insert('observations', {
        'id': id,
        'farm_id': _farmId,
        'entity_type': entityType,
        'entity_id': entityId,
        'observation_type': observationType,
        'quality': quality,
        'value_numeric': valueNumeric,
        'value_text': valueText,
        'unit': unit,
        'severity': severity,
        'observer_id': observerId,
        'observed_at': now,
        'notes': notes,
        'verified': 0,
      });
      await _writeEventAndQueue(
        txn,
        entityType: entityType,
        entityId: entityId,
        eventType: 'observation_recorded',
        payload: {'observationType': observationType, 'valueNumeric': valueNumeric, 'valueText': valueText},
      );
    });
    return const WriteResult.ok();
  }

  // -------------------------------------------------------------------- Milk

  /// Validation rule (tech spec §14): "Liters >= 0; destination sale
  /// blocked or hard-warned if withdrawal active." [isUnderWithdrawal] is
  /// resolved by the caller (it needs the animal's current withdrawal
  /// date) and passed in so this service stays free of a read dependency.
  Future<WriteResult> recordMilk({
    required String animalId,
    required String session,
    required double liters,
    required String destination,
    required bool isUnderWithdrawal,
    String? recordedBy,
  }) async {
    if (liters < 0) return const WriteResult.fail('valueMustBePositive');
    if (isUnderWithdrawal && destination == 'sold') {
      return const WriteResult.fail('Blocked: animal is under an active withdrawal period.');
    }
    final db = await _database;
    final id = _uuid.v4();
    final now = DateTime.now().toIso8601String();
    await db.transaction((txn) async {
      await txn.insert('milk_records', {
        'id': id,
        'animal_id': animalId,
        'session': session,
        'liters': liters,
        'quality_status': 'normal',
        'destination': destination,
        'recorded_at': now,
        'recorded_by': recordedBy ?? _userId,
      });
      await _writeEventAndQueue(
        txn,
        entityType: 'animal',
        entityId: animalId,
        eventType: 'milk_recorded',
        payload: {'session': session, 'liters': liters, 'destination': destination},
      );
    });
    return const WriteResult.ok();
  }

  // -------------------------------------------------------------------- Feed

  /// Validation rule (tech spec §14): "Current quantity cannot go negative
  /// without explicit override." [allowNegative] models that override.
  Future<WriteResult> recordFeedTransaction({
    required String itemId,
    required String direction,
    required double quantity,
    required String reason,
    String? linkedEntityType,
    String? linkedEntityId,
    bool allowNegative = false,
  }) async {
    if (quantity <= 0) return const WriteResult.fail('valueMustBePositive');
    final db = await _database;
    final id = _uuid.v4();
    final now = DateTime.now().toIso8601String();

    return db.transaction((txn) async {
      final rows = await txn.query('inventory_items', where: 'id = ?', whereArgs: [itemId]);
      if (rows.isEmpty) return const WriteResult.fail('Unknown inventory item.');
      final currentQty = (rows.first['current_qty'] as num).toDouble();
      final delta = direction == 'out' ? -quantity : quantity;
      final newQty = currentQty + delta;
      if (newQty < 0 && !allowNegative) {
        return const WriteResult.fail('Feed stock cannot go negative without an override.');
      }

      await txn.insert('inventory_transactions', {
        'id': id,
        'item_id': itemId,
        'direction': direction,
        'quantity': quantity,
        'reason': reason,
        'linked_entity_type': linkedEntityType,
        'linked_entity_id': linkedEntityId,
        'created_at': now,
      });
      await txn.update('inventory_items', {'current_qty': newQty}, where: 'id = ?', whereArgs: [itemId]);
      await _writeEventAndQueue(
        txn,
        entityType: 'inventory_item',
        entityId: itemId,
        eventType: 'feed_transaction',
        payload: {'direction': direction, 'quantity': quantity, 'reason': reason},
      );
      return const WriteResult.ok();
    });
  }

  // -------------------------------------------------------------- Treatment

  /// Manager/veterinarian-gated (Constitution: "Veterinarians diagnose and
  /// prescribe"). Callers must check [AppUser.canDiagnose] before reaching
  /// this method — see `features/animals/treat_dialog.dart`.
  Future<WriteResult> recordTreatment({
    required String entityType,
    required String entityId,
    required String medication,
    required String dose,
    required String route,
    required String responsibleUserId,
    String? diagnosis,
    DateTime? withdrawalUntil,
    String? notes,
  }) async {
    if (medication.isEmpty || dose.isEmpty || route.isEmpty) {
      return const WriteResult.fail('Medication, dose and route are required.');
    }
    final db = await _database;
    final id = _uuid.v4();
    final now = DateTime.now();
    await db.transaction((txn) async {
      await txn.insert('treatments', {
        'id': id,
        'entity_type': entityType,
        'entity_id': entityId,
        'diagnosis': diagnosis,
        'medication': medication,
        'dose': dose,
        'route': route,
        'start_at': now.toIso8601String(),
        'withdrawal_until': withdrawalUntil?.toIso8601String(),
        'responsible_user_id': responsibleUserId,
        'status': 'active',
        'notes': notes,
      });
      if (withdrawalUntil != null && entityType == 'animal') {
        await txn.update(
          'animals',
          {'withdrawal_until': withdrawalUntil.toIso8601String(), 'withdrawal_reason': 'Medication'},
          where: 'id = ?',
          whereArgs: [entityId],
        );
      }
      await _writeEventAndQueue(
        txn,
        entityType: entityType,
        entityId: entityId,
        eventType: 'treatment_recorded',
        payload: {'medication': medication, 'withdrawalUntil': withdrawalUntil?.toIso8601String()},
      );
    });
    return const WriteResult.ok();
  }

  // -------------------------------------------------------------------- Move

  Future<WriteResult> moveAnimal({required String animalId, required String newLocation}) async {
    if (newLocation.trim().isEmpty) return const WriteResult.fail('entityRequired');
    final db = await _database;
    await db.transaction((txn) async {
      await txn.update('animals', {'location': newLocation, 'updated_at': DateTime.now().toIso8601String()},
          where: 'id = ?', whereArgs: [animalId]);
      await _writeEventAndQueue(
        txn,
        entityType: 'animal',
        entityId: animalId,
        eventType: 'animal_moved',
        payload: {'newLocation': newLocation},
      );
    });
    return const WriteResult.ok();
  }

  // ------------------------------------------------------------------- Tasks

  Future<WriteResult> updateTaskStatus({required String taskId, required String status}) async {
    final db = await _database;
    await db.transaction((txn) async {
      await txn.update('tasks', {'status': status}, where: 'id = ?', whereArgs: [taskId]);
      await _writeEventAndQueue(
        txn,
        entityType: 'task',
        entityId: taskId,
        eventType: 'task_status_changed',
        payload: {'status': status},
      );
    });
    return const WriteResult.ok();
  }
}
