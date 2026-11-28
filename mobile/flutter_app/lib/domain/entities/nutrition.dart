/// Nutrient requirements and formula assessments (master prompt Package 11),
/// as the server computes them: the app shows them, it never recomputes.
library;

double? _dn(Object? v) => (v as num?)?.toDouble();
double _d(Object? v) => (v as num?)?.toDouble() ?? 0;
List<Map<String, dynamic>> _maps(Object? v) => [for (final x in (v as List? ?? const [])) (x as Map).cast<String, dynamic>()];

class RequirementValue {
  const RequirementValue({required this.code, required this.name, required this.nameAr, this.min, this.max, required this.unit});
  final String code;
  final String name;
  final String nameAr;
  final double? min;
  final double? max;
  final String unit;

  String label(String lang) => lang == 'ar' ? nameAr : name;

  factory RequirementValue.fromJson(Map<String, dynamic> j) => RequirementValue(
        code: '${j['nutrient_code']}',
        name: '${j['name'] ?? j['nutrient_code']}',
        nameAr: '${j['name_ar'] ?? j['name'] ?? j['nutrient_code']}',
        min: _dn(j['min_value']),
        max: _dn(j['max_value']),
        unit: '${j['unit'] ?? ''}',
      );
}

/// What one kind of animal at one stage needs, on the ration's dry matter, from a named source.
class RequirementSet {
  const RequirementSet({
    required this.id,
    required this.code,
    required this.version,
    required this.name,
    required this.speciesCode,
    this.stage,
    this.referenceWeightKg,
    this.milkYieldKg,
    this.expectedDmiKg,
    required this.sourceType,
    required this.sourceReference,
    required this.status,
    required this.values,
  });

  final String id;
  final String code;
  final int version;
  final String name;
  final String speciesCode;
  final String? stage;
  final double? referenceWeightKg;
  final double? milkYieldKg;
  final double? expectedDmiKg;
  final String sourceType;
  final String sourceReference;

  /// active | retired
  final String status;
  final List<RequirementValue> values;

  factory RequirementSet.fromJson(Map<String, dynamic> j) => RequirementSet(
        id: '${j['id']}',
        code: '${j['code']}',
        version: (j['version'] as num?)?.toInt() ?? 1,
        name: '${j['name'] ?? ''}',
        speciesCode: '${j['species_code'] ?? ''}',
        stage: j['production_stage'] as String?,
        referenceWeightKg: _dn(j['reference_body_weight_kg']),
        milkYieldKg: _dn(j['milk_yield_kg']),
        expectedDmiKg: _dn(j['expected_dmi_kg']),
        sourceType: '${j['source_type'] ?? ''}',
        sourceReference: '${j['source_reference'] ?? ''}',
        status: '${j['status'] ?? 'active'}',
        values: [for (final v in _maps(j['values'])) RequirementValue.fromJson(v)],
      );
}

class AssessedComponent {
  const AssessedComponent({required this.name, required this.quantityKg, required this.inclusionPct, this.dmPct, this.profileSource, this.profileBasis});
  final String name;
  final double quantityKg;
  final double inclusionPct;
  final double? dmPct;
  final String? profileSource;
  final String? profileBasis;

  factory AssessedComponent.fromJson(Map<String, dynamic> j) {
    final p = (j['profile'] as Map?)?.cast<String, dynamic>();
    return AssessedComponent(
      name: '${j['name'] ?? ''}',
      quantityKg: _d(j['quantity_kg']),
      inclusionPct: _d(j['inclusion_pct']),
      dmPct: _dn(j['dm_pct']),
      profileSource: p?['source_type'] as String?,
      profileBasis: p?['basis'] as String?,
    );
  }
}

class MixNutrient {
  const MixNutrient({required this.code, required this.name, required this.nameAr, this.unit, this.asFed, this.dryMatter, required this.coveragePct});
  final String code;
  final String name;
  final String nameAr;
  final String? unit;
  final double? asFed;
  final double? dryMatter;
  final double coveragePct;

  String label(String lang) => lang == 'ar' ? nameAr : name;

  factory MixNutrient.fromJson(Map<String, dynamic> j) => MixNutrient(
        code: '${j['nutrient_code']}',
        name: '${j['name'] ?? j['nutrient_code']}',
        nameAr: '${j['name_ar'] ?? j['name'] ?? j['nutrient_code']}',
        unit: j['unit'] as String?,
        asFed: _dn(j['as_fed_value']),
        dryMatter: _dn(j['dry_matter_value']),
        coveragePct: _d(j['coverage_pct']),
      );
}

