/// The livestock record on the tablet (database/LIVESTOCK-SCHEMA.md,
/// REPRODUCTION-SCHEMA.md, PRODUCTION-SCHEMA.md §8): the animal's
/// reproduction card and timeline, its group memberships, parentage and
/// state history; a group's members and head-count ledger; the incubator.
///
/// Plain readers of the server's responses — every rule (which actions
/// apply, when a pregnancy is due, what a birth closes) is decided by the
/// server and arrives here as data.
library;

DateTime? _dt(Object? v) => v is String ? DateTime.tryParse(v)?.toLocal() : null;
int? _int(Object? v) => (v as num?)?.toInt();
double? _double(Object? v) => (v as num?)?.toDouble();
Map<String, dynamic> _map(Object? v) => v is Map ? v.cast<String, dynamic>() : const <String, dynamic>{};
List<Map<String, dynamic>> _maps(Object? v) => [for (final e in v as List<dynamic>? ?? const []) if (e is Map) e.cast<String, dynamic>()];

/// The code sets the server accepts — the same lists `reproduction_service.py`
/// validates against, so a form can only offer what will be accepted.
class ReproCodes {
  ReproCodes._();
  static const breedingTypes = ['HEAT_OBSERVED', 'NATURAL_MATING', 'ARTIFICIAL_INSEMINATION', 'EMBRYO_TRANSFER'];
  static const assessmentTypes = ['ULTRASOUND', 'PALPATION', 'BLOOD_TEST', 'OBSERVATION'];
  static const results = ['POSITIVE', 'NEGATIVE', 'INCONCLUSIVE'];
  static const lossOutcomes = ['LOSS', 'ABORTION'];
  static const assistance = ['NONE', 'EASY', 'ASSISTED', 'VETERINARY', 'CAESAREAN'];
  static const newbornOutcomes = ['LIVE', 'STILLBORN', 'DIED_AFTER_BIRTH'];
  static const exitTypes = ['dead', 'sold', 'culled', 'slaughtered', 'transferred'];
  static const quantityEvents = ['DEATH', 'SALE', 'CULL', 'PURCHASE', 'ADDITION', 'REMOVAL', 'TRANSFER_IN', 'TRANSFER_OUT', 'COUNT_ADJUSTMENT'];

  /// Head-count events that add (+1), remove (−1) or may go either way (0).
  static int sign(String eventType) => switch (eventType) {
        'PURCHASE' || 'ADDITION' || 'BIRTH' || 'HATCH' || 'TRANSFER_IN' => 1,
        'COUNT_ADJUSTMENT' || 'INITIAL_COUNT' => 0,
        _ => -1,
      };
}

class BreedingRecord {
  const BreedingRecord({required this.id, required this.eventType, required this.occurredAt, required this.status, this.maleName, this.sireReference, this.semenBatch, this.voidReason, this.notes});

  final String id;
  final String eventType;
  final DateTime? occurredAt;
  final String status;
  final String? maleName;
  final String? sireReference;
  final String? semenBatch;
  final String? voidReason;
  final String? notes;

  bool get voided => status == 'voided';

  /// Who sired it: the farm's own male, else the outside sire written down.
  String? get sire => maleName ?? sireReference;

  factory BreedingRecord.fromJson(Map<String, dynamic> j) => BreedingRecord(
        id: j['id'] as String,
        eventType: j['event_type'] as String? ?? 'NATURAL_MATING',
        occurredAt: _dt(j['occurred_at']),
        status: j['status'] as String? ?? 'recorded',
        maleName: j['male_name'] as String?,
        sireReference: j['sire_reference'] as String?,
        semenBatch: j['semen_batch_reference'] as String?,
        voidReason: j['void_reason'] as String?,
        notes: j['notes'] as String?,
      );
}

class PregnancyCheck {
  const PregnancyCheck({required this.id, required this.assessedAt, required this.assessmentType, required this.resultCode, this.gestationDays, this.expectedDueDate, this.notes});

