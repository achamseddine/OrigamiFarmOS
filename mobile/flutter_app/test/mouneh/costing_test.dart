import 'package:flutter_test/flutter_test.dart';
import 'package:farmos/mouneh/costing.dart';

// Pure-Dart unit tests for the Mouneh costing engine — mirrors
// backend/tests/test_mouneh_costing.py so the same cost formula is
// verified on both sides of the offline-first split.
void main() {
  List<MaterialLine> materials() => [
        const MaterialLine(materialId: 'm1', name: 'Baby eggplant', category: 'raw_material', quantity: 20, unit: 'kg', unitCost: 1.5, lossPercent: 5),
        const MaterialLine(materialId: 'm2', name: 'Walnuts', category: 'raw_material', quantity: 2, unit: 'kg', unitCost: 8),
        const MaterialLine(materialId: 'm3', name: 'Jars', category: 'packaging', quantity: 100, unit: 'piece', unitCost: 0.35),
      ];

  group('MaterialLine', () {
    test('loss percent inflates effective quantity and cost', () {
      const line = MaterialLine(materialId: 'm1', name: 'Eggplant', category: 'raw_material', quantity: 100, unit: 'kg', unitCost: 1.0, lossPercent: 10);
      expect(line.effectiveQuantity, closeTo(110, 1e-9));
      expect(line.lineCost, closeTo(110, 1e-9));
    });

    test('zero loss percent is a no-op', () {
      const line = MaterialLine(materialId: 'm1', name: 'Eggplant', category: 'raw_material', quantity: 100, unit: 'kg', unitCost: 2.0);
      expect(line.effectiveQuantity, 100);
      expect(line.lineCost, 200);
    });
  });

  group('CostComponentLine.resolvedAmount', () {
    test('fixed ignores output qty', () {
      const c = CostComponentLine(costType: 'utilities', label: 'Gas', calculationMethod: 'fixed', amount: 12);
      expect(c.resolvedAmount(outputQty: 1, subtotalBeforeThis: 0), 12);
      expect(c.resolvedAmount(outputQty: 1000, subtotalBeforeThis: 0), 12);
    });

    test('per_output_unit scales with output', () {
      const c = CostComponentLine(costType: 'transport', label: 'Delivery', calculationMethod: 'per_output_unit', amount: 0.1);
      expect(c.resolvedAmount(outputQty: 100, subtotalBeforeThis: 0), closeTo(10, 1e-9));
    });

    test('quantity_x_rate multiplies hours by wage', () {
      const c = CostComponentLine(costType: 'labor', label: 'Labor', calculationMethod: 'quantity_x_rate', quantity: 6, unitCost: 5);
      expect(c.resolvedAmount(outputQty: 100, subtotalBeforeThis: 0), 30);
    });

    test('percentage applies to running subtotal', () {
      const c = CostComponentLine(costType: 'market_fees', label: 'Commission', calculationMethod: 'percentage', amount: 10);
      expect(c.resolvedAmount(outputQty: 1, subtotalBeforeThis: 200), closeTo(20, 1e-9));
    });

    test('unknown method throws', () {
      const c = CostComponentLine(costType: 'other', label: 'Mystery', calculationMethod: 'not_a_method');
      expect(() => c.resolvedAmount(outputQty: 1, subtotalBeforeThis: 0), throwsArgumentError);
    });
  });

  group('computeCostBreakdown', () {
    test('zero output qty throws', () {
      expect(() => computeCostBreakdown(materials: const [], components: const [], outputQty: 0), throwsArgumentError);
    });

    test('material and packaging costs are split', () {
      final b = computeCostBreakdown(materials: materials(), components: const [], outputQty: 100);
      // eggplant: 20 * 1.05 * 1.5 = 31.5 ; walnuts: 2 * 8 = 16
      expect(b.materialCost, closeTo(47.5, 1e-9));
      expect(b.packagingCost, closeTo(35.0, 1e-9));
      expect(b.laborCost, 0);
      expect(b.totalCost, closeTo(82.5, 1e-9));
      expect(b.unitCost, closeTo(0.825, 1e-9));
    });

    test('full formula matches hand calculation', () {
      final components = [
        const CostComponentLine(costType: 'labor', label: 'Labor', calculationMethod: 'quantity_x_rate', quantity: 6, unitCost: 5),
        const CostComponentLine(costType: 'utilities', label: 'Gas/Electricity', calculationMethod: 'fixed', amount: 12),
        const CostComponentLine(costType: 'transport', label: 'Delivery', calculationMethod: 'per_output_unit', amount: 0.1),
      ];
      final b = computeCostBreakdown(materials: materials(), components: components, outputQty: 100);
      // materials 47.5 + packaging 35 + labor 30 + utilities 12 + transport 10 = 134.5
      expect(b.totalCost, closeTo(134.5, 1e-9));
      expect(b.unitCost, closeTo(1.345, 1e-9));
      expect(b.componentBreakdown['Labor'], closeTo(30.0, 1e-9));
      expect(b.componentBreakdown['Delivery'], closeTo(10.0, 1e-9));
    });

    test('byproduct credit reduces total cost', () {
      final components = [const CostComponentLine(costType: 'byproduct_credit', label: 'Trimmings sold', calculationMethod: 'fixed', amount: 15)];
      final b = computeCostBreakdown(materials: materials(), components: components, outputQty: 100);
      expect(b.byproductCredit, 15);
      expect(b.totalCost, closeTo(82.5 - 15, 1e-9));
    });
  });

  group('suggestPrice', () {
    test('margin is expressed on selling price', () {
      final s = suggestPrice(unitCost: 2.0, targetMarginPct: 40);
      expect(s.suggestedPrice, closeTo(3.3333, 1e-3));
    });

    test('negative unit cost throws', () {
      expect(() => suggestPrice(unitCost: -1, targetMarginPct: 20), throwsArgumentError);
    });

    test('never suggests below the cost floor', () {
      final s = suggestPrice(unitCost: 5.0, targetMarginPct: 0);
      expect(s.suggestedPrice, greaterThanOrEqualTo(s.minimumPrice));
      expect(s.minimumPrice, closeTo(5.5, 1e-9));
    });
  });

  group('computeSaleMargin', () {
    test('basic margin calculation', () {
      final m = computeSaleMargin(quantity: 10, unitPrice: 5, discount: 0, unitCost: 2);
      expect(m.revenue, 50);
      expect(m.cost, 20);
      expect(m.profit, 30);
      expect(m.marginPct, closeTo(60.0, 1e-9));
    });

    test('discount reduces revenue', () {
      final m = computeSaleMargin(quantity: 10, unitPrice: 5, discount: 5, unitCost: 2);
      expect(m.revenue, 45);
      expect(m.profit, 25);
    });

    test('revenue never goes negative', () {
      final m = computeSaleMargin(quantity: 1, unitPrice: 1, discount: 100, unitCost: 0.5);
      expect(m.revenue, 0);
      expect(m.marginPct, 0);
    });

    test('zero quantity throws', () {
      expect(() => computeSaleMargin(quantity: 0, unitPrice: 5, discount: 0, unitCost: 2), throwsArgumentError);
    });

    test('negative discount throws', () {
      expect(() => computeSaleMargin(quantity: 1, unitPrice: 5, discount: -1, unitCost: 2), throwsArgumentError);
    });
  });
}
