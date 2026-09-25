import 'package:flutter/foundation.dart';

import '../api/api_client.dart';
import '../domain/entities/feeding.dart';

/// The feed workspace's data (generic feed architecture): products and
/// lots, formulas, batches, programs, today's plan, stock cover and
/// reorder alerts, reservations, reconciliations, costs — and the
/// per-subject feeding plan the animal profile shows.
///
/// Every list loads independently and a failure leaves the previous
/// value in place, so a tablet that is offline with a partial cache still
/// shows what it has. Writes go through the API client's outbox like every
/// other write in the app; after one succeeds the affected lists reload.
class FeedingProvider extends ChangeNotifier {
  FeedingProvider({required ApiClient apiClient}) : _api = apiClient;

  final ApiClient _api;

  List<FeedProduct> products = [];
  List<FeedLot> lots = [];
  List<FeedFormula> formulas = [];
  List<FeedBatch> batches = [];
  List<FeedingProgram> programs = [];
  DailyPlan dailyPlan = DailyPlan.empty;
  List<FeedCover> cover = [];
  List<FeedCover> reorder = [];
  List<FeedAllocation> allocations = [];
  List<FeedReconciliation> reconciliations = [];
  FeedCostSummary costs = FeedCostSummary.empty;
  List<NutrientDef> nutrients = [];
  final Map<String, FeedingPlan> _plans = {};
  bool loading = false;
  bool get isLoaded => products.isNotEmpty;

  FeedProduct? productById(String id) {
    for (final p in products) {
      if (p.id == id) return p;
    }
    return null;
  }

  String productName(String id, String lang) => productById(id)?.label(lang) ?? id;

  List<FeedProduct> get feedable => [for (final p in products) if (p.isFeedable && p.status == 'active') p];
  List<FeedProduct> get ingredients => [for (final p in products) if (p.isIngredient && p.status == 'active') p];
  List<FeedProduct> get farmProduced => [for (final p in products) if (p.isFarmProduced && p.status == 'active') p];
  List<FeedLot> lotsFor(String productId) => [for (final l in lots) if (l.feedProductId == productId) l];

  FeedingPlan? cachedPlan(String subjectId) => _plans[subjectId];

