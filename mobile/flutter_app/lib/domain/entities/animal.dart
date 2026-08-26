enum AnimalHealthStatus { healthy, underObservation, underTreatment }

AnimalHealthStatus _statusFromApi(String v) => switch (v) {
      'under_observation' => AnimalHealthStatus.underObservation,
      'under_treatment' => AnimalHealthStatus.underTreatment,
      _ => AnimalHealthStatus.healthy,
    };

/// Dart's `.name` is camelCase and the backend's values are snake_case, so
/// every enum crossing the wire goes through an explicit mapper. A silent
/// mismatch here fails a Postgres CHECK constraint at write time.
String animalStatusToApi(AnimalHealthStatus s) => switch (s) {
      AnimalHealthStatus.healthy => 'healthy',
      AnimalHealthStatus.underObservation => 'under_observation',
      AnimalHealthStatus.underTreatment => 'under_treatment',
    };

enum AnimalSpecies { cow, goat, sheep, horse, layerHen, duck, turkey, other }

AnimalSpecies _speciesFromApi(String v) => switch (v) {
      'goat' => AnimalSpecies.goat,
      'sheep' => AnimalSpecies.sheep,
      'horse' => AnimalSpecies.horse,
      'layer_hen' => AnimalSpecies.layerHen,
      'duck' => AnimalSpecies.duck,
      'turkey' => AnimalSpecies.turkey,
      'other' => AnimalSpecies.other,
      _ => AnimalSpecies.cow,
    };

String animalSpeciesToApi(AnimalSpecies s) => switch (s) {
      AnimalSpecies.cow => 'cow',
      AnimalSpecies.goat => 'goat',
      AnimalSpecies.sheep => 'sheep',
      AnimalSpecies.horse => 'horse',
      AnimalSpecies.layerHen => 'layer_hen',
      AnimalSpecies.duck => 'duck',
      AnimalSpecies.turkey => 'turkey',
      AnimalSpecies.other => 'other',
    };

extension AnimalSpeciesX on AnimalSpecies {
  String get label {
    switch (this) {
      case AnimalSpecies.cow:
        return 'Cow';
      case AnimalSpecies.goat:
        return 'Goat';
      case AnimalSpecies.sheep:
        return 'Sheep';
      case AnimalSpecies.horse:
        return 'Horse';
      case AnimalSpecies.layerHen:
        return 'Layer Hen';
      case AnimalSpecies.duck:
        return 'Duck';
      case AnimalSpecies.turkey:
        return 'Turkey';
      case AnimalSpecies.other:
        return 'Other';
    }
  }
}

/// Animal Digital Twin (Constitution: "Every object has one digital twin").
class Animal {
  const Animal({
    required this.id,
    required this.tag,
    required this.name,
    required this.species,
    required this.breed,
    required this.sex,
    required this.birthDate,
    required this.status,
    required this.location,
    required this.healthScore,
    this.photoPath,
    this.pregnant = false,
    this.pregnancyDays,
    this.lactating = false,
    this.lactationCycle,
    this.underWithdrawalUntil,
    this.withdrawalReason,
    this.milkTodayL,
    this.eggsToday,
    this.weightKg,
    this.groupName,
    this.acquisitionDate,
    this.acquisitionSource,
    this.sireTag,
    this.damTag,
    this.colorMarkings,
    this.purchaseCost,
    this.currentValue,
    this.notes,
  });

  final String id;
  final String tag;
  final String name;
  final AnimalSpecies species;
  final String breed;
  final String sex;
  final DateTime birthDate;
  final AnimalHealthStatus status;
  final String location;
  final int healthScore;
  final String? photoPath;
  final bool pregnant;
  final int? pregnancyDays;
  final bool lactating;
  final int? lactationCycle;
  final DateTime? underWithdrawalUntil;
  final String? withdrawalReason;
  final double? milkTodayL;
  final int? eggsToday;
  final double? weightKg;
  final String? groupName;
  final DateTime? acquisitionDate;
  final String? acquisitionSource;
  final String? sireTag;
  final String? damTag;
  final String? colorMarkings;

  /// Finance data: null for a user who does not hold the Finance module —
  /// the backend omits it rather than the client hiding it.
  final double? purchaseCost;
  final double? currentValue;
  final String? notes;

