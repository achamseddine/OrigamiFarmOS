import 'package:flutter/foundation.dart';

import '../api/api_client.dart';
import '../domain/entities/approvals.dart';

/// What waits for the farm manager, and what an employee asked for
/// (backend /approval-requests and /procurement/requisitions).
///
/// The farm's rule: employees record the day's milk and feedings; buying
/// feed, a numbered mix and correcting a record already on file are the
/// manager's. An employee sends those as requests — through this provider
/// — and the manager approves or rejects them here. The server decides who
/// sees what: a manager gets every request on the modules they approve,
/// an employee only their own.
class ApprovalsProvider extends ChangeNotifier {
  ApprovalsProvider({required ApiClient apiClient, required this.currentUserId}) : _api = apiClient;

  final ApiClient _api;
  final String currentUserId;

  List<ApprovalRequest> requests = [];
  List<PurchaseRequest> purchases = [];
  bool loaded = false;

  /// Mixes and corrections waiting for a decision (the manager's list).
  List<ApprovalRequest> get waiting => [for (final r in requests) if (r.pending && r.requestedBy != currentUserId) r];

  /// Requests to buy waiting for a decision, asked by someone else.
  List<PurchaseRequest> get purchasesWaiting => [for (final p in purchases) if (p.waiting && p.requestedBy != currentUserId) p];

  /// Approved purchases whose delivery has not been recorded yet.
  List<PurchaseRequest> get deliverable => [for (final p in purchases) if (p.deliverable) p];

  /// This person's own requests, newest first, most recent ten.
  List<ApprovalRequest> get mine => [for (final r in requests) if (r.requestedBy == currentUserId) r].take(10).toList();
  List<PurchaseRequest> get myPurchases => [for (final p in purchases) if (p.requestedBy == currentUserId) p].take(10).toList();

  int get waitingCount => waiting.length + purchasesWaiting.length;

  /// The pending correction of [targetId] (a milk record, a feeding), if any.
  ApprovalRequest? pendingFor(String targetId) {
    for (final r in requests) {
      if (r.pending && r.targetId == targetId) return r;
    }
    return null;
  }

  Future<void> load() async {
    await Future.wait([
      _fetch('/approval-requests', {'limit': 100},
          (j) => requests = [for (final r in j as List<dynamic>) ApprovalRequest.fromJson(r as Map<String, dynamic>)]),
      _fetch('/procurement/requisitions', {'limit': 100},
          (j) => purchases = [for (final r in j as List<dynamic>) PurchaseRequest.fromJson(r as Map<String, dynamic>)]),
    ]);
    loaded = true;
    notifyListeners();
  }

  Future<void> _fetch(String path, Map<String, dynamic> query, void Function(dynamic json) apply) async {
    try {
      apply(await _api.get(path, query: query));
    } catch (_) {
      // Keep what was there; the card shows nothing rather than an error.
    }
  }

  Future<WriteResult> _write(Future<dynamic> Function() call) async {
    final result = await _api.write(call);
    if (result.success && !result.queued) await load();
    return result;
  }

  // ------------------------------------------------------------ asking
  /// A numbered mix made by someone without Feed approval: the
  /// `POST /feed-mixes` body, kept until the manager approves it.
  // `requested_by` and `summary` on a request body are for the copy shown
  // while it waits offline (cache_effects.dart); the server ignores them and
  // takes the signed-in user and writes its own summary.
  Future<WriteResult> sendMix(Map<String, dynamic> body, {String? summary}) => _write(() => _api.post('/approval-requests',
      body: {'kind': 'feed_mix', 'payload': body, 'requested_by': currentUserId, 'summary': ?summary}));

  Future<WriteResult> requestMilkCorrection(String recordId, Map<String, dynamic> changes, String reason, {String? summary}) => _write(() =>
      _api.post('/approval-requests', body: {
        'kind': 'milk_correction', 'target_id': recordId, 'payload': changes, 'reason': reason, 'requested_by': currentUserId, 'summary': ?summary,
      }));

  /// Undo a feeding; with [components], what was really fed instead.
  Future<WriteResult> requestFeedingCorrection(String eventId, List<Map<String, dynamic>> components, String reason, {String? summary}) =>
      _write(() => _api.post('/approval-requests', body: {
            'kind': 'feeding_correction', 'target_id': eventId, 'payload': {'components': components}, 'reason': reason,
            'requested_by': currentUserId, 'summary': ?summary,
          }));

  /// Ask the manager to buy [quantity] [unit] of a feed.
  Future<WriteResult> askToBuyFeed({
    required String feedProductId,
    required double quantity,
    required String unit,
    String? inventoryItemId,
    String? itemName,
    DateTime? neededBy,
    String? note,
  }) =>
      _write(() => _api.post('/procurement/requisitions', body: {
            'requested_by': currentUserId,
            'lines': [
              {
                'feed_product_id': feedProductId,
                'requested_quantity': quantity,
                'uom_code': unit,
                'inventory_item_id': ?inventoryItemId,
                'item_name': ?itemName,
              },
            ],
            'purpose_code': 'feed_purchase',
            if (neededBy != null) 'needed_by': neededBy.toUtc().toIso8601String(),
            if (note != null && note.trim().isNotEmpty) 'justification': note.trim(),
            'submit': true,
          }));

  Future<WriteResult> withdraw(ApprovalRequest r) => _write(() => _api.post('/approval-requests/${r.id}/cancel'));

  // ---------------------------------------------------------- deciding
  /// Approve [r]. A mix that is now more than the stock on record is the
  /// manager's override: [allowNegative] with the reason it is recorded
  /// anyway ([overrideReason], kept on the stock exception — v0.8.4).
  Future<WriteResult> approve(ApprovalRequest r, {bool allowNegative = false, String? overrideReason}) =>
      _write(() => _api.post('/approval-requests/${r.id}/approve', body: {'allow_negative': allowNegative, 'override_reason': ?overrideReason}));

  Future<WriteResult> reject(ApprovalRequest r, String why) => _write(() => _api.post('/approval-requests/${r.id}/reject', body: {'note': why}));

  Future<WriteResult> approvePurchase(PurchaseRequest p, {String? note}) =>
      _write(() => _api.post('/procurement/requisitions/${p.id}/approve', body: {'comments': note}));

  Future<WriteResult> rejectPurchase(PurchaseRequest p, String why) =>
      _write(() => _api.post('/procurement/requisitions/${p.id}/reject', body: {'comments': why}));

  // ---------------------------------------------- the manager, directly
  Future<WriteResult> correctMilk(String recordId, Map<String, dynamic> changes, String reason) =>
      _write(() => _api.post('/production/milk/$recordId/correct', body: {...changes, 'reason': reason}));

  Future<WriteResult> correctFeeding(String eventId, List<Map<String, dynamic>> components, String reason) =>
      _write(() => _api.post('/feeding-events/$eventId/correct', body: {'components': components, 'reason': reason}));
}
