/// The generic feed architecture (docs/GENERIC-FEED-ARCHITECTURE.md) as the
/// tablet reads it: products and lots, formulas and batches, programs,
/// the resolved feeding plan of an animal or group, feeding events, and
/// the stock-control views (cover, reorder, allocations, reconciliation).
///
/// Nothing here is species-specific and nothing collapses the five
/// concepts: a product is what can be fed, a formula how a farm-made feed
/// is meant to be made, a batch what was mixed, a program what a subject
/// should get, an event what it did get.
library;

double _d(Object? v, [double fallback = 0]) => (v as num?)?.toDouble() ?? fallback;
double? _dn(Object? v) => (v as num?)?.toDouble();
int _i(Object? v, [int fallback = 0]) => (v as num?)?.toInt() ?? fallback;
DateTime? _dt(Object? v) => v == null ? null : DateTime.tryParse(v as String);
List<Map<String, dynamic>> _maps(Object? v) => [for (final e in v as List<dynamic>? ?? const []) e as Map<String, dynamic>];
List<String> _strings(Object? v) => [for (final e in v as List<dynamic>? ?? const []) e.toString()];

// ------------------------------------------------------------- products
class FeedLot {
  const FeedLot({
    required this.id,
    required this.feedProductId,
    required this.lotCode,
    required this.sourceType,
    this.supplierLabel,
    this.feedBatchId,
    required this.receivedAt,
    this.expiryDate,
    required this.receivedQuantity,
    required this.acceptedQuantity,
    required this.rejectedQuantity,
    required this.quantityOnHand,
    required this.unit,
    this.unitCost,
    required this.status,
    this.reference,
  });

  final String id;
  final String feedProductId;
  final String lotCode;

  /// purchased | farm_produced | opening_balance
  final String sourceType;
  final String? supplierLabel;
  final String? feedBatchId;
  final DateTime receivedAt;
  final DateTime? expiryDate;
  final double receivedQuantity;
  final double acceptedQuantity;
  final double rejectedQuantity;
  final double quantityOnHand;
  final String unit;
  final double? unitCost;

  /// active | quarantined | blocked | recalled | expired | depleted
  final String status;
  final String? reference;

  bool get usable => status == 'active' && quantityOnHand > 0;

  factory FeedLot.fromJson(Map<String, dynamic> json) => FeedLot(
        id: json['id'] as String,
        feedProductId: json['feed_product_id'] as String,
        lotCode: json['lot_code'] as String,
        sourceType: json['source_type'] as String? ?? 'purchased',
        supplierLabel: json['supplier_label'] as String?,
        feedBatchId: json['feed_batch_id'] as String?,
        receivedAt: _dt(json['received_at']) ?? DateTime.now(),
        expiryDate: _dt(json['expiry_date']),
        receivedQuantity: _d(json['received_quantity']),
        acceptedQuantity: _d(json['accepted_quantity']),
        rejectedQuantity: _d(json['rejected_quantity']),
        quantityOnHand: _d(json['quantity_on_hand']),
        unit: json['unit'] as String? ?? 'kg',
        unitCost: _dn(json['unit_cost']),
        status: json['status'] as String? ?? 'active',
        reference: json['reference'] as String?,
      );
}

class FeedAvailability {
  const FeedAvailability({
    required this.onHand,
    required this.unusable,
    required this.reserved,
    required this.available,
    required this.unit,
    this.unusableByStatus = const {},
    this.lots = const [],
  });

  final double onHand;
  final double unusable;
  final double reserved;
  final double available;
  final String unit;
  final Map<String, double> unusableByStatus;
  final List<FeedLot> lots;

  static const empty = FeedAvailability(onHand: 0, unusable: 0, reserved: 0, available: 0, unit: 'kg');

  factory FeedAvailability.fromJson(Map<String, dynamic> json) => FeedAvailability(
        onHand: _d(json['on_hand']),
        unusable: _d(json['unusable']),
        reserved: _d(json['reserved']),
        available: _d(json['available']),
        unit: json['unit'] as String? ?? 'kg',
        unusableByStatus: {for (final e in (json['unusable_by_status'] as Map<String, dynamic>? ?? const {}).entries) e.key: _d(e.value)},
        lots: [
          for (final l in _maps(json['lots']))
            FeedLot.fromJson({...l, 'feed_product_id': json['feed_product_id'] ?? l['feed_product_id'] ?? ''}),
        ],
      );
}

class FeedProduct {
  const FeedProduct({
    required this.id,
    required this.code,
    required this.name,
    this.nameAr,
    required this.sourceType,
    required this.isIngredient,
    required this.isFeedable,
    this.category,
    required this.unit,
    required this.inventoryItemId,
    this.defaultUnitCost,
    required this.status,
    required this.availability,
    this.policyNames = const [],
    this.hasActiveFormula = false,
  });

  final String id;
  final String code;
  final String name;
  final String? nameAr;

  /// purchased | farm_produced
  final String sourceType;
  final bool isIngredient;
  final bool isFeedable;
  final String? category;
  final String unit;
  final String inventoryItemId;
  final double? defaultUnitCost;
  final String status;
  final FeedAvailability availability;
  final List<String> policyNames;
  final bool hasActiveFormula;

  String label(String lang) => lang == 'ar' && (nameAr?.isNotEmpty ?? false) ? nameAr! : name;
  bool get isFarmProduced => sourceType == 'farm_produced';
  bool get isRestricted => policyNames.isNotEmpty;

