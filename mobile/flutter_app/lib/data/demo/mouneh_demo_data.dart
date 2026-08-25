import '../../domain/entities/mouneh.dart';
import '../../mouneh/costing.dart' as costing;

/// Demo dataset for the Mouneh & Farm Product Processing module. Makdous
/// is used purely as an EXAMPLE (tech spec v0.5): every row below is built
/// the same way the Product Builder / Recipe / Batch screens would create
/// it — nothing about "Makdous" is special-cased in the module's code, see
/// `backend/app/mouneh/seed.py` for the equivalent backend dataset (same
/// recipe/costs, kept in sync by hand).
class MounehDemoData {
  MounehDemoData._();

  static final DateTime _now = DateTime.now();

  static const List<RawMaterial> rawMaterials = [
    RawMaterial(id: 'mat-eggplant', name: 'Baby Eggplant', category: 'raw_material', sourceType: 'farm_produced', unit: 'kg', defaultUnitCost: 1.20, currentStock: 320, lossPercentDefault: 6),
    RawMaterial(id: 'mat-walnuts', name: 'Walnuts', category: 'raw_material', sourceType: 'purchased', unit: 'kg', defaultUnitCost: 7.50, currentStock: 25),
    RawMaterial(id: 'mat-pepper-paste', name: 'Red Pepper Paste', category: 'raw_material', sourceType: 'purchased', unit: 'kg', defaultUnitCost: 3.80, currentStock: 18),
    RawMaterial(id: 'mat-garlic', name: 'Garlic', category: 'raw_material', sourceType: 'farm_produced', unit: 'kg', defaultUnitCost: 2.10, currentStock: 12, lossPercentDefault: 3),
    RawMaterial(id: 'mat-olive-oil', name: 'Olive Oil', category: 'raw_material', sourceType: 'farm_produced', unit: 'liter', defaultUnitCost: 6.50, currentStock: 60),
    RawMaterial(id: 'mat-salt', name: 'Salt', category: 'raw_material', sourceType: 'purchased', unit: 'kg', defaultUnitCost: 0.35, currentStock: 40),
    RawMaterial(id: 'mat-jars', name: 'Glass Jars (500ml)', category: 'packaging', sourceType: 'purchased', unit: 'piece', defaultUnitCost: 0.35, currentStock: 600, lossPercentDefault: 1),
    RawMaterial(id: 'mat-lids', name: 'Jar Lids', category: 'packaging', sourceType: 'purchased', unit: 'piece', defaultUnitCost: 0.08, currentStock: 600, lossPercentDefault: 1),
    RawMaterial(id: 'mat-labels', name: 'Labels', category: 'packaging', sourceType: 'purchased', unit: 'piece', defaultUnitCost: 0.05, currentStock: 600),
  ];

  static const MounehProduct makdous = MounehProduct(
    id: 'prod-makdous',
    name: 'Makdous',
    category: 'Mouneh',
    outputUnit: 'jar',
    defaultBatchSize: 100,
    shelfLifeDays: 365,
    warehouseRules: 'Store in a cool, dark room. Fully submerged in olive oil.',
    lowStockThreshold: 20,
    targetPrice: 6.50,
    wholesalePrice: 5.00,
    targetMarginPct: 40,
    status: 'active',
  );

  static const List<MounehProduct> products = [makdous];

  static const List<MounehRecipeItem> _recipeItems = [
    MounehRecipeItem(materialId: 'mat-eggplant', materialType: 'raw_material', quantity: 45, unit: 'kg', lossPercent: 6),
    MounehRecipeItem(materialId: 'mat-walnuts', materialType: 'raw_material', quantity: 4, unit: 'kg'),
    MounehRecipeItem(materialId: 'mat-pepper-paste', materialType: 'raw_material', quantity: 3, unit: 'kg'),
    MounehRecipeItem(materialId: 'mat-garlic', materialType: 'raw_material', quantity: 2, unit: 'kg', lossPercent: 3),
    MounehRecipeItem(materialId: 'mat-olive-oil', materialType: 'raw_material', quantity: 18, unit: 'liter'),
    MounehRecipeItem(materialId: 'mat-salt', materialType: 'raw_material', quantity: 2.5, unit: 'kg'),
    MounehRecipeItem(materialId: 'mat-jars', materialType: 'packaging', quantity: 100, unit: 'piece', lossPercent: 1),
    MounehRecipeItem(materialId: 'mat-lids', materialType: 'packaging', quantity: 100, unit: 'piece', lossPercent: 1),
    MounehRecipeItem(materialId: 'mat-labels', materialType: 'packaging', quantity: 100, unit: 'piece'),
  ];

  static const List<MounehCostComponent> _costComponents = [
    MounehCostComponent(costType: 'labor', label: 'Labor (curing + packing)', calculationMethod: 'quantity_x_rate', quantity: 10, unitCost: 5.0),
    MounehCostComponent(costType: 'utilities', label: 'Gas & Electricity', calculationMethod: 'fixed', amount: 14),
    MounehCostComponent(costType: 'transport', label: 'Delivery to market', calculationMethod: 'per_output_unit', amount: 0.10),
    MounehCostComponent(costType: 'cooling_storage', label: 'Cold storage allocation', calculationMethod: 'fixed', amount: 8),
    MounehCostComponent(costType: 'market_fees', label: 'Co-op commission', calculationMethod: 'percentage', amount: 3),
  ];

