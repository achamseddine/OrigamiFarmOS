/// Offline execution of veterinarian-approved emergency protocols
/// (database/CLINICAL-DECISION-SUPPORT-EMERGENCY-PROTOCOLS.md §14).
///
/// When the tablet cannot reach the farm server it triages against the
/// **signed offline package** it last downloaded: only the approved
/// versions marked offline-eligible, their trigger and eligibility rules,
/// their steps, and the medicines they name with the eligible lots as of
/// the download. The arithmetic here is the server's, line for line
/// (`emergency_service._score`, `_eval_trigger`, `_eval_eligibility`,
/// `prepare_step`): the same signs give the same score, the same facts the
/// same eligibility, the same weight the same dose inside the same
/// approved limits. What the tablet showed and did is then submitted with
/// the package signature, and the server re-runs the triage and records
/// every difference rather than trusting the device.
///
/// What this never does, exactly like the server: show a drug, route or
/// dose that is not on an approved offline-eligible version; proceed on a
/// danger sign, a missing required observation, a failed BLOCK or
/// REQUIRE_VET rule, an unknown weight for a per-weight dose, a dose
/// outside the approved range, or stock the package does not list as
/// eligible. Each of those is an escalation: call the veterinarian.
library;

import '../domain/entities/animal.dart';
import '../domain/entities/emergency.dart';
import '../domain/entities/livestock.dart';

/// ELIGIBLE < WARN < REQUIRE_VET < BLOCK, as the server ranks them.
const List<String> eligibilityOrder = ['ELIGIBLE', 'WARN', 'REQUIRE_VET', 'BLOCK'];

String _worst(Iterable<String> results) {
  var worst = 'ELIGIBLE';
  for (final r in results) {
    if (eligibilityOrder.indexOf(r) > eligibilityOrder.indexOf(worst)) worst = r;
  }
  return worst;
}

const Map<String, String> _aliases = {'temperature': 'temperature_c', 'temp': 'temperature_c', 'body_temperature': 'temperature_c', 'mortality': 'mortality_count', 'down': 'recumbent', 'off_feed': 'appetite'};

String normaliseSignCode(String code) {
  final c = code.trim().toLowerCase().replaceAll(' ', '_');
  return _aliases[c] ?? c;
}

const List<String> _allergyTypes = ['allergy', 'adverse_reaction', 'contraindication'];

String _g(num v) {
  if (v == v.roundToDouble()) return v.toInt().toString();
  var s = v.toStringAsFixed(3);
  while (s.endsWith('0')) {
    s = s.substring(0, s.length - 1);
  }
  return s.endsWith('.') ? s.substring(0, s.length - 1) : s;
}

/// The animal's facts as the server builds them (`_facts`), from what the
/// tablet holds: the herd record, and the Digital Twin's care record when
/// it was downloaded (conditions, latest dated weight, recent doses, open
/// diagnoses). A fact the tablet does not hold is simply absent, and the
/// rule that needs it says so.
Map<String, dynamic> factsForAnimal(Animal animal, {Map<String, dynamic>? twin, DateTime? now}) {
  final at = now ?? DateTime.now();
  final latestWeight = twin?['latest_weight'];
  double? weight = animal.weightKg;
  int? weightAge;
  String? weightSource = weight == null ? null : 'animal_record';
  if (latestWeight is Map) {
    final w = (latestWeight['weight_kg'] as num?)?.toDouble();
    final measured = latestWeight['measured_at'] == null ? null : DateTime.tryParse(latestWeight['measured_at'] as String);
    if (w != null) {
      weight = w;
      weightSource = 'record';
      if (measured != null) weightAge = at.difference(measured).inDays;
    }
  }
  final conditions = [for (final c in twin?['active_conditions'] as List<dynamic>? ?? const []) if (c is Map) c];
  final openCase = twin?['open_health_case'];
  return {
    'subject_type': 'animal',
    'species': animal.species,
    'sex': animal.sex,
    'life_stage': animal.lifeStage,
    'management_profile': animal.managementProfile,
    'status': animalStatusToApi(animal.status),
    'weight_kg': weight,
    'weight_known': weight != null,
    'weight_age_days': weightAge,
    'weight_source': weightSource,
    'age_days': at.difference(animal.birthDate).inDays,
    'pregnant': animal.pregnant,
    'lactating': animal.lactating,
    'withdrawal_active': animal.isUnderWithdrawal,
    'allergies': [for (final c in conditions) if (_allergyTypes.contains(c['condition_type'])) (c['code'] as String? ?? '').toLowerCase()],
    'conditions': [for (final c in conditions) if (c['condition_type'] == 'chronic_condition') (c['code'] as String? ?? '').toLowerCase()],
    'active_diagnoses': [for (final d in (openCase is Map ? openCase['active_diagnoses'] : null) as List<dynamic>? ?? const []) d.toString().toLowerCase()],
    'recent_medications': [
      for (final a in twin?['recent_administrations'] as List<dynamic>? ?? const [])
        if (a is Map && a['status'] == 'recorded') {'inventory_item_id': a['inventory_item_id'], 'administered_at': a['administered_at']},
    ],
  };
}

