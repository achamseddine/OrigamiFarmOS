/// Origami's financials (v0.8.0) as the server answers them
/// (backend app/services/finance_service.py). Amounts are in the farm's
/// currency (USD); a sale or bill made in LBP keeps its LBP amount and the
/// rate used.
library;

double _d(Object? v) => (v as num?)?.toDouble() ?? 0;
double? _dn(Object? v) => (v as num?)?.toDouble();
DateTime? _t(Object? v) => v == null ? null : DateTime.tryParse('$v');

class FinanceSale {
  const FinanceSale({
    required this.id,
    required this.productType,
    this.productLabel,
    this.quantity,
    this.unit,
    this.unitPrice,
    required this.amount,
    this.currency = 'USD',
    this.originalAmount,
    this.originalCurrency,
    this.exchangeRate,
    required this.paymentStatus,
    this.paidAt,
    required this.soldAt,
    this.buyerName,
    this.reference,
    this.notes,
    this.status = 'recorded',
    this.cancelReason,
    this.reversalOfId,
    this.activity,
    this.amountPaid = 0,
    this.balanceDue,
    this.mounehSaleId,
    this.pending = false,
  });

  final String id;
  final String productType;
  final String? productLabel;
  final double? quantity;
  final String? unit;
  final double? unitPrice;
  final double amount;
  final String currency;
  final double? originalAmount;
  final String? originalCurrency;
  final double? exchangeRate;
  final String paymentStatus;
  final DateTime? paidAt;
  final DateTime soldAt;
  final String? buyerName;
  final String? reference;
  final String? notes;

  /// recorded | cancelled | reversal (the negative row undoing a cancelled sale)
  final String status;
  final String? cancelReason;
  final String? reversalOfId;
  final String? activity;

  /// Received so far (all of it once paid; the parts of a sale paid in part).
  final double amountPaid;

  /// What the buyer still owes, as the server counts it (the amount less
  /// the parts paid); null on a sale not yet sent.
  final double? balanceDue;

  /// A sale in the Mouneh shop: its line there.
  final String? mounehSaleId;

  /// Saved on this device, waiting to be sent.
  final bool pending;

  bool get cancelled => status == 'cancelled';
  bool get isReversal => status == 'reversal';
  bool get paid => paymentStatus == 'paid';
  bool get partlyPaid => paymentStatus == 'partial';

  /// What is still to be received for it.
  double get due => status == 'recorded' && !paid && amount > 0 ? (balanceDue ?? amount) : 0;
  bool get owed => due > 0.004;

  factory FinanceSale.fromJson(Map<String, dynamic> j) => FinanceSale(
        id: j['id'] as String,
        productType: j['product_type'] as String? ?? 'other',
        productLabel: j['product_label'] as String?,
        quantity: _dn(j['quantity']),
        unit: j['unit'] as String?,
        unitPrice: _dn(j['unit_price']),
        amount: _d(j['amount']),
        currency: j['currency'] as String? ?? 'USD',
        originalAmount: _dn(j['original_amount']),
        originalCurrency: j['original_currency'] as String?,
        exchangeRate: _dn(j['exchange_rate']),
        paymentStatus: j['payment_status'] as String? ?? 'paid',
        paidAt: _t(j['paid_at']),
        soldAt: _t(j['sold_at']) ?? DateTime.now(),
        buyerName: j['buyer_name'] as String?,
        reference: j['reference'] as String?,
        notes: j['notes'] as String?,
        status: j['status'] as String? ?? 'recorded',
        cancelReason: j['cancel_reason'] as String?,
        reversalOfId: j['reversal_of_id'] as String?,
        activity: j['activity'] as String?,
        amountPaid: _d(j['amount_paid']),
        balanceDue: _dn(j['balance_due']),
        mounehSaleId: j['mouneh_sale_id'] as String?,
        pending: j['_pending'] == true,
      );
}