  static const MounehRecipe makdousRecipe = MounehRecipe(
    id: 'recipe-makdous-v1',
    productId: 'prod-makdous',
    version: 1,
    basisQuantity: 100,
    basisUnit: 'jar',
    items: _recipeItems,
    costComponents: _costComponents,
    notes: 'Standard Makdous recipe — baby eggplant stuffed with walnuts, red pepper paste and garlic, cured in olive oil.',
  );

  static final Map<String, RawMaterial> _materialById = {for (final m in rawMaterials) m.id: m};

  static List<costing.MaterialLine> _materialLines(double scale) => [
        for (final item in _recipeItems)
          costing.MaterialLine(
            materialId: item.materialId,
            name: _materialById[item.materialId]!.name,
            category: item.materialType,
            quantity: item.quantity * scale,
            unit: item.unit,
            unitCost: _materialById[item.materialId]!.defaultUnitCost,
            lossPercent: item.lossPercent,
          ),
      ];

  static List<costing.CostComponentLine> get _componentLines => [
        for (final c in _costComponents)
          costing.CostComponentLine(costType: c.costType, label: c.label, calculationMethod: c.calculationMethod, amount: c.amount, quantity: c.quantity, unitCost: c.unitCost),
      ];

  /// Batch 1: completed 65 days ago -> 98 jars of finished goods stock.
  static final ProductionBatch completedBatch = () {
    final breakdown = costing.computeCostBreakdown(materials: _materialLines(1.0), components: _componentLines, outputQty: 98);
    return ProductionBatch(
      id: 'batch-makdous-001',
      productId: 'prod-makdous',
      recipeId: 'recipe-makdous-v1',
      batchCode: 'MOU-20260620-001',
      plannedQty: 100,
      actualOutputQty: 98,
      wasteQty: 2,
      qualityStatus: 'good',
      expiryDate: _now.add(const Duration(days: 350)),
      warehouseLocation: 'Storage Room A — Shelf 3',
      status: 'completed',
      plannedUnitCost: breakdown.unitCost,
      plannedTotalCost: breakdown.totalCost,
      actualUnitCost: breakdown.unitCost,
      actualTotalCost: breakdown.totalCost,
      laborHours: 10,
      startedAt: _now.subtract(const Duration(days: 66)),
      completedAt: _now.subtract(const Duration(days: 65)),
      consumptions: [
        for (final m in _materialLines(1.0))
          BatchInputConsumption(materialId: m.materialId, plannedQty: m.effectiveQuantity, actualQty: m.effectiveQuantity, unitCost: m.unitCost, totalCost: m.lineCost),
      ],
    );
  }();

  /// Batch 2: 60-jar batch, started 2 days ago, still in progress.
  static final ProductionBatch inProgressBatch = () {
    final breakdown = costing.computeCostBreakdown(materials: _materialLines(0.6), components: _componentLines, outputQty: 60);
    return ProductionBatch(
      id: 'batch-makdous-002',
      productId: 'prod-makdous',
      recipeId: 'recipe-makdous-v1',
      batchCode: 'MOU-20260821-001',
      plannedQty: 60,
      status: 'in_progress',
      plannedUnitCost: breakdown.unitCost,
      plannedTotalCost: breakdown.totalCost,
      warehouseLocation: 'Storage Room A — Shelf 3',
      startedAt: _now.subtract(const Duration(days: 2)),
      consumptions: [
        for (final m in _materialLines(0.6)) BatchInputConsumption(materialId: m.materialId, plannedQty: m.effectiveQuantity, unitCost: m.unitCost),
      ],
    );
  }();

  static List<ProductionBatch> get batches => [completedBatch, inProgressBatch];

  static FinishedGoodsStock get finishedGoods => FinishedGoodsStock(
        id: 'stock-makdous-001',
        productId: 'prod-makdous',
        batchId: completedBatch.id,
        warehouseLocation: completedBatch.warehouseLocation,
        quantityProduced: 98,
        quantityAvailable: 53,
        quantitySold: 45,
        unitCost: completedBatch.actualUnitCost!,
        expiryDate: completedBatch.expiryDate,
      );

  static List<MounehSale> get sales {
    final unitCost = completedBatch.actualUnitCost!;
    final entries = [
      (qty: 20.0, price: 6.50, discount: 0.0, channel: 'retail', daysAgo: 8),
      (qty: 15.0, price: 5.00, discount: 5.0, channel: 'wholesale', daysAgo: 5),
      (qty: 10.0, price: 6.50, discount: 0.0, channel: 'market', daysAgo: 2),
    ];
    return [
      for (var i = 0; i < entries.length; i++)
        () {
          final e = entries[i];
          final margin = costing.computeSaleMargin(quantity: e.qty, unitPrice: e.price, discount: e.discount, unitCost: unitCost);
          return MounehSale(
            id: 'sale-makdous-00${i + 1}',
            productId: 'prod-makdous',
            batchId: completedBatch.id,
            finishedGoodsStockId: finishedGoods.id,
            quantity: e.qty,
            unitPrice: e.price,
            discount: e.discount,
            channel: e.channel,
            costPerUnit: unitCost,
            revenue: margin.revenue,
            margin: margin.profit,
            soldAt: _now.subtract(Duration(days: e.daysAgo)),
          );
        }(),
    ];
  }
}
