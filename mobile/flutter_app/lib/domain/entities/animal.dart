enum AnimalHealthStatus { healthy, underObservation, underTreatment }

AnimalHealthStatus _statusFromApi(String v) => switch (v) {
      'under_observation' => AnimalHealthStatus.underObservation,
      'under_treatment' => AnimalHealthStatus.underTreatment,
      _ => AnimalHealthStatus.healthy,
    };

enum AnimalSpecies { cow, goat, sheep, horse, layerHen, duck, turkey }

AnimalSpecies _speciesFromApi(String v) => switch (v) {
      'goat' => AnimalSpecies.goat,
      'sheep' => AnimalSpecies.sheep,
      'horse' => AnimalSpecies.horse,
      'layer_hen' => AnimalSpecies.layerHen,
      'duck' => AnimalSpecies.duck,
      'turkey' => AnimalSpecies.turkey,
      _ => AnimalSpecies.cow,
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
