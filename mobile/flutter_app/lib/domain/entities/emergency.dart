/// The emergency protocol engine as the tablet reads it
/// (database/CLINICAL-DECISION-SUPPORT-EMERGENCY-PROTOCOLS.md): the
/// veterinarian-approved protocols, a triage with its candidate matches,
/// why it matched or escalated, and a protocol run with its steps.
///
/// The tablet shows what the server decided and lets the person confirm
/// or escalate. A drug, dose or route on screen always comes from an
/// approved protocol version named next to it; the tablet never computes
/// one.
library;

double? _dn(Object? v) => (v as num?)?.toDouble();
double _d(Object? v, [double fallback = 0]) => (v as num?)?.toDouble() ?? fallback;
int _i(Object? v, [int fallback = 0]) => (v as num?)?.toInt() ?? fallback;
DateTime? _dt(Object? v) => v == null ? null : DateTime.tryParse(v as String);
// Maps may arrive from JSON (`Map<String, dynamic>`) or from an in-memory
// literal (`Map<dynamic, dynamic>`); cast rather than assume.
List<Map<String, dynamic>> _maps(Object? v) => [for (final e in v as List<dynamic>? ?? const []) (e as Map).cast<String, dynamic>()];
List<String> _strings(Object? v) => [for (final e in v as List<dynamic>? ?? const []) e.toString()];
Map<String, dynamic> _map(Object? v) => (v as Map?)?.cast<String, dynamic>() ?? const {};

/// `GET /emergency/summary`.
class EmergencySummary {
  const EmergencySummary({
    required this.protocols,
    required this.activeProtocols,
    required this.openAssessments,
    required this.escalated,
    required this.runsInProgress,
    required this.awaitingReassessment,
    required this.reassessmentsOverdue,
    required this.modelReference,
  });

  final int protocols;
  final int activeProtocols;
  final int openAssessments;
  final int escalated;
  final int runsInProgress;
  final int awaitingReassessment;
  final int reassessmentsOverdue;
  final String modelReference;

  static const empty = EmergencySummary(protocols: 0, activeProtocols: 0, openAssessments: 0, escalated: 0, runsInProgress: 0, awaitingReassessment: 0, reassessmentsOverdue: 0, modelReference: '');

  factory EmergencySummary.fromJson(Map<String, dynamic> json) => EmergencySummary(
        protocols: _i(json['protocols']),
        activeProtocols: _i(json['active_protocols']),
        openAssessments: _i(json['open_assessments']),
        escalated: _i(json['escalated']),
        runsInProgress: _i(json['runs_in_progress']),
        awaitingReassessment: _i(json['awaiting_reassessment']),
        reassessmentsOverdue: _i(json['reassessments_overdue']),
        modelReference: json['model_reference'] as String? ?? '',
      );
}

/// One sign the worker can report: a measurement, a choice or a yes/no.
class SignCode {
  const SignCode({required this.code, required this.kind, this.unit, required this.label, required this.options});
  final String code;

  /// numeric | categorical | boolean
  final String kind;
  final String? unit;
  final String label;
  final List<String> options;

  factory SignCode.fromJson(Map<String, dynamic> json) => SignCode(
        code: json['code'] as String,
        kind: json['kind'] as String? ?? 'boolean',
        unit: json['unit'] as String?,
        label: json['label'] as String? ?? json['code'] as String,
        options: _strings(json['options']),
      );
}

/// A candidate protocol for one assessment: how well the signs fit, what
/// supported the fit, what is missing, and whether the animal is eligible.
class ProtocolMatch {
  const ProtocolMatch({
    required this.id,
    required this.protocolVersionId,
    this.protocolCode,
    this.protocolTitle,
    this.versionNo,
    this.matchScore,
    this.minimumMatchConfidence,
    required this.eligibilityResult,
    required this.blockingReasons,
    required this.selected,
    required this.supporting,
    required this.missing,
    required this.warnings,
    required this.dangerSigns,
  });

  final String id;
  final String protocolVersionId;
  final String? protocolCode;
  final String? protocolTitle;
  final int? versionNo;
  final double? matchScore;
  final double? minimumMatchConfidence;

