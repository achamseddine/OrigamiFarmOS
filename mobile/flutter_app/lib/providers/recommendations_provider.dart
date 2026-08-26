import 'package:flutter/foundation.dart';
import '../api/api_client.dart';
import '../domain/entities/recommendation.dart';

/// Rule-based recommendations (tech spec §15) — used by both the Morning
/// Briefing (all categories) and Health Intelligence (health category)
/// screens. `refresh=true` on every load re-evaluates the backend's rule
/// engine against current farm state first, so this is never stale.
class RecommendationsProvider extends ChangeNotifier {
  RecommendationsProvider({required ApiClient apiClient, required String farmId, required String currentUserId})
      : _api = apiClient,
        _farmId = farmId,
        _currentUserId = currentUserId;

  final ApiClient _api;
  final String _farmId;
  final String _currentUserId;
  List<Recommendation> _recommendations = [];
  bool loading = false;

  List<Recommendation> get recommendations => List.unmodifiable(_recommendations);
  List<Recommendation> forCategory(RecommendationCategory c) => _recommendations.where((r) => r.category == c).toList();

  Future<void> load() async {
    loading = true;
    notifyListeners();
    try {
      final json = await _api.get('/recommendations', query: {'farm_id': _farmId, 'refresh': true}) as List<dynamic>;
      _recommendations = json.map((e) => Recommendation.fromJson(e as Map<String, dynamic>)).toList();
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<WriteResult> decide(String recommendationId, String decision, {String? note}) async {
    final result = await _api.write(() => _api.patch('/recommendations/$recommendationId/decision', body: {'decision': decision, 'decided_by': _currentUserId, 'note': note}));
    if (result.success) await load();
    return result;
  }
}