Map<String, dynamic> factsForGroup(AnimalGroup group) => {
      'subject_type': 'group',
      'species': group.species,
      'sex': group.sexComposition,
      'life_stage': group.lifeStage,
      'management_profile': group.managementProfile,
      'status': group.status,
      'count': group.count,
      'weight_kg': null,
      'weight_known': false,
      'pregnant': false,
      'lactating': false,
      'withdrawal_active': false,
      'allergies': const <String>[],
      'conditions': const <String>[],
      'active_diagnoses': const <String>[],
      'recent_medications': const <Map<String, dynamic>>[],
    };

/// One sign as the engine reads it: `{code, value_numeric, value_text, present}`.
Map<String, Map<String, dynamic>> _signMap(List<Map<String, dynamic>> signs) {
  final out = <String, Map<String, dynamic>>{};
  for (final s in signs) {
    final code = normaliseSignCode(s['code'] as String? ?? '');
    if (code.isEmpty) continue;
    if (s['present'] == false) {
      out[code] = {'code': code, 'present': false};
      continue;
    }
    final text = (s['value_text'] as String?)?.trim().toLowerCase();
    out[code] = {'code': code, 'value_numeric': (s['value_numeric'] as num?)?.toDouble(), 'value_text': text == null || text.isEmpty ? null : text, 'present': true};
  }
  return out;
}

/// `_eval_trigger`: does one rule hold for the sign reported for it?
({bool ok, String detail}) evaluateTrigger(TriggerRule rule, Map<String, dynamic>? sign) {
  final present = sign != null && sign['present'] != false;
  final label = rule.label ?? rule.code;
  if (rule.operator == 'present') return (ok: present, detail: '$label: ${present ? 'reported' : 'not reported'}');
  if (rule.operator == 'absent') return (ok: !present, detail: '$label: ${present ? 'present' : 'absent'}');
  if (!present) return (ok: false, detail: '$label: not reported');
  if (const ['>=', '>', '<=', '<'].contains(rule.operator)) {
    final v = sign['value_numeric'] as double?;
    final t = rule.thresholdNumeric;
    if (v == null || t == null) return (ok: false, detail: '$label: no measurement given');
    final ok = switch (rule.operator) { '>=' => v >= t, '>' => v > t, '<=' => v <= t, _ => v < t };
    final unit = rule.thresholdUnit ?? '';
    return (ok: ok, detail: '$label: ${_g(v)}$unit ${rule.operator} ${_g(t)}$unit → ${ok ? 'yes' : 'no'}');
  }
  final expected = (rule.expectedValueCode ?? '').trim().toLowerCase();
  final actual = (sign['value_text'] as String?) ?? '';
  final numeric = sign['value_numeric'] as double?;
  if (actual.isEmpty && numeric != null && rule.thresholdNumeric != null) {
    final ok = rule.operator == '==' ? numeric == rule.thresholdNumeric : numeric != rule.thresholdNumeric;
    return (ok: ok, detail: '$label: ${_g(numeric)} ${rule.operator} ${_g(rule.thresholdNumeric!)} → ${ok ? 'yes' : 'no'}');
  }
  final ok = rule.operator == '==' ? actual == expected : actual != expected;
  return (ok: ok, detail: "$label: '${actual.isEmpty ? '—' : actual}' ${rule.operator} '$expected' → ${ok ? 'yes' : 'no'}");
}

