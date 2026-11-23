/// The farm's milk tank and the milk sold from it (backend
/// app/services/milk_sales_service.py). The tank is worked out by the
/// server from the records — stored milk − sold + adjustments — and never
/// typed in.
class MilkTank {
  const MilkTank({
    required this.balanceL,
    required this.storedL,
    required this.soldL,
    required this.adjustedL,
    required this.currency,
    this.lastPricePerLiter,
    this.lastBuyerName,
  });

  final double balanceL;
  final double storedL;
  final double soldL;
  final double adjustedL;
  final String currency;
  final double? lastPricePerLiter;
  final String? lastBuyerName;

  static const empty = MilkTank(balanceL: 0, storedL: 0, soldL: 0, adjustedL: 0, currency: 'USD');

  factory MilkTank.fromJson(Map<String, dynamic> j) => MilkTank(
        balanceL: (j['balance_l'] as num?)?.toDouble() ?? 0,
        storedL: (j['stored_l'] as num?)?.toDouble() ?? 0,
        soldL: (j['sold_l'] as num?)?.toDouble() ?? 0,
        adjustedL: (j['adjusted_l'] as num?)?.toDouble() ?? 0,
        currency: j['currency'] as String? ?? 'USD',
        lastPricePerLiter: (j['last_price_per_liter'] as num?)?.toDouble(),
        lastBuyerName: j['last_buyer_name'] as String?,
      );
}

class MilkSale {
  const MilkSale({
    required this.id,
    required this.soldAt,
    required this.liters,
    required this.pricePerLiter,
    required this.amount,
    required this.currency,
    this.buyerName,
    required this.paymentStatus,
    this.reference,
    this.notes,
    required this.status,
    this.cancelReason,
    this.pending = false,
  });

  final String id;
  final DateTime soldAt;
  final double liters;
  final double pricePerLiter;
  final double amount;
  final String currency;
  final String? buyerName;

  /// paid | pending
  final String paymentStatus;
  final String? reference;
  final String? notes;

  /// recorded | cancelled
  final String status;
  final String? cancelReason;

  /// Saved on this device, not yet on the server.
  final bool pending;

  bool get cancelled => status == 'cancelled';
  bool get paid => paymentStatus == 'paid';

  factory MilkSale.fromJson(Map<String, dynamic> j) {
    final liters = (j['liters'] as num?)?.toDouble() ?? 0;
    final price = (j['price_per_liter'] as num?)?.toDouble() ?? 0;
    return MilkSale(
      id: j['id'] as String,
      soldAt: DateTime.tryParse(j['sold_at'] as String? ?? '') ?? DateTime.now(),
      liters: liters,
      pricePerLiter: price,
      amount: (j['amount'] as num?)?.toDouble() ?? double.parse((liters * price).toStringAsFixed(2)),
      currency: j['currency'] as String? ?? 'USD',
      buyerName: j['buyer_name'] as String?,
      paymentStatus: j['payment_status'] as String? ?? 'paid',
      reference: j['reference'] as String?,
      notes: j['notes'] as String?,
      status: j['status'] as String? ?? 'recorded',
      cancelReason: j['cancel_reason'] as String?,
      pending: j['_pending'] == true,
    );
  }
}

/// Milk that left the tank outside a sale, or a count of the tank.
class MilkTankAdjustment {
  const MilkTankAdjustment({required this.id, required this.occurredAt, required this.liters, required this.reason, this.countedLevel, this.notes});
  final String id;
  final DateTime occurredAt;

  /// Signed: out of the tank is negative.
  final double liters;

  /// count | spoiled | calves | home_use | other
  final String reason;
  final double? countedLevel;
  final String? notes;

  factory MilkTankAdjustment.fromJson(Map<String, dynamic> j) => MilkTankAdjustment(
        id: j['id'] as String,
        occurredAt: DateTime.tryParse(j['occurred_at'] as String? ?? '') ?? DateTime.now(),
        liters: (j['liters'] as num?)?.toDouble() ?? 0,
        reason: j['reason'] as String? ?? 'other',
        countedLevel: (j['counted_level'] as num?)?.toDouble(),
        notes: j['notes'] as String?,
      );
}
