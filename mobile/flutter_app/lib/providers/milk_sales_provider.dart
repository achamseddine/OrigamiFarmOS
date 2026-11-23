import 'package:flutter/foundation.dart';

import '../api/api_client.dart';
import '../domain/entities/milk_sales.dart';

/// The milk tank and the milk sold from it (backend /production/milk-tank,
/// /production/milk-sales). Selling writes the farm's revenue too, so after
/// a sale the Sales & Finance figures are reloaded by whoever shows them.
class MilkSalesProvider extends ChangeNotifier {
  MilkSalesProvider({required ApiClient apiClient}) : _api = apiClient;

  final ApiClient _api;

  MilkTank tank = MilkTank.empty;
  List<MilkSale> sales = [];
  List<MilkTankAdjustment> adjustments = [];
  bool loaded = false;

  /// Sales still to be paid, and what they come to.
  List<MilkSale> get unpaid => [for (final s in sales) if (!s.cancelled && !s.paid) s];
  double get unpaidAmount => unpaid.fold(0.0, (t, s) => t + s.amount);

  /// The buyers milk was sold to, most recent first — offered on the form.
  List<String> get recentBuyers {
    final out = <String>[];
    for (final s in sales) {
      final b = (s.buyerName ?? '').trim();
      if (b.isNotEmpty && !out.any((o) => o.toLowerCase() == b.toLowerCase())) out.add(b);
    }
    return out.take(6).toList();
  }

  Future<void> load() async {
    await Future.wait([
      _fetch('/production/milk-tank', null, (j) => tank = MilkTank.fromJson(j as Map<String, dynamic>)),
      _fetch('/production/milk-sales', {'days': 90}, (j) => sales = [for (final s in j as List<dynamic>) MilkSale.fromJson(s as Map<String, dynamic>)]),
      _fetch('/production/milk-tank/adjustments', {'days': 90},
          (j) => adjustments = [for (final a in j as List<dynamic>) MilkTankAdjustment.fromJson(a as Map<String, dynamic>)]),
    ]);
    loaded = true;
    notifyListeners();
  }

  Future<void> _fetch(String path, Map<String, dynamic>? query, void Function(dynamic json) apply) async {
    try {
      apply(await _api.get(path, query: query));
    } catch (_) {
      // Keep what was there; the card says the tank is unknown.
    }
  }

  Future<WriteResult> _write(Future<dynamic> Function() call) async {
    final result = await _api.write(call);
    if (result.success && !result.queued) await load();
    if (result.success && result.queued) notifyListeners();
    return result;
  }

  Future<WriteResult> sell({
    required double liters,
    required double pricePerLiter,
    required DateTime soldAt,
    String? buyerName,
    required bool paid,
    String? reference,
    String? notes,
    bool allowNegative = false,
  }) =>
      _write(() => _api.post('/production/milk-sales', body: {
            'liters': liters,
            'price_per_liter': pricePerLiter,
            'sold_at': soldAt.toUtc().toIso8601String(),
            if (buyerName != null && buyerName.trim().isNotEmpty) 'buyer_name': buyerName.trim(),
            'payment_status': paid ? 'paid' : 'pending',
            if (reference != null && reference.trim().isNotEmpty) 'reference': reference.trim(),
            if (notes != null && notes.trim().isNotEmpty) 'notes': notes.trim(),
            if (allowNegative) 'allow_negative': true,
          }));

  Future<WriteResult> markPaid(MilkSale sale) => _write(() => _api.post('/production/milk-sales/${sale.id}/paid'));

  Future<WriteResult> cancel(MilkSale sale, String reason) => _write(() => _api.post('/production/milk-sales/${sale.id}/cancel', body: {'reason': reason}));

  /// Milk out of the tank outside a sale ([liters]), or a count of the
  /// tank ([countedLevel], reason "count").
  Future<WriteResult> adjust({required String reason, double? liters, double? countedLevel, String? notes}) =>
      _write(() => _api.post('/production/milk-tank/adjustments', body: {
            'reason': reason,
            'liters': ?liters,
            'counted_level': ?countedLevel,
            if (notes != null && notes.trim().isNotEmpty) 'notes': notes.trim(),
          }));
}