  factory FeedProduct.fromJson(Map<String, dynamic> json) => FeedProduct(
        id: json['id'] as String,
        code: json['code'] as String,
        name: json['name'] as String,
        nameAr: json['name_ar'] as String?,
        sourceType: json['source_type'] as String? ?? 'purchased',
        isIngredient: json['is_ingredient'] as bool? ?? true,
        isFeedable: json['is_feedable'] as bool? ?? false,
        category: json['category'] as String?,
        unit: json['unit'] as String? ?? 'kg',
        inventoryItemId: json['inventory_item_id'] as String? ?? '',
        defaultUnitCost: _dn(json['default_unit_cost']),
        status: json['status'] as String? ?? 'active',
        availability: json['availability'] is Map<String, dynamic>
            ? FeedAvailability.fromJson({...json['availability'] as Map<String, dynamic>, 'feed_product_id': json['id']})
            : FeedAvailability.empty,
        policyNames: _strings(json['policy_names']),
        hasActiveFormula: json['has_active_formula'] as bool? ?? false,
      );
}

// ------------------------------------------------------------- formulas
class FormulaComponent {
  const FormulaComponent({required this.id, required this.feedProductId, this.productName, required this.targetQuantity, required this.unit, this.targetPercentage});
  final String id;
  final String feedProductId;
  final String? productName;
  final double targetQuantity;
  final String unit;
  final double? targetPercentage;

  factory FormulaComponent.fromJson(Map<String, dynamic> json) => FormulaComponent(
        id: json['id'] as String? ?? '',
        feedProductId: json['feed_product_id'] as String,
        productName: json['product_name'] as String?,
        targetQuantity: _d(json['target_quantity']),
        unit: json['unit'] as String? ?? 'kg',
        targetPercentage: _dn(json['target_percentage']),
      );
}

class FormulaVersion {
  const FormulaVersion({
    required this.id,
    required this.formulaId,
    required this.version,
    required this.status,
    required this.batchSize,
    required this.unit,
    required this.locked,
    this.notes,
    this.effectiveFrom,
    required this.components,
    this.plannedCost,
  });

  final String id;
  final String formulaId;
  final int version;

  /// draft | active | retired
  final String status;
  final double batchSize;
  final String unit;

  /// Used by a completed batch: immutable from then on.
  final bool locked;
  final String? notes;
  final DateTime? effectiveFrom;
  final List<FormulaComponent> components;
  final double? plannedCost;

  factory FormulaVersion.fromJson(Map<String, dynamic> json) => FormulaVersion(
        id: json['id'] as String,
        formulaId: json['formula_id'] as String? ?? '',
        version: _i(json['version'], 1),
        status: json['status'] as String? ?? 'draft',
        batchSize: _d(json['batch_size'], 1000),
        unit: json['unit'] as String? ?? 'kg',
        locked: json['locked'] as bool? ?? false,
        notes: json['notes'] as String?,
        effectiveFrom: _dt(json['effective_from']),
        components: [for (final c in _maps(json['components'])) FormulaComponent.fromJson(c)],
        plannedCost: _dn(json['planned_cost']),
      );
}

class FeedFormula {
  const FeedFormula({
    required this.id,
    required this.code,
    required this.name,
    required this.feedProductId,
    this.productName,
    this.speciesCode,
    required this.status,
    this.description,
    this.activeVersion,
    required this.versions,
  });

  final String id;
  final String code;
  final String name;
  final String feedProductId;
  final String? productName;
  final String? speciesCode;
  final String status;
  final String? description;
  final int? activeVersion;
  final List<FormulaVersion> versions;

  FormulaVersion? get active {
    for (final v in versions) {
      if (v.status == 'active') return v;
    }
    return null;
  }

  factory FeedFormula.fromJson(Map<String, dynamic> json) => FeedFormula(
        id: json['id'] as String,
        code: json['code'] as String,
        name: json['name'] as String,
        feedProductId: json['feed_product_id'] as String,
        productName: json['product_name'] as String?,
        speciesCode: json['species_code'] as String?,
        status: json['status'] as String? ?? 'active',
        description: json['description'] as String?,
        activeVersion: (json['active_version'] as num?)?.toInt(),
        versions: [for (final v in _maps(json['versions'])) FormulaVersion.fromJson(v)],
      );
}

// -------------------------------------------------------------- batches
class BatchComponent {
  const BatchComponent({
    required this.id,
    required this.feedProductId,
    this.productName,
    this.lotId,
    this.lotCode,
    this.targetQuantity,
    this.actualQuantity,
    required this.unit,
    this.unitCost,
    this.cost,
  });

  final String id;
  final String feedProductId;
  final String? productName;
  final String? lotId;
  final String? lotCode;
  final double? targetQuantity;
  final double? actualQuantity;
  final String unit;
  final double? unitCost;
  final double? cost;

  factory BatchComponent.fromJson(Map<String, dynamic> json) => BatchComponent(
        id: json['id'] as String? ?? '',
        feedProductId: json['feed_product_id'] as String,
        productName: json['product_name'] as String?,
        lotId: json['lot_id'] as String?,
        lotCode: json['lot_code'] as String?,
        targetQuantity: _dn(json['target_quantity']),
        actualQuantity: _dn(json['actual_quantity']),
        unit: json['unit'] as String? ?? 'kg',
        unitCost: _dn(json['unit_cost']),
        cost: _dn(json['cost']),
      );
}