  /// ELIGIBLE | WARN | REQUIRE_VET | BLOCK
  final String eligibilityResult;
  final List<String> blockingReasons;
  final bool selected;
  final List<Map<String, dynamic>> supporting;
  final List<Map<String, dynamic>> missing;
  final List<String> warnings;
  final List<Map<String, dynamic>> dangerSigns;

  bool get startable => selected && (eligibilityResult == 'ELIGIBLE' || eligibilityResult == 'WARN');

  factory ProtocolMatch.fromJson(Map<String, dynamic> json) {
    final ex = _map(json['explanation']);
    return ProtocolMatch(
      id: json['id'] as String,
      protocolVersionId: json['protocol_version_id'] as String? ?? '',
      protocolCode: json['protocol_code'] as String?,
      protocolTitle: json['protocol_title'] as String?,
      versionNo: (json['version_no'] as num?)?.toInt(),
      matchScore: _dn(json['match_score']),
      minimumMatchConfidence: _dn(json['minimum_match_confidence']),
      eligibilityResult: json['eligibility_result'] as String? ?? 'ELIGIBLE',
      blockingReasons: _strings(json['blocking_reasons']),
      selected: json['selected'] as bool? ?? false,
      supporting: _maps(ex['supporting']),
      missing: _maps(ex['missing']),
      warnings: _strings(ex['warnings']),
      dangerSigns: _maps(ex['danger_signs']),
    );
  }
}

/// One triage of one subject (§8), with everything it rested on.
class EmergencyAssessment {
  const EmergencyAssessment({
    required this.id,
    required this.subjectType,
    required this.subjectId,
    this.subjectName,
    this.species,
    this.startedAt,
    required this.source,
    required this.observedSigns,
    required this.triageLevel,
    this.confidence,
    required this.status,
    required this.escalationReasons,
    required this.explanation,
    required this.matches,
    this.selectedMatchId,
    this.runId,
    this.runStatus,
    this.createdByName,
    this.parentRunId,
  });

  final String id;
  final String subjectType;
  final String subjectId;
  final String? subjectName;
  final String? species;
  final DateTime? startedAt;
  final String source;
  final List<Map<String, dynamic>> observedSigns;

  /// LOW | MODERATE | HIGH | CRITICAL
  final String triageLevel;
  final double? confidence;

  /// open | protocol_started | escalated | resolved | closed | queued (offline)
  final String status;
  final List<String> escalationReasons;
  final String explanation;
  final List<ProtocolMatch> matches;
  final String? selectedMatchId;
  final String? runId;
  final String? runStatus;
  final String? createdByName;
  final String? parentRunId;

  bool get isEscalated => status == 'escalated';
  bool get awaitingConfirmation => status == 'open' && selectedMatchId != null;
  bool get isActive => status == 'open' || status == 'protocol_started' || status == 'escalated' || status == 'queued';
  ProtocolMatch? get selectedMatch {
    for (final m in matches) {
      if (m.selected) return m;
    }
    return null;
  }

  factory EmergencyAssessment.fromJson(Map<String, dynamic> json) => EmergencyAssessment(
        id: json['id'] as String,
        subjectType: json['subject_type'] as String? ?? 'animal',
        subjectId: json['subject_id'] as String? ?? '',
        subjectName: json['subject_name'] as String?,
        species: json['species'] as String?,
        startedAt: _dt(json['started_at']),
        source: json['source'] as String? ?? 'worker',
        observedSigns: _maps(json['observed_signs']),
        triageLevel: json['triage_level'] as String? ?? 'LOW',
        confidence: _dn(json['ai_confidence']),
        status: json['status'] as String? ?? 'open',
        escalationReasons: _strings(json['escalation_reasons']),
        explanation: json['explanation'] as String? ?? '',
        matches: [for (final m in _maps(json['matches'])) ProtocolMatch.fromJson(m)],
        selectedMatchId: json['selected_match_id'] as String?,
        runId: json['run_id'] as String?,
        runStatus: json['run_status'] as String?,
        createdByName: json['created_by_name'] as String?,
        parentRunId: json['parent_run_id'] as String?,
      );
}