/// `_score`: the weighted share of non-danger rules that hold, the rules
/// that did and did not, the required ones missing, and the danger signs.
class ScoreResult {
  const ScoreResult({required this.score, required this.matched, required this.unmatched, required this.requiredMissing, required this.dangerSigns});
  final double score;
  final List<Map<String, dynamic>> matched;
  final List<Map<String, dynamic>> unmatched;
  final List<Map<String, dynamic>> requiredMissing;
  final List<Map<String, dynamic>> dangerSigns;
}

ScoreResult scoreVersion(OfflineProtocolVersion version, Map<String, Map<String, dynamic>> signs) {
  final matched = <Map<String, dynamic>>[], unmatched = <Map<String, dynamic>>[], missing = <Map<String, dynamic>>[], danger = <Map<String, dynamic>>[];
  var total = 0.0;
  for (final r in version.triggerRules) {
    if (!r.dangerSign) total += r.weight;
  }
  if (total == 0) total = 1.0;
  var got = 0.0;
  for (final r in version.triggerRules) {
    final res = evaluateTrigger(r, signs[normaliseSignCode(r.code)]);
    final entry = {'code': r.code, 'detail': res.detail, 'weight': r.weight, 'required': r.required, 'danger_sign': r.dangerSign};
    if (r.dangerSign) {
      if (res.ok) danger.add(entry);
      continue;
    }
    if (res.ok) {
      got += r.weight;
      matched.add(entry);
    } else {
      unmatched.add(entry);
      if (r.required) missing.add(entry);
    }
  }
  return ScoreResult(score: double.parse((got / total).toStringAsFixed(4)), matched: matched, unmatched: unmatched, requiredMissing: missing, dangerSigns: danger);
}

/// `_eval_eligibility`, for the facts the tablet holds. A rule whose fact
/// the tablet cannot know offline is not passed silently: it is reported
/// `checked: false` and counts as its failure action, so the person is
/// told and the server settles it at sync.
({String result, List<Map<String, dynamic>> outcomes}) evaluateEligibility(OfflineProtocolVersion version, Map<String, dynamic> facts, {DateTime? now}) {
  final at = now ?? DateTime.now();
  final outcomes = <Map<String, dynamic>>[];
  for (final r in version.eligibilityRules) {
    final p = r.payload;
    dynamic value = facts[r.ruleType];
    var passed = true;
    var checked = true;
    switch (r.ruleType) {
      case 'species' || 'sex' || 'life_stage' || 'management_profile' || 'status' || 'subject_type':
        if (p.containsKey('in')) {
          passed = (p['in'] as List).contains(value);
        } else if (p.containsKey('not_in')) {
          passed = !(p['not_in'] as List).contains(value);
        } else if (p.containsKey('value')) {
          passed = (r.operator == '==' || r.operator == 'in') ? value == p['value'] : value != p['value'];
        }
      case 'weight_kg' || 'age_days':
        if (value == null) {
          passed = !(p['required'] as bool? ?? true);
        } else {
          final v = (value as num).toDouble();
          final lo = (p['min'] as num?)?.toDouble(), hi = (p['max'] as num?)?.toDouble();
          passed = (lo == null || v >= lo) && (hi == null || v <= hi);
        }
      case 'weight_known' || 'pregnant' || 'lactating' || 'withdrawal_active':
        passed = (value == true) == (p['value'] as bool? ?? true);
      case 'recent_medication':
        final recent = facts['recent_medications'];
        if (recent is! List) {
          checked = false;
          passed = false;
        } else {
          final within = (p['within_hours'] as num?)?.toDouble() ?? 24;
          final cutoff = at.subtract(Duration(minutes: (within * 60).round()));
          passed = !recent.any((m) => m is Map && m['inventory_item_id'] == p['not'] && (DateTime.tryParse(m['administered_at']?.toString() ?? '')?.isAfter(cutoff) ?? false));
        }
      case 'active_diagnosis' || 'allergy' || 'condition':
        final key = switch (r.ruleType) { 'active_diagnosis' => 'active_diagnoses', 'allergy' => 'allergies', _ => 'conditions' };
        final raw = facts[key];
        if (raw is! List) {
          checked = false;
          passed = false;
          value = null;
        } else {
          final have = {for (final x in raw) x.toString().toLowerCase()};
          final listed = {for (final x in (p['not_in'] as List? ?? (p['not'] != null ? [p['not']] : const []))) x.toString().toLowerCase()};
          final wanted = {for (final x in p['in'] as List? ?? const []) x.toString().toLowerCase()};
          if (listed.isNotEmpty) {
            passed = have.intersection(listed).isEmpty;
          } else if (wanted.isNotEmpty) {
            passed = have.intersection(wanted).isNotEmpty;
          } else if (p.containsKey('any')) {
            passed = have.isNotEmpty == (p['any'] == true);
          } else {
            passed = have.isEmpty;
          }
          value = have.toList()..sort();
        }
      case 'weight_age_days':
        final age = facts['weight_age_days'];
        if (age == null) {
          passed = !(p['required'] as bool? ?? true);
        } else {
          passed = (age as num).toDouble() <= ((p['max'] as num?)?.toDouble() ?? 30);
        }
        value = age;
      default:
        checked = false;
        passed = false;
    }
    outcomes.add({
      'rule_type': r.ruleType,
      'passed': passed,
      'checked': checked,
      'failure_action': r.failureAction,
      'message': checked ? (r.message ?? '${r.ruleType} check ${passed ? 'passed' : 'failed'}') : '${r.ruleType}: could not be checked offline — the server checks it at sync',
      'fact': value,
    });
  }
  return (result: _worst([for (final o in outcomes) if (o['passed'] != true) o['failure_action'] as String]), outcomes: outcomes);
}

