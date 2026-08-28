import 'dart:async';
import 'package:flutter/foundation.dart';
import '../data/demo/demo_data.dart';
import '../data/local/farm_write_service.dart';
import '../data/local/local_repository.dart';
import '../domain/entities/inventory.dart';
import '../sync/sync_queue_controller.dart';

class FeedProvider extends ChangeNotifier {
  FeedProvider({
    required FarmWriteService writeService,
    required SyncQueueController syncQueue,
    LocalRepository? localRepository,
  })  : _writeService = writeService,
        _syncQueue = syncQueue,
        _localRepository = localRepository ?? LocalRepository(),
        _items = List.of(DemoData.feedInventory) {
    unawaited(reload());
  }

  final FarmWriteService _writeService;
  final SyncQueueController _syncQueue;
  final LocalRepository _localRepository;
  List<InventoryItem> _items;

  List<InventoryItem> get items => List.unmodifiable(_items);

  /// Re-reads the local SQLite cache (demo-seeded, or server-synced) and
  /// replaces the in-memory list with it — see `AnimalsProvider.reload`.
  Future<void> reload() async {
    try {
      final loaded = await _localRepository.loadFeedItems();
      if (loaded.isNotEmpty) {
        _items = loaded;
        notifyListeners();
      }
    } catch (_) {
      // SQLite unavailable on this platform/target — keep the demo list.
    }
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
