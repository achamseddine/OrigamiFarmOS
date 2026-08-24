enum MilkSession { morning, evening }

enum MilkDestination { stored, sold, processed, consumed }

class MilkRecord {
  const MilkRecord({
    required this.id,
    required this.animalId,
    required this.session,
    required this.liters,
    required this.destination,
    required this.recordedAt,
    this.qualityStatus = 'normal',
  });

  final String id;
  final String animalId;
  final MilkSession session;
  final double liters;
  final MilkDestination destination;
  final DateTime recordedAt;
  final String qualityStatus;

  Map<String, Object?> toMap() => {
        'id': id,
        'animal_id': animalId,
        'session': session.name,
        'liters': liters,
        'destination': destination.name,
        'recorded_at': recordedAt.toIso8601String(),
        'quality_status': qualityStatus,
      };
}

class EggRecord {
  const EggRecord({
    required this.id,
    required this.flockId,
    required this.totalEggs,
    required this.sellableEggs,
    required this.brokenEggs,
    required this.consumed,
    required this.hatched,
    required this.wasted,
    required this.recordedAt,
  });

  final String id;
  final String flockId;
  final int totalEggs;
  final int sellableEggs;
  final int brokenEggs;
  final int consumed;
  final int hatched;
  final int wasted;
  final DateTime recordedAt;

  /// Validation rule (tech spec §14): allocation cannot exceed total.
  bool get isValid =>
      sellableEggs >= 0 &&
      brokenEggs >= 0 &&
      consumed >= 0 &&
      hatched >= 0 &&
      wasted >= 0 &&
      (sellableEggs + brokenEggs + consumed + hatched + wasted) <= totalEggs;

  Map<String, Object?> toMap() => {
        'id': id,
        'flock_id': flockId,
        'total_eggs': totalEggs,
        'sellable_eggs': sellableEggs,
        'broken_eggs': brokenEggs,
        'consumed': consumed,
        'hatched': hatched,
        'wasted': wasted,
        'recorded_at': recordedAt.toIso8601String(),
      };
}

class HarvestRecord {
  const HarvestRecord({
    required this.id,
    required this.fieldId,
    required this.productName,
    required this.quantityKg,
    required this.wasteKg,
    required this.destination,
    required this.recordedAt,
  });

  final String id;
  final String fieldId;
  final String productName;
  final double quantityKg;
  final double wasteKg;
  final String destination;
  final DateTime recordedAt;

  Map<String, Object?> toMap() => {
        'id': id,
        'field_id': fieldId,
        'product_name': productName,
        'quantity_kg': quantityKg,
        'waste_kg': wasteKg,
        'destination': destination,
        'recorded_at': recordedAt.toIso8601String(),
      };
}
