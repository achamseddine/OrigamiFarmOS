enum RecommendationPriority { high, medium, low, info }

enum RecommendationCategory { health, feed, egg, withdrawal, harvest, finance }

enum RecommendationStatus { generated, reviewed, accepted, rejected, postponed, taskCreated }

RecommendationStatus _statusFromApi(String v) => switch (v) {
      'reviewed' => RecommendationStatus.reviewed,
      'accepted' => RecommendationStatus.accepted,
      'rejected' => RecommendationStatus.rejected,
      'postponed' => RecommendationStatus.postponed,
      'task_created' => RecommendationStatus.taskCreated,
      _ => RecommendationStatus.generated,
    };

/// One piece of supporting evidence for a [Recommendation]. Constitution:
/// "Every recommendation requires evidence."
class RecommendationEvidence {
  const RecommendationEvidence({required this.label, required this.value, this.trendDown});
  final String label;
  final String value;
  final bool? trendDown;
}

/// Rule-based, explainable recommendation (tech spec §15, handbook 04.2).
/// Never generated without evidence + confidence + rationale, per
/// CONSTITUTION.md.
class Recommendation {
  const Recommendation({
    required this.id,
    required this.category,
    required this.priority,
    required this.title,
    required this.entityLabel,
    required this.confidence,
    required this.rationale,
    required this.suggestedAction,
    required this.evidence,
    required this.generatedAt,
    this.status = RecommendationStatus.generated,
    this.ruleId,
  });

  final String id;
  final RecommendationCategory category;
  final RecommendationPriority priority;
  final String title;
  final String entityLabel;
  final double confidence; // 0..1
  final String rationale;
  final String suggestedAction;
  final List<RecommendationEvidence> evidence;
  final DateTime generatedAt;
  final RecommendationStatus status;
  final String? ruleId;

  int get confidencePct => (confidence * 100).round();

  /// Backend `RecommendationOut` shape (schemas/recommendations.py).
  factory Recommendation.fromJson(Map<String, dynamic> json) => Recommendation(
        id: json['id'] as String,
        category: RecommendationCategory.values.byName(json['category'] as String),
        priority: RecommendationPriority.values.byName(json['priority'] as String),
        title: json['title'] as String,
        entityLabel: json['entity_label'] as String? ?? '',
        confidence: (json['confidence'] as num).toDouble(),
        rationale: json['rationale'] as String,
        suggestedAction: json['suggested_action'] as String,
        evidence: [
          for (final e in (json['evidence'] as List<dynamic>? ?? [])) RecommendationEvidence(label: (e as Map<String, dynamic>)['label'] as String, value: e['value'] as String),
        ],
        generatedAt: DateTime.parse(json['generated_at'] as String),
        status: _statusFromApi(json['status'] as String? ?? 'generated'),
        ruleId: json['rule_id'] as String?,
      );
}