  final String id;
  final DateTime? assessedAt;
  final String assessmentType;
  final String resultCode;
  final int? gestationDays;
  final DateTime? expectedDueDate;
  final String? notes;

  factory PregnancyCheck.fromJson(Map<String, dynamic> j) => PregnancyCheck(
        id: j['id'] as String,
        assessedAt: _dt(j['assessed_at']),
        assessmentType: j['assessment_type'] as String? ?? 'OBSERVATION',
        resultCode: j['result_code'] as String? ?? 'INCONCLUSIVE',
        gestationDays: _int(j['estimated_gestation_days']),
        expectedDueDate: _dt(j['expected_due_date']),
        notes: j['notes'] as String?,
      );
}

class Pregnancy {
  const Pregnancy({required this.id, required this.status, this.conceivedAt, this.expectedDueDate, this.daysPregnant, this.daysToDue, this.endedAt, this.outcomeCode, this.source});

  final String id;
  final String status;
  final DateTime? conceivedAt;
  final DateTime? expectedDueDate;
  final int? daysPregnant;
  final int? daysToDue;
  final DateTime? endedAt;
  final String? outcomeCode;
  final String? source;

  bool get active => status == 'active';
  bool get overdue => active && daysToDue != null && daysToDue! < 0;

  factory Pregnancy.fromJson(Map<String, dynamic> j) => Pregnancy(
        id: j['id'] as String,
        status: j['status'] as String? ?? 'active',
        conceivedAt: _dt(j['estimated_conception_at']),
        expectedDueDate: _dt(j['expected_due_date']),
        daysPregnant: _int(j['days_pregnant']),
        daysToDue: _int(j['days_to_due']),
        endedAt: _dt(j['ended_at']),
        outcomeCode: j['outcome_code'] as String?,
        source: j['source'] as String?,
      );
}

class Newborn {
  const Newborn({required this.sequenceNo, required this.outcomeCode, this.sex, this.birthWeightKg, this.animalId, this.animalName, this.animalTag, this.groupName, this.registrable = false});

  final int sequenceNo;
  final String outcomeCode;
  final String? sex;
  final double? birthWeightKg;
  final String? animalId;
  final String? animalName;
  final String? animalTag;
  final String? groupName;

  /// Born live, not registered and not counted into a group: the tablet
  /// offers "Register" on it.
  final bool registrable;

  factory Newborn.fromJson(Map<String, dynamic> j) => Newborn(
        sequenceNo: _int(j['sequence_no']) ?? 1,
        outcomeCode: j['outcome_code'] as String? ?? 'LIVE',
        sex: j['sex'] as String?,
        birthWeightKg: _double(j['birth_weight_kg']),
        animalId: j['offspring_animal_id'] as String?,
        animalName: j['offspring_name'] as String?,
        animalTag: j['offspring_tag'] as String?,
        groupName: j['destination_group_name'] as String?,
        registrable: j['registrable'] == true,
      );
}

class BirthRecord {
  const BirthRecord({required this.id, required this.occurredAt, required this.assistanceCode, required this.offspringCount, required this.liveCount, required this.stillbornCount, this.sire, this.notes, this.offspring = const []});

  final String id;
  final DateTime? occurredAt;
  final String assistanceCode;
  final int offspringCount;
  final int liveCount;
  final int stillbornCount;
  final String? sire;
  final String? notes;
  final List<Newborn> offspring;

  factory BirthRecord.fromJson(Map<String, dynamic> j) => BirthRecord(
        id: j['id'] as String,
        occurredAt: _dt(j['occurred_at']),
        assistanceCode: j['assistance_code'] as String? ?? 'NONE',
        offspringCount: _int(j['offspring_count']) ?? 0,
        liveCount: _int(j['live_count']) ?? 0,
        stillbornCount: _int(j['stillborn_count']) ?? 0,
        sire: (j['sire_name'] ?? j['sire_reference']) as String?,
        notes: j['notes'] as String?,
        offspring: [for (final o in _maps(j['offspring'])) Newborn.fromJson(o)],
      );
}