  bool get isUnderWithdrawal =>
      underWithdrawalUntil != null && underWithdrawalUntil!.isAfter(DateTime.now());

  /// Backend `AnimalOut` shape (schemas/animals.py) — `milkTodayL`/
  /// `eggsToday` aren't part of that response (the API doesn't compute a
  /// per-animal "today" rollup), so they stay null here; the Milk/Egg
  /// screens get today's totals from `ProductionProvider` instead.
  factory Animal.fromJson(Map<String, dynamic> json) => Animal(
        id: json['id'] as String,
        tag: json['tag'] as String,
        name: json['name'] as String,
        species: _speciesFromApi(json['species'] as String),
        breed: json['breed'] as String? ?? '',
        sex: json['sex'] as String? ?? '',
        birthDate: json['birth_date'] != null ? DateTime.parse(json['birth_date'] as String) : DateTime.now(),
        status: _statusFromApi(json['status'] as String),
        location: json['location_label'] as String? ?? '',
        healthScore: (json['health_score'] as num?)?.toInt() ?? 100,
        photoPath: json['photo_path'] as String?,
        pregnant: json['pregnant'] as bool? ?? false,
        pregnancyDays: (json['pregnancy_days'] as num?)?.toInt(),
        lactating: json['lactating'] as bool? ?? false,
        lactationCycle: (json['lactation_cycle'] as num?)?.toInt(),
        underWithdrawalUntil: json['withdrawal_until'] != null ? DateTime.parse(json['withdrawal_until'] as String) : null,
        withdrawalReason: json['withdrawal_reason'] as String?,
        weightKg: (json['weight_kg'] as num?)?.toDouble(),
        groupName: json['group_name'] as String?,
        acquisitionDate: json['acquisition_date'] != null ? DateTime.parse(json['acquisition_date'] as String) : null,
        acquisitionSource: json['acquisition_source'] as String?,
        sireTag: json['sire_tag'] as String?,
        damTag: json['dam_tag'] as String?,
        colorMarkings: json['color_markings'] as String?,
        purchaseCost: (json['purchase_cost'] as num?)?.toDouble(),
        currentValue: (json['current_value'] as num?)?.toDouble(),
        notes: json['notes'] as String?,
      );

  /// Copies with selected overrides. Every field is carried through by
  /// name, so adding a column to [Animal] can never silently drop it from
  /// an in-place update the way hand-written copies did.
  Animal copyWith({
    AnimalHealthStatus? status,
    String? location,
    double? milkTodayL,
    DateTime? underWithdrawalUntil,
    String? withdrawalReason,
  }) =>
      Animal(
        id: id,
        tag: tag,
        name: name,
        species: species,
        breed: breed,
        sex: sex,
        birthDate: birthDate,
        status: status ?? this.status,
        location: location ?? this.location,
        healthScore: healthScore,
        photoPath: photoPath,
        pregnant: pregnant,
        pregnancyDays: pregnancyDays,
        lactating: lactating,
        lactationCycle: lactationCycle,
        underWithdrawalUntil: underWithdrawalUntil ?? this.underWithdrawalUntil,
        withdrawalReason: withdrawalReason ?? this.withdrawalReason,
        milkTodayL: milkTodayL ?? this.milkTodayL,
        eggsToday: eggsToday,
        weightKg: weightKg,
        groupName: groupName,
        acquisitionDate: acquisitionDate,
        acquisitionSource: acquisitionSource,
        sireTag: sireTag,
        damTag: damTag,
        colorMarkings: colorMarkings,
        purchaseCost: purchaseCost,
        currentValue: currentValue,
        notes: notes,
      );

  String get ageLabel {
    final now = DateTime.now();
    final months = (now.year - birthDate.year) * 12 + now.month - birthDate.month;
    final years = months ~/ 12;
    final remMonths = months % 12;
    if (years <= 0) return '${remMonths}m';
    return '${years}y ${remMonths}m';
  }
}

class Flock {
  const Flock({
    required this.id,
    required this.name,
    required this.species,
    required this.count,
    required this.location,
    required this.status,
    required this.eggsToday,
    required this.vsLastWeekPct,
  });

  final String id;
  final String name;
  final AnimalSpecies species;
  final int count;
  final String location;
  final AnimalHealthStatus status;
  final int eggsToday;
  final double vsLastWeekPct;
}
