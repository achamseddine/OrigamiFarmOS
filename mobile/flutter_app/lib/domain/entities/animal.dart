import 'livestock.dart';

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

/// Animal Digital Twin (Constitution: "Every object has one digital twin").
///
/// One class for every species (generic animal model §1). There is no
/// species enum: [species] is the catalog code the server knows, and what
/// the animal can do — be milked, be pregnant, lay, need a farrier — comes
/// from the capability resolver, never from checking that code.
class Animal {
  const Animal({
    required this.id,
    this.tag,
    required this.name,
    required this.species,
    required this.breed,
    required this.sex,
    required this.birthDate,
    required this.status,
    required this.location,
    required this.healthScore,
    this.identifiers = const [],
    this.breedId,
    this.birthDateEstimated = false,
    this.lifeStage,
    this.managementProfile,
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

  /// The primary identifier's value, denormalised by the server for
  /// sorting and search. Null for an animal registered with none — an ear
  /// tag is not mandatory any more (§4); prefer [primaryId] for display.
  final String? tag;
  final String name;

  /// The species *code* (`cow`, `layer_hen`, …): a key into the catalog
  /// `GET /species` serves. Names, icons and terminology are looked up
  /// there, so a species added on the server needs no app change.
  final String species;
  final String breed;
  final String? breedId;

  /// `F`, `M` or `U` — the resolver's inputs, with the life stage and the
  /// management profile.
  final String sex;
  final DateTime birthDate;
  final bool birthDateEstimated;
  final String? lifeStage;
  final String? managementProfile;

  /// Every identifier the animal has carried, active and retired.
  final List<AnimalIdentifier> identifiers;
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

  List<AnimalIdentifier> get activeIdentifiers => [
        for (final i in identifiers)
          if (i.isActive) i,
      ];

  /// The identifier the farm knows this animal by: the one flagged
  /// primary, else the first active one.
  AnimalIdentifier? get primaryIdentifier {
    AnimalIdentifier? first;
    for (final i in identifiers) {
      if (!i.isActive) continue;
      if (i.isPrimary) return i;
      first ??= i;
    }
    return first;
  }

  /// What goes after the `#` on a card: the primary identifier's value,
  /// the legacy tag if that is all there is, or nothing — never `null`
  /// printed on a screen.
  String get primaryId => primaryIdentifier?.value ?? tag ?? '';

  /// True when [needle] matches the name or any identifier the animal has
  /// ever carried — a retired ear tag still finds the animal it was on.
  bool matches(String needle) {
    final n = needle.toLowerCase();
    if (name.toLowerCase().contains(n)) return true;
    if ((tag ?? '').toLowerCase().contains(n)) return true;
    return identifiers.any((i) => i.value.toLowerCase().contains(n));
  }

  /// Backend `AnimalOut` shape (schemas/animals.py) — `milkTodayL`/
  /// `eggsToday` aren't part of that response (the API doesn't compute a
  /// per-animal "today" rollup), so they stay null here; the Milk/Egg
  /// screens get today's totals from `ProductionProvider` instead.
  factory Animal.fromJson(Map<String, dynamic> json) => Animal(
        id: json['id'] as String,
        tag: json['tag'] as String?,
        name: json['name'] as String,
        species: json['species'] as String? ?? 'other',
        breed: json['breed'] as String? ?? '',
        breedId: json['breed_id'] as String?,
        sex: json['sex'] as String? ?? '',
        birthDate: json['birth_date'] != null ? DateTime.parse(json['birth_date'] as String) : DateTime.now(),
        birthDateEstimated: json['birth_date_estimated'] as bool? ?? false,
        lifeStage: json['life_stage'] as String?,
        managementProfile: json['management_profile'] as String?,
        identifiers: [
          for (final i in json['identifiers'] as List<dynamic>? ?? const [])
            AnimalIdentifier.fromJson(i as Map<String, dynamic>),
        ],
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
        breedId: breedId,
        sex: sex,
        birthDate: birthDate,
        birthDateEstimated: birthDateEstimated,
        lifeStage: lifeStage,
        managementProfile: managementProfile,
        identifiers: identifiers,
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
    final label = years <= 0 ? '${remMonths}m' : '${years}y ${remMonths}m';
    return birthDateEstimated ? '~$label' : label;
  }
}
