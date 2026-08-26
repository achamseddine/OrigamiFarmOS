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
  bool loading = false;

  List<InventoryItem> get items => List.unmodifiable(_items);

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
    if (result.success) _applyDelta(itemId, -quantityKg);
    return result;
  }

  Future<WriteResult> recordPurchase({required String itemId, required double quantityKg, String? supplier}) async {
    final result = await _api.write(() => _api.post('/feed/transactions', body: {
          'item_id': itemId,
          'direction': 'in',
          'quantity': quantityKg,
          'reason': 'purchase',
        }));
    if (result.success) _applyDelta(itemId, quantityKg);
    return result;
  }

  void _applyDelta(String itemId, double delta) {
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
      lastPurchase: current.lastPurchase,
      unitCost: current.unitCost,
    );
    notifyListeners();
  }
}