class RationNutrient {
  const RationNutrient({required this.code, required this.name, required this.nameAr, required this.unit, this.min, this.max, this.value, required this.status});
  final String code;
  final String name;
  final String nameAr;
  final String unit;
  final double? min;
  final double? max;
  final double? value;

  /// met | below | above | insufficient_data
  final String status;

  String label(String lang) => lang == 'ar' ? nameAr : name;

  factory RationNutrient.fromJson(Map<String, dynamic> j) => RationNutrient(
        code: '${j['nutrient_code']}',
        name: '${j['name'] ?? j['nutrient_code']}',
        nameAr: '${j['name_ar'] ?? j['name'] ?? j['nutrient_code']}',
        unit: '${j['unit'] ?? ''}',
        min: _dn(j['min_value']),
        max: _dn(j['max_value']),
        value: _dn(j['value']),
        status: '${j['status'] ?? 'insufficient_data'}',
      );
}

/// One assessment, as the server stored it.
class NutritionAssessment {
  const NutritionAssessment({
    required this.id,
    required this.status,
    this.createdAt,
    this.createdByName,
    required this.formulaName,
    required this.formulaVersion,
    required this.baseTotalKg,
    required this.totalKg,
    this.premix,
    required this.components,
    this.mixDryMatterKg,
    this.mixDmPct,
    required this.mixNutrients,
    this.dryMatterIntakeKg,
    this.expectedDmiKg,
    this.intakeStatus,
    required this.rationNutrients,
    required this.missing,
    this.recommendation,
    required this.setCode,
    required this.setVersion,
    required this.setSource,
  });

  final String id;

  /// meets | does_not_meet | insufficient_data
  final String status;
  final DateTime? createdAt;
  final String? createdByName;
  final String formulaName;
  final int formulaVersion;

  /// The formula's own quantities: the farm's base concentrate is 1,210 kg before any premix.
  final double baseTotalKg;
  final double totalKg;
  final AssessedComponent? premix;
  final List<AssessedComponent> components;
  final double? mixDryMatterKg;
  final double? mixDmPct;
  final List<MixNutrient> mixNutrients;
  final double? dryMatterIntakeKg;
  final double? expectedDmiKg;
  final String? intakeStatus;
  final List<RationNutrient> rationNutrients;
  final List<({String code, String detail})> missing;

  /// Null when anything is unknown: no recommendation on insufficient data.
  final String? recommendation;
  final String setCode;
  final int setVersion;
  final String setSource;

  bool get insufficient => status == 'insufficient_data';

  factory NutritionAssessment.fromJson(Map<String, dynamic> j) {
    final mix = (j['mix'] as Map?)?.cast<String, dynamic>() ?? const {};
    final ration = (j['ration'] as Map?)?.cast<String, dynamic>() ?? const {};
    final set = (j['requirement_set'] as Map?)?.cast<String, dynamic>() ?? const {};
    final premix = (mix['premix'] as Map?)?.cast<String, dynamic>();
    return NutritionAssessment(
      id: '${j['id']}',
      status: '${j['status'] ?? 'insufficient_data'}',
      createdAt: DateTime.tryParse('${j['created_at'] ?? ''}'),
      createdByName: j['created_by_name'] as String?,
      formulaName: '${mix['formula_name'] ?? ''}',
      formulaVersion: (mix['formula_version'] as num?)?.toInt() ?? 1,
      baseTotalKg: _d(mix['base_total_kg']),
      totalKg: _d(mix['total_kg']),
      premix: premix == null ? null : AssessedComponent.fromJson(premix),
      components: [for (final c in _maps(mix['components'])) AssessedComponent.fromJson(c)],
      mixDryMatterKg: _dn(mix['dry_matter_kg']),
      mixDmPct: _dn(mix['dm_pct']),
      mixNutrients: [for (final n in _maps(mix['nutrients'])) MixNutrient.fromJson(n)],
      dryMatterIntakeKg: _dn(ration['dry_matter_intake_kg']),
      expectedDmiKg: _dn(ration['expected_dmi_kg']),
      intakeStatus: ration['intake_status'] as String?,
      rationNutrients: [for (final n in _maps(ration['nutrients'])) RationNutrient.fromJson(n)],
      missing: [for (final m in _maps(j['missing'])) (code: '${m['code']}', detail: '${m['detail'] ?? ''}')],
      recommendation: j['recommendation'] as String?,
      setCode: '${set['code'] ?? ''}',
      setVersion: (set['version'] as num?)?.toInt() ?? 1,
      setSource: '${set['source_reference'] ?? ''}',
    );
  }
}