class FeedBatch {
  const FeedBatch({
    required this.id,
    required this.feedProductId,
    this.productName,
    this.formulaVersionId,
    this.formulaCode,
    this.formulaVersion,
    required this.batchCode,
    required this.status,
    this.targetQuantity,
    this.actualQuantity,
    required this.unit,
    this.plannedCost,
    this.actualCost,
    this.unitCost,
    this.outputLotId,
    required this.startedAt,
    this.producedAt,
    this.notes,
    required this.components,
    this.variance = const [],
  });

  final String id;
  final String feedProductId;
  final String? productName;
  final String? formulaVersionId;
  final String? formulaCode;
  final int? formulaVersion;
  final String batchCode;

  /// planned | in_progress | completed | quarantined | cancelled
  final String status;
  final double? targetQuantity;
  final double? actualQuantity;
  final String unit;
  final double? plannedCost;
  final double? actualCost;
  final double? unitCost;
  final String? outputLotId;
  final DateTime startedAt;
  final DateTime? producedAt;
  final String? notes;
  final List<BatchComponent> components;
  final List<Map<String, dynamic>> variance;

  bool get isOpen => status == 'planned' || status == 'in_progress';

  factory FeedBatch.fromJson(Map<String, dynamic> json) => FeedBatch(
        id: json['id'] as String,
        feedProductId: json['feed_product_id'] as String,
        productName: json['product_name'] as String?,
        formulaVersionId: json['formula_version_id'] as String?,
        formulaCode: json['formula_code'] as String?,
        formulaVersion: (json['formula_version'] as num?)?.toInt(),
        batchCode: json['batch_code'] as String,
        status: json['status'] as String? ?? 'planned',
        targetQuantity: _dn(json['target_quantity']),
        actualQuantity: _dn(json['actual_quantity']),
        unit: json['unit'] as String? ?? 'kg',
        plannedCost: _dn(json['planned_cost']),
        actualCost: _dn(json['actual_cost']),
        unitCost: _dn(json['unit_cost']),
        outputLotId: json['output_lot_id'] as String?,
        startedAt: _dt(json['started_at']) ?? DateTime.now(),
        producedAt: _dt(json['produced_at']),
        notes: json['notes'] as String?,
        components: [for (final c in _maps(json['components'])) BatchComponent.fromJson(c)],
        variance: _maps(json['variance']),
      );
}

// ------------------------------------------------------------- programs
class ProgramComponent {
  const ProgramComponent({
    required this.id,
    required this.feedProductId,
    this.productName,
    required this.quantityPerHead,
    required this.unit,
    required this.frequency,
    this.timing,
    required this.dailyPerHead,
  });

  final String id;
  final String feedProductId;
  final String? productName;
  final double quantityPerHead;
  final String unit;

  /// per_day | per_feeding
  final String frequency;
  final String? timing;
  final double dailyPerHead;

  factory ProgramComponent.fromJson(Map<String, dynamic> json) => ProgramComponent(
        id: json['id'] as String? ?? '',
        feedProductId: json['feed_product_id'] as String,
        productName: json['product_name'] as String?,
        quantityPerHead: _d(json['quantity_per_head']),
        unit: json['unit'] as String? ?? 'kg',
        frequency: json['frequency'] as String? ?? 'per_day',
        timing: json['timing'] as String?,
        dailyPerHead: _d(json['daily_per_head'], _d(json['quantity_per_head'])),
      );
}

class ProgramRule {
  const ProgramRule({
    required this.id,
    this.speciesCode,
    this.sex,
    this.lifeStage,
    this.managementProfile,
    this.reproductiveState,
    this.lactationState,
    this.productionMetric,
    this.productionMin,
    this.productionMax,
    this.weightMin,
    this.weightMax,
    this.ageMinDays,
    this.ageMaxDays,
    required this.priority,
  });

  final String id;
  final String? speciesCode;
  final String? sex;
  final String? lifeStage;
  final String? managementProfile;
  final String? reproductiveState;
  final String? lactationState;
  final String? productionMetric;
  final double? productionMin;
  final double? productionMax;
  final double? weightMin;
  final double? weightMax;
  final int? ageMinDays;
  final int? ageMaxDays;
  final int priority;

  /// "cow · F · adult · dairy · lactating · milk 20+ L" — the rule as a
  /// line, for the programs tab. Species names are looked up by the caller.
  List<String> parts(String Function(String code) speciesName) => [
        if (speciesCode != null) speciesName(speciesCode!),
        if (sex != null) sex!,
        if (lifeStage != null) lifeStage!,
        if (managementProfile != null) managementProfile!,
        if (reproductiveState != null) reproductiveState!,
        if (lactationState != null) lactationState!,
        if (productionMin != null || productionMax != null)
          '${(productionMetric ?? 'milk_l_per_day').replaceAll('_', ' ')} ${productionMin ?? 0}–${productionMax ?? '∞'}',
        if (weightMin != null || weightMax != null) 'weight ${weightMin ?? 0}–${weightMax ?? '∞'} kg',
        if (ageMinDays != null || ageMaxDays != null) 'age ${ageMinDays ?? 0}–${ageMaxDays ?? '∞'} d',
      ];