class Lactation {
  const Lactation({required this.id, required this.status, this.number, this.startedAt, this.endedAt, this.daysInMilk, this.endReason});

  final String id;
  final String status;
  final int? number;
  final DateTime? startedAt;
  final DateTime? endedAt;
  final int? daysInMilk;
  final String? endReason;

  bool get active => status == 'active';

  factory Lactation.fromJson(Map<String, dynamic> j) => Lactation(
        id: j['id'] as String,
        status: j['status'] as String? ?? 'active',
        number: _int(j['lactation_number']),
        startedAt: _dt(j['started_at']),
        endedAt: _dt(j['ended_at']),
        daysInMilk: _int(j['days_in_milk']),
        endReason: j['end_reason_code'] as String?,
      );
}

/// Which reproduction actions apply to this animal — the server's resolved
/// capabilities, so a hen is never offered a pregnancy check.
class ReproApplies {
  const ReproApplies({this.breeding = false, this.pregnancy = false, this.liveBirth = false, this.lactation = false});

  final bool breeding;
  final bool pregnancy;
  final bool liveBirth;
  final bool lactation;

  bool get any => breeding || pregnancy || liveBirth || lactation;

  factory ReproApplies.fromJson(Map<String, dynamic> j) => ReproApplies(
        breeding: j['breeding'] == true,
        pregnancy: j['pregnancy'] == true,
        liveBirth: j['live_birth'] == true,
        lactation: j['lactation'] == true,
      );
}

class ReproSummary {
  const ReproSummary({
    this.applies = const ReproApplies(),
    this.terminology = const {},
    this.pregnant = false,
    this.pregnancy,
    this.lactation,
    this.lastBreeding,
    this.lastCheck,
    this.lastBirthAt,
    this.lastBirthLive,
    this.birthsCount = 0,
    this.awaitingCheck = false,
    this.lactationNumber,
  });

  final ReproApplies applies;
  final Map<String, dynamic> terminology;
  final bool pregnant;
  final Pregnancy? pregnancy;
  final Lactation? lactation;
  final BreedingRecord? lastBreeding;
  final PregnancyCheck? lastCheck;
  final DateTime? lastBirthAt;
  final int? lastBirthLive;
  final int birthsCount;
  final bool awaitingCheck;
  final int? lactationNumber;

  /// The species' own word: "Calving", "Lambing", "Kidding", "Foaling".
  String birthTerm(bool arabic) => (terminology[arabic ? 'birth_ar' : 'birth_en'] as String?) ?? (arabic ? 'ولادة' : 'Birth');
  String offspringTerm(bool arabic) => (terminology[arabic ? 'offspring_ar' : 'offspring_en'] as String?) ?? (arabic ? 'مولود' : 'Offspring');

  factory ReproSummary.fromJson(Map<String, dynamic> j) {
    final lastBirth = _map(j['last_birth']);
    return ReproSummary(
      applies: ReproApplies.fromJson(_map(j['applies'])),
      terminology: _map(j['terminology']),
      pregnant: j['pregnant'] == true,
      pregnancy: j['pregnancy'] is Map ? Pregnancy.fromJson(_map(j['pregnancy'])) : null,
      lactation: j['lactation'] is Map ? Lactation.fromJson(_map(j['lactation'])) : null,
      lastBreeding: j['last_breeding'] is Map ? BreedingRecord.fromJson(_map(j['last_breeding'])) : null,
      lastCheck: j['last_check'] is Map ? PregnancyCheck.fromJson(_map(j['last_check'])) : null,
      lastBirthAt: _dt(lastBirth['occurred_at']),
      lastBirthLive: _int(lastBirth['live_count']),
      birthsCount: _int(j['births_count']) ?? 0,
      awaitingCheck: j['awaiting_pregnancy_check'] == true,
      lactationNumber: _int(j['lactation_number']),
    );
  }
}

