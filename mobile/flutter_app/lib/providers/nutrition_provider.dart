import 'package:flutter/foundation.dart';

import '../api/api_client.dart';
import '../domain/entities/nutrition.dart';

/// Nutrient requirements and formula assessments (master prompt Package 11).
/// The server keeps the sets (versioned, with their source) and does every
/// calculation; an assessment is stored as it was computed. An assessment
/// asked for offline waits in the outbox and is computed when it arrives.
class NutritionProvider extends ChangeNotifier {
  NutritionProvider({required ApiClient apiClient}) : _api = apiClient;

  final ApiClient _api;

  List<RequirementSet> sets = [];
  List<NutritionAssessment> assessments = [];
  bool loaded = false;

  Future<void> load() async {
    try {
      final rows = await _api.get('/nutrition/requirement-sets') as List<dynamic>;
      sets = [for (final r in rows) RequirementSet.fromJson((r as Map).cast<String, dynamic>())];
    } catch (_) {
      // Keep what was there; the tab says so when it is empty.
    }
    try {
      final rows = await _api.get('/nutrition/assessments', query: {'limit': 20}) as List<dynamic>;
      assessments = [for (final r in rows) NutritionAssessment.fromJson((r as Map).cast<String, dynamic>())];
    } catch (_) {}
    loaded = true;
    notifyListeners();
  }

  Future<WriteResult> _write(Future<dynamic> Function() call) async {
    final result = await _api.write(call);
    if (result.success && !result.queued) await load();
    return result;
  }

  /// A new requirement set, with where its figures come from (the manager).
  Future<WriteResult> createSet(Map<String, dynamic> body) => _write(() => _api.post('/nutrition/requirement-sets', body: body));

  /// A revision: a new version with its own source; the old one is kept, retired.
  Future<WriteResult> revise(String setId, Map<String, dynamic> body) =>
      _write(() => _api.post('/nutrition/requirement-sets/$setId/versions', body: body));

  /// Assesses a formula version (and its ration) against a set; the result
  /// is in [WriteResult.data] (or, queued, computed when it reaches the server).
  Future<(WriteResult, NutritionAssessment?)> assess(Map<String, dynamic> body) async {
    final result = await _write(() => _api.post('/nutrition/assessments', body: body));
    final data = result.data;
    if (result.success && !result.queued && data is Map) {
      return (result, NutritionAssessment.fromJson(data.cast<String, dynamic>()));
    }
    return (result, null);
  }
}
