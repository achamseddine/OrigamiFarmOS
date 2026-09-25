/// Mouneh & Farm Product Processing module — local domain entities
/// (tech spec v0.5 §3). Field names mirror `backend/app/domain/mouneh_models.py`
/// so payloads round-trip cleanly once sync is wired to the real API.
library;

/// REQ-MOU-001: license-controlled module, activated/deactivated by a
/// super user per farm.
class ModuleLicense {
  const ModuleLicense({
    required this.moduleCode,
    required this.status, // active | inactive | expired
    this.plan = 'mouneh_addon',
    this.activatedBy,
  });

  final String moduleCode;
  final String status;
  final String plan;
  final String? activatedBy;

  bool get isActive => status == 'active';

  ModuleLicense copyWith({String? status}) => ModuleLicense(
        moduleCode: moduleCode,
        status: status ?? this.status,
        plan: plan,
        activatedBy: activatedBy,
      );

  factory ModuleLicense.fromJson(Map<String, dynamic> json) => ModuleLicense(
        moduleCode: json['module_code'] as String,
        status: json['status'] as String,
        plan: json['plan'] as String? ?? 'mouneh_addon',
        activatedBy: json['activated_by'] as String?,
      );
}

const List<String> kMounehOutputUnits = ['jar', 'bottle', 'pack', 'kg', 'liter', 'tray', 'piece', 'custom'];
const List<String> kMounehMaterialCategories = ['raw_material', 'packaging'];
const List<String> kMounehSourceTypes = ['farm_produced', 'purchased'];
const List<String> kMounehCostTypes = [
  'labor',
  'packaging_extra',
  'utilities',
  'transport',
  'cooling_storage',
  'market_fees',
  'byproduct_credit',
  'other',
];
const List<String> kMounehCalculationMethods = ['fixed', 'per_output_unit', 'quantity_x_rate', 'percentage'];
const List<String> kMounehSaleChannels = ['retail', 'wholesale', 'market', 'other'];

/// An ingredient OR a packaging input — `category` tells them apart, both
/// are consumed and costed the same way (REQ-MOU-002).
class RawMaterial {
  const RawMaterial({
    required this.id,
    required this.name,
    this.category = 'raw_material',
    this.sourceType = 'purchased',
    required this.unit,
    this.defaultUnitCost = 0,
    this.currentStock = 0,
    this.lossPercentDefault = 0,
  });

  final String id;
  final String name;
  final String category;
  final String sourceType;
  final String unit;
  final double defaultUnitCost;
  final double currentStock;
  final double lossPercentDefault;

  bool get isPackaging => category == 'packaging';

  RawMaterial copyWith({double? currentStock}) => RawMaterial(
        id: id,
        name: name,
        category: category,
        sourceType: sourceType,
        unit: unit,
        defaultUnitCost: defaultUnitCost,
        currentStock: currentStock ?? this.currentStock,
        lossPercentDefault: lossPercentDefault,
      );

  factory RawMaterial.fromJson(Map<String, dynamic> json) => RawMaterial(
        id: json['id'] as String,
        name: json['name'] as String,
        category: json['category'] as String? ?? 'raw_material',
        sourceType: json['source_type'] as String? ?? 'purchased',
        unit: json['unit'] as String,
        defaultUnitCost: (json['default_unit_cost'] as num?)?.toDouble() ?? 0,
        currentStock: (json['current_stock'] as num?)?.toDouble() ?? 0,
        lossPercentDefault: (json['loss_percent_default'] as num?)?.toDouble() ?? 0,
      );
}

class MounehRecipeItem {
  const MounehRecipeItem({
    required this.materialId,
    required this.materialType,
    required this.quantity,
    required this.unit,
    this.lossPercent = 0,
  });

  final String materialId;
  final String materialType; // snapshot of the material's category
  final double quantity;
  final String unit;
  final double lossPercent;

  factory MounehRecipeItem.fromJson(Map<String, dynamic> json) => MounehRecipeItem(
        materialId: json['material_id'] as String,
        materialType: json['material_type'] as String? ?? 'raw_material',
        quantity: (json['quantity'] as num).toDouble(),
        unit: json['unit'] as String,
        lossPercent: (json['loss_percent'] as num?)?.toDouble() ?? 0,
      );
}