class Relative {
  const Relative({required this.animalId, required this.name, required this.relationshipType, this.tag, this.sex, this.active = true});

  final String animalId;
  final String name;
  final String relationshipType;
  final String? tag;
  final String? sex;
  final bool active;

  factory Relative.fromJson(Map<String, dynamic> j) => Relative(
        animalId: j['animal_id'] as String,
        name: j['name'] as String? ?? '',
        relationshipType: j['relationship_type'] as String? ?? 'DAM_OF',
        tag: j['tag'] as String?,
        sex: j['sex'] as String?,
        active: j['active'] != false,
      );
}

class Parentage {
  const Parentage({this.dam, this.sire, this.offspring = const []});

  final Relative? dam;
  final Relative? sire;
  final List<Relative> offspring;

  bool get isEmpty => dam == null && sire == null && offspring.isEmpty;

  factory Parentage.fromJson(Map<String, dynamic> j) => Parentage(
        dam: j['dam'] is Map ? Relative.fromJson(_map(j['dam'])) : null,
        sire: j['sire'] is Map ? Relative.fromJson(_map(j['sire'])) : null,
        offspring: [for (final o in _maps(j['offspring'])) Relative.fromJson(o)],
      );
}

class ReproTimeline {
  const ReproTimeline({required this.summary, this.breedings = const [], this.checks = const [], this.pregnancies = const [], this.births = const [], this.lactations = const [], this.parentage = const Parentage()});

  final ReproSummary summary;
  final List<BreedingRecord> breedings;
  final List<PregnancyCheck> checks;
  final List<Pregnancy> pregnancies;
  final List<BirthRecord> births;
  final List<Lactation> lactations;
  final Parentage parentage;

  bool get isEmpty => breedings.isEmpty && checks.isEmpty && pregnancies.isEmpty && births.isEmpty && lactations.isEmpty;

  factory ReproTimeline.fromJson(Map<String, dynamic> j) => ReproTimeline(
        summary: ReproSummary.fromJson(_map(j['summary'])),
        breedings: [for (final b in _maps(j['breedings'])) BreedingRecord.fromJson(b)],
        checks: [for (final c in _maps(j['assessments'])) PregnancyCheck.fromJson(c)],
        pregnancies: [for (final p in _maps(j['pregnancies'])) Pregnancy.fromJson(p)],
        births: [for (final b in _maps(j['births'])) BirthRecord.fromJson(b)],
        lactations: [for (final l in _maps(j['lactations'])) Lactation.fromJson(l)],
        parentage: Parentage.fromJson(_map(j['relationships'])),
      );
}

class GroupMembership {
  const GroupMembership({required this.id, required this.groupId, required this.animalId, this.groupName, this.groupType, this.animalName, this.animalTag, this.validFrom, this.validTo, this.reason, this.endReason});

  final String id;
  final String groupId;
  final String animalId;
  final String? groupName;
  final String? groupType;
  final String? animalName;
  final String? animalTag;
  final DateTime? validFrom;
  final DateTime? validTo;
  final String? reason;
  final String? endReason;

  bool get current => validTo == null;

  factory GroupMembership.fromJson(Map<String, dynamic> j) => GroupMembership(
        id: j['id'] as String,
        groupId: j['group_id'] as String,
        animalId: j['animal_id'] as String,
        groupName: j['group_name'] as String?,
        groupType: j['group_type'] as String?,
        animalName: j['animal_name'] as String?,
        animalTag: j['animal_tag'] as String?,
        validFrom: _dt(j['valid_from']),
        validTo: _dt(j['valid_to']),
        reason: j['reason'] as String?,
        endReason: j['end_reason'] as String?,
      );
}