  factory ProgramRule.fromJson(Map<String, dynamic> json) => ProgramRule(
        id: json['id'] as String? ?? '',
        speciesCode: json['species_code'] as String?,
        sex: json['sex'] as String?,
        lifeStage: json['life_stage'] as String?,
        managementProfile: json['management_profile'] as String?,
        reproductiveState: json['reproductive_state'] as String?,
        lactationState: json['lactation_state'] as String?,
        productionMetric: json['production_metric'] as String?,
        productionMin: _dn(json['production_min']),
        productionMax: _dn(json['production_max']),
        weightMin: _dn(json['weight_min']),
        weightMax: _dn(json['weight_max']),
        ageMinDays: (json['age_min_days'] as num?)?.toInt(),
        ageMaxDays: (json['age_max_days'] as num?)?.toInt(),
        priority: _i(json['priority']),
      );
}

class ProgramVersion {
  const ProgramVersion({
    required this.id,
    required this.programId,
    required this.version,
    required this.status,
    required this.feedingsPerDay,
    required this.locked,
    required this.components,
    required this.rules,
  });

  final String id;
  final String programId;
  final int version;
  final String status;
  final int feedingsPerDay;
  final bool locked;
  final List<ProgramComponent> components;
  final List<ProgramRule> rules;

  factory ProgramVersion.fromJson(Map<String, dynamic> json) => ProgramVersion(
        id: json['id'] as String,
        programId: json['program_id'] as String? ?? '',
        version: _i(json['version'], 1),
        status: json['status'] as String? ?? 'draft',
        feedingsPerDay: _i(json['feedings_per_day'], 2),
        locked: json['locked'] as bool? ?? false,
        components: [for (final c in _maps(json['components'])) ProgramComponent.fromJson(c)],
        rules: [for (final r in _maps(json['rules'])) ProgramRule.fromJson(r)],
      );
}

class FeedingProgram {
  const FeedingProgram({
    required this.id,
    required this.code,
    required this.name,
    this.nameAr,
    this.category,
    required this.status,
    this.description,
    this.activeVersion,
    required this.versions,
    this.subjectsAssigned = 0,
  });

  final String id;
  final String code;
  final String name;
  final String? nameAr;
  final String? category;
  final String status;
  final String? description;
  final int? activeVersion;
  final List<ProgramVersion> versions;
  final int subjectsAssigned;

  String label(String lang) => lang == 'ar' && (nameAr?.isNotEmpty ?? false) ? nameAr! : name;

  ProgramVersion? get active {
    for (final v in versions) {
      if (v.status == 'active') return v;
    }
    return null;
  }

  factory FeedingProgram.fromJson(Map<String, dynamic> json) => FeedingProgram(
        id: json['id'] as String,
        code: json['code'] as String,
        name: json['name'] as String,
        nameAr: json['name_ar'] as String?,
        category: json['category'] as String?,
        status: json['status'] as String? ?? 'active',
        description: json['description'] as String?,
        activeVersion: (json['active_version'] as num?)?.toInt(),
        versions: [for (final v in _maps(json['versions'])) ProgramVersion.fromJson(v)],
        subjectsAssigned: _i(json['subjects_assigned']),
      );
}

/// The resolver's answer for one program (§14): which rule matched and why.
class ProgramMatch {
  const ProgramMatch({
    required this.programId,
    required this.programCode,
    required this.programName,
    this.programNameAr,
    required this.versionId,
    required this.version,
    required this.specificity,
    required this.priority,
    required this.reasons,
  });

  final String programId;
  final String programCode;
  final String programName;
  final String? programNameAr;
  final String versionId;
  final int version;
  final int specificity;
  final int priority;
  final List<String> reasons;

  String label(String lang) => lang == 'ar' && (programNameAr?.isNotEmpty ?? false) ? programNameAr! : programName;

  factory ProgramMatch.fromJson(Map<String, dynamic> json) => ProgramMatch(
        programId: json['program_id'] as String,
        programCode: json['program_code'] as String? ?? '',
        programName: json['program_name'] as String? ?? '',
        programNameAr: json['program_name_ar'] as String?,
        versionId: json['version_id'] as String? ?? '',
        version: _i(json['version'], 1),
        specificity: _i(json['specificity']),
        priority: _i(json['priority']),
        reasons: _strings(json['reasons']),
      );
}

// ----------------------------------------------------------------- plan
class DailyTarget {
  const DailyTarget({required this.feedProductId, this.productName, required this.unit, required this.dailyTotal, this.fedToday, this.remainingToday});
  final String feedProductId;
  final String? productName;
  final String unit;
  final double dailyTotal;
  final double? fedToday;
  final double? remainingToday;

  factory DailyTarget.fromJson(Map<String, dynamic> json) => DailyTarget(
        feedProductId: json['feed_product_id'] as String,
        productName: json['product_name'] as String?,
        unit: json['unit'] as String? ?? 'kg',
        dailyTotal: _d(json['daily_total']),
        fedToday: _dn(json['fed_today']),
        remainingToday: _dn(json['remaining_today']),
      );
}

class PlanLine {
  const PlanLine({
    required this.feedProductId,
    this.productName,
    required this.quantityPerHead,
    required this.unit,
    required this.frequency,
    this.timing,
    required this.dailyPerHead,
    required this.dailyTotal,
    this.note,
  });

  final String feedProductId;
  final String? productName;
  final double quantityPerHead;
  final String unit;
  final String frequency;
  final String? timing;
  final double dailyPerHead;
  final double dailyTotal;

  /// "override: …" when an individual quantity replaced the program's.
  final String? note;