/// Labor / utilities / transport / cooling / market fees / other overhead
/// / byproduct credit — anything that isn't a material line item.
class MounehCostComponent {
  const MounehCostComponent({
    required this.costType,
    required this.label,
    this.calculationMethod = 'fixed',
    this.amount,
    this.quantity,
    this.unitCost,
  });

  final String costType;
  final String label;
  final String calculationMethod;
  final double? amount;
  final double? quantity;
  final double? unitCost;

  factory MounehCostComponent.fromJson(Map<String, dynamic> json) => MounehCostComponent(
        costType: json['cost_type'] as String,
        label: json['label'] as String? ?? '',
        calculationMethod: json['calculation_method'] as String? ?? 'fixed',
        amount: (json['amount'] as num?)?.toDouble(),
        quantity: (json['quantity'] as num?)?.toDouble(),
        unitCost: (json['unit_cost'] as num?)?.toDouble(),
      );
}

/// A versioned Bill of Materials for a product. A new recipe call always
/// creates a new version — corrections never overwrite a prior one, so a
/// completed batch's snapshot cost never silently changes.
class MounehRecipe {
  const MounehRecipe({
    required this.id,
    required this.productId,
    required this.version,
    required this.basisQuantity,
    required this.basisUnit,
    required this.items,
    required this.costComponents,
    this.active = true,
    this.notes,
  });

  final String id;
  final String productId;
  final int version;
  final double basisQuantity;
  final String basisUnit;
  final List<MounehRecipeItem> items;
  final List<MounehCostComponent> costComponents;
  final bool active;
  final String? notes;

  factory MounehRecipe.fromJson(Map<String, dynamic> json) => MounehRecipe(
        id: json['id'] as String,
        productId: json['product_id'] as String,
        version: json['version'] as int,
        basisQuantity: (json['basis_quantity'] as num).toDouble(),
        basisUnit: json['basis_unit'] as String,
        items: [for (final i in (json['items'] as List<dynamic>? ?? [])) MounehRecipeItem.fromJson(i as Map<String, dynamic>)],
        costComponents: [for (final c in (json['cost_components'] as List<dynamic>? ?? [])) MounehCostComponent.fromJson(c as Map<String, dynamic>)],
        active: json['active'] as bool? ?? true,
        notes: json['notes'] as String?,
      );
}

/// A manager-defined product — created dynamically through the Product
/// Builder Wizard. Nothing about a specific product name is hard-coded
/// anywhere in this module.
class MounehProduct {
  const MounehProduct({
    required this.id,
    required this.name,
    this.category = 'general',
    this.photoPath,
    required this.outputUnit,
    this.customOutputUnitLabel,
    this.defaultBatchSize = 1,
    this.shelfLifeDays,
    this.warehouseRules,
    this.lowStockThreshold,
    this.targetPrice,
    this.wholesalePrice,
    this.targetMarginPct,
    this.status = 'draft', // draft | active | archived
  });

  final String id;
  final String name;
  final String category;
  final String? photoPath;
  final String outputUnit;
  final String? customOutputUnitLabel;
  final double defaultBatchSize;
  final int? shelfLifeDays;
  final String? warehouseRules;
  final double? lowStockThreshold;
  final double? targetPrice;
  final double? wholesalePrice;
  final double? targetMarginPct;
  final String status;

  MounehProduct copyWith({String? status}) => MounehProduct(
        id: id,
        name: name,
        category: category,
        photoPath: photoPath,
        outputUnit: outputUnit,
        customOutputUnitLabel: customOutputUnitLabel,
        defaultBatchSize: defaultBatchSize,
        shelfLifeDays: shelfLifeDays,
        warehouseRules: warehouseRules,
        lowStockThreshold: lowStockThreshold,
        targetPrice: targetPrice,
        wholesalePrice: wholesalePrice,
        targetMarginPct: targetMarginPct,
        status: status ?? this.status,
      );

