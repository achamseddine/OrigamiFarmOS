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
}
