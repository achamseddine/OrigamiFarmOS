import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
import '../data/local/database.dart';
import '../data/local/farm_write_service.dart' show WriteResult;

/// Offline-first write pipeline for the Farm Visits & Agri-Tourism module
/// (tech spec v0.6 §10) — same shape as [MounehWriteService]: local
/// validation -> save domain row(s) -> write an immutable event -> queue
/// for sync, all in one SQLite transaction. Its own bounded context rather
/// than folded into [FarmWriteService]/[MounehWriteService].
///
/// Booking-status transitions are never applied here without having
/// already passed `lib/visits/analytics.dart::validateStatusTransition` and
/// the relevant capacity/welfare/handler checks in the caller
/// ([VisitsProvider]) — this class only persists the already-validated
/// result plus its audit event (RULE-VIS-008).
class VisitsWriteService {
  VisitsWriteService({FarmDatabase? db, String farmId = 'farm-origami', String userId = 'user-rami'})
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

  /// RULE-VIS-001: super user activate/deactivate, per farm.
  Future<WriteResult> setModuleStatus({required String moduleCode, required String status, String? activatedBy}) async {
    final db = await _database;
    await db.transaction((txn) async {
      await txn.insert(
        'module_licenses',
        {'module_code': moduleCode, 'status': status, 'plan': 'visits_agritourism', 'activated_by': activatedBy ?? _userId},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await _writeEventAndQueue(txn, entityType: 'module_license', entityId: moduleCode, eventType: 'module_$status', payload: {'status': status});
    });
    return const WriteResult.ok();
  }

  /// RULE-VIS-003: opening days are configurable, never hard-coded — this
  /// upserts one weekday row at a time from the Opening Calendar screen.
  Future<WriteResult> upsertCalendarDay({
    required int weekday,
    required bool isOpen,
    String? openTime,
    String? closeTime,
    required int defaultCapacity,
    String? notes,
  }) async {
    final db = await _database;
    await db.transaction((txn) async {
      await txn.insert(
        'visit_opening_calendar',
        {'weekday': weekday, 'is_open': isOpen ? 1 : 0, 'open_time': openTime, 'close_time': closeTime, 'default_capacity': defaultCapacity, 'notes': notes},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await _writeEventAndQueue(txn, entityType: 'visit_opening_calendar', entityId: 'weekday-$weekday', eventType: 'calendar_day_updated', payload: {'weekday': weekday, 'is_open': isOpen});
    });
    return const WriteResult.ok();
  }

  Future<WriteResult> createSession({
    required String id,
    required DateTime date,
    required String startTime,
    required String endTime,
    required int capacity,
    String? weatherNote,
    double? expectedStaffCost,
  }) async {
    final db = await _database;
    await db.transaction((txn) async {
      await txn.insert('visit_sessions', {
        'id': id,
        'farm_id': _farmId,
        'date': date.toIso8601String(),
        'start_time': startTime,
        'end_time': endTime,
        'capacity': capacity,
        'status': 'open',
        'weather_note': weatherNote,
        'expected_staff_cost': expectedStaffCost,
      });
      await _writeEventAndQueue(txn, entityType: 'visit_session', entityId: id, eventType: 'session_created', payload: {'date': date.toIso8601String(), 'capacity': capacity});
    });
    return const WriteResult.ok();
  }

  Future<WriteResult> updateSession({required String id, int? capacity, String? status, String? weatherNote, double? expectedStaffCost}) async {
    final db = await _database;
    await db.transaction((txn) async {
      final values = <String, Object?>{};
      if (capacity != null) values['capacity'] = capacity;
      if (status != null) values['status'] = status;
      if (weatherNote != null) values['weather_note'] = weatherNote;
      if (expectedStaffCost != null) values['expected_staff_cost'] = expectedStaffCost;
      if (values.isNotEmpty) {
        await txn.update('visit_sessions', values, where: 'id = ?', whereArgs: [id]);
      }
      await _writeEventAndQueue(txn, entityType: 'visit_session', entityId: id, eventType: 'session_updated', payload: values);
    });
    return const WriteResult.ok();
  }

  /// A brand-new sellable package created dynamically through the Package
  /// Builder — no enum of package names exists anywhere.
  Future<WriteResult> createPackage({
    required String id,
    required String name,
    String? description,
    double basePrice = 0,
    String currency = 'USD',
    int? durationMinutes,
  }) async {
    if (name.trim().isEmpty) return const WriteResult.fail('entityRequired');
    final db = await _database;
    await db.transaction((txn) async {
      await txn.insert('visit_packages', {
        'id': id,
        'farm_id': _farmId,
        'name': name,
        'description': description,
        'base_price': basePrice,
        'currency': currency,
        'duration_minutes': durationMinutes,
        'active': 1,
      });
      await _writeEventAndQueue(txn, entityType: 'visit_package', entityId: id, eventType: 'package_created', payload: {'name': name, 'base_price': basePrice});
    });
    return const WriteResult.ok();
  }

  /// RULE-VIS-004/005/010: an activity is whatever a manager types — "Horse
  /// Ride" is only ever example data, never special-cased here.
  Future<WriteResult> createActivity({
    required String id,
    required String name,
    String activityType = 'other',
    double price = 0,
    int capacityPerSlot = 1,
    int? durationMinutes,
    String? requiresStaffRole,
    String? requiresAnimalId,
    int? maxUsesPerDay,
  }) async {
    if (name.trim().isEmpty) return const WriteResult.fail('entityRequired');
    final db = await _database;
    await db.transaction((txn) async {
      await txn.insert('visit_activities', {
        'id': id,
        'farm_id': _farmId,
        'name': name,
        'activity_type': activityType,
        'price': price,
        'capacity_per_slot': capacityPerSlot,
        'duration_minutes': durationMinutes,
        'requires_staff_role': requiresStaffRole,
        'requires_animal_id': requiresAnimalId,
        'max_uses_per_day': maxUsesPerDay,
        'active': 1,
      });
      await _writeEventAndQueue(txn, entityType: 'visit_activity', entityId: id, eventType: 'activity_created', payload: {'name': name, 'activity_type': activityType});
    });
    return const WriteResult.ok();
  }

  Future<WriteResult> createVisitor({
    required String id,
    required String fullName,
    String? phone,
    String? email,
    String preferredLanguage = 'en',
    String? notes,
    bool consentMarketing = false,
  }) async {
    if (fullName.trim().isEmpty) return const WriteResult.fail('entityRequired');
    final db = await _database;
    await db.transaction((txn) async {
      await txn.insert('visitor_profiles', {
        'id': id,
        'farm_id': _farmId,
        'full_name': fullName,
        'phone': phone,
        'email': email,
        'preferred_language': preferredLanguage,
        'notes': notes,
        'consent_marketing': consentMarketing ? 1 : 0,
      });
      await _writeEventAndQueue(txn, entityType: 'visitor_profile', entityId: id, eventType: 'visitor_created', payload: {'full_name': fullName});
    });
    return const WriteResult.ok();
  }

  /// A booking is always created as `draft` — RULE-VIS-008's status machine
  /// (see `lib/visits/analytics.dart`) drives every transition afterwards.
  /// `idempotencyKey` lets a repeated offline walk-in sync be de-duplicated
  /// by the caller before this is ever invoked a second time.
  Future<WriteResult> createBooking({
    required String id,
    required String visitorId,
    required String sessionId,
    required String packageId,
    int adults = 1,
    int children = 0,
    required double totalAmount,
    double depositAmount = 0,
    required double balanceDue,
    String source = 'manual',
    String? notes,
    String? idempotencyKey,
    required List<Map<String, Object?>> activities,
  }) async {
    final db = await _database;
    await db.transaction((txn) async {
      final now = DateTime.now().toIso8601String();
      await txn.insert('visit_bookings', {
        'id': id,
        'farm_id': _farmId,
        'visitor_id': visitorId,
        'session_id': sessionId,
        'package_id': packageId,
        'status': 'draft',
        'adults': adults,
        'children': children,
        'total_amount': totalAmount,
        'deposit_amount': depositAmount,
        'balance_due': balanceDue,
        'source': source,
        'notes': notes,
        'idempotency_key': idempotencyKey,
        'created_at': now,
      });
      for (final a in activities) {
        await txn.insert('visit_booking_activities', {'id': _uuid.v4(), 'booking_id': id, ...a});
      }
      await _writeEventAndQueue(txn, entityType: 'visit_booking', entityId: id, eventType: 'booking_created', payload: {'visitor_id': visitorId, 'session_id': sessionId, 'guest_count': adults + children});
    });
    return const WriteResult.ok();
  }

  /// RULE-VIS-008: persists an already-validated status transition and the
  /// matching timestamp column (`no_show`/`refunded` have none — pass
  /// `null`); never rewrites history — each call is a new audit event on
  /// top of the same row.
  Future<WriteResult> updateBookingStatus({required String id, required String status, String? timestampColumn}) async {
    final db = await _database;
    await db.transaction((txn) async {
      final values = <String, Object?>{'status': status};
      if (timestampColumn != null) values[timestampColumn] = DateTime.now().toIso8601String();
      await txn.update('visit_bookings', values, where: 'id = ?', whereArgs: [id]);
      await _writeEventAndQueue(txn, entityType: 'visit_booking', entityId: id, eventType: 'booking_$status', payload: {'status': status});
    });
    return const WriteResult.ok();
  }

  Future<WriteResult> addStaffRoster({
    required String id,
    required String sessionId,
    required String workerId,
    String? workerName,
    required String role,
    required String startTime,
    required String endTime,
    double hourlyRate = 0,
    double? totalCost,
  }) async {
    final db = await _database;
    await db.transaction((txn) async {
      await txn.insert('visit_staff_roster', {
        'id': id,
        'farm_id': _farmId,
        'session_id': sessionId,
        'worker_id': workerId,
        'worker_name': workerName,
        'role': role,
        'start_time': startTime,
        'end_time': endTime,
        'hourly_rate': hourlyRate,
        'total_cost': totalCost,
      });
      await _writeEventAndQueue(txn, entityType: 'visit_staff_roster', entityId: id, eventType: 'staff_assigned', payload: {'session_id': sessionId, 'role': role});
    });
    return const WriteResult.ok();
  }

  Future<WriteResult> addCost({
    required String id,
    required String sessionId,
    required String category,
    String? description,
    double amount = 0,
    String allocationMethod = 'per_session',
  }) async {
    final db = await _database;
    await db.transaction((txn) async {
      await txn.insert('visit_costs', {
        'id': id,
        'farm_id': _farmId,
        'session_id': sessionId,
        'category': category,
        'description': description,
        'amount': amount,
        'allocation_method': allocationMethod,
      });
      await _writeEventAndQueue(txn, entityType: 'visit_cost', entityId: id, eventType: 'cost_recorded', payload: {'session_id': sessionId, 'category': category, 'amount': amount});
    });
    return const WriteResult.ok();
  }

  /// RULE-VIS-006: the caller is responsible for deducting the underlying
  /// inventory/finished-goods row (via `FeedProvider`/`MounehProvider`, each
  /// through their own write service) in the same user action; this only
  /// persists the visitor-facing retail-sale record and its audit event.
  Future<WriteResult> recordRetailSale({
    required String id,
    String? bookingId,
    String? visitorId,
    String channel = 'farm_shop',
    required double totalAmount,
  }) async {
    final db = await _database;
    await db.transaction((txn) async {
      await txn.insert('visit_retail_sales', {
        'id': id,
        'farm_id': _farmId,
        'booking_id': bookingId,
        'visitor_id': visitorId,
        'channel': channel,
        'total_amount': totalAmount,
        'sold_at': DateTime.now().toIso8601String(),
      });
      await _writeEventAndQueue(txn, entityType: 'visit_retail_sale', entityId: id, eventType: 'retail_sale_recorded', payload: {'booking_id': bookingId, 'total_amount': totalAmount});
    });
    return const WriteResult.ok();
  }

  Future<WriteResult> addFeedback({
    required String id,
    required String bookingId,
    required int rating,
    String? comments,
    bool? wouldReturn,
  }) async {
    final db = await _database;
    await db.transaction((txn) async {
      await txn.insert('visitor_feedback', {
        'id': id,
        'booking_id': bookingId,
        'rating': rating,
        'comments': comments,
        'would_return': wouldReturn == null ? null : (wouldReturn ? 1 : 0),
        'submitted_at': DateTime.now().toIso8601String(),
      });
      await _writeEventAndQueue(txn, entityType: 'visitor_feedback', entityId: id, eventType: 'feedback_submitted', payload: {'booking_id': bookingId, 'rating': rating});
    });
    return const WriteResult.ok();
  }

  Future<WriteResult> addIncident({
    required String id,
    required String sessionId,
    String? bookingId,
    required String incidentType,
    String severity = 'low',
    required String description,
    String? actionTaken,
  }) async {
    if (description.trim().isEmpty) return const WriteResult.fail('entityRequired');
    final db = await _database;
    await db.transaction((txn) async {
      await txn.insert('visit_incidents', {
        'id': id,
        'farm_id': _farmId,
        'session_id': sessionId,
        'booking_id': bookingId,
        'incident_type': incidentType,
        'severity': severity,
        'description': description,
        'action_taken': actionTaken,
        'created_at': DateTime.now().toIso8601String(),
      });
      await _writeEventAndQueue(txn, entityType: 'visit_incident', entityId: id, eventType: 'incident_reported', payload: {'session_id': sessionId, 'incident_type': incidentType, 'severity': severity});
    });
    return const WriteResult.ok();
  }
}