  factory PlanLine.fromJson(Map<String, dynamic> json) => PlanLine(
        feedProductId: json['feed_product_id'] as String,
        productName: json['product_name'] as String?,
        quantityPerHead: _d(json['quantity_per_head']),
        unit: json['unit'] as String? ?? 'kg',
        frequency: json['frequency'] as String? ?? 'per_day',
        timing: json['timing'] as String?,
        dailyPerHead: _d(json['daily_per_head']),
        dailyTotal: _d(json['daily_total']),
        note: json['note'] as String?,
      );
}

class PlanSupplement {
  const PlanSupplement({required this.assignmentId, required this.feedProductId, this.productName, required this.dailyPerHead, required this.unit, required this.dailyTotal, this.reason, this.validTo});
  final String assignmentId;
  final String feedProductId;
  final String? productName;
  final double dailyPerHead;
  final String unit;
  final double dailyTotal;
  final String? reason;
  final DateTime? validTo;

  factory PlanSupplement.fromJson(Map<String, dynamic> json) => PlanSupplement(
        assignmentId: json['assignment_id'] as String? ?? '',
        feedProductId: json['feed_product_id'] as String,
        productName: json['product_name'] as String?,
        dailyPerHead: _d(json['daily_per_head']),
        unit: json['unit'] as String? ?? 'kg',
        dailyTotal: _d(json['daily_total']),
        reason: json['reason'] as String?,
        validTo: _dt(json['valid_to']),
      );
}

class PlanProgram {
  const PlanProgram({
    required this.programId,
    required this.programName,
    this.programNameAr,
    required this.programCode,
    required this.versionId,
    required this.version,
    required this.feedingsPerDay,
    required this.source,
    required this.assignmentId,
    this.inheritedFromGroupId,
    this.inheritedFromGroupName,
    this.since,
  });

  final String programId;
  final String programName;
  final String? programNameAr;
  final String programCode;
  final String versionId;
  final int version;
  final int feedingsPerDay;

  /// explicit | inherited
  final String source;
  final String assignmentId;
  final String? inheritedFromGroupId;
  final String? inheritedFromGroupName;
  final DateTime? since;

  bool get isInherited => source == 'inherited';
  String label(String lang) => lang == 'ar' && (programNameAr?.isNotEmpty ?? false) ? programNameAr! : programName;

  factory PlanProgram.fromJson(Map<String, dynamic> json) {
    final from = json['inherited_from'] as Map<String, dynamic>?;
    return PlanProgram(
      programId: json['program_id'] as String,
      programName: json['program_name'] as String? ?? '',
      programNameAr: json['program_name_ar'] as String?,
      programCode: json['program_code'] as String? ?? '',
      versionId: json['version_id'] as String? ?? '',
      version: _i(json['version'], 1),
      feedingsPerDay: _i(json['feedings_per_day'], 2),
      source: json['source'] as String? ?? 'explicit',
      assignmentId: json['assignment_id'] as String? ?? '',
      inheritedFromGroupId: from?['group_id'] as String?,
      inheritedFromGroupName: from?['group_name'] as String?,
      since: _dt(json['since']),
    );
  }
}

/// `GET /livestock-subjects/{id}/feeding-plan` — the feeding section of an
/// animal or group profile (§17): what it should get today, from where,
/// with what exceptions, what it did get, and whether a review is due.
class FeedingPlan {
  const FeedingPlan({
    required this.subject,
    this.program,
    required this.headCount,
    required this.components,
    required this.supplements,
    required this.overrides,
    required this.restrictions,
    required this.dailyTargets,
    required this.reviewRequired,
    this.recommended,
    required this.warnings,
    required this.eligible,
    required this.recentEvents,
    required this.feedCost7d,
    required this.fed7d,
  });

  final Map<String, dynamic> subject;
  final PlanProgram? program;
  final int headCount;
  final List<PlanLine> components;
  final List<PlanSupplement> supplements;
  final List<Map<String, dynamic>> overrides;
  final List<Map<String, dynamic>> restrictions;
  final List<DailyTarget> dailyTargets;
  final bool reviewRequired;
  final ProgramMatch? recommended;
  final List<String> warnings;
  final List<ProgramMatch> eligible;
  final List<FeedingEvent> recentEvents;
  final double feedCost7d;
  final List<DailyTarget> fed7d;

  String get subjectType => subject['subject_type'] as String? ?? 'animal';
  String get subjectId => subject['subject_id'] as String? ?? '';

  factory FeedingPlan.fromJson(Map<String, dynamic> json) {
    final review = json['review'] as Map<String, dynamic>? ?? const {};
    return FeedingPlan(
      subject: json['subject'] as Map<String, dynamic>? ?? const {},
      program: json['program'] is Map<String, dynamic> ? PlanProgram.fromJson(json['program'] as Map<String, dynamic>) : null,
      headCount: _i(json['head_count'], 1),
      components: [for (final c in _maps(json['components'])) PlanLine.fromJson(c)],
      supplements: [for (final s in _maps(json['supplements'])) PlanSupplement.fromJson(s)],
      overrides: _maps(json['overrides']),
      restrictions: _maps(json['restrictions']),
      dailyTargets: [for (final t in _maps(json['daily_targets'])) DailyTarget.fromJson(t)],
      reviewRequired: review['required'] as bool? ?? false,
      recommended: review['recommended'] is Map<String, dynamic> ? ProgramMatch.fromJson(review['recommended'] as Map<String, dynamic>) : null,
      warnings: _strings(review['warnings']),
      eligible: [for (final e in _maps(json['eligible_programs'])) ProgramMatch.fromJson(e)],
      recentEvents: [for (final e in _maps(json['recent_events'])) FeedingEvent.fromJson(e)],
      feedCost7d: _d(json['feed_cost_7d']),
      fed7d: [for (final t in _maps(json['fed_7d'])) DailyTarget.fromJson({...t, 'daily_total': t['quantity']})],
    );
  }
}