  factory MounehProduct.fromJson(Map<String, dynamic> json) => MounehProduct(
        id: json['id'] as String,
        name: json['name'] as String,
        category: json['category'] as String? ?? 'general',
        photoPath: json['photo_path'] as String?,
        outputUnit: json['output_unit'] as String,
        customOutputUnitLabel: json['custom_output_unit_label'] as String?,
        defaultBatchSize: (json['default_batch_size'] as num?)?.toDouble() ?? 1,
        shelfLifeDays: json['shelf_life_days'] as int?,
        warehouseRules: json['warehouse_rules'] as String?,
        lowStockThreshold: (json['low_stock_threshold'] as num?)?.toDouble(),
        targetPrice: (json['target_price'] as num?)?.toDouble(),
        wholesalePrice: (json['wholesale_price'] as num?)?.toDouble(),
        targetMarginPct: (json['target_margin_pct'] as num?)?.toDouble(),
        status: json['status'] as String? ?? 'draft',
      );
}

class BatchInputConsumption {
  const BatchInputConsumption({
    required this.materialId,
    required this.plannedQty,
    this.actualQty,
    required this.unitCost,
    this.totalCost,
  });

  final String materialId;
  final double plannedQty;
  final double? actualQty;
  final double unitCost;
  final double? totalCost;

  BatchInputConsumption copyWith({double? actualQty, double? totalCost}) => BatchInputConsumption(
        materialId: materialId,
        plannedQty: plannedQty,
        actualQty: actualQty ?? this.actualQty,
        unitCost: unitCost,
        totalCost: totalCost ?? this.totalCost,
      );

  factory BatchInputConsumption.fromJson(Map<String, dynamic> json) => BatchInputConsumption(
        materialId: json['material_id'] as String,
        plannedQty: (json['planned_qty'] as num).toDouble(),
        actualQty: (json['actual_qty'] as num?)?.toDouble(),
        unitCost: (json['unit_cost'] as num).toDouble(),
        totalCost: (json['total_cost'] as num?)?.toDouble(),
      );
}

/// REQ-MOU-004/005: create batches from a recipe, consume actual raw
/// materials, complete into finished goods. Completed batches are never
/// mutated again — a correction is a new event, not an overwrite.
class ProductionBatch {
  const ProductionBatch({
    required this.id,
    required this.productId,
    required this.recipeId,
    required this.batchCode,
    required this.plannedQty,
    this.actualOutputQty,
    this.wasteQty = 0,
    this.damagedQty = 0,
    this.qualityStatus = 'good', // good | substandard | rejected
    this.expiryDate,
    this.warehouseLocation,
    this.status = 'in_progress', // draft | in_progress | completed | cancelled
    this.plannedUnitCost,
    this.plannedTotalCost,
    this.actualUnitCost,
    this.actualTotalCost,
    this.laborHours,
    required this.startedAt,
    this.completedAt,
    required this.consumptions,
  });

  final String id;
  final String productId;
  final String recipeId;
  final String batchCode;
  final double plannedQty;
  final double? actualOutputQty;
  final double wasteQty;
  final double damagedQty;
  final String qualityStatus;
  final DateTime? expiryDate;
  final String? warehouseLocation;
  final String status;
  final double? plannedUnitCost;
  final double? plannedTotalCost;
  final double? actualUnitCost;
  final double? actualTotalCost;
  final double? laborHours;
  final DateTime startedAt;
  final DateTime? completedAt;
  final List<BatchInputConsumption> consumptions;

  bool get isInProgress => status == 'in_progress';
  bool get isCompleted => status == 'completed';

