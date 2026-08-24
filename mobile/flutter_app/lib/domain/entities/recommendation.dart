enum RecommendationPriority { high, medium, low, info }

enum RecommendationCategory { health, feed, egg, withdrawal, harvest, finance }

enum RecommendationStatus { generated, reviewed, accepted, rejected, postponed, taskCreated }

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
}
