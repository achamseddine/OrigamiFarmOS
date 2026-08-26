import 'package:flutter/foundation.dart';
import '../api/api_client.dart';
import '../domain/entities/mouneh.dart';
import '../mouneh/costing.dart' as costing;

const String kMounehModuleCode = 'mouneh';

/// Provider for the Mouneh & Farm Product Processing module — always
/// online: [load] fetches the farm's real products/materials/batches/
/// finished-goods/sales from the backend, and every write posts straight
/// through, then re-reads (or locally applies) the result.
class MounehProvider extends ChangeNotifier {
  MounehProvider({required ApiClient apiClient}) : _api = apiClient;

  final ApiClient _api;

  ModuleLicense _license = const ModuleLicense(moduleCode: kMounehModuleCode, status: 'inactive');
  List<MounehProduct> _products = [];
  List<RawMaterial> _rawMaterials = [];
  final Map<String, MounehRecipe> _recipes = {}; // productId -> active recipe
  List<ProductionBatch> _batches = [];
  List<FinishedGoodsStock> _finishedGoods = [];
  List<MounehSale> _sales = [];
  bool loading = false;

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

  // -------------------------------------------------------------- Loading
  Future<void> load() async {
    loading = true;
    notifyListeners();
    try {
      final licenses = await _api.get('/modules') as List<dynamic>;
      final mine = licenses.cast<Map<String, dynamic>>().where((m) => m['module_code'] == kMounehModuleCode).firstOrNull;
      _license = mine != null ? ModuleLicense.fromJson(mine) : const ModuleLicense(moduleCode: kMounehModuleCode, status: 'inactive');
      if (!_license.isActive) {
        loading = false;
        notifyListeners();
        return;
      }

      final results = await Future.wait([
        _api.get('/mouneh/products'),
        _api.get('/mouneh/raw-materials'),
        _api.get('/mouneh/batches'),
        _api.get('/mouneh/finished-goods'),
        _api.get('/mouneh/sales'),
      ]);
      _products = (results[0] as List<dynamic>).map((e) => MounehProduct.fromJson(e as Map<String, dynamic>)).toList();
      _rawMaterials = (results[1] as List<dynamic>).map((e) => RawMaterial.fromJson(e as Map<String, dynamic>)).toList();
      _batches = (results[2] as List<dynamic>).map((e) => ProductionBatch.fromJson(e as Map<String, dynamic>)).toList();
      _finishedGoods = (results[3] as List<dynamic>).map((e) => FinishedGoodsStock.fromJson(e as Map<String, dynamic>)).toList();
      _sales = (results[4] as List<dynamic>).map((e) => MounehSale.fromJson(e as Map<String, dynamic>)).toList();

      _recipes.clear();
      for (final product in _products) {
        final json = await _api.get('/mouneh/products/${product.id}') as Map<String, dynamic>;
        final recipeJson = json['active_recipe'];
        if (recipeJson != null) _recipes[product.id] = MounehRecipe.fromJson(recipeJson as Map<String, dynamic>);
      }
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  // -------------------------------------------------------------- License
  /// Module activation itself is super-user only on the backend
  /// (RULE-MOU-001) — this call only succeeds for that role; a
  /// manager/employee's attempt surfaces the 403 as [WriteResult.error].
  Future<WriteResult> setModuleActive(bool active) async {
    final action = active ? 'activate' : 'deactivate';
    final result = await _api.write(() => _api.post('/modules/$kMounehModuleCode/$action'));
    if (result.success) await load();
    return result;
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
    final result = await _api.write(() => _api.post('/mouneh/products', body: {
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
        }));
    if (result.success) await load();
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
    final result = await _api.write(() => _api.post('/mouneh/raw-materials', body: {
          'name': name,
          'category': category,
          'source_type': sourceType,
          'unit': unit,
          'default_unit_cost': defaultUnitCost,
          'current_stock': currentStock,
          'loss_percent_default': lossPercentDefault,
        }));
    if (result.success) await load();
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
    final result = await _api.write(() => _api.post('/mouneh/products/$productId/recipes', body: {
          'basis_quantity': basisQuantity,
          'basis_unit': basisUnit,
          'notes': notes,
          'items': [for (final i in items) {'material_id': i.materialId, 'quantity': i.quantity, 'unit': i.unit, 'loss_percent': i.lossPercent}],
          'cost_components': [
            for (final c in costComponents) {'cost_type': c.costType, 'label': c.label, 'calculation_method': c.calculationMethod, 'amount': c.amount, 'quantity': c.quantity, 'unit_cost': c.unitCost},
          ],
        }));
    if (result.success) await load();
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
  /// starts — computed locally from the already-loaded recipe/material
  /// data (same pure engine as the backend) for instant feedback while a
  /// manager is typing, rather than a round-trip per keystroke.
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
  Future<WriteResult> createBatch({required String productId, required double plannedQty, String? warehouseLocation}) async {
    final product = productById(productId);
    if (product == null || _recipes[productId] == null) {
      return const WriteResult.fail('This product has no recipe yet — add raw materials before starting a batch.');
    }
    if (plannedQty <= 0) return const WriteResult.fail('valueMustBePositive');
    final result = await _api.write(() => _api.post('/mouneh/batches', body: {'product_id': productId, 'planned_qty': plannedQty, 'warehouse_location': warehouseLocation}));
    if (result.success) await load();
    return result;
  }

  Future<WriteResult> consumeBatchInputs({required String batchId, required Map<String, double> actualQtyByMaterial, bool allowNegative = false}) async {
    final result = await _api.write(() => _api.post('/mouneh/batches/$batchId/consume', body: {
          'lines': [for (final e in actualQtyByMaterial.entries) {'material_id': e.key, 'actual_qty': e.value}],
          'allow_negative': allowNegative,
        }));
    if (result.success) await load();
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
    if (actualOutputQty <= 0) return const WriteResult.fail('valueMustBePositive');
    final result = await _api.write(() => _api.post('/mouneh/batches/$batchId/complete', body: {
          'actual_output_qty': actualOutputQty,
          'waste_qty': wasteQty,
          'damaged_qty': damagedQty,
          'quality_status': qualityStatus,
          'expiry_date': expiryDate?.toIso8601String(),
          'warehouse_location': warehouseLocation,
          'labor_hours': laborHours,
          'extra_cost_components': [
            for (final c in extraCostComponents) {'cost_type': c.costType, 'label': c.label, 'calculation_method': c.calculationMethod, 'amount': c.amount, 'quantity': c.quantity, 'unit_cost': c.unitCost},
          ],
        }));
    if (result.success) await load();
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
    final result = await _api.write(() => _api.post('/mouneh/sales', body: {
          'product_id': productId,
          'finished_goods_stock_id': finishedGoodsStockId,
          'quantity': quantity,
          'unit_price': unitPrice,
          'discount': discount,
          'channel': channel,
        }));
    if (result.success) await load();
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