/// `GET /feeding-plan/today` — the feed-room list.
class DailyPlanLine {
  const DailyPlanLine({
    required this.subjectType,
    required this.subjectId,
    required this.name,
    required this.species,
    required this.headCount,
    this.program,
    required this.dailyTargets,
    required this.warnings,
    required this.reviewRequired,
  });

  final String subjectType;
  final String subjectId;
  final String name;
  final String species;
  final int headCount;
  final PlanProgram? program;
  final List<DailyTarget> dailyTargets;
  final List<String> warnings;
  final bool reviewRequired;

  factory DailyPlanLine.fromJson(Map<String, dynamic> json) => DailyPlanLine(
        subjectType: json['subject_type'] as String,
        subjectId: json['subject_id'] as String,
        name: json['name'] as String? ?? '',
        species: json['species'] as String? ?? '',
        headCount: _i(json['head_count'], 1),
        program: json['program'] is Map<String, dynamic> ? PlanProgram.fromJson(json['program'] as Map<String, dynamic>) : null,
        dailyTargets: [for (final t in _maps(json['daily_targets'])) DailyTarget.fromJson(t)],
        warnings: _strings(json['warnings']),
        reviewRequired: json['review_required'] as bool? ?? false,
      );
}

class DailyPlan {
  const DailyPlan({required this.date, required this.lines, required this.totals});
  final String date;
  final List<DailyPlanLine> lines;
  final List<DailyTarget> totals;

  static const empty = DailyPlan(date: '', lines: [], totals: []);

  factory DailyPlan.fromJson(Map<String, dynamic> json) => DailyPlan(
        date: json['date'] as String? ?? '',
        lines: [for (final l in _maps(json['lines'])) DailyPlanLine.fromJson(l)],
        totals: [for (final t in _maps(json['totals'])) DailyTarget.fromJson(t)],
      );
}

// --------------------------------------------------------------- events
class FeedingEventComponent {
  const FeedingEventComponent({required this.id, required this.feedProductId, this.lotId, this.batchId, required this.quantityOffered, this.quantityConsumed, required this.unit, this.unitCost, this.cost});
  final String id;
  final String feedProductId;
  final String? lotId;
  final String? batchId;
  final double quantityOffered;

  /// Null means "not measured" — never zero.
  final double? quantityConsumed;
  final String unit;
  final double? unitCost;
  final double? cost;

  factory FeedingEventComponent.fromJson(Map<String, dynamic> json) => FeedingEventComponent(
        id: json['id'] as String? ?? '',
        feedProductId: json['feed_product_id'] as String,
        lotId: json['lot_id'] as String?,
        batchId: json['batch_id'] as String?,
        quantityOffered: _d(json['quantity_offered']),
        quantityConsumed: _dn(json['quantity_consumed']),
        unit: json['unit'] as String? ?? 'kg',
        unitCost: _dn(json['unit_cost']),
        cost: _dn(json['cost']),
      );
}

class FeedingEvent {
  const FeedingEvent({
    required this.id,
    required this.subjectType,
    required this.subjectId,
    this.programVersionId,
    required this.occurredAt,
    required this.eventType,
    this.headCount,
    this.recordedBy,
    this.notes,
    required this.status,
    this.reversalOfId,
    this.totalCost,
    required this.components,
  });

  final String id;
  final String subjectType;
  final String subjectId;
  final String? programVersionId;
  final DateTime occurredAt;

  /// offered | delivered | consumed_estimate | refusal
  final String eventType;
  final int? headCount;
  final String? recordedBy;
  final String? notes;

  /// recorded | reversed | reversal
  final String status;
  final String? reversalOfId;
  final double? totalCost;
  final List<FeedingEventComponent> components;

  double get totalQuantity => components.fold(0.0, (s, c) => s + c.quantityOffered);

  factory FeedingEvent.fromJson(Map<String, dynamic> json) => FeedingEvent(
        id: json['id'] as String,
        subjectType: json['subject_type'] as String? ?? 'animal',
        subjectId: json['subject_id'] as String? ?? '',
        programVersionId: json['program_version_id'] as String?,
        occurredAt: _dt(json['occurred_at']) ?? DateTime.now(),
        eventType: json['event_type'] as String? ?? 'offered',
        headCount: (json['head_count'] as num?)?.toInt(),
        recordedBy: json['recorded_by'] as String?,
        notes: json['notes'] as String?,
        status: json['status'] as String? ?? 'recorded',
        reversalOfId: json['reversal_of_id'] as String?,
        totalCost: _dn(json['total_cost']),
        components: [for (final c in _maps(json['components'])) FeedingEventComponent.fromJson(c)],
      );
}