/// A candidate version and how it fared.
class OfflineMatch {
  const OfflineMatch({required this.version, required this.score, required this.eligibility, required this.outcomes, required this.scoring});
  final OfflineProtocolVersion version;
  final double score;
  final String eligibility;
  final List<Map<String, dynamic>> outcomes;
  final ScoreResult scoring;

  List<String> get blockingReasons => [for (final o in outcomes) if (o['passed'] != true && (o['failure_action'] == 'BLOCK' || o['failure_action'] == 'REQUIRE_VET')) o['message'] as String];
  List<String> get warnings => [for (final o in outcomes) if (o['passed'] != true && o['failure_action'] == 'WARN') o['message'] as String];
  bool get startable => eligibility == 'ELIGIBLE' || eligibility == 'WARN';
}

/// What the tablet decided from the package: the triage level, the match
/// it would act on (if any) or the escalation and its reasons, and the
/// explanation a person reads before confirming anything.
class OfflineTriageResult {
  const OfflineTriageResult({required this.triageLevel, required this.escalated, required this.escalationReasons, required this.match, required this.candidates, required this.explanation, required this.dangerSigns});
  final String triageLevel;
  final bool escalated;
  final List<String> escalationReasons;
  final OfflineMatch? match;
  final List<OfflineMatch> candidates;
  final String explanation;
  final List<String> dangerSigns;

  double get confidence => candidates.isEmpty ? 0 : candidates.map((c) => c.score).reduce((a, b) => a > b ? a : b);
}

