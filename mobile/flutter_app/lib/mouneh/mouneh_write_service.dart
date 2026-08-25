import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
import '../data/local/database.dart';
import '../data/local/farm_write_service.dart' show WriteResult;

/// Offline-first write pipeline for the Mouneh & Farm Product Processing
/// module — same shape as [FarmWriteService]: local validation -> save
/// domain row(s) -> write an immutable event -> queue for sync, all in one
/// SQLite transaction. Kept as its own service (a separate bounded
/// context, per tech spec v0.5 §10) rather than folded into
/// [FarmWriteService].
///
/// A completed batch or a recorded sale is never rewritten by a later
/// call here — corrections are new rows/events, matching "never overwrite
/// historical batch records" (tech spec v0.5 §8).
class MounehWriteService {
  MounehWriteService({FarmDatabase? db, String farmId = 'farm-origami', String userId = 'user-rami'})
      : _db = db ?? FarmDatabase.instance,
        _farmId = farmId,
        _userId = userId;

  final FarmDatabase _db;
  final String _farmId;
  final String _userId;
  static const _uuid = Uuid();

  Future<Database> get _database => _db.database;

  Future<void> _writeEventAndQueue(
    DatabaseExecutor txn, {
    required String entityType,
    required String entityId,
    required String eventType,
    required Map<String, Object?> payload,
  }) async {
    final eventId = _uuid.v4();
    await txn.insert('events', {
      'id': eventId,
      'farm_id': _farmId,
      'entity_type': entityType,
      'entity_id': entityId,
      'event_type': eventType,
      'payload_json': jsonEncode(payload),
      'created_by': _userId,
      'created_at': DateTime.now().toIso8601String(),
    });
    await txn.insert('sync_queue', {
      'id': _uuid.v4(),
      'local_event_id': eventId,
      'operation': 'create',
      'entity_type': entityType,
      'entity_id': entityId,
      'payload_json': jsonEncode(payload),
      'status': 'pending',
      'retry_count': 0,
      'created_at': DateTime.now().toIso8601String(),
    });
  }

