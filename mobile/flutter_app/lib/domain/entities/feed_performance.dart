/// Feed Performance Intelligence as the tablet reads it
/// (database/FEED-PERFORMANCE-INTELLIGENCE.md): what is watched, what the
/// last evaluation said and how sure it was, the alerts that stay open
/// until the evidence clears, the score card of every numbered mix and
/// the supplier rows, one per ingredient.
///
/// Every figure here is the server's explanation of facts it holds
/// elsewhere. Nothing is a diagnosis, and nothing changes a lot, a
/// formula or a supplier's standing.
library;

double? _dn(Object? v) => (v as num?)?.toDouble();
double _d(Object? v, [double fallback = 0]) => (v as num?)?.toDouble() ?? fallback;
int _i(Object? v, [int fallback = 0]) => (v as num?)?.toInt() ?? fallback;
DateTime? _dt(Object? v) => v == null ? null : DateTime.tryParse(v as String);
List<Map<String, dynamic>> _maps(Object? v) => [for (final e in v as List<dynamic>? ?? const []) e as Map<String, dynamic>];
List<String> _strings(Object? v) => [for (final e in v as List<dynamic>? ?? const []) e.toString()];
Map<String, dynamic> _map(Object? v) => (v as Map<String, dynamic>?) ?? const {};

/// `GET /feed-performance/summary`.
class FeedPerformanceSummary {
  const FeedPerformanceSummary({
    required this.openAlerts,
    required this.alertsByType,
    required this.monitors,
    this.lastEvaluatedAt,
    required this.batchesScored,
    required this.suppliersScored,
    required this.modelReference,
    required this.modelVersion,
  });

  final int openAlerts;
  final Map<String, int> alertsByType;
  final int monitors;
  final DateTime? lastEvaluatedAt;
  final int batchesScored;
  final int suppliersScored;
  final String modelReference;
  final String modelVersion;

  static const empty = FeedPerformanceSummary(openAlerts: 0, alertsByType: {}, monitors: 0, batchesScored: 0, suppliersScored: 0, modelReference: '', modelVersion: '');

  factory FeedPerformanceSummary.fromJson(Map<String, dynamic> json) => FeedPerformanceSummary(
        openAlerts: _i(json['open_alerts']),
        alertsByType: {for (final e in _map(json['alerts_by_type']).entries) e.key: _i(e.value)},
        monitors: _i(json['monitors']),
        lastEvaluatedAt: _dt(json['last_evaluated_at']),
        batchesScored: _i(json['batches_scored']),
        suppliersScored: _i(json['suppliers_scored']),
        modelReference: json['model_reference'] as String? ?? '',
        modelVersion: json['model_version'] as String? ?? '',
      );
}

/// One evaluation of one monitor: the explicit baseline, what was observed,
/// the likelihood label, the confidence and the explanation a person can
/// check. `status` is normal | anomaly | insufficient.
class FeedPerformanceAssessment {
  const FeedPerformanceAssessment({
    required this.id,
    required this.monitorId,
    this.subjectType,
    this.subjectId,
    this.subjectName,
    this.metric,
    this.evaluatedAt,
    this.baselineValue,
    this.observedValue,
    this.variancePercent,
    required this.likelihood,
    required this.confidence,
    required this.modelReference,
    required this.explanation,
    required this.status,
    required this.feedChanges,
    required this.missingContext,
    required this.unit,
  });

  final String id;
  final String monitorId;
  final String? subjectType;
  final String? subjectId;
  final String? subjectName;
  final String? metric;
  final DateTime? evaluatedAt;
  final double? baselineValue;
  final double? observedValue;
  final double? variancePercent;

  /// LOW | MODERATE | HIGH | INSUFFICIENT_EVIDENCE — an association, never a cause.
  final String likelihood;
  final double confidence;
  final String modelReference;
  final String explanation;
  final String status;
  final List<Map<String, dynamic>> feedChanges;

  /// Context the farm does not record, each of which lowered the confidence.
  final List<String> missingContext;
  final String unit;

  bool get isAnomaly => status == 'anomaly';
  bool get isInsufficient => status == 'insufficient';