/// The server's `assess`, against the package: species- and scope-
/// matching offline-eligible versions are scored, the best one that
/// clears its threshold with no required observation missing and no
/// BLOCK / REQUIRE_VET failure is the match; a danger sign or no match
/// is an escalation.
OfflineTriageResult triageOffline({required OfflinePackage package, required Map<String, dynamic> facts, required List<Map<String, dynamic>> signs, DateTime? now, String? subjectName}) {
  final signMap = _signMap(signs);
  final species = facts['species'] as String?;
  final subjectType = facts['subject_type'] as String? ?? 'animal';
  final candidates = <OfflineMatch>[];
  final danger = <String>[];
  for (final v in package.versions) {
    if (!v.offlineEligible) continue;
    if (v.speciesCode != null && v.speciesCode != species) continue;
    if (v.subjectScope != 'any' && v.subjectScope != subjectType) continue;
    final scoring = scoreVersion(v, signMap);
    final elig = evaluateEligibility(v, facts, now: now);
    candidates.add(OfflineMatch(version: v, score: scoring.score, eligibility: elig.result, outcomes: elig.outcomes, scoring: scoring));
    danger.addAll(scoring.dangerSigns.map((d) => '${v.protocolCode}: ${d['detail']}'));
  }
  candidates.sort((a, b) => b.score.compareTo(a.score));
  final reasons = <String>[];
  OfflineMatch? best;
  for (final c in candidates) {
    if (c.score < c.version.minimumMatchConfidence) continue;
    if (c.scoring.requiredMissing.isNotEmpty) {
      reasons.add('${c.version.protocolCode}: required observation missing — ${c.scoring.requiredMissing.map((e) => e['code']).join(', ')}');
      continue;
    }
    if (c.eligibility == 'BLOCK' || c.eligibility == 'REQUIRE_VET') {
      reasons.add('${c.version.protocolCode}: ${c.eligibility == 'BLOCK' ? 'blocked' : 'requires the veterinarian'} — ${c.blockingReasons.join('; ')}');
      continue;
    }
    best = c;
    break;
  }
  final pattern = candidates.any((c) => c.score > 0);
  final String triage;
  if (danger.isNotEmpty) {
    triage = 'CRITICAL';
    reasons.insertAll(0, danger.map((d) => 'danger sign — $d'));
  } else if (best != null) {
    triage = best.score >= 0.8 ? 'HIGH' : 'MODERATE';
  } else if (pattern) {
    triage = 'MODERATE';
  } else {
    triage = 'LOW';
  }
  final name = subjectName ?? facts['subject_id']?.toString() ?? 'Subject';
  if (danger.isNotEmpty || best == null) {
    if (candidates.isEmpty) {
      reasons.add('no offline-eligible veterinarian-approved protocol exists for this species / subject in the package');
    } else if (best == null && reasons.isEmpty) {
      reasons.add('no approved protocol matched above its confidence threshold — ${candidates.map((c) => '${c.version.protocolCode} ${c.score.toStringAsFixed(2)} < ${c.version.minimumMatchConfidence.toStringAsFixed(2)}').join('; ')}');
    }
    return OfflineTriageResult(
      triageLevel: triage,
      escalated: true,
      escalationReasons: reasons,
      match: null,
      candidates: candidates,
      explanation: '$name: ESCALATE — contact the veterinarian / manager now. ${reasons.join(' | ')}. No drug, dose or route is shown because no current approved protocol applies.',
      dangerSigns: danger,
    );
  }
  final v = best.version;
  final warn = best.warnings;
  final explanation = '$name: ${v.protocolTitle} (v${v.versionNo}, ref ${v.approvalReference ?? '—'}, offline package) matched at ${best.score.toStringAsFixed(2)} ≥ ${v.minimumMatchConfidence.toStringAsFixed(2)}. '
      'Supported by: ${best.scoring.matched.map((e) => e['detail']).join('; ')}'
      '${best.scoring.unmatched.isNotEmpty ? '. Not reported: ${best.scoring.unmatched.map((e) => e['code']).join('; ')}' : ''}'
      '${warn.isNotEmpty ? '. Warnings: ${warn.join('; ')}' : ''}. Confirm to start the protocol; a person decides. The server revalidates this when the tablet syncs.';
  return OfflineTriageResult(triageLevel: triage, escalated: false, escalationReasons: const [], match: best, candidates: candidates, explanation: explanation, dangerSigns: const []);
}

// ----------------------------------------------------------------- doses

double? _convertUnits(double quantity, String from, String to) {
  final f = from.trim().toLowerCase(), t = to.trim().toLowerCase();
  if (f == t) return quantity;
  const toBase = {'ml': 0.001, 'l': 1.0, 'liter': 1.0, 'litre': 1.0, 'mg': 1e-6, 'g': 1e-3, 'kg': 1.0, 'mcg': 1e-9, 'µg': 1e-9, 'ug': 1e-9};
  const family = {'ml': 'vol', 'l': 'vol', 'liter': 'vol', 'litre': 'vol', 'mg': 'mass', 'g': 'mass', 'kg': 'mass', 'mcg': 'mass', 'µg': 'mass', 'ug': 'mass'};
  if (family[f] == null || family[f] != family[t]) return null;
  return quantity * toBase[f]! / toBase[t]!;
}

