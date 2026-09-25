import 'package:flutter_test/flutter_test.dart';
import 'package:farmos/visits/analytics.dart';

// Pure-Dart unit tests for the Farm Visits & Agri-Tourism analytics engine
// — mirrors backend/tests/test_visits_analytics.py so booking status
// rules, capacity/welfare/handler checks and every profitability formula
// are verified identically on both sides of the offline-first split.
void main() {
  group('validateStatusTransition', () {
    test('draft can move to confirmed or cancelled', () {
      expect(() => validateStatusTransition('draft', 'confirmed'), returnsNormally);
      expect(() => validateStatusTransition('draft', 'cancelled'), returnsNormally);
    });

    test('draft cannot skip straight to checked_in', () {
      expect(() => validateStatusTransition('draft', 'checked_in'), throwsArgumentError);
    });

    test('refunded is a terminal state', () {
      expect(() => validateStatusTransition('refunded', 'confirmed'), throwsArgumentError);
    });

    test('completed, cancelled and no_show can all be refunded', () {
      expect(() => validateStatusTransition('completed', 'refunded'), returnsNormally);
      expect(() => validateStatusTransition('cancelled', 'refunded'), returnsNormally);
      expect(() => validateStatusTransition('no_show', 'refunded'), returnsNormally);
    });

    test('unknown status throws', () {
      expect(() => validateStatusTransition('draft', 'teleported'), throwsArgumentError);
    });
  });

  group('validateSessionCapacity (RULE-VIS-002)', () {
    test('within capacity is fine', () {
      expect(() => validateSessionCapacity(capacity: 40, alreadyBooked: 30, requested: 10), returnsNormally);
    });

    test('exceeding capacity throws', () {
      expect(() => validateSessionCapacity(capacity: 40, alreadyBooked: 35, requested: 10), throwsArgumentError);
    });

    test('negative requested count throws', () {
      expect(() => validateSessionCapacity(capacity: 40, alreadyBooked: 0, requested: -1), throwsArgumentError);
    });
  });

  group('validateActivityCapacity (RULE-VIS-004)', () {
    test('within a slot is fine', () {
      expect(() => validateActivityCapacity(capacityPerSlot: 4, alreadyBooked: 2, requested: 2), returnsNormally);
    });

    test('exceeding a slot throws', () {
      expect(() => validateActivityCapacity(capacityPerSlot: 4, alreadyBooked: 3, requested: 2), throwsArgumentError);
    });
  });

  group('validateWelfareLimit (RULE-VIS-004)', () {
    test('null limit never throws', () {
      expect(() => validateWelfareLimit(maxUsesPerDay: null, usesToday: 999, requested: 5), returnsNormally);
    });

    test('within the daily limit is fine', () {
      expect(() => validateWelfareLimit(maxUsesPerDay: 10, usesToday: 6, requested: 4), returnsNormally);
    });

    test('exceeding the daily limit throws', () {
      expect(() => validateWelfareLimit(maxUsesPerDay: 10, usesToday: 8, requested: 4), throwsArgumentError);
    });
  });

  group('validateHandlerAssignment (RULE-VIS-005)', () {
    test('no required role never throws', () {
      expect(() => validateHandlerAssignment(requiresStaffRole: null, assignedRoles: {}), returnsNormally);
    });

    test('required role present is fine', () {
      expect(() => validateHandlerAssignment(requiresStaffRole: 'horse_handler', assignedRoles: {'guide', 'horse_handler'}), returnsNormally);
    });

    test('required role missing throws', () {
      expect(() => validateHandlerAssignment(requiresStaffRole: 'horse_handler', assignedRoles: {'guide'}), throwsArgumentError);
    });
  });

  group('analytics formulas (tech spec v0.6 §9)', () {
    test('visitor revenue sums the three components', () {
      expect(computeVisitorRevenue(packageRevenue: 100, activityRevenue: 40, retailRevenue: 15), closeTo(155, 1e-9));
    });

    test('direct visit cost sums every cost bucket', () {
      expect(
        computeDirectVisitCost(staffCost: 60, activityCost: 10, includedProductCost: 5, cleaningUtilitiesCost: 20, otherCost: 5),
        closeTo(100, 1e-9),
      );
    });

    test('gross margin is revenue minus cost', () {
      expect(computeGrossMargin(visitorRevenue: 155, directVisitCost: 100), closeTo(55, 1e-9));
    });

    test('revenue per visitor divides safely by zero', () {
      expect(computeRevenuePerVisitor(visitorRevenue: 155, checkedInVisitors: 0), 0);
      expect(computeRevenuePerVisitor(visitorRevenue: 150, checkedInVisitors: 10), closeTo(15, 1e-9));
    });

    test('activity utilization is a percentage', () {
      expect(computeActivityUtilization(soldSlots: 8, availableSlots: 10), closeTo(80.0, 1e-9));
    });

    test('retail conversion is a percentage', () {
      expect(computeRetailConversion(visitorsWithPurchase: 3, checkedInVisitors: 12), closeTo(25.0, 1e-9));
    });

    test('average basket value divides safely by zero', () {
      expect(computeAverageBasketValue(retailSalesTotal: 45, purchaseCount: 0), 0);
      expect(computeAverageBasketValue(retailSalesTotal: 45, purchaseCount: 3), closeTo(15, 1e-9));
    });

    test('package profitability is revenue minus allocated cost', () {
      expect(computePackageProfitability(packageRevenue: 90, allocatedCosts: 30), closeTo(60, 1e-9));
    });
  });
}