  Future<void> load() async {
    loading = true;
    notifyListeners();
    try {
      await Future.wait([
        _fetch('/feed-products', (j) => products = [for (final p in j as List<dynamic>) FeedProduct.fromJson(p as Map<String, dynamic>)]),
        _fetch('/feed-lots', (j) => lots = [for (final l in j as List<dynamic>) FeedLot.fromJson(l as Map<String, dynamic>)]),
        _fetch('/feed-formulas', (j) => formulas = [for (final f in j as List<dynamic>) FeedFormula.fromJson(f as Map<String, dynamic>)]),
        _fetch('/feed-batches', (j) => batches = [for (final b in j as List<dynamic>) FeedBatch.fromJson(b as Map<String, dynamic>)]),
        _fetch('/feeding-programs', (j) => programs = [for (final p in j as List<dynamic>) FeedingProgram.fromJson(p as Map<String, dynamic>)]),
        _fetch('/feeding-plan/today', (j) => dailyPlan = DailyPlan.fromJson(j as Map<String, dynamic>)),
        _fetch('/feed-inventory/days-of-cover', (j) => cover = [for (final c in j as List<dynamic>) FeedCover.fromJson(c as Map<String, dynamic>)]),
        _fetch('/feed-inventory/reorder-recommendations', (j) => reorder = [for (final c in j as List<dynamic>) FeedCover.fromJson(c as Map<String, dynamic>)]),
        _fetch('/feed-allocations', (j) => allocations = [for (final a in j as List<dynamic>) FeedAllocation.fromJson(a as Map<String, dynamic>)]),
        _fetch('/feed-reconciliations', (j) => reconciliations = [for (final r in j as List<dynamic>) FeedReconciliation.fromJson(r as Map<String, dynamic>)]),
        _fetch('/feed-costs', (j) => costs = FeedCostSummary.fromJson(j as Map<String, dynamic>), query: {'days': 30}),
        _fetch('/feed-nutrients', (j) => nutrients = [for (final n in j as List<dynamic>) NutrientDef.fromJson(n as Map<String, dynamic>)]),
      ]);
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  /// What a write to stock changes: products (availability), lots, cover,
  /// the reorder list and today's plan totals.
  Future<void> refreshStock() async {
    await Future.wait([
      _fetch('/feed-products', (j) => products = [for (final p in j as List<dynamic>) FeedProduct.fromJson(p as Map<String, dynamic>)]),
      _fetch('/feed-lots', (j) => lots = [for (final l in j as List<dynamic>) FeedLot.fromJson(l as Map<String, dynamic>)]),
      _fetch('/feed-inventory/days-of-cover', (j) => cover = [for (final c in j as List<dynamic>) FeedCover.fromJson(c as Map<String, dynamic>)]),
      _fetch('/feed-inventory/reorder-recommendations', (j) => reorder = [for (final c in j as List<dynamic>) FeedCover.fromJson(c as Map<String, dynamic>)]),
      _fetch('/feeding-plan/today', (j) => dailyPlan = DailyPlan.fromJson(j as Map<String, dynamic>)),
      _fetch('/feed-costs', (j) => costs = FeedCostSummary.fromJson(j as Map<String, dynamic>), query: {'days': 30}),
    ]);
    notifyListeners();
  }

  Future<void> _fetch(String path, void Function(dynamic json) apply, {Map<String, dynamic>? query}) async {
    try {
      apply(await _api.get(path, query: query));
    } catch (_) {
      // Keep what we had; the screen shows its empty state if that is nothing.
    }
  }

  // ------------------------------------------------------------ reads
  Future<FeedingPlan?> planFor(String subjectId, {bool force = false}) async {
    if (!force && _plans.containsKey(subjectId)) return _plans[subjectId];
    try {
      final plan = FeedingPlan.fromJson(await _api.get('/livestock-subjects/$subjectId/feeding-plan') as Map<String, dynamic>);
      _plans[subjectId] = plan;
      notifyListeners();
      return plan;
    } catch (_) {
      return _plans[subjectId];
    }
  }

  Future<LotTrace?> trace(String lotId) async {
    try {
      return LotTrace.fromJson(await _api.get('/feed-lots/$lotId/trace') as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<List<NutrientProfile>> profilesFor(String subjectType, String subjectId) async {
    try {
      final json = await _api.get('/feed-nutrient-profiles', query: {'subject_type': subjectType, 'subject_id': subjectId}) as List<dynamic>;
      return [for (final p in json) NutrientProfile.fromJson(p as Map<String, dynamic>)];
    } catch (_) {
      return [];
    }
  }

  Future<Map<String, dynamic>?> formulaNutrients(String formulaId, int version) async {
    try {
      return await _api.get('/feed-formulas/$formulaId/versions/$version/nutrients') as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>?> scale(String formulaId, int version, double batchSize) async {
    try {
      return await _api.get('/feed-formulas/$formulaId/versions/$version/scale', query: {'batch_size': batchSize}) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>?> resolve(Map<String, dynamic> body) async {
    try {
      return await _api.post('/feeding-programs/resolve', body: body) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  // ----------------------------------------------------------- writes
  Future<WriteResult> _write(Future<dynamic> Function() call, {Future<void> Function()? then}) async {
    final result = await _api.write(call);
    if (result.success && then != null) await then();
    return result;
  }

  Future<WriteResult> createProduct(Map<String, dynamic> body) => _write(() => _api.post('/feed-products', body: body), then: refreshStock);
  Future<WriteResult> receiveLot(Map<String, dynamic> body) => _write(() => _api.post('/feed-lots/receive', body: body), then: refreshStock);
  Future<WriteResult> setLotStatus(String lotId, String status, {String? reason}) =>
      _write(() => _api.patch('/feed-lots/$lotId/status', body: {'status': status, 'reason': reason}), then: refreshStock);
  Future<WriteResult> adjust(Map<String, dynamic> body) => _write(() => _api.post('/feed-inventory/adjustments', body: body), then: refreshStock);

  Future<WriteResult> createFormula(Map<String, dynamic> body) => _write(() => _api.post('/feed-formulas', body: body), then: _reloadFormulas);
  Future<WriteResult> addFormulaVersion(String formulaId, Map<String, dynamic> body) =>
      _write(() => _api.post('/feed-formulas/$formulaId/versions', body: body), then: _reloadFormulas);
  Future<void> _reloadFormulas() async {
    await _fetch('/feed-formulas', (j) => formulas = [for (final f in j as List<dynamic>) FeedFormula.fromJson(f as Map<String, dynamic>)]);
    notifyListeners();
  }

  Future<WriteResult> startBatch(Map<String, dynamic> body) => _write(() => _api.post('/feed-batches', body: body), then: _reloadBatches);
  Future<WriteResult> completeBatch(String batchId, Map<String, dynamic> body) =>
      _write(() => _api.post('/feed-batches/$batchId/complete', body: body), then: () async {
        await _reloadBatches();
        await _reloadFormulas();
        await refreshStock();
      });
  Future<WriteResult> quarantineBatch(String batchId, String reason) =>
      _write(() => _api.post('/feed-batches/$batchId/quarantine', body: {'reason': reason}), then: () async {
        await _reloadBatches();
        await refreshStock();
      });
  Future<void> _reloadBatches() async {
    await _fetch('/feed-batches', (j) => batches = [for (final b in j as List<dynamic>) FeedBatch.fromJson(b as Map<String, dynamic>)]);
    notifyListeners();
  }

  Future<WriteResult> createProgram(Map<String, dynamic> body) => _write(() => _api.post('/feeding-programs', body: body), then: _reloadPrograms);
  Future<WriteResult> addProgramVersion(String programId, Map<String, dynamic> body) =>
      _write(() => _api.post('/feeding-programs/$programId/versions', body: body), then: _reloadPrograms);
  Future<void> _reloadPrograms() async {
    await _fetch('/feeding-programs', (j) => programs = [for (final p in j as List<dynamic>) FeedingProgram.fromJson(p as Map<String, dynamic>)]);
    await _fetch('/feeding-plan/today', (j) => dailyPlan = DailyPlan.fromJson(j as Map<String, dynamic>));
    _plans.clear();
    notifyListeners();
  }

  Future<WriteResult> assign(String subjectId, Map<String, dynamic> body) =>
      _write(() => _api.post('/livestock-subjects/$subjectId/feeding-assignments', body: body), then: () async {
        await planFor(subjectId, force: true);
        await _fetch('/feeding-plan/today', (j) => dailyPlan = DailyPlan.fromJson(j as Map<String, dynamic>));
        notifyListeners();
      });
  Future<WriteResult> endAssignment(String subjectId, String assignmentId) =>
      _write(() => _api.delete('/livestock-subjects/$subjectId/feeding-assignments/$assignmentId'), then: () => planFor(subjectId, force: true));

  Future<WriteResult> recordFeeding(Map<String, dynamic> body) =>
      _write(() => _api.post('/feeding-events', body: body), then: () async {
        final subjectId = body['subject_id'] as String?;
        if (subjectId != null) await planFor(subjectId, force: true);
        await refreshStock();
      });
  Future<WriteResult> reverseFeeding(String eventId, String reason, {String? subjectId}) =>
      _write(() => _api.post('/feeding-events/$eventId/reverse', body: {'reason': reason}), then: () async {
        if (subjectId != null) await planFor(subjectId, force: true);
        await refreshStock();
      });

  Future<WriteResult> createAllocation(Map<String, dynamic> body) => _write(() => _api.post('/feed-allocations', body: body), then: _reloadAllocations);
  Future<WriteResult> releaseAllocation(String id) => _write(() => _api.post('/feed-allocations/$id/release'), then: _reloadAllocations);
  Future<void> _reloadAllocations() async {
    await _fetch('/feed-allocations', (j) => allocations = [for (final a in j as List<dynamic>) FeedAllocation.fromJson(a as Map<String, dynamic>)]);
    await refreshStock();
  }

  Future<WriteResult> acknowledgeReorder(String productId, {double? quantity, String? note}) =>
      _write(() => _api.post('/feed-inventory/reorder-recommendations/$productId/acknowledge', body: {'quantity': quantity, 'note': note}), then: refreshStock);

  Future<WriteResult> createReconciliation(Map<String, dynamic> body) => _write(() => _api.post('/feed-reconciliations', body: body), then: _reloadReconciliations);
  Future<WriteResult> closeReconciliation(String id, {required bool postAdjustment, String? explanation}) =>
      _write(() => _api.post('/feed-reconciliations/$id/close', body: {'post_adjustment': postAdjustment, 'explanation': explanation}), then: () async {
        await _reloadReconciliations();
        await refreshStock();
      });
  Future<void> _reloadReconciliations() async {
    await _fetch('/feed-reconciliations', (j) => reconciliations = [for (final r in j as List<dynamic>) FeedReconciliation.fromJson(r as Map<String, dynamic>)]);
    notifyListeners();
  }

  Future<WriteResult> recordNutrientProfile(Map<String, dynamic> body) => _write(() => _api.post('/feed-nutrient-profiles', body: body));
}
