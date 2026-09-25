/// Farm Visits & Agri-Tourism — pure analytics/validation engine. Dart
/// port of `backend/app/visits/analytics.py` so capacity checks, the
/// booking status machine, and every profitability formula work
/// identically offline. No I/O — see test/visits/analytics_test.dart.
library;

const Set<String> kBookingStatuses = {'draft', 'confirmed', 'checked_in', 'completed', 'cancelled', 'no_show', 'refunded'};

const Map<String, Set<String>> kAllowedTransitions = {
  'draft': {'confirmed', 'cancelled'},
  'confirmed': {'checked_in', 'cancelled', 'no_show'},
  'checked_in': {'completed', 'cancelled'},
  'completed': {'refunded'},
  'cancelled': {'refunded'},
  'no_show': {'refunded'},
  'refunded': {},
};

void validateStatusTransition(String current, String next) {
  if (!kBookingStatuses.contains(current)) throw ArgumentError('Unknown booking status: $current');
  if (!kBookingStatuses.contains(next)) throw ArgumentError('Unknown booking status: $next');
  if (!(kAllowedTransitions[current] ?? {}).contains(next)) {
    throw ArgumentError('Cannot move a booking from $current to $next');
  }
}

/// RULE-VIS-002.
void validateSessionCapacity({required int capacity, required int alreadyBooked, required int requested}) {
  if (requested < 0) throw ArgumentError('requested guest count cannot be negative');
  if (alreadyBooked + requested > capacity) {
    final available = (capacity - alreadyBooked) < 0 ? 0 : (capacity - alreadyBooked);
    throw ArgumentError('Session capacity is $capacity; only $available spot(s) remain, cannot confirm $requested more.');
  }
}

/// RULE-VIS-004.
void validateActivityCapacity({required int capacityPerSlot, required int alreadyBooked, required int requested}) {
  if (requested < 0) throw ArgumentError('requested quantity cannot be negative');
  if (alreadyBooked + requested > capacityPerSlot) {
    final available = (capacityPerSlot - alreadyBooked) < 0 ? 0 : (capacityPerSlot - alreadyBooked);
    throw ArgumentError('This activity slot holds $capacityPerSlot; only $available spot(s) remain.');
  }
}

void validateWelfareLimit({required int? maxUsesPerDay, required int usesToday, required int requested}) {
  if (maxUsesPerDay == null) return;
  if (usesToday + requested > maxUsesPerDay) {
    throw ArgumentError('This activity is limited to $maxUsesPerDay use(s) per day for animal welfare; $usesToday already scheduled today.');
  }
}

/// RULE-VIS-005.
void validateHandlerAssignment({required String? requiresStaffRole, required Set<String> assignedRoles}) {
  if (requiresStaffRole != null && requiresStaffRole.isNotEmpty && !assignedRoles.contains(requiresStaffRole)) {
    throw ArgumentError('This activity requires a staff member with role "$requiresStaffRole" assigned to the session first.');
  }
}

double _safeDiv(double numerator, double denominator) => denominator == 0 ? 0.0 : numerator / denominator;

double _round(double v, [int places = 2]) {
  final mult = places == 1 ? 10.0 : 100.0;
  return (v * mult).round() / mult;
}

double computeVisitorRevenue({required double packageRevenue, required double activityRevenue, required double retailRevenue}) =>
    _round(packageRevenue + activityRevenue + retailRevenue);

double computeDirectVisitCost({
  required double staffCost,
  required double activityCost,
  required double includedProductCost,
  required double cleaningUtilitiesCost,
  required double otherCost,
}) =>
    _round(staffCost + activityCost + includedProductCost + cleaningUtilitiesCost + otherCost);

double computeGrossMargin({required double visitorRevenue, required double directVisitCost}) => _round(visitorRevenue - directVisitCost);

double computeRevenuePerVisitor({required double visitorRevenue, required int checkedInVisitors}) =>
    _round(_safeDiv(visitorRevenue, checkedInVisitors.toDouble()));

double computeActivityUtilization({required int soldSlots, required int availableSlots}) =>
    _round(_safeDiv(soldSlots.toDouble(), availableSlots.toDouble()) * 100, 1);

double computeRetailConversion({required int visitorsWithPurchase, required int checkedInVisitors}) =>
    _round(_safeDiv(visitorsWithPurchase.toDouble(), checkedInVisitors.toDouble()) * 100, 1);

double computeAverageBasketValue({required double retailSalesTotal, required int purchaseCount}) =>
    _round(_safeDiv(retailSalesTotal, purchaseCount.toDouble()));

double computePackageProfitability({required double packageRevenue, required double allocatedCosts}) =>
    _round(packageRevenue - allocatedCosts);