// ------------------------------------------------------ stock control
/// One row of `GET /feed-inventory/days-of-cover`, and — with the reorder
/// fields — of `GET /feed-inventory/reorder-recommendations` (§28, §29).
class FeedCover {
  const FeedCover({
    required this.feedProductId,
    required this.code,
    required this.name,
    required this.unit,
    required this.sourceType,
    required this.onHand,
    required this.unusable,
    required this.reserved,
    required this.available,
    required this.eligibleAvailable,
    this.dailyDemand,
    this.demandSource,
    required this.demandBySpecies,
    this.daysOfCover,
    this.projectedStockoutAt,
    this.leadTimeDays,
    required this.status,
    required this.reasons,
    required this.warnings,
    this.reorderPolicy,
    this.suggestedReorderQuantity,
    this.programsAffected = const [],
    this.coveredByTaskId,
    this.priority,
  });

  final String feedProductId;
  final String code;
  final String name;
  final String unit;
  final String sourceType;
  final double onHand;
  final double unusable;
  final double reserved;
  final double available;
  final double eligibleAvailable;
  final double? dailyDemand;

  /// programs | history | null
  final String? demandSource;
  final Map<String, double> demandBySpecies;
  final double? daysOfCover;
  final DateTime? projectedStockoutAt;
  final int? leadTimeDays;

  /// ok | reorder | below_minimum | stockout_risk | no_demand
  final String status;
  final List<String> reasons;
  final List<String> warnings;
  final Map<String, dynamic>? reorderPolicy;
  final double? suggestedReorderQuantity;
  final List<String> programsAffected;
  final String? coveredByTaskId;
  final String? priority;

  bool get atRisk => status == 'reorder' || status == 'below_minimum' || status == 'stockout_risk';

  factory FeedCover.fromJson(Map<String, dynamic> json) => FeedCover(
        feedProductId: json['feed_product_id'] as String,
        code: json['code'] as String? ?? '',
        name: json['name'] as String? ?? '',
        unit: json['unit'] as String? ?? 'kg',
        sourceType: json['source_type'] as String? ?? 'purchased',
        onHand: _d(json['on_hand']),
        unusable: _d(json['unusable']),
        reserved: _d(json['reserved']),
        available: _d(json['available']),
        eligibleAvailable: _d(json['eligible_available'], _d(json['available'])),
        dailyDemand: _dn(json['daily_demand']),
        demandSource: json['demand_source'] as String?,
        demandBySpecies: {for (final e in (json['demand_by_species'] as Map<String, dynamic>? ?? const {}).entries) e.key: _d(e.value)},
        daysOfCover: _dn(json['days_of_cover']),
        projectedStockoutAt: _dt(json['projected_stockout_at']),
        leadTimeDays: (json['lead_time_days'] as num?)?.toInt(),
        status: json['status'] as String? ?? 'ok',
        reasons: _strings(json['reasons']),
        warnings: _strings(json['warnings']),
        reorderPolicy: json['reorder_policy'] as Map<String, dynamic>?,
        suggestedReorderQuantity: _dn(json['suggested_reorder_quantity']),
        programsAffected: _strings(json['programs_affected']),
        coveredByTaskId: json['covered_by_task_id'] as String?,
        priority: json['priority'] as String?,
      );
}

class FeedAllocation {
  const FeedAllocation({
    required this.id,
    required this.feedProductId,
    this.productName,
    this.lotId,
    this.speciesCode,
    this.subjectType,
    this.subjectId,
    this.feedingProgramId,
    this.purpose,
    required this.allocatedQuantity,
    required this.consumedQuantity,
    required this.remainingQuantity,
    required this.unit,
    required this.transferable,
    required this.status,
  });

  final String id;
  final String feedProductId;
  final String? productName;
  final String? lotId;
  final String? speciesCode;
  final String? subjectType;
  final String? subjectId;
  final String? feedingProgramId;
  final String? purpose;
  final double allocatedQuantity;
  final double consumedQuantity;
  final double remainingQuantity;
  final String unit;
  final bool transferable;
  final String status;

  factory FeedAllocation.fromJson(Map<String, dynamic> json) => FeedAllocation(
        id: json['id'] as String,
        feedProductId: json['feed_product_id'] as String,
        productName: json['product_name'] as String?,
        lotId: json['lot_id'] as String?,
        speciesCode: json['species_code'] as String?,
        subjectType: json['subject_type'] as String?,
        subjectId: json['subject_id'] as String?,
        feedingProgramId: json['feeding_program_id'] as String?,
        purpose: json['purpose'] as String?,
        allocatedQuantity: _d(json['allocated_quantity']),
        consumedQuantity: _d(json['consumed_quantity']),
        remainingQuantity: _d(json['remaining_quantity'], _d(json['allocated_quantity']) - _d(json['consumed_quantity'])),
        unit: json['unit'] as String? ?? 'kg',
        transferable: json['transferable'] as bool? ?? false,
        status: json['status'] as String? ?? 'active',
      );
}

class FeedReconciliation {
  const FeedReconciliation({
    required this.id,
    required this.feedProductId,
    this.productName,
    this.lotId,
    required this.periodFrom,
    required this.periodTo,
    required this.opening,
    required this.received,
    required this.issuedToBatches,
    required this.issuedToFeeding,
    required this.otherIssued,
    required this.waste,
    required this.returned,
    required this.adjustment,
    required this.expectedClosing,
    this.countedClosing,
    this.varianceQuantity,
    this.variancePct,
    required this.unit,
    required this.status,
    this.explanation,
  });

