/// Observation quality levels (handbook/04.3-Observation-Model.md §2).
enum ObservationQuality { instrumentMeasured, counted, humanObserved, opinion }

/// The backend stores quality as a snake_case string (see
/// database/schema.sql's CHECK constraint) — never the Dart enum's own
/// `.name`, which is camelCase.
ObservationQuality observationQualityFromApi(String v) => switch (v) {
      'instrument_measured' => ObservationQuality.instrumentMeasured,
      'counted' => ObservationQuality.counted,
      'opinion' => ObservationQuality.opinion,
      _ => ObservationQuality.humanObserved,
    };

String observationQualityToApi(ObservationQuality q) => switch (q) {
      ObservationQuality.instrumentMeasured => 'instrument_measured',
      ObservationQuality.counted => 'counted',
      ObservationQuality.humanObserved => 'human_observed',
      ObservationQuality.opinion => 'opinion',
    };

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

  factory Observation.fromJson(Map<String, dynamic> json) => Observation(
        id: json['id'] as String,
        farmId: json['farm_id'] as String,
        entityType: json['entity_type'] as String,
        entityId: json['entity_id'] as String,
        observationType: json['observation_type'] as String,
        quality: observationQualityFromApi(json['quality'] as String? ?? 'human_observed'),
        observerId: json['observer_id'] as String,
        observedAt: DateTime.parse(json['observed_at'] as String),
        valueNumeric: (json['value_numeric'] as num?)?.toDouble(),
        valueText: json['value_text'] as String?,
        unit: json['unit'] as String?,
        severity: json['severity'] as String?,
        notes: json['notes'] as String?,
      );
}
