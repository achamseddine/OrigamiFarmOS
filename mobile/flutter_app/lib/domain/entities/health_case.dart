/// Health cases and the farm's observations (database/HEALTH-VETERINARY-SCHEMA.md),
/// as `GET /health/cases`, `GET /health/cases/{id}` and `GET /observations`
/// return them.
///
/// A case groups what happened to one animal or group around one problem:
/// the observations that raised it, the veterinarian's diagnoses and
/// treatment plans, the treatments given, and how it ended. Diagnoses and
/// plans are written by a diagnostic role only; the tablet shows them and
/// never invents one.
library;

DateTime? _dt(Object? v) => v is String ? DateTime.tryParse(v) : null;

class HealthCaseCodes {
  HealthCaseCodes._();

  /// `hm.CASE_SEVERITIES`, mildest first.
  static const severities = ['low', 'moderate', 'high', 'critical'];
  static const openStatuses = {'open', 'monitoring'};
}

class CaseDiagnosis {
  const CaseDiagnosis({required this.id, required this.code, this.text, required this.certainty, this.diagnosedAt, this.diagnosedByName, required this.status});
  final String id;
  final String code;
  final String? text;

  /// suspected | probable | confirmed | ruled_out
  final String certainty;
  final DateTime? diagnosedAt;
  final String? diagnosedByName;

  /// active | resolved | superseded
  final String status;

  String get label => (text != null && text!.trim().isNotEmpty) ? text! : code.replaceAll('_', ' ');

  factory CaseDiagnosis.fromJson(Map<String, dynamic> j) => CaseDiagnosis(
        id: j['id'] as String? ?? '',
        code: j['diagnosis_code'] as String? ?? '',
        text: j['diagnosis_text'] as String?,
        certainty: j['certainty_code'] as String? ?? 'suspected',
        diagnosedAt: _dt(j['diagnosed_at']),
        diagnosedByName: j['diagnosed_by_name'] as String?,
        status: j['status'] as String? ?? 'active',
      );
}

class CasePlan {
  const CasePlan({required this.id, required this.status, this.prescribedAt, this.prescribedByName, this.instructions, this.completedAt});
  final String id;

  /// prescribed | active | completed | cancelled
  final String status;
  final DateTime? prescribedAt;
  final String? prescribedByName;
  final String? instructions;
  final DateTime? completedAt;

  factory CasePlan.fromJson(Map<String, dynamic> j) => CasePlan(
        id: j['id'] as String? ?? '',
        status: j['status'] as String? ?? 'prescribed',
        prescribedAt: _dt(j['prescribed_at']),
        prescribedByName: j['prescribed_by_name'] as String?,
        instructions: j['instructions'] as String?,
        completedAt: _dt(j['completed_at']),
      );
}

class HealthCase {
  const HealthCase({
    required this.id,
    required this.caseCode,
    required this.subjectType,
    required this.subjectId,
    this.subjectName,
    this.species,
    this.openedAt,
    this.closedAt,
    required this.status,
    this.severity,
    this.problem,
    this.responsibleName,
    this.sourceType,
    this.outcome,
    this.notes,
    this.activeDiagnoses = const [],
    this.diagnoses = const [],
    this.plans = const [],
    this.treatments = const [],
    this.observations = const [],
    this.pending = false,
  });

  final String id;
  final String caseCode;

  /// animal | group
  final String subjectType;
  final String subjectId;
  final String? subjectName;
  final String? species;
  final DateTime? openedAt;
  final DateTime? closedAt;

  /// open | monitoring | resolved | closed
  final String status;

  /// low | moderate | high | critical
  final String? severity;
  final String? problem;
  final String? responsibleName;

  /// manual | observation | emergency_assessment | emergency_run
  final String? sourceType;
  final String? outcome;
  final String? notes;
  final List<String> activeDiagnoses;

  // Only on the detail response.
  final List<CaseDiagnosis> diagnoses;
  final List<CasePlan> plans;
  final List<Map<String, dynamic>> treatments;
  final List<Map<String, dynamic>> observations;

  /// Opened on this tablet and not yet accepted by the farm server.
  final bool pending;

  bool get isOpen => HealthCaseCodes.openStatuses.contains(status);

  /// Most severe first, so the case that needs a person is on top.
  int get severityRank => severity == null ? -1 : HealthCaseCodes.severities.indexOf(severity!);

  factory HealthCase.fromJson(Map<String, dynamic> j) {
    List<Map<String, dynamic>> maps(Object? v) => [for (final m in (v as List<dynamic>? ?? const [])) if (m is Map) m.cast<String, dynamic>()];
    return HealthCase(
      id: j['id'] as String,
      caseCode: j['case_code'] as String? ?? '…',
      subjectType: j['subject_type'] as String? ?? 'animal',
      subjectId: j['subject_id'] as String? ?? '',
      subjectName: j['subject_name'] as String?,
      species: j['species'] as String?,
      openedAt: _dt(j['opened_at']),
      closedAt: _dt(j['closed_at']),
      status: j['status'] as String? ?? 'open',
      severity: j['severity_code'] as String?,
      problem: j['primary_problem_code'] as String?,
      responsibleName: j['responsible_user_name'] as String?,
      sourceType: j['source_type'] as String?,
      outcome: j['outcome'] as String?,
      notes: j['notes'] as String?,
      activeDiagnoses: [for (final d in (j['active_diagnoses'] as List<dynamic>? ?? const [])) '$d'],
      diagnoses: [for (final d in maps(j['diagnoses'])) CaseDiagnosis.fromJson(d)],
      plans: [for (final p in maps(j['plans'])) CasePlan.fromJson(p)],
      treatments: maps(j['treatments']),
      observations: maps(j['observations']),
      pending: j['_pending'] == true,
    );
  }
}

/// One observation from `GET /observations` — what a person saw, never a
/// diagnosis (Constitution: workers record observations, they do not
/// diagnose).
class ObservationRecord {
  const ObservationRecord({required this.id, required this.entityType, required this.entityId, required this.type, this.severity, required this.observedAt, this.notes});
  final String id;
  final String entityType;
  final String entityId;
  final String type;
  final String? severity;
  final DateTime observedAt;
  final String? notes;

  factory ObservationRecord.fromJson(Map<String, dynamic> j) => ObservationRecord(
        id: j['id'] as String? ?? '',
        entityType: j['entity_type'] as String? ?? 'animal',
        entityId: j['entity_id'] as String? ?? '',
        type: j['observation_type'] as String? ?? 'observation',
        severity: j['severity'] as String?,
        observedAt: _dt(j['observed_at']) ?? DateTime.now(),
        notes: j['notes'] as String?,
      );
}