  final String id;
  final String feedProductId;
  final String? productName;
  final String? lotId;
  final DateTime periodFrom;
  final DateTime periodTo;
  final double opening;
  final double received;
  final double issuedToBatches;
  final double issuedToFeeding;
  final double otherIssued;
  final double waste;
  final double returned;
  final double adjustment;
  final double expectedClosing;
  final double? countedClosing;
  final double? varianceQuantity;
  final double? variancePct;
  final String unit;

  /// open | reviewed | closed
  final String status;
  final String? explanation;

  factory FeedReconciliation.fromJson(Map<String, dynamic> json) => FeedReconciliation(
        id: json['id'] as String,
        feedProductId: json['feed_product_id'] as String,
        productName: json['product_name'] as String?,
        lotId: json['lot_id'] as String?,
        periodFrom: _dt(json['period_from']) ?? DateTime.now(),
        periodTo: _dt(json['period_to']) ?? DateTime.now(),
        opening: _d(json['opening_quantity']),
        received: _d(json['received_quantity']),
        issuedToBatches: _d(json['issued_to_batches']),
        issuedToFeeding: _d(json['issued_to_feeding']),
        otherIssued: _d(json['other_issued_quantity']),
        waste: _d(json['waste_quantity']),
        returned: _d(json['returned_quantity']),
        adjustment: _d(json['adjustment_quantity']),
        expectedClosing: _d(json['expected_closing_quantity']),
        countedClosing: _dn(json['counted_closing_quantity']),
        varianceQuantity: _dn(json['variance_quantity']),
        variancePct: _dn(json['variance_pct']),
        unit: json['unit'] as String? ?? 'kg',
        status: json['status'] as String? ?? 'open',
        explanation: json['explanation'] as String?,
      );
}

class FeedCostSummary {
  const FeedCostSummary({
    required this.days,
    required this.totalFeedingCost,
    required this.dailyAverage,
    required this.bySubject,
    required this.byProduct,
    required this.batches,
    required this.batchCostTotal,
  });

  final int days;
  final double totalFeedingCost;
  final double dailyAverage;
  final List<Map<String, dynamic>> bySubject;
  final List<Map<String, dynamic>> byProduct;
  final List<Map<String, dynamic>> batches;
  final double batchCostTotal;

  static const empty = FeedCostSummary(days: 30, totalFeedingCost: 0, dailyAverage: 0, bySubject: [], byProduct: [], batches: [], batchCostTotal: 0);

  factory FeedCostSummary.fromJson(Map<String, dynamic> json) => FeedCostSummary(
        days: _i(json['days'], 30),
        totalFeedingCost: _d(json['total_feeding_cost']),
        dailyAverage: _d(json['daily_average']),
        bySubject: _maps(json['by_subject']),
        byProduct: _maps(json['by_product']),
        batches: _maps(json['batches']),
        batchCostTotal: _d(json['batch_cost_total']),
      );
}

class NutrientDef {
  const NutrientDef({required this.code, required this.nameEn, required this.nameAr, required this.unit, required this.category});
  final String code;
  final String nameEn;
  final String nameAr;
  final String unit;
  final String category;

  String label(String lang) => lang == 'ar' ? nameAr : nameEn;

  factory NutrientDef.fromJson(Map<String, dynamic> json) => NutrientDef(
        code: json['code'] as String,
        nameEn: json['name_en'] as String,
        nameAr: json['name_ar'] as String? ?? json['name_en'] as String,
        unit: json['unit'] as String? ?? '',
        category: json['category'] as String? ?? 'other',
      );
}

class NutrientProfile {
  const NutrientProfile({required this.id, required this.subjectType, required this.subjectId, required this.basis, required this.sourceType, this.reference, required this.effectiveAt, required this.values});
  final String id;
  final String subjectType;
  final String subjectId;
  final String basis;

  /// declared | calculated | lab
  final String sourceType;
  final String? reference;
  final DateTime effectiveAt;

  /// {nutrient_code, value, unit}
  final List<Map<String, dynamic>> values;

  factory NutrientProfile.fromJson(Map<String, dynamic> json) => NutrientProfile(
        id: json['id'] as String? ?? '',
        subjectType: json['subject_type'] as String? ?? 'feed_product',
        subjectId: json['subject_id'] as String? ?? '',
        basis: json['basis'] as String? ?? 'as_fed',
        sourceType: json['source_type'] as String? ?? 'declared',
        reference: json['reference'] as String?,
        effectiveAt: _dt(json['effective_at']) ?? DateTime.now(),
        values: _maps(json['values']),
      );
}

/// `GET /feed-lots/{id}/trace` — both directions (§12).
class LotTrace {
  const LotTrace({required this.lot, required this.upstream, required this.downstreamBatches, required this.feedingEvents, required this.exposedSubjects});
  final Map<String, dynamic> lot;
  final List<Map<String, dynamic>> upstream;
  final List<Map<String, dynamic>> downstreamBatches;
  final List<Map<String, dynamic>> feedingEvents;
  final List<Map<String, dynamic>> exposedSubjects;

  factory LotTrace.fromJson(Map<String, dynamic> json) => LotTrace(
        lot: json['lot'] as Map<String, dynamic>? ?? const {},
        upstream: _maps(json['upstream_ingredient_lots']),
        downstreamBatches: _maps(json['downstream_batches']),
        feedingEvents: _maps(json['feeding_events']),
        exposedSubjects: _maps(json['exposed_subjects']),
      );
}
