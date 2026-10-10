import 'package:flutter/foundation.dart';

import '../api/api_client.dart';
import '../domain/entities/emergency.dart';

/// The emergency protocol engine (database/CLINICAL-DECISION-SUPPORT-
/// EMERGENCY-PROTOCOLS.md): approved protocols, live cases, runs and the
/// sign vocabulary. The server triages, matches, calculates and
/// escalates; this provider carries the person's answers — the signs
/// they saw, the confirmation they gave — and reloads what the engine
/// decided.
class EmergencyProvider extends ChangeNotifier {
  EmergencyProvider({required ApiClient apiClient}) : _api = apiClient;

  final ApiClient _api;

  EmergencySummary summary = EmergencySummary.empty;
  List<EmergencyAssessment> assessments = [];
  List<EmergencyRun> runs = [];
  List<EmergencyProtocol> protocols = [];
  List<SignCode> signCodes = [];
  bool loading = false;

  List<EmergencyAssessment> get activeCases => [for (final a in assessments) if (a.isActive && a.parentRunId == null) a];
  List<EmergencyAssessment> get escalated => [for (final a in assessments) if (a.isEscalated && a.parentRunId == null) a];
  List<EmergencyRun> get activeRuns => [for (final r in runs) if (r.isActive) r];
  EmergencyRun? runById(String? id) {
    for (final r in runs) {
      if (r.id == id) return r;
    }
    return null;
  }

  Future<void> load() async {
    loading = true;
    notifyListeners();
    try {
      await Future.wait(_fetches());
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> reload() async {
    await Future.wait(_fetches());
    notifyListeners();
  }

  List<Future<void>> _fetches() => [
        _fetch('/emergency/summary', (j) => summary = EmergencySummary.fromJson(j as Map<String, dynamic>)),
        _fetch('/emergency/assessments', (j) => assessments = [for (final a in j as List<dynamic>) EmergencyAssessment.fromJson(a as Map<String, dynamic>)]),
        _fetch('/emergency/runs', (j) => runs = [for (final r in j as List<dynamic>) EmergencyRun.fromJson(r as Map<String, dynamic>)]),
        _fetch('/emergency/protocols', (j) => protocols = [for (final p in j as List<dynamic>) EmergencyProtocol.fromJson(p as Map<String, dynamic>)]),
        _fetch('/emergency/sign-codes', (j) => signCodes = [for (final s in j as List<dynamic>) SignCode.fromJson(s as Map<String, dynamic>)]),
      ];

  Future<void> _fetch(String path, void Function(dynamic json) apply) async {
    try {
      apply(await _api.get(path));
    } catch (_) {
      // Keep what we had; the tab shows its empty state if that is nothing.
    }
  }

  // ------------------------------------------------------------ writes
  Future<WriteResult> _write(Future<dynamic> Function() call) async {
    final result = await _api.write(call);
    if (result.success) await reload();
    return result;
  }

  /// Triage from the signs the person saw. Offline it is queued; the
  /// server triages when it arrives — the tablet never guesses a match.
  Future<WriteResult> assess(Map<String, dynamic> body) => _write(() => _api.post('/emergency/assessments', body: body));
  Future<WriteResult> startRun(String assessmentId, {String? matchId}) =>
      _write(() => _api.post('/emergency/assessments/$assessmentId/start', body: {'match_id': matchId, 'confirmed': true}));
  Future<WriteResult> closeAssessment(String assessmentId, String outcome) =>
      _write(() => _api.post('/emergency/assessments/$assessmentId/close', body: {'outcome': outcome}));
  Future<WriteResult> prepareStep(String runId, String stepId, {double? weightKg, int? headCount}) =>
      _write(() => _api.post('/emergency/runs/$runId/steps/$stepId/prepare', body: {'weight_kg': weightKg, 'head_count': headCount}));
  Future<WriteResult> confirmStep(String runId, String stepId, {double? weightKg, int? headCount, Map<String, dynamic>? result, String? notes}) =>
      _write(() => _api.post('/emergency/runs/$runId/steps/$stepId/confirm', body: {'weight_kg': weightKg, 'head_count': headCount, 'result': result ?? const {}, 'notes': notes}));
  Future<WriteResult> skipStep(String runId, String stepId, String reason) => _write(() => _api.post('/emergency/runs/$runId/steps/$stepId/skip', body: {'reason': reason}));
  Future<WriteResult> reassess(String runId, List<Map<String, dynamic>> signs, {String? notes}) =>
      _write(() => _api.post('/emergency/runs/$runId/reassess', body: {'signs': signs, 'notes': notes}));
  Future<WriteResult> escalate(String runId, String reason) => _write(() => _api.post('/emergency/runs/$runId/escalate', body: {'reason': reason}));
  Future<WriteResult> resolveRun(String runId, String outcome) => _write(() => _api.post('/emergency/runs/$runId/resolve', body: {'outcome': outcome}));
}
