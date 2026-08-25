import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import '../data/demo/mouneh_demo_data.dart';
import '../data/local/farm_write_service.dart' show WriteResult;
import '../domain/entities/mouneh.dart';
import '../mouneh/costing.dart' as costing;
import '../mouneh/mouneh_write_service.dart';
import '../sync/sync_queue_controller.dart';

const String kMounehModuleCode = 'mouneh';
const _uuid = Uuid();

/// Provider for the Mouneh & Farm Product Processing module — same shape
/// as [FeedProvider]/[AnimalsProvider]: in-memory state seeded from demo
/// data, mutated only after [MounehWriteService] confirms the offline
/// write succeeded.
class MounehProvider extends ChangeNotifier {
  MounehProvider({required MounehWriteService writeService, required SyncQueueController syncQueue})
      : _writeService = writeService,
        _syncQueue = syncQueue,
        _license = const ModuleLicense(moduleCode: kMounehModuleCode, status: 'active', activatedBy: 'user-super-1'),
        _products = List.of(MounehDemoData.products),
        _rawMaterials = List.of(MounehDemoData.rawMaterials),
        _recipes = {MounehDemoData.makdousRecipe.productId: MounehDemoData.makdousRecipe},
        _batches = List.of(MounehDemoData.batches),
        _finishedGoods = [MounehDemoData.finishedGoods],
        _sales = List.of(MounehDemoData.sales);

  final MounehWriteService _writeService;
  final SyncQueueController _syncQueue;

  ModuleLicense _license;
  List<MounehProduct> _products;
  List<RawMaterial> _rawMaterials;
  final Map<String, MounehRecipe> _recipes; // productId -> active recipe
  List<ProductionBatch> _batches;
  List<FinishedGoodsStock> _finishedGoods;
  List<MounehSale> _sales;

  ModuleLicense get license => _license;
  bool get isActive => _license.isActive;
  List<MounehProduct> get products => List.unmodifiable(_products);
  List<RawMaterial> get rawMaterials => List.unmodifiable(_rawMaterials);
  List<ProductionBatch> get batches => List.unmodifiable(_batches);
  List<FinishedGoodsStock> get finishedGoods => List.unmodifiable(_finishedGoods);
  List<MounehSale> get sales => List.unmodifiable(_sales);

  MounehRecipe? recipeFor(String productId) => _recipes[productId];
  RawMaterial? materialById(String id) => _rawMaterials.where((m) => m.id == id).firstOrNull;
  MounehProduct? productById(String id) => _products.where((p) => p.id == id).firstOrNull;
  List<ProductionBatch> batchesFor(String productId) => _batches.where((b) => b.productId == productId).toList();
  List<FinishedGoodsStock> stockFor(String productId) => _finishedGoods.where((s) => s.productId == productId).toList();

  // -------------------------------------------------------------- License
  Future<void> setModuleActive(bool active) async {
    final status = active ? 'active' : 'inactive';
    final result = await _writeService.setModuleStatus(moduleCode: kMounehModuleCode, status: status);
    if (result.success) {
      _license = _license.copyWith(status: status);
      notifyListeners();
    }
  }