class FinanceExpense {
  const FinanceExpense({
    required this.id,
    required this.category,
    this.description,
    required this.amount,
    this.currency = 'USD',
    this.originalAmount,
    this.originalCurrency,
    this.exchangeRate,
    required this.incurredAt,
    this.supplierName,
    required this.paymentStatus,
    this.dueDate,
    this.paidAt,
    this.reference,
    this.notes,
    this.status = 'recorded',
    this.cancelReason,
    this.activity,
    this.amountPaid = 0,
    this.balanceDue,
    this.stockPurchase = false,
    this.lotId,
    this.credited = 0,
    this.pending = false,
  });

  final String id;
  final String category;
  final String? description;
  final double amount;
  final String currency;
  final double? originalAmount;
  final String? originalCurrency;
  final double? exchangeRate;
  final DateTime incurredAt;
  final String? supplierName;

  /// paid | pending (a bill still to pay)
  final String paymentStatus;
  final DateTime? dueDate;
  final DateTime? paidAt;
  final String? reference;
  final String? notes;
  final String status;
  final String? cancelReason;
  final String? activity;

  /// Paid so far (USD) and still owed (USD at the bill's rate) — v0.8.9.
  final double amountPaid;
  final double? balanceDue;

  /// A supplier's bill for stock received (a feed or medicine delivery).
  final bool stockPurchase;
  final String? lotId;

  /// Taken off by credit notes (goods returned), in the bill's currency.
  final double credited;
  final bool pending;

  bool get cancelled => status == 'cancelled';
  bool get paid => paymentStatus == 'paid';
  bool get partlyPaid => paymentStatus == 'partial';
  bool get toPay => !cancelled && !paid && owed > 0.004;

  /// What is still to pay on it.
  double get owed => cancelled || paid ? 0 : (balanceDue ?? amount);

  /// A bill past its due date, still unpaid.
  bool overdue(DateTime today) {
    final due = dueDate?.toLocal();
    return toPay && due != null && DateTime(due.year, due.month, due.day).isBefore(DateTime(today.year, today.month, today.day));
  }

  factory FinanceExpense.fromJson(Map<String, dynamic> j) => FinanceExpense(
        id: j['id'] as String,
        category: j['category'] as String? ?? 'other',
        description: j['description'] as String?,
        amount: _d(j['amount']),
        currency: j['currency'] as String? ?? 'USD',
        originalAmount: _dn(j['original_amount']),
        originalCurrency: j['original_currency'] as String?,
        exchangeRate: _dn(j['exchange_rate']),
        incurredAt: _t(j['incurred_at']) ?? DateTime.now(),
        supplierName: (j['supplier_name'] ?? j['supplier_label']) as String?,
        paymentStatus: j['payment_status'] as String? ?? 'paid',
        dueDate: _t(j['due_date']),
        paidAt: _t(j['paid_at']),
        reference: j['reference'] as String?,
        notes: j['notes'] as String?,
        status: j['status'] as String? ?? 'recorded',
        cancelReason: j['cancel_reason'] as String?,
        activity: j['activity'] as String?,
        amountPaid: _d(j['amount_paid']),
        balanceDue: _dn(j['balance_due']),
        stockPurchase: j['stock_purchase'] == true,
        lotId: j['lot_id'] as String?,
        credited: _d(j['credited']),
        pending: j['_pending'] == true,
      );
}

/// The LBP rate in force and the ones set before it.
class ExchangeRates {
  const ExchangeRates({this.lbpPerUsd, this.lbpSince, this.history = const []});
  final double? lbpPerUsd;
  final DateTime? lbpSince;
  final List<({double rate, DateTime since, String? notes})> history;

  static const empty = ExchangeRates();

  factory ExchangeRates.fromJson(Map<String, dynamic> j) {
    final lbp = ((j['current'] as Map?)?['LBP'] as Map?)?.cast<String, dynamic>();
    return ExchangeRates(
      lbpPerUsd: _dn(lbp?['rate_per_usd']),
      lbpSince: _t(lbp?['effective_date']),
      history: [
        for (final r in (j['history'] as List<dynamic>? ?? const []))
          if ((r as Map)['currency'] == 'LBP')
            (rate: _d(r['rate_per_usd']), since: _t(r['effective_date']) ?? DateTime.now(), notes: r['notes'] as String?),
      ],
    );
  }
}