  factory FeedPerformanceAssessment.fromJson(Map<String, dynamic> json) {
    final evidence = _map(json['evidence']);
    return FeedPerformanceAssessment(
      id: json['id'] as String,
      monitorId: json['monitor_id'] as String? ?? '',
      subjectType: json['subject_type'] as String?,
      subjectId: json['subject_id'] as String?,
      subjectName: json['subject_name'] as String?,
      metric: json['production_metric_code'] as String?,
      evaluatedAt: _dt(json['evaluated_at']),
      baselineValue: _dn(json['baseline_value']),
      observedValue: _dn(json['observed_value']),
      variancePercent: _dn(json['variance_percent']),
      likelihood: json['feed_related_likelihood'] as String? ?? 'INSUFFICIENT_EVIDENCE',
      confidence: _d(json['confidence_score']),
      modelReference: json['model_reference'] as String? ?? '',
      explanation: json['explanation'] as String? ?? '',
      status: json['status'] as String? ?? 'insufficient',
      feedChanges: _maps(evidence['feed_changes']),
      missingContext: _strings(_map(json['confounders'])['missing_context']),
      unit: evidence['unit'] as String? ?? '',
    );
  }
}

/// What the farm continuously evaluates: one subject, one metric, one
/// explicit baseline method, and the thresholds that decide when a change
/// is worth a person's attention.
class FeedPerformanceMonitor {
  const FeedPerformanceMonitor({
    required this.id,
    required this.subjectType,
    required this.subjectId,
    this.subjectName,
    this.species,
    required this.metric,
    required this.baselineMethod,
    required this.baselineWindowDays,
    required this.evaluationWindowDays,
    required this.thresholdPercent,
    required this.active,
    this.latest,
  });

  final String id;
  final String subjectType;
  final String subjectId;
  final String? subjectName;
  final String? species;
  final String metric;
  final String baselineMethod;
  final int baselineWindowDays;
  final int evaluationWindowDays;
  final double thresholdPercent;
  final bool active;
  final FeedPerformanceAssessment? latest;

  factory FeedPerformanceMonitor.fromJson(Map<String, dynamic> json) => FeedPerformanceMonitor(
        id: json['id'] as String,
        subjectType: json['subject_type'] as String? ?? 'animal',
        subjectId: json['subject_id'] as String? ?? '',
        subjectName: json['subject_name'] as String?,
        species: json['species'] as String?,
        metric: json['production_metric_code'] as String? ?? 'milk_l_per_day',
        baselineMethod: json['baseline_method_code'] as String? ?? 'rolling_subject',
        baselineWindowDays: _i(json['baseline_window_days'], 14),
        evaluationWindowDays: _i(json['evaluation_window_days'], 3),
        thresholdPercent: _d(json['alert_threshold_percent'], 5),
        active: json['active'] as bool? ?? true,
        latest: json['latest_assessment'] == null ? null : FeedPerformanceAssessment.fromJson(json['latest_assessment'] as Map<String, dynamic>),
      );
}

/// A persistent, deduplicated finding. Acknowledging records that a person
/// saw it; only the evidence clearing (or an explained manual close)
/// resolves it.
class FeedPerformanceAlert {
  const FeedPerformanceAlert({
    required this.id,
    required this.alertType,
    required this.severity,
    required this.status,
    required this.title,
    required this.explanation,
    this.confidence,
    this.mixCode,
    this.feedBatchId,
    this.productName,
    this.subjectType,
    this.subjectId,
    this.subjectName,
    this.detectedAt,
    this.lastSeenAt,
    this.acknowledgedAt,
    this.resolvedAt,
    this.resolutionNote,
    required this.evidence,
  });

  final String id;
  final String alertType;

  /// critical | high | medium | low | info — the bell's priorities.
  final String severity;

  /// open | acknowledged | resolved.
  final String status;
  final String title;
  final String explanation;
  final double? confidence;
  final String? mixCode;
  final String? feedBatchId;
  final String? productName;
  final String? subjectType;
  final String? subjectId;
  final String? subjectName;
  final DateTime? detectedAt;
  final DateTime? lastSeenAt;
  final DateTime? acknowledgedAt;
  final DateTime? resolvedAt;
  final String? resolutionNote;
  final Map<String, dynamic> evidence;

  bool get isOpen => status == 'open';
  bool get isResolved => status == 'resolved';

  factory FeedPerformanceAlert.fromJson(Map<String, dynamic> json) => FeedPerformanceAlert(
        id: json['id'] as String,
        alertType: json['alert_type'] as String? ?? '',
        severity: json['severity'] as String? ?? 'medium',
        status: json['status'] as String? ?? 'open',
        title: json['title'] as String? ?? '',
        explanation: json['explanation'] as String? ?? '',
        confidence: _dn(json['confidence_score']),
        mixCode: json['mix_code'] as String?,
        feedBatchId: json['feed_batch_id'] as String?,
        productName: json['product_name'] as String?,
        subjectType: json['subject_type'] as String?,
        subjectId: json['subject_id'] as String?,
        subjectName: json['subject_name'] as String?,
        detectedAt: _dt(json['detected_at']),
        lastSeenAt: _dt(json['last_seen_at']),
        acknowledgedAt: _dt(json['acknowledged_at']),
        resolvedAt: _dt(json['resolved_at']),
        resolutionNote: json['resolution_note'] as String?,
        evidence: _map(json['evidence']),
      );
}