  // ------------------------------------------------------------- Products
  Future<WriteResult> createProduct({
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
    if (_products.any((p) => p.category == category && p.name.toLowerCase() == name.toLowerCase())) {
      return WriteResult.fail('A product named "$name" already exists in "$category".');
    }
    final id = _uuid.v4();
    final result = await _writeService.createProduct(
      id: id,
      name: name,
      category: category,
      outputUnit: outputUnit,
      customOutputUnitLabel: customOutputUnitLabel,
      defaultBatchSize: defaultBatchSize,
      shelfLifeDays: shelfLifeDays,
      warehouseRules: warehouseRules,
      lowStockThreshold: lowStockThreshold,
      targetPrice: targetPrice,
      wholesalePrice: wholesalePrice,
      targetMarginPct: targetMarginPct,
    );
    if (result.success) {
      _products.add(MounehProduct(
        id: id,
        name: name,
        category: category,
        outputUnit: outputUnit,
        customOutputUnitLabel: customOutputUnitLabel,
        defaultBatchSize: defaultBatchSize,
        shelfLifeDays: shelfLifeDays,
        warehouseRules: warehouseRules,
        lowStockThreshold: lowStockThreshold,
        targetPrice: targetPrice,
        wholesalePrice: wholesalePrice,
        targetMarginPct: targetMarginPct,
      ));
      _syncQueue.enqueue(entityType: 'mouneh_product', entityId: id, operation: 'create');
      notifyListeners();
    }
    return result;
  }

  // --------------------------------------------------------- Raw materials
  Future<WriteResult> createRawMaterial({
    required String name,
    required String category,
    required String sourceType,
    required String unit,
    required double defaultUnitCost,
    double currentStock = 0,
    double lossPercentDefault = 0,
  }) async {
    final id = _uuid.v4();
    final result = await _writeService.createRawMaterial(
      id: id,
      name: name,
      category: category,
      sourceType: sourceType,
      unit: unit,
      defaultUnitCost: defaultUnitCost,
      currentStock: currentStock,
      lossPercentDefault: lossPercentDefault,
    );
    if (result.success) {
      _rawMaterials.add(RawMaterial(
        id: id,
        name: name,
        category: category,
        sourceType: sourceType,
        unit: unit,
        defaultUnitCost: defaultUnitCost,
        currentStock: currentStock,
        lossPercentDefault: lossPercentDefault,
      ));
      _syncQueue.enqueue(entityType: 'raw_material', entityId: id, operation: 'create');
      notifyListeners();
    }
    return result;
  }

  // ---------------------------------------------------------------- Recipe
  Future<WriteResult> createRecipe({
    required String productId,
    required double basisQuantity,
    required String basisUnit,
    required List<MounehRecipeItem> items,
    required List<MounehCostComponent> costComponents,
    String? notes,
  }) async {
    if (items.isEmpty) return const WriteResult.fail('Add at least one raw material or packaging line.');
    final prior = _recipes[productId];
    final nextVersion = (prior?.version ?? 0) + 1;
    final id = _uuid.v4();
    final result = await _writeService.createRecipe(
      id: id,
      productId: productId,
      version: nextVersion,
      basisQuantity: basisQuantity,
      basisUnit: basisUnit,
      notes: notes,
      items: [
        for (final i in items)
          {'material_id': i.materialId, 'material_type': i.materialType, 'quantity': i.quantity, 'unit': i.unit, 'loss_percent': i.lossPercent},
      ],
      costComponents: [
        for (final c in costComponents)
          {'cost_type': c.costType, 'label': c.label, 'calculation_method': c.calculationMethod, 'amount': c.amount, 'quantity': c.quantity, 'unit_cost': c.unitCost},
      ],
    );
    if (result.success) {
      _recipes[productId] = MounehRecipe(
        id: id,
        productId: productId,
        version: nextVersion,
        basisQuantity: basisQuantity,
        basisUnit: basisUnit,
        items: items,
        costComponents: costComponents,
        notes: notes,
      );
      final index = _products.indexWhere((p) => p.id == productId);
      if (index != -1 && _products[index].status == 'draft') {
        _products[index] = _products[index].copyWith(status: 'active');
      }
      _syncQueue.enqueue(entityType: 'mouneh_recipe', entityId: id, operation: 'create');
      notifyListeners();
    }
    return result;
  }

  // ---------------------------------------------------------- Cost preview
  List<costing.MaterialLine> _materialLinesFor(MounehRecipe recipe, double outputQty) {
    final scale = recipe.basisQuantity > 0 ? outputQty / recipe.basisQuantity : 1.0;
    return [
      for (final item in recipe.items)
        costing.MaterialLine(
          materialId: item.materialId,
          name: materialById(item.materialId)?.name ?? item.materialId,
          category: item.materialType,
          quantity: item.quantity * scale,
          unit: item.unit,
          unitCost: materialById(item.materialId)?.defaultUnitCost ?? 0,
          lossPercent: item.lossPercent,
        ),
    ];
  }

  List<costing.CostComponentLine> _componentLinesFor(MounehRecipe recipe, double outputQty) {
    final scale = recipe.basisQuantity > 0 ? outputQty / recipe.basisQuantity : 1.0;
    return [
      for (final c in recipe.costComponents)
        costing.CostComponentLine(
          costType: c.costType,
          label: c.label,
          calculationMethod: c.calculationMethod,
          amount: c.calculationMethod == 'fixed' && c.amount != null ? c.amount! * scale : c.amount,
          quantity: c.calculationMethod == 'quantity_x_rate' && c.quantity != null ? c.quantity! * scale : c.quantity,
          unitCost: c.unitCost,
        ),
    ];
  }

  /// REQ-MOU-004: planned cost per batch and per unit, before a batch even
  /// starts.
  costing.CostBreakdown? previewCost(String productId, double outputQty) {
    final recipe = _recipes[productId];
    if (recipe == null || outputQty <= 0) return null;
    return costing.computeCostBreakdown(materials: _materialLinesFor(recipe, outputQty), components: _componentLinesFor(recipe, outputQty), outputQty: outputQty);
  }

  costing.PriceSuggestion? suggestedPriceFor(String productId, double outputQty) {
    final breakdown = previewCost(productId, outputQty);
    final product = productById(productId);
    if (breakdown == null || product?.targetMarginPct == null) return null;
    return costing.suggestPrice(unitCost: breakdown.unitCost, targetMarginPct: product!.targetMarginPct!);
  }

  // ---------------------------------------------------------------- Batch
  String _generateBatchCode(MounehProduct product) {
    final prefix = '${(product.category.isEmpty ? 'GEN' : product.category).substring(0, product.category.length < 3 ? product.category.length : 3).toUpperCase()}-'
        '${DateTime.now().toIso8601String().substring(0, 10).replaceAll('-', '')}';
    final existing = _batches.where((b) => b.batchCode.startsWith(prefix)).length;
    return '$prefix-${(existing + 1).toString().padLeft(3, '0')}';
  }

  Future<WriteResult> createBatch({required String productId, required double plannedQty, String? warehouseLocation}) async {
    final product = productById(productId);
    final recipe = _recipes[productId];
    if (product == null || recipe == null) {
      return const WriteResult.fail('This product has no recipe yet — add raw materials before starting a batch.');
    }
    if (plannedQty <= 0) return const WriteResult.fail('valueMustBePositive');
    final breakdown = previewCost(productId, plannedQty)!;
    final materials = _materialLinesFor(recipe, plannedQty);
    final id = _uuid.v4();
    final batchCode = _generateBatchCode(product);

    final result = await _writeService.createBatch(
      id: id,
      productId: productId,
      recipeId: recipe.id,
      batchCode: batchCode,
      plannedQty: plannedQty,
      plannedUnitCost: breakdown.unitCost,
      plannedTotalCost: breakdown.totalCost,
      warehouseLocation: warehouseLocation,
      consumptions: [
        for (final m in materials) {'material_id': m.materialId, 'planned_qty': m.effectiveQuantity, 'unit_cost': m.unitCost},
      ],
    );
    if (result.success) {
      _batches.add(ProductionBatch(
        id: id,
        productId: productId,
        recipeId: recipe.id,
        batchCode: batchCode,
        plannedQty: plannedQty,
        plannedUnitCost: breakdown.unitCost,
        plannedTotalCost: breakdown.totalCost,
        warehouseLocation: warehouseLocation,
        startedAt: DateTime.now(),
        consumptions: [for (final m in materials) BatchInputConsumption(materialId: m.materialId, plannedQty: m.effectiveQuantity, unitCost: m.unitCost)],
      ));
      _syncQueue.enqueue(entityType: 'production_batch', entityId: id, operation: 'create');
      notifyListeners();
    }
    return result;
  }

  Future<WriteResult> consumeBatchInputs({required String batchId, required Map<String, double> actualQtyByMaterial, bool allowNegative = false}) async {
    final batchIndex = _batches.indexWhere((b) => b.id == batchId);
    if (batchIndex == -1) return const WriteResult.fail('Batch not found.');
    final batch = _batches[batchIndex];

    final unitCosts = {for (final c in batch.consumptions) c.materialId: c.unitCost};
    final result = await _writeService.consumeBatchInputs(batchId: batchId, actualQtyByMaterial: actualQtyByMaterial, unitCostByMaterial: unitCosts, allowNegative: allowNegative);
    if (result.success) {
      final updatedConsumptions = [
        for (final c in batch.consumptions)
          if (actualQtyByMaterial.containsKey(c.materialId))
            c.copyWith(actualQty: actualQtyByMaterial[c.materialId], totalCost: actualQtyByMaterial[c.materialId]! * c.unitCost)
          else
            c,
      ];
      _batches[batchIndex] = batch.copyWith(consumptions: updatedConsumptions);
      for (final entry in actualQtyByMaterial.entries) {
        final mIndex = _rawMaterials.indexWhere((m) => m.id == entry.key);
        if (mIndex != -1) {
          _rawMaterials[mIndex] = _rawMaterials[mIndex].copyWith(currentStock: _rawMaterials[mIndex].currentStock - entry.value);
        }
      }
      _syncQueue.enqueue(entityType: 'production_batch', entityId: batchId, operation: 'update');
      notifyListeners();
    }
    return result;
  }

  /// REQ-MOU-005: batch completion consumes stock and creates finished goods.
  Future<WriteResult> completeBatch({
    required String batchId,
    required double actualOutputQty,
    double wasteQty = 0,
    double damagedQty = 0,
    String qualityStatus = 'good',
    DateTime? expiryDate,
    String? warehouseLocation,
    double? laborHours,
    List<MounehCostComponent> extraCostComponents = const [],
  }) async {
    final batchIndex = _batches.indexWhere((b) => b.id == batchId);
    if (batchIndex == -1) return const WriteResult.fail('Batch not found.');
    final batch = _batches[batchIndex];
    if (!batch.isInProgress) return WriteResult.fail('Batch is already "${batch.status}".');
    if (actualOutputQty <= 0) return const WriteResult.fail('valueMustBePositive');

    // Fill in any material never explicitly consumed, at its planned qty.
    final filledConsumptions = [
      for (final c in batch.consumptions)
        if (c.actualQty == null) c.copyWith(actualQty: c.plannedQty, totalCost: c.plannedQty * c.unitCost) else c,
    ];
    for (final c in batch.consumptions.where((c) => c.actualQty == null)) {
      final mIndex = _rawMaterials.indexWhere((m) => m.id == c.materialId);
      if (mIndex != -1) {
        _rawMaterials[mIndex] = _rawMaterials[mIndex].copyWith(currentStock: _rawMaterials[mIndex].currentStock - c.plannedQty);
      }
    }

    final materials = [
      for (final c in filledConsumptions)
        costing.MaterialLine(materialId: c.materialId, name: materialById(c.materialId)?.name ?? c.materialId, category: 'raw_material', quantity: c.actualQty!, unit: '', unitCost: c.unitCost),
    ];
    final recipe = _recipes[batch.productId]!;
    final components = [
      ..._componentLinesFor(recipe, batch.plannedQty).map((c) => costing.CostComponentLine(costType: c.costType, label: c.label, calculationMethod: c.calculationMethod, amount: c.amount, quantity: c.quantity, unitCost: c.unitCost)),
      for (final c in extraCostComponents)
        costing.CostComponentLine(costType: c.costType, label: c.label, calculationMethod: c.calculationMethod, amount: c.amount, quantity: c.quantity, unitCost: c.unitCost),
    ];
    final breakdown = costing.computeCostBreakdown(materials: materials, components: components, outputQty: actualOutputQty);

    final stockId = _uuid.v4();
    final result = await _writeService.completeBatch(
      batchId: batchId,
      productId: batch.productId,
      actualOutputQty: actualOutputQty,
      wasteQty: wasteQty,
      damagedQty: damagedQty,
      qualityStatus: qualityStatus,
      expiryDate: expiryDate,
      warehouseLocation: warehouseLocation ?? batch.warehouseLocation,
      laborHours: laborHours,
      actualUnitCost: breakdown.unitCost,
      actualTotalCost: breakdown.totalCost,
      finishedGoodsStockId: stockId,
    );
    if (result.success) {
      _batches[batchIndex] = batch.copyWith(
        actualOutputQty: actualOutputQty,
        wasteQty: wasteQty,
        damagedQty: damagedQty,
        qualityStatus: qualityStatus,
        expiryDate: expiryDate,
        warehouseLocation: warehouseLocation,
        status: 'completed',
        actualUnitCost: breakdown.unitCost,
        actualTotalCost: breakdown.totalCost,
        laborHours: laborHours,
        completedAt: DateTime.now(),
        consumptions: filledConsumptions,
      );
      _finishedGoods.add(FinishedGoodsStock(
        id: stockId,
        productId: batch.productId,
        batchId: batchId,
        warehouseLocation: warehouseLocation ?? batch.warehouseLocation,
        quantityProduced: actualOutputQty,
        quantityAvailable: actualOutputQty,
        unitCost: breakdown.unitCost,
        expiryDate: expiryDate,
      ));
      _syncQueue.enqueue(entityType: 'production_batch', entityId: batchId, operation: 'update');
      notifyListeners();
    }
    return result;
  }

  // ---------------------------------------------------------------- Sales
  Future<WriteResult> recordSale({
    required String productId,
    String? finishedGoodsStockId,
    required double quantity,
    required double unitPrice,
    double discount = 0,
    String channel = 'retail',
  }) async {
    if (quantity <= 0) return const WriteResult.fail('valueMustBePositive');
    if (discount < 0) return const WriteResult.fail('valueMustBePositive');
    FinishedGoodsStock? stock;
    if (finishedGoodsStockId != null) {
      stock = _finishedGoods.where((s) => s.id == finishedGoodsStockId).firstOrNull;
    } else {
      final candidates = _finishedGoods.where((s) => s.productId == productId && s.quantityAvailable > 0).toList()
        ..sort((a, b) => (a.expiryDate ?? DateTime(9999)).compareTo(b.expiryDate ?? DateTime(9999)));
      stock = candidates.firstOrNull;
    }
    if (stock == null) return const WriteResult.fail('No available stock for this product.');
    if (quantity > stock.quantityAvailable) {
      return WriteResult.fail('Only ${stock.quantityAvailable} units available, cannot sell $quantity.');
    }

    final margin = costing.computeSaleMargin(quantity: quantity, unitPrice: unitPrice, discount: discount, unitCost: stock.unitCost);
    final id = _uuid.v4();
    final result = await _writeService.recordSale(
      id: id,
      productId: productId,
      batchId: stock.batchId,
      finishedGoodsStockId: stock.id,
      quantity: quantity,
      unitPrice: unitPrice,
      discount: discount,
      channel: channel,
      costPerUnit: stock.unitCost,
      revenue: margin.revenue,
      margin: margin.profit,
    );
    if (result.success) {
      final stockIndex = _finishedGoods.indexWhere((s) => s.id == stock!.id);
      _finishedGoods[stockIndex] = stock.copyWith(quantityAvailable: stock.quantityAvailable - quantity, quantitySold: stock.quantitySold + quantity);
      _sales.add(MounehSale(
        id: id,
        productId: productId,
        batchId: stock.batchId,
        finishedGoodsStockId: stock.id,
        quantity: quantity,
        unitPrice: unitPrice,
        discount: discount,
        channel: channel,
        costPerUnit: stock.unitCost,
        revenue: margin.revenue,
        margin: margin.profit,
        soldAt: DateTime.now(),
      ));
      _syncQueue.enqueue(entityType: 'mouneh_sale_line', entityId: id, operation: 'create');
      notifyListeners();
    }
    return result;
  }

  // --------------------------------------------------------- Dashboards
  MounehProductProfitability profitabilityFor(String productId, {int windowDays = 30}) {
    final product = productById(productId);
    final stocks = stockFor(productId);
    final productSales = _sales.where((s) => s.productId == productId).toList();

    final unitsProduced = stocks.fold<double>(0, (sum, s) => sum + s.quantityProduced);
    final unitsSold = stocks.fold<double>(0, (sum, s) => sum + s.quantitySold);
    final unitsRemaining = stocks.fold<double>(0, (sum, s) => sum + s.quantityAvailable);
    final avgUnitCost = unitsProduced > 0 ? stocks.fold<double>(0, (sum, s) => sum + s.quantityProduced * s.unitCost) / unitsProduced : 0.0;

    final totalRevenue = productSales.fold<double>(0, (sum, s) => sum + s.revenue);
    final totalCost = productSales.fold<double>(0, (sum, s) => sum + s.costPerUnit * s.quantity);
    final totalProfit = productSales.fold<double>(0, (sum, s) => sum + s.margin);
    final avgSalePrice = unitsSold > 0 ? productSales.fold<double>(0, (sum, s) => sum + s.unitPrice * s.quantity) / unitsSold : 0.0;
    final grossMarginPct = totalRevenue > 0 ? totalProfit / totalRevenue * 100 : 0.0;

    final cutoff = DateTime.now().subtract(Duration(days: windowDays));
    final recentQty = productSales.where((s) => s.soldAt.isAfter(cutoff)).fold<double>(0, (sum, s) => sum + s.quantity);
    final velocity = recentQty / windowDays;

    String recommendation;
    if (totalRevenue > 0 && grossMarginPct < 10) {
      recommendation = 'review_pricing';
    } else if (velocity > 0 && unitsRemaining / velocity > (product?.shelfLifeDays ?? windowDays)) {
      recommendation = 'slow_mover';
    } else if (velocity > 0) {
      recommendation = 'continue_production';
    } else {
      recommendation = unitsProduced > 0 ? 'slow_mover' : 'continue_production';
    }

    return MounehProductProfitability(
      productId: productId,
      productName: product?.name ?? productId,
      unitsProduced: unitsProduced,
      unitsSold: unitsSold,
      unitsRemaining: unitsRemaining,
      avgUnitCost: avgUnitCost,
      avgSalePrice: avgSalePrice,
      totalRevenue: totalRevenue,
      totalCost: totalCost,
      totalProfit: totalProfit,
      grossMarginPct: grossMarginPct,
      salesVelocityPerDay: velocity,
      recommendation: recommendation,
    );
  }

  List<MounehProductProfitability> get allProfitability => [for (final p in _products) profitabilityFor(p.id)];

  int get activeBatchCount => _batches.where((b) => b.isInProgress).length;
  double get totalFinishedUnits => _finishedGoods.fold<double>(0, (sum, s) => sum + s.quantityAvailable);
  double get totalStockValue => _finishedGoods.fold<double>(0, (sum, s) => sum + s.quantityAvailable * s.unitCost);
  double get totalRevenue => _sales.fold<double>(0, (sum, s) => sum + s.revenue);
  double get totalProfit => _sales.fold<double>(0, (sum, s) => sum + s.margin);
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
