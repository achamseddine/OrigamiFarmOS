import 'package:flutter/foundation.dart';
import '../api/api_client.dart';
import '../domain/entities/inventory.dart';

class FeedProvider extends ChangeNotifier {
  FeedProvider({required ApiClient apiClient, required String farmId})
      : _api = apiClient,
        _farmId = farmId;

  final ApiClient _api;
  final String _farmId;
  List<InventoryItem> _items = [];
  List<InventoryTransaction> _transactions = [];
  bool loading = false;

  List<InventoryItem> get items => List.unmodifiable(_items);

  /// Newest first, as the server returns them. Empty until
  /// [loadTransactions] has run, and empty again if it could not.
  List<InventoryTransaction> get transactions => List.unmodifiable(_transactions);

  InventoryItem? itemById(String id) {
    for (final item in _items) {
      if (item.id == id) return item;
    }
    return null;
  }

  Future<void> load() async {
    loading = true;
    notifyListeners();
    try {
      final json = await _api.get('/feed/items', query: {'farm_id': _farmId}) as List<dynamic>;
      _items = json.map((e) => InventoryItem.fromJson(e as Map<String, dynamic>)).toList();
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  /// The movement history behind the feed screen's "recent movements"
  /// panel. It is its own call, made when that screen opens, because the
  /// items list is loaded for everyone at sign-in and the history is only
  /// wanted there. A failure leaves the panel empty rather than taking the
  /// screen down with it — the stock figures do not depend on it.
  Future<void> loadTransactions({int days = 30}) async {
    try {
      final json = await _api.get('/feed/transactions', query: {'farm_id': _farmId, 'days': days}) as List<dynamic>;
      _transactions = json.map((e) => InventoryTransaction.fromJson(e as Map<String, dynamic>)).toList();
    } catch (_) {
      _transactions = [];
    }
    notifyListeners();
  }

  Future<WriteResult> recordDistribution({
    required String itemId,
    required double quantityKg,
    required String reason,
    String? linkedEntityType,
    String? linkedEntityId,
  }) async {
    final result = await _api.write(() => _api.post('/feed/transactions', body: {
          'item_id': itemId,
          'direction': 'out',
          'quantity': quantityKg,
          'reason': reason,
          'linked_entity_type': linkedEntityType,
          'linked_entity_id': linkedEntityId,
        }));
    if (result.success) _applyDelta(itemId, -quantityKg, reason: reason);
    return result;
  }

  Future<WriteResult> recordPurchase({required String itemId, required double quantityKg, String? supplier}) async {
    final result = await _api.write(() => _api.post('/feed/transactions', body: {
          'item_id': itemId,
          'direction': 'in',
          'quantity': quantityKg,
          'reason': 'purchase',
        }));
    if (result.success) _applyDelta(itemId, quantityKg, reason: 'purchase');
    return result;
  }

  void _applyDelta(String itemId, double delta, {required String reason}) {
    final index = _items.indexWhere((i) => i.id == itemId);
    if (index == -1) return;
    final current = _items[index];
    _items[index] = InventoryItem(
      id: current.id,
      name: current.name,
      category: current.category,
      unit: current.unit,
      currentQty: current.currentQty + delta,
      reorderLevel: current.reorderLevel,
      supplier: current.supplier,
      lastPurchase: delta > 0 ? DateTime.now() : current.lastPurchase,
      unitCost: current.unitCost,
    );
    // Show the movement straight away, whether the server took it or the
    // outbox is holding it: the person just recorded it and expects to see
    // it. The next [loadTransactions] replaces this with the server's row.
    _transactions = [
      InventoryTransaction(
        id: 'local-${DateTime.now().microsecondsSinceEpoch}',
        itemId: itemId,
        direction: delta > 0 ? 'in' : 'out',
        quantity: delta.abs(),
        reason: reason,
        createdAt: DateTime.now(),
      ),
      ..._transactions,
    ];
    notifyListeners();
  }
}
