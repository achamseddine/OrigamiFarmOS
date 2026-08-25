/// Observation quality levels (handbook/04.3-Observation-Model.md §2).
enum ObservationQuality { instrumentMeasured, counted, humanObserved, opinion }

extension ObservationQualityX on ObservationQuality {
  /// A=highest confidence .. D=lowest.
  String get grade {
    switch (this) {
      case ObservationQuality.instrumentMeasured:
        return 'A';
      case ObservationQuality.counted:
        return 'B';
      case ObservationQuality.humanObserved:
        return 'C';
      case ObservationQuality.opinion:
        return 'D';
    }
  }

  double get confidenceWeight {
    switch (this) {
      case ObservationQuality.instrumentMeasured:
        return 0.95;
      case ObservationQuality.counted:
        return 0.85;
      case ObservationQuality.humanObserved:
        return 0.65;
      case ObservationQuality.opinion:
        return 0.35;
    }
  }
}

/// Constitution: "Workers record observations. Workers do not diagnose."
/// This entity intentionally has no `diagnosis` field — see [Treatment] for
/// the manager/vet-gated diagnosis + prescription record.
class Observation {
  const Observation({
    required this.id,
    required this.farmId,
    required this.entityType,
    required this.entityId,
    required this.observationType,
    required this.quality,
    required this.observerId,
    required this.observedAt,
    this.valueNumeric,
    this.valueText,
    this.unit,
    this.severity,
    this.notes,
    this.verified = false,
  });

  final String id;
  final String farmId;
  final String entityType; // animal | flock | field
  final String entityId;
  final String observationType; // e.g. reduced_appetite, limping, milk_yield
  final ObservationQuality quality;
  final String observerId;
  final DateTime observedAt;
  final double? valueNumeric;
  final String? valueText;
  final String? unit;
  final String? severity;
  final String? notes;
  final bool verified;

  Map<String, Object?> toMap() => {
        'id': id,
        'farm_id': farmId,
        'entity_type': entityType,
        'entity_id': entityId,
        'observation_type': observationType,
        'quality': quality.name,
        'observer_id': observerId,
        'observed_at': observedAt.toIso8601String(),
        'value_numeric': valueNumeric,
        'value_text': valueText,
        'unit': unit,
        'severity': severity,
        'notes': notes,
        'verified': verified ? 1 : 0,
      };
}

/// Constitution: "Every important change is an event. History is never
/// silently deleted." One immutable row per state change.
class FarmEvent {
  const FarmEvent({
    required this.id,
    required this.farmId,
    required this.entityType,
    required this.entityId,
    required this.eventType,
    required this.payload,
    required this.createdBy,
    required this.createdAt,
  });

  final String id;
  final String farmId;
  final String entityType;
  final String entityId;
  final String eventType;
  final Map<String, Object?> payload;
  final String createdBy;
  final DateTime createdAt;

  Map<String, Object?> toMap() => {
        'id': id,
        'farm_id': farmId,
        'entity_type': entityType,
        'entity_id': entityId,
        'event_type': eventType,
        'created_by': createdBy,
        'created_at': createdAt.toIso8601String(),
      };
}