  ProductionBatch copyWith({
    double? actualOutputQty,
    double? wasteQty,
    double? damagedQty,
    String? qualityStatus,
    DateTime? expiryDate,
    String? warehouseLocation,
    String? status,
    double? actualUnitCost,
    double? actualTotalCost,
    double? laborHours,
    DateTime? completedAt,
    List<BatchInputConsumption>? consumptions,
  }) =>
      ProductionBatch(
        id: id,
        productId: productId,
        recipeId: recipeId,
        batchCode: batchCode,
        plannedQty: plannedQty,
        actualOutputQty: actualOutputQty ?? this.actualOutputQty,
        wasteQty: wasteQty ?? this.wasteQty,
        damagedQty: damagedQty ?? this.damagedQty,
        qualityStatus: qualityStatus ?? this.qualityStatus,
        expiryDate: expiryDate ?? this.expiryDate,
        warehouseLocation: warehouseLocation ?? this.warehouseLocation,
        status: status ?? this.status,
        plannedUnitCost: plannedUnitCost,
        plannedTotalCost: plannedTotalCost,
        actualUnitCost: actualUnitCost ?? this.actualUnitCost,
        actualTotalCost: actualTotalCost ?? this.actualTotalCost,
        laborHours: laborHours ?? this.laborHours,
        startedAt: startedAt,
        completedAt: completedAt ?? this.completedAt,
        consumptions: consumptions ?? this.consumptions,
      );

  factory ProductionBatch.fromJson(Map<String, dynamic> json) => ProductionBatch(
        id: json['id'] as String,
        productId: json['product_id'] as String,
        recipeId: json['recipe_version_id'] as String,
        batchCode: json['batch_code'] as String,
        plannedQty: (json['planned_qty'] as num).toDouble(),
        actualOutputQty: (json['actual_output_qty'] as num?)?.toDouble(),
        wasteQty: (json['waste_qty'] as num?)?.toDouble() ?? 0,
        damagedQty: (json['damaged_qty'] as num?)?.toDouble() ?? 0,
        qualityStatus: json['quality_status'] as String? ?? 'good',
        expiryDate: json['expiry_date'] != null ? DateTime.parse(json['expiry_date'] as String) : null,
        warehouseLocation: json['warehouse_location'] as String?,
        status: json['status'] as String? ?? 'in_progress',
        plannedUnitCost: (json['planned_unit_cost'] as num?)?.toDouble(),
        plannedTotalCost: (json['planned_total_cost'] as num?)?.toDouble(),
        actualUnitCost: (json['actual_unit_cost'] as num?)?.toDouble(),
        actualTotalCost: (json['actual_total_cost'] as num?)?.toDouble(),
        laborHours: (json['labor_hours'] as num?)?.toDouble(),
        startedAt: DateTime.parse(json['started_at'] as String),
        completedAt: json['completed_at'] != null ? DateTime.parse(json['completed_at'] as String) : null,
        consumptions: [for (final c in (json['consumptions'] as List<dynamic>? ?? [])) BatchInputConsumption.fromJson(c as Map<String, dynamic>)],
      );
}

/// A completed batch creates one of these; sales draw down from it.
class FinishedGoodsStock {
  const FinishedGoodsStock({
    required this.id,
    required this.productId,
    required this.batchId,
    this.warehouseLocation,
    required this.quantityProduced,
    required this.quantityAvailable,
    this.quantityReserved = 0,
    this.quantitySold = 0,
    this.quantityExpired = 0,
    this.quantityDamaged = 0,
    required this.unitCost,
    this.expiryDate,
  });

  final String id;
  final String productId;
  final String batchId;
  final String? warehouseLocation;
  final double quantityProduced;
  final double quantityAvailable;
  final double quantityReserved;
  final double quantitySold;
  final double quantityExpired;
  final double quantityDamaged;
  final double unitCost;
  final DateTime? expiryDate;

  FinishedGoodsStock copyWith({double? quantityAvailable, double? quantitySold}) => FinishedGoodsStock(
        id: id,
        productId: productId,
        batchId: batchId,
        warehouseLocation: warehouseLocation,
        quantityProduced: quantityProduced,
        quantityAvailable: quantityAvailable ?? this.quantityAvailable,
        quantityReserved: quantityReserved,
        quantitySold: quantitySold ?? this.quantitySold,
        quantityExpired: quantityExpired,
        quantityDamaged: quantityDamaged,
        unitCost: unitCost,
        expiryDate: expiryDate,
      );