/// What a medication step would do, prepared from the approved rule and
/// the package's stock snapshot (`prepare_step`). Any problem means the
/// step is blocked and the run escalates — the dose is never shown.
class OfflineDose {
  const OfflineDose({required this.medicine, required this.doseQuantity, required this.doseUnit, required this.routeCode, required this.weightUsedKg, required this.weightSource, required this.headCount, required this.quantityConsumed, required this.stockUnit, required this.lot, required this.problems, required this.withdrawalRule});
  final OfflineMedicine? medicine;
  final double? doseQuantity;
  final String doseUnit;
  final String routeCode;
  final double? weightUsedKg;
  final String? weightSource;
  final int headCount;
  final double? quantityConsumed;
  final String? stockUnit;
  final OfflineLot? lot;
  final List<String> problems;
  final Map<String, dynamic> withdrawalRule;

  bool get blocked => problems.isNotEmpty;

  Map<String, dynamic> toResult() => {
        'medicine_product_id': medicine?.medicineProductId,
        'medicine_name': medicine?.name,
        'route_code': routeCode,
        'dose_quantity': doseQuantity,
        'dose_unit': doseUnit,
        'weight_used_kg': weightUsedKg,
        'weight_source': weightSource,
        'head_count': headCount,
        'quantity_consumed': quantityConsumed,
        'stock_unit': stockUnit,
        'lot_id': lot?.lotId,
        'lot_code': lot?.lotCode,
        'problems': problems,
        'source': 'approved protocol parameters (offline package)',
      };
}