// ------------------------------------------------------------------ least-cost drafts (Package 12)
class DraftLine {
  const DraftLine({required this.name, required this.quantityKg, required this.inclusionPct, this.pricePerKg, this.cost});
  final String name;
  final double quantityKg;
  final double inclusionPct;
  final double? pricePerKg;
  final double? cost;

  factory DraftLine.fromJson(Map<String, dynamic> j) => DraftLine(
        name: '${j['name'] ?? ''}',
        quantityKg: _d(j['quantity_kg']),
        inclusionPct: _d(j['inclusion_pct']),
        pricePerKg: _dn(j['price_per_kg']),
        cost: _dn(j['cost']),
      );
}

/// One draft of a least-cost run: A the cheapest, B with a margin, C the closest to today's formula.
class FormulationDraft {
  const FormulationDraft({
    required this.key,
    required this.label,
    required this.lines,
    this.premix,
    required this.batchKg,
    required this.totalKg,
    required this.cost,
    required this.costPerKg,
    this.saving,
    this.changedKg,
    required this.nutrients,
  });

  final String key;

  /// least_cost | with_margin | least_change
  final String label;
  final List<DraftLine> lines;
  final DraftLine? premix;
  final double batchKg;
  final double totalKg;
  final double cost;
  final double costPerKg;
  final double? saving;
  final double? changedKg;
  final List<RationNutrient> nutrients;

  factory FormulationDraft.fromJson(Map<String, dynamic> j) {
    final premix = (j['premix'] as Map?)?.cast<String, dynamic>();
    return FormulationDraft(
      key: '${j['key']}',
      label: '${j['label'] ?? ''}',
      lines: [for (final c in _maps(j['components'])) DraftLine.fromJson(c)],
      premix: premix == null ? null : DraftLine.fromJson({...premix, 'inclusion_pct': 0}),
      batchKg: _d(j['batch_kg']),
      totalKg: _d(j['total_kg']),
      cost: _d(j['cost']),
      costPerKg: _d(j['cost_per_kg']),
      saving: _dn(j['saving']),
      changedKg: _dn(j['changed_kg']),
      nutrients: [for (final n in _maps(j['nutrients'])) RationNutrient.fromJson(n)],
    );
  }
}

class LeastCostRun {
  const LeastCostRun({
    required this.id,
    required this.status,
    this.createdAt,
    this.baseName,
    this.baseVersion,
    this.baseCostToday,
    required this.batchKg,
    required this.drafts,
    required this.infeasible,
    required this.missing,
    required this.setCode,
    required this.setVersion,
    this.approvedDraft,
    this.approvalNote,
  });

  final String id;

  /// drafts | infeasible | insufficient_data
  final String status;
  final DateTime? createdAt;
  final String? baseName;
  final int? baseVersion;
  final double? baseCostToday;
  final double batchKg;
  final List<FormulationDraft> drafts;
  final List<String> infeasible;
  final List<({String code, String detail})> missing;
  final String setCode;
  final int setVersion;
  final String? approvedDraft;
  final String? approvalNote;

  factory LeastCostRun.fromJson(Map<String, dynamic> j) {
    final base = (j['base'] as Map?)?.cast<String, dynamic>();
    final set = (j['requirement_set'] as Map?)?.cast<String, dynamic>() ?? const {};
    final approval = (j['approval'] as Map?)?.cast<String, dynamic>();
    return LeastCostRun(
      id: '${j['id']}',
      status: '${j['status'] ?? 'insufficient_data'}',
      createdAt: DateTime.tryParse('${j['created_at'] ?? ''}'),
      baseName: base?['formula_name'] as String?,
      baseVersion: (base?['version'] as num?)?.toInt(),
      baseCostToday: _dn(base?['cost_today']),
      batchKg: _d(j['batch_size_kg']),
      drafts: [for (final d in _maps(j['drafts'])) FormulationDraft.fromJson(d)],
      infeasible: [for (final x in _maps(j['infeasible'])) '${x['detail'] ?? ''}'],
      missing: [for (final m in _maps(j['missing'])) (code: '${m['code']}', detail: '${m['detail'] ?? ''}')],
      setCode: '${set['code'] ?? ''}',
      setVersion: (set['version'] as num?)?.toInt() ?? 1,
      approvedDraft: approval?['draft'] as String?,
      approvalNote: approval?['note'] as String?,
    );
  }
}
