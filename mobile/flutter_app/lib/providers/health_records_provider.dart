import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api/api_client.dart';
import '../domain/entities/health_case.dart';

/// The farm's health record behind the Health screen: every health case
/// (open, monitoring and closed) and the observations people recorded.
///
/// Opening, moving to monitoring and closing a case go through
/// [ApiClient.write] like every other write — straight to the server, or
/// into the outbox with the cached lists updated at once
/// (`cache_effects.dart`). Diagnoses and treatment plans are not written
/// here: the server takes them from a diagnostic role only, and the tablet
/// shows what the veterinarian recorded.
class HealthRecordsProvider extends ChangeNotifier {
  HealthRecordsProvider({required ApiClient apiClient, required String farmId})
      : _api = apiClient,
        _farmId = farmId;

  final ApiClient _api;
  final String _farmId;

  List<HealthCase> cases = [];
  List<ObservationRecord> observations = [];
  bool loading = false;

  List<HealthCase> get openCases => [for (final c in cases) if (c.isOpen) c]
    ..sort((a, b) {
      final bySeverity = b.severityRank.compareTo(a.severityRank);
      return bySeverity != 0 ? bySeverity : (b.openedAt ?? DateTime(2000)).compareTo(a.openedAt ?? DateTime(2000));
    });

  List<HealthCase> casesFor(String subjectId) => [for (final c in cases) if (c.subjectId == subjectId) c];

  Future<void> load() async {
    loading = true;
    notifyListeners();
    try {
      await Future.wait([
        _fetch('/health/cases', (j) => cases = [for (final c in j as List<dynamic>) HealthCase.fromJson(c as Map<String, dynamic>)], query: {'status': 'all'}),
        _fetch('/observations', (j) => observations = [for (final o in j as List<dynamic>) ObservationRecord.fromJson(o as Map<String, dynamic>)],
            query: {'farm_id': _farmId}),
      ]);
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  /// A case with its diagnoses, plans, treatments and observations.
  Future<HealthCase> detail(String caseId) async => HealthCase.fromJson(await _api.get('/health/cases/$caseId') as Map<String, dynamic>);

  Future<WriteResult> openCase({required String subjectType, required String subjectId, String? severity, String? problem, String? notes}) =>
      _write(() => _api.post('/health/cases', body: {
            'subject_type': subjectType,
            'subject_id': subjectId,
            'severity_code': ?severity,
            'primary_problem_code': ?_blank(problem),
            'notes': ?_blank(notes),
          }));

  /// "Monitoring": nothing more to do now, but not over yet.
  Future<WriteResult> setStatus(String caseId, String status) => _write(() => _api.patch('/health/cases/$caseId', body: {'status': status}));

  Future<WriteResult> closeCase(String caseId, {required String outcome, String status = 'resolved'}) =>
      _write(() => _api.post('/health/cases/$caseId/close', body: {'outcome': outcome.trim(), 'status': status}));

  Future<void> _fetch(String path, void Function(dynamic json) apply, {Map<String, dynamic>? query}) async {
    try {
      apply(await _api.get(path, query: query));
    } catch (_) {
      // Keep what we had; the screen shows its empty state if that is nothing.
    }
  }

  Future<WriteResult> _write(Future<dynamic> Function() action) async {
    final result = await _api.write(action);
    if (result.success) unawaited(load());
    return result;
  }

  static String? _blank(String? v) => v == null || v.trim().isEmpty ? null : v.trim();
}