class StateChange {
  const StateChange({required this.id, required this.stateType, this.value, this.effectiveFrom, this.effectiveTo, this.reason});

  final String id;
  final String stateType;
  final String? value;
  final DateTime? effectiveFrom;
  final DateTime? effectiveTo;
  final String? reason;

  bool get current => effectiveTo == null;

  factory StateChange.fromJson(Map<String, dynamic> j) => StateChange(
        id: j['id'] as String,
        stateType: j['state_type'] as String? ?? 'STATUS',
        value: j['value'] as String?,
        effectiveFrom: _dt(j['effective_from']),
        effectiveTo: _dt(j['effective_to']),
        reason: j['reason'] as String?,
      );
}

class QuantityEvent {
  const QuantityEvent({required this.id, required this.eventType, required this.delta, required this.resulting, this.occurredAt, this.reason});

  final String id;
  final String eventType;
  final int delta;
  final int resulting;
  final DateTime? occurredAt;
  final String? reason;

  factory QuantityEvent.fromJson(Map<String, dynamic> j) => QuantityEvent(
        id: j['id'] as String,
        eventType: j['event_type'] as String? ?? 'COUNT_ADJUSTMENT',
        delta: _int(j['quantity_delta']) ?? 0,
        resulting: _int(j['resulting_quantity']) ?? 0,
        occurredAt: _dt(j['occurred_at']),
        reason: j['reason'] as String?,
      );
}

class IncubationBatch {
  const IncubationBatch({required this.id, required this.code, required this.speciesCode, required this.eggsSet, required this.status, this.setAt, this.expectedHatch, this.daysToHatch, this.sourceGroupName, this.hatchedLive, this.hatchRate});

  final String id;
  final String code;
  final String speciesCode;
  final int eggsSet;
  final String status;
  final DateTime? setAt;
  final DateTime? expectedHatch;
  final int? daysToHatch;
  final String? sourceGroupName;
  final int? hatchedLive;
  final double? hatchRate;

  bool get incubating => status == 'incubating';

  factory IncubationBatch.fromJson(Map<String, dynamic> j) {
    final hatch = _map(j['hatch']);
    return IncubationBatch(
      id: j['id'] as String,
      code: j['code'] as String? ?? '',
      speciesCode: j['species_code'] as String? ?? '',
      eggsSet: _int(j['eggs_set']) ?? 0,
      status: j['status'] as String? ?? 'incubating',
      setAt: _dt(j['set_at']),
      expectedHatch: _dt(j['expected_hatch_date']),
      daysToHatch: _int(j['days_to_hatch']),
      sourceGroupName: j['source_group_name'] as String?,
      hatchedLive: _int(hatch['hatched_live']),
      hatchRate: _double(hatch['hatch_rate_percent']),
    );
  }
}

/// The farm's reproduction day (`GET /reproduction/overview`).
class ReproOverview {
  const ReproOverview({this.pregnant = const [], this.awaitingCheck = const [], this.recentBirths = 0, this.inMilk = 0, this.dueSoon = 0, this.incubations = const []});

  final List<Map<String, dynamic>> pregnant;
  final List<Map<String, dynamic>> awaitingCheck;
  final int recentBirths;
  final int inMilk;
  final int dueSoon;
  final List<IncubationBatch> incubations;

  bool get isEmpty => pregnant.isEmpty && awaitingCheck.isEmpty && recentBirths == 0 && inMilk == 0 && incubations.isEmpty;

  factory ReproOverview.fromJson(Map<String, dynamic> j) => ReproOverview(
        pregnant: _maps(j['pregnant']),
        awaitingCheck: _maps(j['awaiting_pregnancy_check']),
        recentBirths: _maps(j['recent_births']).length,
        inMilk: _int(j['in_milk_count']) ?? 0,
        dueSoon: _int(j['due_soon_count']) ?? 0,
        incubations: [for (final b in _maps(j['incubations'])) IncubationBatch.fromJson(b)],
      );
}
