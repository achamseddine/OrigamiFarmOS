/// Milk/egg/harvest history and health treatments — thin read-only
/// mirrors of the backend's list-endpoint shapes, used by
/// [ProductionProvider]/[HealthProvider] for trend charts and history
/// tables instead of a static demo dataset.
class MilkRecord {
  const MilkRecord({
    required this.id,
    required this.animalId,
    required this.session,
    required this.liters,
    required this.destination,
    required this.recordedAt,
    this.withdrawalCheck = 'unchecked',
    this.releaseStatus = 'saleable',
    this.safetyNote,
    this.animalName,
  });
  final String id;
  final String animalId;
  final String session;
  final double liters;
  final String destination;
  final DateTime recordedAt;

  /// The server's judgement at the milking time (v0.8.5): clear |
  /// withdrawal | uncertain | unchecked (recorded before v0.8.5).
  final String withdrawalCheck;

  /// saleable | held (kept, not sold until reviewed) | released |
  /// not_for_sale (withheld) — or, on the tablet only, awaiting_check:
  /// recorded offline, not yet judged by the server (ADR-008).
  final String releaseStatus;
  final String? safetyNote;
  final String? animalName;

  bool get isHeld => releaseStatus == 'held';

  /// Recorded on this tablet while offline: the server has not checked it
  /// against the treatments it knows of, so it is nobody's sellable milk yet.
  bool get awaitingCheck => releaseStatus == 'awaiting_check';

  /// May be sold (counts in the tank when stored).
  bool get saleable => releaseStatus == 'saleable' || releaseStatus == 'released';

  factory MilkRecord.fromJson(Map<String, dynamic> json) => MilkRecord(
        id: json['id'] as String,
        animalId: json['animal_id'] as String,
        session: json['session'] as String,
        liters: (json['liters'] as num).toDouble(),
        destination: json['destination'] as String,
        recordedAt: DateTime.parse(json['recorded_at'] as String),
        withdrawalCheck: json['withdrawal_check'] as String? ?? 'unchecked',
        releaseStatus: json['release_status'] as String? ?? 'saleable',
        safetyNote: json['safety_note'] as String?,
        animalName: json['animal_name'] as String?,
      );
}

/// What the server says about a milking of an animal at a time, before it
/// is saved (`GET /production/milk-safety`, v0.8.5): whether a withdrawal
/// covered it, and whether a lactation did.
class MilkSafety {
  const MilkSafety({required this.withdrawalCheck, this.note, this.until, this.lactationProblem});
  final String withdrawalCheck;
  final String? note;
  final DateTime? until;
  final String? lactationProblem;

  bool get isWithdrawal => withdrawalCheck == 'withdrawal';
  bool get isUncertain => withdrawalCheck == 'uncertain';

  factory MilkSafety.fromJson(Map<String, dynamic> json) => MilkSafety(
        withdrawalCheck: json['withdrawal_check'] as String? ?? 'clear',
        note: json['note'] as String?,
        until: json['until'] == null ? null : DateTime.tryParse(json['until'] as String),
        lactationProblem: json['lactation_problem'] as String?,
      );
}

class EggRecord {
  const EggRecord({required this.id, required this.flockId, required this.totalEggs, required this.sellableEggs, required this.brokenEggs, required this.recordedAt});
  final String id;
  final String flockId;
  final int totalEggs;
  final int sellableEggs;
  final int brokenEggs;
  final DateTime recordedAt;

  factory EggRecord.fromJson(Map<String, dynamic> json) => EggRecord(
        id: json['id'] as String,
        flockId: json['flock_id'] as String,
        totalEggs: json['total_eggs'] as int,
        sellableEggs: json['sellable_eggs'] as int,
        brokenEggs: json['broken_eggs'] as int,
        recordedAt: DateTime.parse(json['recorded_at'] as String),
      );
}

class HarvestRecord {
  const HarvestRecord({required this.id, required this.fieldId, required this.productName, required this.quantity, required this.unit, required this.recordedAt});
  final String id;
  final String fieldId;
  final String productName;
  final double quantity;
  final String unit;
  final DateTime recordedAt;

  factory HarvestRecord.fromJson(Map<String, dynamic> json) => HarvestRecord(
        id: json['id'] as String,
        fieldId: json['field_id'] as String,
        productName: json['product_name'] as String,
        quantity: (json['quantity'] as num).toDouble(),
        unit: json['unit'] as String,
        recordedAt: DateTime.parse(json['recorded_at'] as String),
      );
}

class TreatmentRecord {
  const TreatmentRecord({
    required this.id,
    required this.entityType,
    required this.entityId,
    this.diagnosis,
    required this.medication,
    required this.status,
    this.withdrawalUntil,
    required this.startAt,
  });
  final String id;
  final String entityType;
  final String entityId;
  final String? diagnosis;
  final String medication;
  final String status;
  final DateTime? withdrawalUntil;
  final DateTime startAt;

  factory TreatmentRecord.fromJson(Map<String, dynamic> json) => TreatmentRecord(
        id: json['id'] as String,
        entityType: json['entity_type'] as String,
        entityId: json['entity_id'] as String,
        diagnosis: json['diagnosis'] as String?,
        medication: json['medication'] as String,
        status: json['status'] as String,
        withdrawalUntil: json['withdrawal_until'] != null ? DateTime.parse(json['withdrawal_until'] as String) : null,
        startAt: DateTime.parse(json['start_at'] as String),
      );
}

/// One dated body weight (`GET /animals/{id}/weights`): how it was taken
/// matters as much as the figure — a tape estimate is not a scale reading.
class WeightRecord {
  const WeightRecord({required this.id, required this.weightKg, required this.measuredAt, required this.method, this.recordedByName, this.notes, this.pending = false});
  final String id;
  final double weightKg;
  final DateTime measuredAt;

  /// scale | tape | visual_estimate | point_of_care | legacy
  final String method;
  final String? recordedByName;
  final String? notes;

  /// Saved on this tablet and not yet accepted by the farm server.
  final bool pending;

  factory WeightRecord.fromJson(Map<String, dynamic> json) => WeightRecord(
        id: json['id'] as String? ?? '',
        weightKg: (json['weight_kg'] as num?)?.toDouble() ?? 0,
        measuredAt: DateTime.tryParse(json['measured_at'] as String? ?? '') ?? DateTime.now(),
        method: json['method'] as String? ?? 'scale',
        recordedByName: json['recorded_by_name'] as String?,
        notes: json['notes'] as String?,
        pending: json['_pending'] == true,
      );
}