/// A step of an approved protocol version. A medication step carries
/// the approved drug, route and dose rule — the only source of them.
class ProtocolStepDef {
  const ProtocolStepDef({
    required this.id,
    required this.stepNo,
    required this.stepType,
    required this.title,
    required this.instructions,
    required this.required,
    required this.requiresConfirmation,
    this.timingOffsetMinutes,
    this.medication,
  });

  final String id;
  final int stepNo;
  final String stepType;
  final String title;
  final String instructions;
  final bool required;
  final bool requiresConfirmation;
  final int? timingOffsetMinutes;
  final Map<String, dynamic>? medication;

  bool get isMedication => stepType == 'MEDICATION';

  factory ProtocolStepDef.fromJson(Map<String, dynamic> json) => ProtocolStepDef(
        id: json['id'] as String,
        stepNo: _i(json['step_no']),
        stepType: json['step_type'] as String? ?? 'ASSESS',
        title: json['title'] as String? ?? '',
        instructions: json['instructions'] as String? ?? '',
        required: json['required'] as bool? ?? true,
        requiresConfirmation: json['requires_confirmation'] as bool? ?? true,
        timingOffsetMinutes: (json['timing_offset_minutes'] as num?)?.toInt(),
        medication: json['medication'] == null ? null : json['medication'] as Map<String, dynamic>,
      );
}

class ProtocolRunStep {
  const ProtocolRunStep({
    required this.id,
    required this.sequence,
    required this.status,
    this.dueAt,
    this.confirmedAt,
    this.confirmedByName,
    this.medicationAdministrationId,
    required this.result,
    this.skipReason,
    required this.step,
  });

  final String id;
  final int sequence;

  /// pending | presented | completed | skipped | blocked
  final String status;
  final DateTime? dueAt;
  final DateTime? confirmedAt;
  final String? confirmedByName;
  final String? medicationAdministrationId;

  /// The prepared dose, lot and problems for a medication step; the
  /// recorded result for the others.
  final Map<String, dynamic> result;
  final String? skipReason;
  final ProtocolStepDef step;

  bool get isDone => status == 'completed' || status == 'skipped';
  bool get isBlocked => status == 'blocked';
  List<String> get problems => _strings(result['problems']);

  factory ProtocolRunStep.fromJson(Map<String, dynamic> json) => ProtocolRunStep(
        id: json['id'] as String,
        sequence: _i(json['sequence']),
        status: json['status'] as String? ?? 'pending',
        dueAt: _dt(json['due_at']),
        confirmedAt: _dt(json['confirmed_at']),
        confirmedByName: json['confirmed_by_name'] as String?,
        medicationAdministrationId: json['medication_administration_id'] as String?,
        result: _map(json['result']),
        skipReason: json['skip_reason'] as String?,
        step: ProtocolStepDef.fromJson(_map(json['step'])),
      );
}

/// A protocol in progress on one subject (§10).
class EmergencyRun {
  const EmergencyRun({
    required this.id,
    required this.assessmentId,
    this.protocolCode,
    this.protocolTitle,
    this.versionNo,
    this.approvalReference,
    required this.subjectType,
    required this.subjectId,
    this.subjectName,
    this.startedAt,
    this.startedByName,
    required this.status,
    this.managerNotifiedAt,
    this.vetNotifiedAt,
    this.nextReassessmentAt,
    required this.reassessmentOverdue,
    this.escalatedAt,
    this.escalationReason,
    this.completedAt,
    this.outcome,
    required this.steps,
    this.nextStepId,
  });

  final String id;
  final String assessmentId;
  final String? protocolCode;
  final String? protocolTitle;
  final int? versionNo;
  final String? approvalReference;
  final String subjectType;
  final String subjectId;
  final String? subjectName;
  final DateTime? startedAt;
  final String? startedByName;

