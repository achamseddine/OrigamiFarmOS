/// Milk/egg/harvest history and health treatments — thin read-only
/// mirrors of the backend's list-endpoint shapes, used by
/// [ProductionProvider]/[HealthProvider] for trend charts and history
/// tables instead of a static demo dataset.
class MilkRecord {
  const MilkRecord({required this.id, required this.animalId, required this.session, required this.liters, required this.destination, required this.recordedAt});
  final String id;
  final String animalId;
  final String session;
  final double liters;
  final String destination;
  final DateTime recordedAt;

  factory MilkRecord.fromJson(Map<String, dynamic> json) => MilkRecord(
        id: json['id'] as String,
        animalId: json['animal_id'] as String,
        session: json['session'] as String,
        liters: (json['liters'] as num).toDouble(),
        destination: json['destination'] as String,
        recordedAt: DateTime.parse(json['recorded_at'] as String),
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