  factory FinishedGoodsStock.fromJson(Map<String, dynamic> json) => FinishedGoodsStock(
        id: json['id'] as String,
        productId: json['product_id'] as String,
        batchId: json['batch_id'] as String,
        warehouseLocation: json['warehouse_location'] as String?,
        quantityProduced: (json['quantity_produced'] as num).toDouble(),
        quantityAvailable: (json['quantity_available'] as num).toDouble(),
        quantityReserved: (json['quantity_reserved'] as num?)?.toDouble() ?? 0,
        quantitySold: (json['quantity_sold'] as num?)?.toDouble() ?? 0,
        quantityExpired: (json['quantity_expired'] as num?)?.toDouble() ?? 0,
        quantityDamaged: (json['quantity_damaged'] as num?)?.toDouble() ?? 0,
        unitCost: (json['unit_cost'] as num).toDouble(),
        expiryDate: json['expiry_date'] != null ? DateTime.parse(json['expiry_date'] as String) : null,
      );
}

/// REQ-MOU-006: sales reduce finished goods stock and calculate profit.
class MounehSale {
  const MounehSale({
    required this.id,
    required this.productId,
    required this.batchId,
    required this.finishedGoodsStockId,
    required this.quantity,
    required this.unitPrice,
    this.discount = 0,
    this.channel = 'retail',
    required this.costPerUnit,
    required this.revenue,
    required this.margin,
    required this.soldAt,
  });

  final String id;
  final String productId;
  final String batchId;
  final String finishedGoodsStockId;
  final double quantity;
  final double unitPrice;
  final double discount;
  final String channel;
  final double costPerUnit;
  final double revenue;
  final double margin;
  final DateTime soldAt;

  factory MounehSale.fromJson(Map<String, dynamic> json) => MounehSale(
        id: json['id'] as String,
        productId: json['product_id'] as String,
        batchId: json['batch_id'] as String,
        finishedGoodsStockId: json['finished_goods_stock_id'] as String,
        quantity: (json['quantity'] as num).toDouble(),
        unitPrice: (json['unit_price'] as num).toDouble(),
        discount: (json['discount'] as num?)?.toDouble() ?? 0,
        channel: json['channel'] as String? ?? 'retail',
        costPerUnit: (json['cost_per_unit'] as num).toDouble(),
        revenue: (json['revenue'] as num).toDouble(),
        margin: (json['margin'] as num).toDouble(),
        soldAt: DateTime.parse(json['sold_at'] as String),
      );
}

/// Per-product roll-up shown on the profitability dashboard.
class MounehProductProfitability {
  const MounehProductProfitability({
    required this.productId,
    required this.productName,
    required this.unitsProduced,
    required this.unitsSold,
    required this.unitsRemaining,
    required this.avgUnitCost,
    required this.avgSalePrice,
    required this.totalRevenue,
    required this.totalCost,
    required this.totalProfit,
    required this.grossMarginPct,
    required this.salesVelocityPerDay,
    required this.recommendation, // continue_production | slow_mover | review_pricing
  });

  final String productId;
  final String productName;
  final double unitsProduced;
  final double unitsSold;
  final double unitsRemaining;
  final double avgUnitCost;
  final double avgSalePrice;
  final double totalRevenue;
  final double totalCost;
  final double totalProfit;
  final double grossMarginPct;
  final double salesVelocityPerDay;
  final String recommendation;

  factory MounehProductProfitability.fromJson(Map<String, dynamic> json) => MounehProductProfitability(
        productId: json['product_id'] as String,
        productName: json['product_name'] as String,
        unitsProduced: (json['units_produced'] as num).toDouble(),
        unitsSold: (json['units_sold'] as num).toDouble(),
        unitsRemaining: (json['units_remaining'] as num).toDouble(),
        avgUnitCost: (json['avg_unit_cost'] as num).toDouble(),
        avgSalePrice: (json['avg_sale_price'] as num).toDouble(),
        totalRevenue: (json['total_revenue'] as num).toDouble(),
        totalCost: (json['total_cost'] as num).toDouble(),
        totalProfit: (json['total_profit'] as num).toDouble(),
        grossMarginPct: (json['gross_margin_pct'] as num).toDouble(),
        salesVelocityPerDay: (json['sales_velocity_per_day'] as num).toDouble(),
        recommendation: json['recommendation'] as String,
      );
}
