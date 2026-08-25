/// Mouneh costing engine — Dart port of `backend/app/mouneh/costing.py`
/// so the tablet can compute a cost preview and complete a batch while
/// fully offline. Pure functions, no I/O, so this stays trivially
/// testable (see test/mouneh/costing_test.dart).
///
/// Core formula (tech spec v0.5 §7):
///   Unit Cost = (Raw Material Cost + Packaging Cost + Labor Cost
///                + Processing Overhead + Logistics Cost
///                + Storage/Cooling Cost + Other Allocated Costs
///                - Byproduct Value) / Sellable Output Quantity
library;

const String kLaborCostType = 'labor';
const String kByproductCreditType = 'byproduct_credit';
const double kMinimumMarginPctOverCost = 10.0;

class MaterialLine {
  const MaterialLine({
    required this.materialId,
    required this.name,
    required this.category,
    required this.quantity,
    required this.unit,
    required this.unitCost,
    this.lossPercent = 0,
  });

  final String materialId;
  final String name;
  final String category; // raw_material | packaging
  final double quantity;
  final String unit;
  final double unitCost;
  final double lossPercent;

  double get effectiveQuantity => quantity * (1 + (lossPercent < 0 ? 0 : lossPercent) / 100);
  double get lineCost => effectiveQuantity * unitCost;
}

class CostComponentLine {
  const CostComponentLine({
    required this.costType,
    required this.label,
    this.calculationMethod = 'fixed',
    this.amount,
    this.quantity,
    this.unitCost,
  });

  final String costType;
  final String label;
  final String calculationMethod; // fixed | per_output_unit | quantity_x_rate | percentage
  final double? amount;
  final double? quantity;
  final double? unitCost;

  double resolvedAmount({required double outputQty, required double subtotalBeforeThis}) {
    switch (calculationMethod) {
      case 'fixed':
        return amount ?? 0;
      case 'per_output_unit':
        return (amount ?? 0) * (outputQty < 0 ? 0 : outputQty);
      case 'quantity_x_rate':
        return (quantity ?? 0) * (unitCost ?? 0);
      case 'percentage':
        return subtotalBeforeThis * ((amount ?? 0) / 100);
      default:
        throw ArgumentError('Unknown calculation_method: $calculationMethod');
    }
  }
}

class CostBreakdown {
  const CostBreakdown({
    required this.materialCost,
    required this.packagingCost,
    required this.laborCost,
    required this.overheadCost,
    required this.byproductCredit,
    required this.outputQty,
    required this.totalCost,
    required this.unitCost,
    required this.componentBreakdown,
  });

  final double materialCost;
  final double packagingCost;
  final double laborCost;
  final double overheadCost;
  final double byproductCredit;
  final double outputQty;
  final double totalCost;
  final double unitCost;
  final Map<String, double> componentBreakdown;
}

double _round(double v, [int places = 4]) {
  final mult = 1.0 * (places == 2 ? 100 : (places == 4 ? 10000 : 1000));
  return (v * mult).round() / mult;
}

CostBreakdown computeCostBreakdown({
  required List<MaterialLine> materials,
  required List<CostComponentLine> components,
  required double outputQty,
}) {
  if (outputQty <= 0) {
    throw ArgumentError('outputQty must be greater than zero to compute a unit cost');
  }

  final materialCost = materials.where((m) => m.category != 'packaging').fold<double>(0, (sum, m) => sum + m.lineCost);
  final packagingCost = materials.where((m) => m.category == 'packaging').fold<double>(0, (sum, m) => sum + m.lineCost);

  var laborCost = 0.0;
  var overheadCost = 0.0;
  var byproductCredit = 0.0;
  final componentBreakdown = <String, double>{};

  var runningSubtotal = materialCost + packagingCost;
  for (final component in components) {
    final resolved = component.resolvedAmount(outputQty: outputQty, subtotalBeforeThis: runningSubtotal);
    final key = component.label;
    componentBreakdown[key] = (componentBreakdown[key] ?? 0) + resolved;

    if (component.costType == kLaborCostType) {
      laborCost += resolved;
      runningSubtotal += resolved;
    } else if (component.costType == kByproductCreditType) {
      byproductCredit += resolved;
      runningSubtotal -= resolved;
    } else {
      overheadCost += resolved;
      runningSubtotal += resolved;
    }
  }

  final totalCost = materialCost + packagingCost + laborCost + overheadCost - byproductCredit;
  final unitCost = totalCost / outputQty;

  return CostBreakdown(
    materialCost: _round(materialCost),
    packagingCost: _round(packagingCost),
    laborCost: _round(laborCost),
    overheadCost: _round(overheadCost),
    byproductCredit: _round(byproductCredit),
    outputQty: outputQty,
    totalCost: _round(totalCost),
    unitCost: _round(unitCost),
    componentBreakdown: componentBreakdown.map((k, v) => MapEntry(k, _round(v))),
  );
}

class PriceSuggestion {
  const PriceSuggestion({required this.unitCost, required this.targetMarginPct, required this.suggestedPrice, required this.minimumPrice});
  final double unitCost;
  final double targetMarginPct;
  final double suggestedPrice;
  final double minimumPrice;
}

PriceSuggestion suggestPrice({required double unitCost, required double targetMarginPct}) {
  if (unitCost < 0) throw ArgumentError('unitCost cannot be negative');
  final marginFraction = ((targetMarginPct < 0 ? 0.0 : targetMarginPct) / 100).clamp(0.0, 0.95).toDouble();
  final suggested = marginFraction < 1 ? unitCost / (1 - marginFraction) : unitCost;
  final minimum = unitCost * (1 + kMinimumMarginPctOverCost / 100);
  return PriceSuggestion(
    unitCost: _round(unitCost),
    targetMarginPct: targetMarginPct,
    suggestedPrice: _round(suggested > minimum ? suggested : minimum),
    minimumPrice: _round(minimum),
  );
}

class SaleMargin {
  const SaleMargin({required this.revenue, required this.cost, required this.profit, required this.marginPct});
  final double revenue;
  final double cost;
  final double profit;
  final double marginPct;
}

SaleMargin computeSaleMargin({required double quantity, required double unitPrice, required double discount, required double unitCost}) {
  if (quantity <= 0) throw ArgumentError('quantity must be greater than zero');
  if (discount < 0) throw ArgumentError('discount cannot be negative');
  final revenue = (quantity * unitPrice - discount).clamp(0, double.infinity).toDouble();
  final cost = quantity * unitCost;
  final profit = revenue - cost;
  final marginPct = revenue > 0 ? profit / revenue * 100 : 0.0;
  return SaleMargin(revenue: _round(revenue), cost: _round(cost), profit: _round(profit), marginPct: _round(marginPct, 2));
}