  /// REQ-MOU-001: super user activate/deactivate, per farm.
  Future<WriteResult> setModuleStatus({required String moduleCode, required String status, String? activatedBy}) async {
    final db = await _database;
    await db.transaction((txn) async {
      await txn.insert(
        'module_licenses',
        {'module_code': moduleCode, 'status': status, 'plan': 'mouneh_addon', 'activated_by': activatedBy ?? _userId},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await _writeEventAndQueue(txn, entityType: 'module_license', entityId: moduleCode, eventType: 'module_$status', payload: {'status': status});
    });
    return const WriteResult.ok();
  }

  /// REQ-MOU-002/003: create a brand-new product type. No enum of product
  /// names exists anywhere — `name`/`category` are whatever the manager types.
  Future<WriteResult> createProduct({
    required String id,
    required String name,
    required String category,
    required String outputUnit,
    String? customOutputUnitLabel,
    double defaultBatchSize = 1,
    int? shelfLifeDays,
    String? warehouseRules,
    double? lowStockThreshold,
    double? targetPrice,
    double? wholesalePrice,
    double? targetMarginPct,
  }) async {
    if (name.trim().isEmpty) return const WriteResult.fail('entityRequired');
    final db = await _database;
    await db.transaction((txn) async {
      await txn.insert('mouneh_products', {
        'id': id,
        'farm_id': _farmId,
        'name': name,
        'category': category,
        'output_unit': outputUnit,
        'custom_output_unit_label': customOutputUnitLabel,
        'default_batch_size': defaultBatchSize,
        'shelf_life_days': shelfLifeDays,
        'warehouse_rules': warehouseRules,
        'low_stock_threshold': lowStockThreshold,
        'target_price': targetPrice,
        'wholesale_price': wholesalePrice,
        'target_margin_pct': targetMarginPct,
        'status': 'draft',
        'created_at': DateTime.now().toIso8601String(),
      });
      await _writeEventAndQueue(txn, entityType: 'mouneh_product', entityId: id, eventType: 'product_created', payload: {'name': name, 'category': category});
    });
    return const WriteResult.ok();
  }

  Future<WriteResult> createRawMaterial({
    required String id,
    required String name,
    required String category,
    required String sourceType,
    required String unit,
    required double defaultUnitCost,
    double currentStock = 0,
    double lossPercentDefault = 0,
  }) async {
    if (name.trim().isEmpty) return const WriteResult.fail('entityRequired');
    final db = await _database;
    await db.transaction((txn) async {
      await txn.insert('raw_materials', {
        'id': id,
        'farm_id': _farmId,
        'name': name,
        'category': category,
        'source_type': sourceType,
        'unit': unit,
        'default_unit_cost': defaultUnitCost,
        'current_stock': currentStock,
        'loss_percent_default': lossPercentDefault,
      });
      await _writeEventAndQueue(txn, entityType: 'raw_material', entityId: id, eventType: 'raw_material_created', payload: {'name': name, 'category': category});
    });
    return const WriteResult.ok();
  }

  /// A new recipe always gets its own row (a new version) — see class doc.
  Future<WriteResult> createRecipe({
    required String id,
    required String productId,
    required int version,
    required double basisQuantity,
    required String basisUnit,
    required List<Map<String, Object?>> items,
    required List<Map<String, Object?>> costComponents,
    String? notes,
  }) async {
    if (items.isEmpty) return const WriteResult.fail('A recipe needs at least one raw material or packaging line.');
    final db = await _database;
    await db.transaction((txn) async {
      await txn.update('mouneh_recipes', {'active': 0}, where: 'product_id = ? AND active = 1', whereArgs: [productId]);
      await txn.insert('mouneh_recipes', {
        'id': id,
        'product_id': productId,
        'version': version,
        'basis_quantity': basisQuantity,
        'basis_unit': basisUnit,
        'active': 1,
        'notes': notes,
        'created_at': DateTime.now().toIso8601String(),
      });
      for (final item in items) {
        await txn.insert('mouneh_recipe_items', {'id': _uuid.v4(), 'recipe_id': id, ...item});
      }
      await txn.delete('cost_components', where: 'product_id = ? AND batch_id IS NULL', whereArgs: [productId]);
      for (final component in costComponents) {
        await txn.insert('cost_components', {'id': _uuid.v4(), 'product_id': productId, 'batch_id': null, ...component});
      }
      await txn.update('mouneh_products', {'status': 'active'}, where: "id = ? AND status = 'draft'", whereArgs: [productId]);
      await _writeEventAndQueue(txn, entityType: 'mouneh_recipe', entityId: id, eventType: 'recipe_created', payload: {'product_id': productId, 'version': version});
    });
    return const WriteResult.ok();
  }

  Future<WriteResult> createBatch({
    required String id,
    required String productId,
    required String recipeId,
    required String batchCode,
    required double plannedQty,
    required double plannedUnitCost,
    required double plannedTotalCost,
    String? warehouseLocation,
    required List<Map<String, Object?>> consumptions,
  }) async {
    final db = await _database;
    await db.transaction((txn) async {
      await txn.insert('production_batches', {
        'id': id,
        'farm_id': _farmId,
        'product_id': productId,
        'recipe_id': recipeId,
        'batch_code': batchCode,
        'planned_qty': plannedQty,
        'status': 'in_progress',
        'planned_unit_cost': plannedUnitCost,
        'planned_total_cost': plannedTotalCost,
        'warehouse_location': warehouseLocation,
        'started_at': DateTime.now().toIso8601String(),
      });
      for (final c in consumptions) {
        await txn.insert('batch_input_consumptions', {'id': _uuid.v4(), 'batch_id': id, ...c});
      }
      await _writeEventAndQueue(txn, entityType: 'production_batch', entityId: id, eventType: 'batch_started', payload: {'product_id': productId, 'planned_qty': plannedQty, 'batch_code': batchCode});
    });
    return const WriteResult.ok();
  }

  /// Deducts actual raw-material usage from stock. Validation rule
  /// (mirrors tech spec §14 for feed): stock cannot go negative without
  /// an explicit override.
  Future<WriteResult> consumeBatchInputs({
    required String batchId,
    required Map<String, double> actualQtyByMaterial,
    required Map<String, double> unitCostByMaterial,
    bool allowNegative = false,
  }) async {
    final db = await _database;
    return db.transaction((txn) async {
      for (final entry in actualQtyByMaterial.entries) {
        final rows = await txn.query('raw_materials', where: 'id = ?', whereArgs: [entry.key]);
        if (rows.isEmpty) continue;
        final current = (rows.first['current_stock'] as num).toDouble();
        final newStock = current - entry.value;
        if (newStock < 0 && !allowNegative) {
          return WriteResult.fail('Not enough ${rows.first['name']} in stock.');
        }
        await txn.update('raw_materials', {'current_stock': newStock}, where: 'id = ?', whereArgs: [entry.key]);
        await txn.update(
          'batch_input_consumptions',
          {'actual_qty': entry.value, 'total_cost': entry.value * (unitCostByMaterial[entry.key] ?? 0)},
          where: 'batch_id = ? AND material_id = ?',
          whereArgs: [batchId, entry.key],
        );
      }
      await _writeEventAndQueue(txn, entityType: 'production_batch', entityId: batchId, eventType: 'batch_inputs_consumed', payload: {'lines': actualQtyByMaterial});
      return const WriteResult.ok();
    });
  }

  /// REQ-MOU-005: completing a batch consumes any remaining planned stock
  /// and creates finished goods stock.
  Future<WriteResult> completeBatch({
    required String batchId,
    required String productId,
    required double actualOutputQty,
    required double wasteQty,
    required double damagedQty,
    required String qualityStatus,
    DateTime? expiryDate,
    String? warehouseLocation,
    double? laborHours,
    required double actualUnitCost,
    required double actualTotalCost,
    required String finishedGoodsStockId,
  }) async {
    final db = await _database;
    await db.transaction((txn) async {
      final pending = await txn.query('batch_input_consumptions', where: 'batch_id = ? AND actual_qty IS NULL', whereArgs: [batchId]);
      for (final row in pending) {
        final plannedQty = (row['planned_qty'] as num).toDouble();
        final unitCost = (row['unit_cost'] as num).toDouble();
        final materialId = row['material_id'] as String;
        await txn.update('batch_input_consumptions', {'actual_qty': plannedQty, 'total_cost': plannedQty * unitCost},
            where: 'id = ?', whereArgs: [row['id']]);
        final materialRows = await txn.query('raw_materials', where: 'id = ?', whereArgs: [materialId]);
        if (materialRows.isNotEmpty) {
          final current = (materialRows.first['current_stock'] as num).toDouble();
          await txn.update('raw_materials', {'current_stock': current - plannedQty}, where: 'id = ?', whereArgs: [materialId]);
        }
      }

      await txn.update(
        'production_batches',
        {
          'actual_output_qty': actualOutputQty,
          'waste_qty': wasteQty,
          'damaged_qty': damagedQty,
          'quality_status': qualityStatus,
          'expiry_date': expiryDate?.toIso8601String(),
          'warehouse_location': warehouseLocation,
          'labor_hours': laborHours,
          'status': 'completed',
          'actual_unit_cost': actualUnitCost,
          'actual_total_cost': actualTotalCost,
          'completed_at': DateTime.now().toIso8601String(),
        },
        where: 'id = ?',
        whereArgs: [batchId],
      );

      await txn.insert('finished_goods_stock', {
        'id': finishedGoodsStockId,
        'farm_id': _farmId,
        'product_id': productId,
        'batch_id': batchId,
        'warehouse_location': warehouseLocation,
        'quantity_produced': actualOutputQty,
        'quantity_available': actualOutputQty,
        'unit_cost': actualUnitCost,
        'expiry_date': expiryDate?.toIso8601String(),
      });

      await _writeEventAndQueue(txn, entityType: 'production_batch', entityId: batchId, eventType: 'batch_completed', payload: {'actual_output_qty': actualOutputQty, 'actual_unit_cost': actualUnitCost});
    });
    return const WriteResult.ok();
  }

  /// REQ-MOU-006: sales reduce finished goods stock and calculate profit.
  Future<WriteResult> recordSale({
    required String id,
    required String productId,
    required String batchId,
    required String finishedGoodsStockId,
    required double quantity,
    required double unitPrice,
    required double discount,
    required String channel,
    required double costPerUnit,
    required double revenue,
    required double margin,
  }) async {
    final db = await _database;
    return db.transaction((txn) async {
      final rows = await txn.query('finished_goods_stock', where: 'id = ?', whereArgs: [finishedGoodsStockId]);
      if (rows.isEmpty) return const WriteResult.fail('Stock record not found.');
      final available = (rows.first['quantity_available'] as num).toDouble();
      if (quantity > available) {
        return WriteResult.fail('Only $available units available.');
      }
      await txn.insert('mouneh_sale_lines', {
        'id': id,
        'farm_id': _farmId,
        'product_id': productId,
        'batch_id': batchId,
        'finished_goods_stock_id': finishedGoodsStockId,
        'quantity': quantity,
        'unit_price': unitPrice,
        'discount': discount,
        'channel': channel,
        'cost_per_unit': costPerUnit,
        'revenue': revenue,
        'margin': margin,
        'sold_at': DateTime.now().toIso8601String(),
      });
      await txn.update(
        'finished_goods_stock',
        {
          'quantity_available': available - quantity,
          'quantity_sold': ((rows.first['quantity_sold'] as num?) ?? 0).toDouble() + quantity,
        },
        where: 'id = ?',
        whereArgs: [finishedGoodsStockId],
      );
      await _writeEventAndQueue(txn, entityType: 'mouneh_sale_line', entityId: id, eventType: 'sale_recorded', payload: {'product_id': productId, 'quantity': quantity, 'revenue': revenue});
      return const WriteResult.ok();
    });
  }
}
