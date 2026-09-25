enum AnimalHealthStatus { healthy, underObservation, underTreatment }

enum AnimalSpecies { cow, goat, sheep, horse, layerHen, duck, turkey }

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
