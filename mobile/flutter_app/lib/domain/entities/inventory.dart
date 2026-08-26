enum StockStatus { good, low, critical }

class InventoryItem {
  const InventoryItem({
    required this.id,
    required this.name,
    required this.category,
    required this.unit,
    required this.currentQty,
    required this.reorderLevel,
    required this.supplier,
    required this.lastPurchase,
    this.unitCost,
  });

  final String id;
  final String name;
  final String category;
  final String unit;
  final double currentQty;
  final double reorderLevel;
  final String supplier;
  final DateTime lastPurchase;
  final double? unitCost;

  StockStatus get status {
    if (currentQty <= reorderLevel * 0.7) return StockStatus.critical;
    if (currentQty <= reorderLevel) return StockStatus.low;
    return StockStatus.good;
  }

  double get shortfall {
    final diff = reorderLevel - currentQty;
    return diff > 0 ? diff : 0;
  }

  /// Backend `InventoryItemOut` shape (schemas/feed.py).
  factory InventoryItem.fromJson(Map<String, dynamic> json) => InventoryItem(
        id: json['id'] as String,
        name: json['name'] as String,
        category: json['category'] as String? ?? 'other',
        unit: json['unit'] as String,
        currentQty: (json['current_qty'] as num).toDouble(),
        reorderLevel: (json['reorder_level'] as num?)?.toDouble() ?? 0,
        supplier: json['supplier_label'] as String? ?? '',
        lastPurchase: json['last_purchase'] != null ? DateTime.parse(json['last_purchase'] as String) : DateTime.now(),
        unitCost: (json['unit_cost'] as num?)?.toDouble(),
      );
}

/// Local mirror of the backend `inventory_transactions` table
/// (tech spec §9). Every feed distribution / purchase writes one of these.
class InventoryTransaction {
  const InventoryTransaction({
    required this.id,
    required this.itemId,
    required this.direction, // 'in' | 'out'
    required this.quantity,
    required this.reason,
    required this.createdAt,
    this.linkedEntityType,
    this.linkedEntityId,
  });

  final String id;
  final String itemId;
  final String direction;
  final double quantity;
  final String reason;
  final DateTime createdAt;
  final String? linkedEntityType;
  final String? linkedEntityId;

  Map<String, Object?> toMap() => {
        'id': id,
        'item_id': itemId,
        'direction': direction,
        'quantity': quantity,
        'reason': reason,
        'created_at': createdAt.toIso8601String(),
        'linked_entity_type': linkedEntityType,
        'linked_entity_id': linkedEntityId,
      };
}

class FeedingPlanLine {
  const FeedingPlanLine({
    required this.groupLabel,
    required this.subLabel,
    required this.quantityKg,
    required this.perHeadKg,
  });

  final String groupLabel;
  final String subLabel;
  final double quantityKg;
  final double perHeadKg;
}
