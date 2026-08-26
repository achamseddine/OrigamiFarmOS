import 'package:flutter/foundation.dart';
import '../data/local/farm_read_service.dart';
import '../data/local/farm_write_service.dart';
import '../domain/entities/inventory.dart';
import '../sync/sync_queue_controller.dart';

class FeedProvider extends ChangeNotifier {
  FeedProvider({required FarmWriteService writeService, required FarmReadService readService, required SyncQueueController syncQueue})
      : _writeService = writeService,
        _readService = readService,
        _syncQueue = syncQueue,
        _items = [];

  final FarmWriteService _writeService;
  final FarmReadService _readService;
  final SyncQueueController _syncQueue;
  List<InventoryItem> _items;

  List<InventoryItem> get items => List.unmodifiable(_items);

  Future<void> load() async {
    _items = await _readService.inventoryItems();
    notifyListeners();
  }

  Future<WriteResult> recordDistribution({
    required String itemId,
    required double quantityKg,
    required String reason,
    String? linkedEntityType,
    String? linkedEntityId,
  }) async {
    final result = await _writeService.recordFeedTransaction(
      itemId: itemId,
      direction: 'out',
      quantity: quantityKg,
      reason: reason,
      linkedEntityType: linkedEntityType,
      linkedEntityId: linkedEntityId,
    );
    if (result.success) {
      _applyDelta(itemId, -quantityKg);
      _syncQueue.enqueue(entityType: 'inventory_item', entityId: itemId, operation: 'update');
    }
    return result;
  }

  Future<WriteResult> recordPurchase({required String itemId, required double quantityKg, String? supplier}) async {
    final result = await _writeService.recordFeedTransaction(
      itemId: itemId,
      direction: 'in',
      quantity: quantityKg,
      reason: 'purchase',
    );
    if (result.success) {
      _applyDelta(itemId, quantityKg);
      _syncQueue.enqueue(entityType: 'inventory_item', entityId: itemId, operation: 'update');
    }
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