  /// in_progress | awaiting_reassessment | escalated | completed | cancelled
  final String status;
  final DateTime? managerNotifiedAt;
  final DateTime? vetNotifiedAt;
  final DateTime? nextReassessmentAt;
  final bool reassessmentOverdue;
  final DateTime? escalatedAt;
  final String? escalationReason;
  final DateTime? completedAt;
  final String? outcome;
  final List<ProtocolRunStep> steps;
  final String? nextStepId;

  bool get isActive => status == 'in_progress' || status == 'awaiting_reassessment';
  ProtocolRunStep? get nextStep {
    for (final s in steps) {
      if (s.id == nextStepId) return s;
    }
    return null;
  }

  factory EmergencyRun.fromJson(Map<String, dynamic> json) => EmergencyRun(
        id: json['id'] as String,
        assessmentId: json['assessment_id'] as String? ?? '',
        protocolCode: json['protocol_code'] as String?,
        protocolTitle: json['protocol_title'] as String?,
        versionNo: (json['version_no'] as num?)?.toInt(),
        approvalReference: json['approval_reference'] as String?,
        subjectType: json['subject_type'] as String? ?? 'animal',
        subjectId: json['subject_id'] as String? ?? '',
        subjectName: json['subject_name'] as String?,
        startedAt: _dt(json['started_at']),
        startedByName: json['started_by_name'] as String?,
        status: json['status'] as String? ?? 'in_progress',
        managerNotifiedAt: _dt(json['manager_notified_at']),
        vetNotifiedAt: _dt(json['veterinarian_notified_at']),
        nextReassessmentAt: _dt(json['next_reassessment_at']),
        reassessmentOverdue: json['reassessment_overdue'] as bool? ?? false,
        escalatedAt: _dt(json['escalated_at']),
        escalationReason: json['escalation_reason'] as String?,
        completedAt: _dt(json['completed_at']),
        outcome: json['outcome'] as String?,
        steps: [for (final s in _maps(json['steps'])) ProtocolRunStep.fromJson(s)],
        nextStepId: json['next_step_id'] as String?,
      );
}

/// A protocol with its current approved version, if any.
class EmergencyProtocol {
  const EmergencyProtocol({
    required this.id,
    required this.code,
    required this.title,
    required this.conditionFamilyCode,
    this.speciesCode,
    required this.subjectScope,
    required this.status,
    this.currentVersionNo,
    this.approvalReference,
    this.approvedByName,
    this.approvedAt,
    required this.offlineEligible,
    required this.steps,
    this.protocolText,
    required this.minimumMatchConfidence,
  });

  final String id;
  final String code;
  final String title;
  final String conditionFamilyCode;
  final String? speciesCode;
  final String subjectScope;

  /// draft | active | withdrawn
  final String status;
  final int? currentVersionNo;
  final String? approvalReference;
  final String? approvedByName;
  final DateTime? approvedAt;
  final bool offlineEligible;
  final List<ProtocolStepDef> steps;
  final String? protocolText;
  final double minimumMatchConfidence;

  bool get isActive => status == 'active';

  factory EmergencyProtocol.fromJson(Map<String, dynamic> json) {
    final v = _map(json['current_version']);
    return EmergencyProtocol(
      id: json['id'] as String,
      code: json['code'] as String? ?? '',
      title: json['title'] as String? ?? '',
      conditionFamilyCode: json['condition_family_code'] as String? ?? '',
      speciesCode: json['species_code'] as String?,
      subjectScope: json['subject_scope'] as String? ?? 'animal',
      status: json['status'] as String? ?? 'draft',
      currentVersionNo: (json['current_version_no'] as num?)?.toInt(),
      approvalReference: v['approval_reference'] as String?,
      approvedByName: v['approved_by_name'] as String?,
      approvedAt: _dt(v['approved_at']),
      offlineEligible: v['offline_eligible'] as bool? ?? false,
      steps: [for (final s in _maps(v['steps'])) ProtocolStepDef.fromJson(s)],
      protocolText: v['protocol_text'] as String?,
      minimumMatchConfidence: _d(v['minimum_match_confidence'], 0.6),
    );
  }
}
