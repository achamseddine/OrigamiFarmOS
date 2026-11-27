/// Ordering feed from suppliers (master prompt Package 2; backend
/// /procurement/supplier-items and /procurement/purchase-orders).
///
/// A supplier's quote is the price it asks now; an order keeps the price it
/// was placed at; what came, what was accepted, billed, paid and owed are
/// the server's — read from its receipts, lots and bills.
class SupplierQuote {
  const SupplierQuote({
    required this.id,
    required this.supplierId,
    required this.supplierName,
    required this.unitPrice,
    required this.currency,
    required this.purchaseUom,
    this.unitPriceUsd,
    this.lastDeliveryUsd,
  });

  final String id;
  final String supplierId;
  final String supplierName;
  final double? unitPrice;
  final String currency;
  final String purchaseUom;

  /// The quote in USD at today's rate (how the list is ordered: cheapest first).
  final double? unitPriceUsd;

  /// What this supplier's last delivery cost, in USD per the feed's unit.
  final double? lastDeliveryUsd;

  factory SupplierQuote.fromJson(Map<String, dynamic> j) => SupplierQuote(
        id: j['id'] as String,
        supplierId: j['supplier_id'] as String,
        supplierName: (j['supplier_name'] as String?) ?? '—',
        unitPrice: (j['unit_price'] as num?)?.toDouble(),
        currency: (j['currency'] as String?) ?? 'USD',
        purchaseUom: (j['purchase_uom'] as String?) ?? 'kg',
        unitPriceUsd: (j['unit_price_usd'] as num?)?.toDouble(),
        lastDeliveryUsd: ((j['last_delivery'] as Map?)?['unit_cost_usd'] as num?)?.toDouble(),
      );
}

class PurchaseOrderLine {
  const PurchaseOrderLine({
    required this.id,
    required this.lineNo,
    required this.feedProductId,
    required this.name,
    required this.orderedQuantity,
    required this.unit,
    required this.unitPrice,
    required this.lineTotal,
    required this.receivedQuantity,
    required this.acceptedQuantity,
    required this.rejectedQuantity,
    required this.remainingQuantity,
    required this.status,
  });

  final String id;
  final int lineNo;
  final String? feedProductId;
  final String name;
  final double orderedQuantity;
  final String unit;
  final double unitPrice;
  final double lineTotal;
  final double receivedQuantity;
  final double acceptedQuantity;
  final double rejectedQuantity;
  final double remainingQuantity;
  final String status;

  static double _d(Object? v) => (v as num?)?.toDouble() ?? 0;

  factory PurchaseOrderLine.fromJson(Map<String, dynamic> j) => PurchaseOrderLine(
        id: j['id'] as String,
        lineNo: (j['line_no'] as num?)?.toInt() ?? 1,
        feedProductId: j['feed_product_id'] as String?,
        name: (j['name'] as String?) ?? '—',
        orderedQuantity: _d(j['ordered_quantity']),
        unit: (j['unit'] as String?) ?? 'kg',
        unitPrice: _d(j['unit_price']),
        lineTotal: _d(j['line_total']),
        receivedQuantity: _d(j['received_quantity']),
        acceptedQuantity: _d(j['accepted_quantity']),
        rejectedQuantity: _d(j['rejected_quantity']),
        remainingQuantity: _d(j['remaining_quantity'] ?? j['ordered_quantity']),
        status: (j['status'] as String?) ?? 'open',
      );
}

class PurchaseOrder {
  const PurchaseOrder({
    required this.id,
    required this.poNo,
    required this.supplierId,
    required this.supplierName,
    required this.status,
    required this.currency,
    required this.paymentTerms,
    required this.totalAmount,
    required this.lines,
    this.requisitionNo,
    this.orderDate,
    this.closedReason,
    this.pending = false,
  });

  final String id;
  final String poNo;
  final String supplierId;
  final String supplierName;

  /// draft | approved | partially_received | received | closed | cancelled
  final String status;
  final String currency;

  /// paid (on each delivery) | credit
  final String paymentTerms;
  final double totalAmount;
  final List<PurchaseOrderLine> lines;
  final String? requisitionNo;
  final DateTime? orderDate;
  final String? closedReason;

  /// Made on this tablet and not on the server yet.
  final bool pending;

  bool get isDraft => status == 'draft';

  /// Deliveries may be received against it.
  bool get isOpen => status == 'approved' || status == 'partially_received';
  bool get anythingReceived => lines.any((l) => l.receivedQuantity > 0);

  factory PurchaseOrder.fromJson(Map<String, dynamic> j) => PurchaseOrder(
        id: j['id'] as String,
        poNo: (j['po_no'] as String?) ?? '…',
        supplierId: (j['supplier_id'] as String?) ?? '',
        supplierName: (j['supplier_name'] as String?) ?? (j['supplier_label'] as String?) ?? '—',
        status: (j['status'] as String?) ?? 'draft',
        currency: (j['currency'] as String?) ?? 'USD',
        paymentTerms: (j['payment_terms'] as String?) ?? 'credit',
        totalAmount: (j['total_amount'] as num?)?.toDouble() ?? 0,
        lines: [for (final l in (j['lines'] as List<dynamic>? ?? const [])) PurchaseOrderLine.fromJson((l as Map).cast<String, dynamic>())],
        requisitionNo: j['requisition_no'] as String?,
        orderDate: DateTime.tryParse('${j['order_date']}'),
        closedReason: j['closed_reason'] as String?,
        pending: j['_pending'] == true,
      );
}

/// What was ordered against what came, was accepted, billed, paid and is
/// owed — the server's match of the order.
class OrderMatch {
  const OrderMatch({required this.state, required this.currency, required this.lines, required this.totals, required this.problems});

  /// awaiting_approval | awaiting_delivery | partly_delivered |
  /// delivered_awaiting_payment | complete | closed_short | cancelled
  final String state;
  final String currency;
  final List<Map<String, dynamic>> lines;
  final Map<String, double> totals;
  final List<String> problems;

  factory OrderMatch.fromJson(Map<String, dynamic> j) => OrderMatch(
        state: (j['state'] as String?) ?? '',
        currency: (j['currency'] as String?) ?? 'USD',
        lines: [for (final l in (j['lines'] as List<dynamic>? ?? const [])) (l as Map).cast<String, dynamic>()],
        totals: {for (final e in ((j['totals'] as Map?) ?? const {}).entries) '${e.key}': (e.value as num?)?.toDouble() ?? 0},
        problems: [for (final p in (j['problems'] as List<dynamic>? ?? const [])) '$p'],
      );
}
