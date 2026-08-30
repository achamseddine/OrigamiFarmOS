import 'dart:async';
import 'package:flutter/foundation.dart';
import '../data/demo/demo_data.dart';
import '../data/local/entity_mappers.dart';
import '../data/remote/api_exception.dart';
import '../data/remote/farmos_api.dart';
import '../data/remote/session_manager.dart';
import '../domain/entities/recommendation.dart';

/// AI recommendations for the Health Intelligence and Morning Briefing
/// screens. Starts on [DemoData] (demo mode); [refresh] pulls the real,
/// evidence-backed `GET /recommendations` list once signed in — see
/// OrigamiFarmServer `app/farmos/recommendations.py` for the rules that
/// generate them (RULE-FEED-COST-INSIGHT, RULE-HARVEST-DUE,
/// RULE-LOW-FEED, RULE-EGG-DROP).
class RecommendationsProvider extends ChangeNotifier {
  RecommendationsProvider({required SessionManager session, required FarmosApi api})
      : _session = session,
        _api = api,
        _recommendations = List.of(DemoData.recommendations) {
    unawaited(refresh());
  }

  final SessionManager _session;
  final FarmosApi _api;
  List<Recommendation> _recommendations;

  List<Recommendation> get recommendations => List.unmodifiable(_recommendations);

  Future<void> refresh() async {
    final farmId = _session.farmId;
    if (!_session.isLoggedIn || farmId == null) return;
    try {
      final rows = await _api.listRecommendations(farmId);
      _recommendations =
          rows.map((r) => recommendationFromJson(r as Map<String, dynamic>)).toList();
      notifyListeners();
    } on ApiOfflineException {
      // Keep whatever was last loaded (demo data or a previous fetch).
    } on ApiException {
      // Same: a rejected request shouldn't blank out a working screen.
    }
  }
}