OfflineDose prepareOfflineDose({required ProtocolStepDef step, required OfflinePackage package, required Map<String, dynamic> facts, double? enteredWeightKg, int? headCount, List<Map<String, dynamic>> earlierDoses = const [], DateTime? now}) {
  final med = step.medication ?? const {};
  final productId = med['medicine_product_id'] as String?;
  final medicine = productId == null ? null : package.medicines[productId];
  final doseUnit = med['dose_unit'] as String? ?? '';
  final route = med['route_code'] as String? ?? '';
  final problems = <String>[];
  final heads = headCount ?? (facts['subject_type'] == 'group' ? ((facts['count'] as num?)?.toInt() ?? 1).clamp(1, 1 << 30) : 1);
  if (medicine == null) problems.add('the medicine of this step is not in the offline package');
  // Authoritative clinical facts first: a recorded allergy / adverse reaction to the product or its ingredients.
  final allergies = {for (final a in facts['allergies'] as List? ?? const []) a.toString().toLowerCase()};
  if (medicine != null && allergies.isNotEmpty) {
    final codes = {...medicine.ingredientCodes.map((c) => c.toLowerCase()), medicine.medicineProductId.toLowerCase()};
    final hit = allergies.intersection(codes);
    if (hit.isNotEmpty) problems.add('recorded allergy / adverse reaction to ${(hit.toList()..sort()).join(', ')}');
  }
  double? dose;
  double? weightUsed;
  String? weightSource;
  int? weightAge;
  if (med['dose_rule_type'] == 'FIXED') {
    dose = (med['fixed_dose_quantity'] as num?)?.toDouble();
  } else {
    if (enteredWeightKg != null) {
      weightUsed = enteredWeightKg;
      weightSource = 'entered now';
      weightAge = 0;
    } else if (facts['weight_kg'] != null) {
      weightUsed = (facts['weight_kg'] as num).toDouble();
      weightAge = (facts['weight_age_days'] as num?)?.toInt();
      weightSource = facts['weight_source'] == 'record' ? 'weight record ${weightAge ?? '?'} day(s) old' : 'animal record (undated)';
    }
    if (weightUsed == null) {
      problems.add('weight unknown — a per-weight dose cannot be calculated');
    } else {
      final maxAge = (med['weight_max_age_days'] as num?)?.toInt();
      if (maxAge != null && (weightAge == null || weightAge > maxAge)) {
        problems.add('the protocol requires a weight no older than $maxAge day(s); the recorded weight is ${weightAge != null ? '$weightAge day(s) old' : 'undated'} — weigh the animal and enter the weight');
      }
      final perKg = (med['dose_per_weight_quantity'] as num?)?.toDouble() ?? 0;
      dose = double.parse((perKg * weightUsed).toStringAsFixed(3));
    }
  }
  if (dose != null) {
    final lo = (med['minimum_dose_quantity'] as num?)?.toDouble(), hi = (med['maximum_dose_quantity'] as num?)?.toDouble();
    if (lo != null && dose < lo) problems.add('calculated dose ${_g(dose)} $doseUnit is below the approved minimum ${_g(lo)}');
    if (hi != null && dose > hi) problems.add('calculated dose ${_g(dose)} $doseUnit exceeds the approved maximum ${_g(hi)}');
  }
  final maxAdmin = (med['maximum_administrations'] as num?)?.toInt();
  if (maxAdmin != null && earlierDoses.length >= maxAdmin) problems.add('the approved maximum of $maxAdmin administration(s) is reached');
  final interval = (med['repeat_interval_minutes'] as num?)?.toInt();
  if (interval != null && earlierDoses.isNotEmpty) {
    final at = now ?? DateTime.now();
    final last = earlierDoses.map((d) => DateTime.tryParse(d['occurred_at']?.toString() ?? '')).whereType<DateTime>().fold<DateTime?>(null, (p, c) => p == null || c.isAfter(p) ? c : p);
    if (last != null && at.isBefore(last.add(Duration(minutes: interval)))) problems.add('the repeat interval of $interval min has not passed');
  }
  OfflineLot? lot;
  double? needed;
  if (dose != null && problems.isEmpty && medicine != null) {
    needed = _convertUnits(dose * heads, doseUnit, medicine.unit);
    if (needed == null) {
      problems.add('dose unit $doseUnit cannot be converted to the stock unit ${medicine.unit}');
    } else {
      needed = double.parse(needed.toStringAsFixed(6));
      for (final l in medicine.eligibleLots) {
        if (l.freeQuantity + 0.0005 >= needed) {
          lot = l;
          break;
        }
      }
      if (lot == null) {
        final eligible = medicine.eligibleLots.fold<double>(0, (s, l) => s + l.freeQuantity);
        problems.add('${medicine.name}: no eligible lot in the package holds ${_g(needed)} ${medicine.unit} (eligible ${_g(eligible)} as of the download)');
      }
    }
  }
  return OfflineDose(
    medicine: medicine,
    doseQuantity: dose,
    doseUnit: doseUnit,
    routeCode: route,
    weightUsedKg: weightUsed,
    weightSource: weightSource,
    headCount: heads,
    quantityConsumed: needed,
    stockUnit: medicine?.unit,
    lot: lot,
    problems: problems,
    withdrawalRule: (med['withdrawal_rule_payload'] as Map?)?.cast<String, dynamic>() ?? medicine?.withdrawalRules ?? const {},
  );
}

/// The body of `POST /emergency/offline-runs`: what the tablet showed and
/// did, with the operation id that makes the sync idempotent and the
/// package signature the server checks against its current one.
Map<String, dynamic> offlineRunPayload({
  required String operationId,
  required String? deviceId,
  required OfflinePackage package,
  required String subjectType,
  required String subjectId,
  required List<Map<String, dynamic>> signs,
  required OfflineTriageResult triage,
  required List<Map<String, dynamic>> steps,
  DateTime? occurredAt,
  String? notes,
}) =>
    {
      'operation_id': operationId,
      'device_id': deviceId,
      'package_signature': package.signature,
      'subject_type': subjectType,
      'subject_id': subjectId,
      'signs': signs,
      'occurred_at': (occurredAt ?? DateTime.now()).toUtc().toIso8601String(),
      'shown': {
        'protocol_version_id': triage.match?.version.id,
        'match_score': triage.match?.score,
        'triage_level': triage.triageLevel,
        'escalated': triage.escalated,
        'escalation_reasons': triage.escalationReasons,
      },
      'steps': steps,
      if (notes != null && notes.isNotEmpty) 'notes': notes,
    };
