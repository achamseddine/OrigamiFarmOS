import 'package:flutter/foundation.dart';

import '../api/api_client.dart';
import '../domain/entities/purchase_orders.dart';

/// Buying feed (master prompt Package 2): the suppliers' prices, the
/// orders, the deliveries received against them and each order's match.
/// The server decides who may do what — a worker drafts orders and
/// receives deliveries against an approved one; the manager sets prices
/// and places, closes or cancels orders — and every write is refused there
/// if the person may not.
class PurchaseOrdersProvider extends ChangeNotifier {
  PurchaseOrdersProvider({required ApiClient apiClient}) : _api = apiClient;

  final ApiClient _api;

  List<PurchaseOrder> orders = [];

  /// The farm's suppliers (from Sales & Finance), offered on the forms.
  List<({String id, String name})> suppliers = [];
  bool loaded = false;

  List<PurchaseOrder> get open => [for (final o in orders) if (o.isDraft || o.isOpen) o];
  List<PurchaseOrder> get done => [for (final o in orders) if (!o.isDraft && !o.isOpen) o];

  Future<void> load() async {
    try {
      final json = await _api.get('/procurement/purchase-orders', query: {'limit': 100});
      orders = [for (final o in json as List<dynamic>) PurchaseOrder.fromJson((o as Map).cast<String, dynamic>())];
    } catch (_) {
      // Keep what was there; the card says so when empty.
    }
    try {
      final json = await _api.get('/suppliers');
      suppliers = [for (final s in json as List<dynamic>) (id: '${(s as Map)['id']}', name: '${s['name']}')];
    } catch (_) {
      // Not everyone reads the supplier list; a new name can be typed.
    }
    loaded = true;
    notifyListeners();
  }

  /// Who sells [feedProductId] and for how much — cheapest first.
  Future<List<SupplierQuote>> quotes(String feedProductId) async {
    try {
      final json = await _api.get('/procurement/supplier-items', query: {'feed_product_id': feedProductId});
      return [for (final q in json as List<dynamic>) SupplierQuote.fromJson((q as Map).cast<String, dynamic>())];
    } catch (_) {
      return const [];
    }
  }

  Future<OrderMatch?> match(String orderId) async {
    try {
      return OrderMatch.fromJson((await _api.get('/procurement/purchase-orders/$orderId/match') as Map).cast<String, dynamic>());
    } catch (_) {
      return null;
    }
  }

  Future<WriteResult> _write(Future<dynamic> Function() call) async {
    final result = await _api.write(call);
    if (result.success && !result.queued) await load();
    if (result.success && result.queued) notifyListeners();
    return result;
  }

  Map<String, dynamic> _supplier(String? supplierId, String? supplierName) => {
        if (supplierId != null && supplierId.isNotEmpty) 'supplier_id': supplierId,
        if ((supplierId == null || supplierId.isEmpty) && supplierName != null && supplierName.trim().isNotEmpty) 'supplier_name': supplierName.trim(),
      };

  Future<WriteResult> setQuote({String? supplierId, String? supplierName, required String feedProductId, required double unitPrice, String currency = 'USD', String? unit}) =>
      _write(() => _api.post('/procurement/supplier-items', body: {
            ..._supplier(supplierId, supplierName),
            'feed_product_id': feedProductId,
            'unit_price': unitPrice,
            'currency': currency,
            if (unit != null) 'purchase_uom': unit,
          }));

  Future<WriteResult> createOrder({
    String? supplierId,
    String? supplierName,
    required String feedProductId,
    required double quantity,
    required String unit,
    double? unitPrice,
    String currency = 'USD',
    double? exchangeRate,
    String paymentTerms = 'credit',
    bool approve = false,
    String? requisitionId,
  }) =>
      _write(() => _api.post('/procurement/purchase-orders', body: {
            ..._supplier(supplierId, supplierName),
            'lines': [
              {'feed_product_id': feedProductId, 'quantity': quantity, 'unit': unit, if (unitPrice != null) 'unit_price': unitPrice},
            ],
            'currency': currency,
            if (exchangeRate != null) 'exchange_rate': exchangeRate,
            'payment_terms': paymentTerms,
            'approve': approve,
            if (requisitionId != null) 'requisition_id': requisitionId,
          }));

  Future<WriteResult> approve(PurchaseOrder o) => _write(() => _api.post('/procurement/purchase-orders/${o.id}/approve', body: const {}));

  Future<WriteResult> close(PurchaseOrder o, String reason) => _write(() => _api.post('/procurement/purchase-orders/${o.id}/close', body: {'reason': reason}));

  Future<WriteResult> cancel(PurchaseOrder o, String reason) => _write(() => _api.post('/procurement/purchase-orders/${o.id}/cancel', body: {'reason': reason}));

  /// A delivery against [o]: per line what came, what was rejected and why,
  /// and the quality seen.
  Future<WriteResult> receive(
    PurchaseOrder o, {
    required List<({String lineId, double received, double rejected, String? reason, String quality})> lines,
    String? deliveryNote,
    String? payment,
  }) =>
      _write(() => _api.post('/procurement/purchase-orders/${o.id}/receive', body: {
            'lines': [
              for (final l in lines)
                {
                  'purchase_order_line_id': l.lineId,
                  'received_quantity': l.received,
                  'rejected_quantity': l.rejected,
                  if (l.reason != null && l.reason!.trim().isNotEmpty) 'rejection_reason': l.reason!.trim(),
                  'quality_grade': l.quality,
                },
            ],
            if (deliveryNote != null && deliveryNote.trim().isNotEmpty) 'delivery_note_no': deliveryNote.trim(),
            if (payment != null) 'payment': payment,
          }));
}
