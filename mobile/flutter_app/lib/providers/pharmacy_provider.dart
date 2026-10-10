import 'package:flutter/foundation.dart';

import '../api/api_client.dart';
import '../domain/entities/pharmacy.dart';

/// The farm pharmacy (database/MEDICINE-PHARMACY-SCHEMA.md): the
/// essential-medicine dashboard, open alerts, recent administrations and
/// the reference categories. Every list loads independently and a
/// failure keeps what was there, like the feed workspace. Writes go
/// through the API client's outbox; after one succeeds the lists reload,
/// because eligible stock and alert status are the server's to compute.
class PharmacyProvider extends ChangeNotifier {
  PharmacyProvider({required ApiClient apiClient}) : _api = apiClient;

  final ApiClient _api;

  PharmacySummary summary = PharmacySummary.empty;
  List<Medicine> medicines = [];
  List<PharmacyAlert> alerts = [];
  List<MedicationAdministration> administrations = [];
  List<MedicineCategory> categories = [];
  bool loading = false;
  bool get isLoaded => medicines.isNotEmpty;

  Medicine? medicineById(String id) {
    for (final m in medicines) {
      if (m.inventoryItemId == id) return m;
    }
    return null;
  }

  /// Alerts nobody has acknowledged yet — the badge on the tab.
  List<PharmacyAlert> get unseenAlerts => [for (final a in alerts) if (a.isOpen) a];

  List<Medicine> get essential => [for (final m in medicines) if (m.essential) m];

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
        _fetch('/pharmacy/summary', (j) => summary = PharmacySummary.fromJson(j as Map<String, dynamic>)),
        _fetch('/pharmacy/medicines', (j) => medicines = [for (final m in j as List<dynamic>) Medicine.fromJson(m as Map<String, dynamic>)]),
        _fetch('/pharmacy/alerts', (j) => alerts = [for (final a in j as List<dynamic>) PharmacyAlert.fromJson(a as Map<String, dynamic>)]),
        _fetch('/pharmacy/administrations', (j) => administrations = [for (final a in j as List<dynamic>) MedicationAdministration.fromJson(a as Map<String, dynamic>)]),
        _fetch('/pharmacy/categories', (j) => categories = [for (final c in j as List<dynamic>) MedicineCategory.fromJson(c as Map<String, dynamic>)]),
      ];

  Future<void> _fetch(String path, void Function(dynamic json) apply) async {
    try {
      apply(await _api.get(path));
    } catch (_) {
      // Keep what we had; the tab shows its empty state if that is nothing.
    }
  }

  /// One medicine with its lots, policies, alerts and recent doses.
  Future<Medicine?> detail(String itemId) async {
    try {
      return Medicine.fromJson(await _api.get('/pharmacy/medicines/$itemId') as Map<String, dynamic>);
    } catch (_) {
      return medicineById(itemId);
    }
  }

  // ------------------------------------------------------------ writes
  Future<WriteResult> _write(Future<dynamic> Function() call) async {
    final result = await _api.write(call);
    if (result.success && !result.queued) await reload();
    return result;
  }

  Future<WriteResult> createMedicine(Map<String, dynamic> body) => _write(() => _api.post('/pharmacy/medicines', body: body));
  Future<WriteResult> receiveLot(Map<String, dynamic> body) => _write(() => _api.post('/pharmacy/lots/receive', body: body));
  Future<WriteResult> setLotStatus(String lotId, String status, {String? reason, String? recallReference}) =>
      _write(() => _api.patch('/pharmacy/lots/$lotId/status', body: {'status': status, 'reason': reason, 'recall_reference': recallReference}));
  Future<WriteResult> setLotStorage(String lotId, {required String storageStatus, required bool coldChainException, String? note}) =>
      _write(() => _api.patch('/pharmacy/lots/$lotId/storage', body: {'storage_status': storageStatus, 'cold_chain_exception': coldChainException, 'note': note}));
  Future<WriteResult> openLot(String lotId) => _write(() => _api.post('/pharmacy/lots/$lotId/open', body: const {}));
  Future<WriteResult> adjust(Map<String, dynamic> body) => _write(() => _api.post('/pharmacy/adjustments', body: body));
  Future<WriteResult> setPolicy(String itemId, Map<String, dynamic> body) => _write(() => _api.put('/pharmacy/policies/$itemId', body: body));
  Future<WriteResult> acknowledgeAlert(String alertId) => _write(() => _api.post('/pharmacy/alerts/$alertId/acknowledge'));
  Future<WriteResult> resolveAlert(String alertId, String note) => _write(() => _api.post('/pharmacy/alerts/$alertId/resolve', body: {'note': note}));
  Future<WriteResult> createRequisition(String alertId) => _write(() => _api.post('/pharmacy/alerts/$alertId/requisition'));
  Future<WriteResult> evaluate() => _write(() => _api.post('/pharmacy/evaluate'));
  Future<WriteResult> administer(Map<String, dynamic> body) => _write(() => _api.post('/pharmacy/administrations', body: body));
  Future<WriteResult> reverseAdministration(String id, String reason) => _write(() => _api.post('/pharmacy/administrations/$id/reverse', body: {'reason': reason}));
}