/// The score card of one numbered mix. A dimension with no evidence is
/// null — never scored as perfect — and lowers the confidence.
class FeedBatchScore {
  const FeedBatchScore({
    required this.feedBatchId,
    required this.mixNumber,
    this.mixCode,
    this.productName,
    this.status,
    this.evaluatedAt,
    this.exposedHeadCount,
    this.exposureDays,
    this.formulaCompliance,
    this.intakeResponse,
    this.productionResponse,
    this.healthSignal,
    this.consistency,
    this.economic,
    this.overall,
    required this.confidence,
    required this.openAlerts,
    required this.evidence,
  });

  final String feedBatchId;
  final int mixNumber;
  final String? mixCode;
  final String? productName;
  final String? status;
  final DateTime? evaluatedAt;
  final int? exposedHeadCount;
  final double? exposureDays;
  final double? formulaCompliance;
  final double? intakeResponse;
  final double? productionResponse;
  final double? healthSignal;
  final double? consistency;
  final double? economic;
  final double? overall;
  final double confidence;
  final List<Map<String, dynamic>> openAlerts;
  final Map<String, dynamic> evidence;

  factory FeedBatchScore.fromJson(Map<String, dynamic> json) => FeedBatchScore(
        feedBatchId: json['feed_batch_id'] as String,
        mixNumber: _i(json['mix_number']),
        mixCode: json['mix_code'] as String?,
        productName: json['product_name'] as String?,
        status: json['status'] as String?,
        evaluatedAt: _dt(json['evaluated_at']),
        exposedHeadCount: (json['exposed_head_count'] as num?)?.toInt(),
        exposureDays: _dn(json['exposure_days']),
        formulaCompliance: _dn(json['formula_compliance_score']),
        intakeResponse: _dn(json['intake_response_score']),
        productionResponse: _dn(json['production_response_score']),
        healthSignal: _dn(json['health_signal_score']),
        consistency: _dn(json['consistency_score']),
        economic: _dn(json['economic_score']),
        overall: _dn(json['overall_score']),
        confidence: _d(json['confidence_score']),
        openAlerts: _maps(json['open_alerts']),
        evidence: _map(json['evidence']),
      );
}

/// Supplier × ingredient, from that supplier's actual lots and what
/// happened downstream of them. Ingredient-specific on purpose.
class SupplierPerformance {
  const SupplierPerformance({
    required this.id,
    this.supplierId,
    required this.supplierLabel,
    required this.feedProductId,
    this.productName,
    required this.lotCount,
    this.feedBatchCount,
    this.purchaseQuantity,
    this.unit,
    this.averageUnitCost,
    this.qualityConsistency,
    this.downstreamPerformance,
    required this.incidentCount,
    required this.confidence,
    required this.methodologyCode,
    this.generatedAt,
  });

  final String id;
  final String? supplierId;
  final String supplierLabel;
  final String feedProductId;
  final String? productName;
  final int lotCount;
  final int? feedBatchCount;
  final double? purchaseQuantity;
  final String? unit;
  final double? averageUnitCost;
  final double? qualityConsistency;
  final double? downstreamPerformance;
  final int incidentCount;
  final double confidence;
  final String methodologyCode;
  final DateTime? generatedAt;

  factory SupplierPerformance.fromJson(Map<String, dynamic> json) => SupplierPerformance(
        id: json['id'] as String,
        supplierId: json['supplier_id'] as String?,
        supplierLabel: json['supplier_label'] as String? ?? '',
        feedProductId: json['feed_product_id'] as String? ?? '',
        productName: json['product_name'] as String?,
        lotCount: _i(json['lot_count']),
        feedBatchCount: (json['feed_batch_count'] as num?)?.toInt(),
        purchaseQuantity: _dn(json['purchase_quantity']),
        unit: json['unit'] as String?,
        averageUnitCost: _dn(json['average_unit_cost']),
        qualityConsistency: _dn(json['quality_consistency_score']),
        downstreamPerformance: _dn(json['downstream_performance_score']),
        incidentCount: _i(json['incident_count']),
        confidence: _d(json['confidence_score']),
        methodologyCode: json['methodology_code'] as String? ?? '',
        generatedAt: _dt(json['generated_at']),
      );
}
