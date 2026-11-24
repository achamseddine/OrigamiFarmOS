import 'package:flutter/foundation.dart';

import '../api/api_client.dart';
import '../domain/entities/finance.dart';

/// Origami's financials (backend /finance/*): every sale, expenses and
/// bills, who owes what, profit and loss, and the USD / LBP rate. Each
/// change is made on the server, which keeps the books; the screens read
/// them back.
class FinanceProvider extends ChangeNotifier {
  FinanceProvider({required ApiClient apiClient}) : _api = apiClient;

  final ApiClient _api;

  List<FinanceSale> sales = [];
  List<FinanceExpense> expenses = [];
  ExchangeRates rates = ExchangeRates.empty;
  Map<String, dynamic>? owed;
  Map<String, dynamic>? profitLoss;
  bool loaded = false;
  String? error;

  /// Sales still to be paid (on record, not cancelled).
  List<FinanceSale> get unpaidSales => [for (final s in sales) if (s.owed) s];

  /// Bills still to pay.
  List<FinanceExpense> get billsToPay => [for (final e in expenses) if (e.toPay) e];

  /// The buyers and suppliers named lately, most recent first — offered on the forms.
  List<String> get recentBuyers => _recent([for (final s in sales) s.buyerName]);
  List<String> get recentSuppliers => _recent([for (final e in expenses) e.supplierName]);

  static List<String> _recent(Iterable<String?> names) {
    final out = <String>[];
    for (final n in names) {
      final v = (n ?? '').trim();
      if (v.isNotEmpty && !out.any((o) => o.toLowerCase() == v.toLowerCase())) out.add(v);
      if (out.length == 6) break;
    }
    return out;
  }

  Future<void> load({bool sales = true, bool expenses = true, bool profitLoss = true}) async {
    error = null;
    await Future.wait([
      _fetch('/finance/exchange-rates', null, (j) => rates = ExchangeRates.fromJson((j as Map).cast<String, dynamic>())),
      if (sales)
        _fetch('/finance/sales', {'days': 365}, (j) => this.sales = [for (final s in j as List<dynamic>) FinanceSale.fromJson((s as Map).cast<String, dynamic>())]),
      if (expenses)
        _fetch('/finance/expenses', {'days': 365},
            (j) => this.expenses = [for (final e in j as List<dynamic>) FinanceExpense.fromJson((e as Map).cast<String, dynamic>())]),
      if (sales || expenses) _fetch('/finance/owed', null, (j) => owed = j is Map ? j.cast<String, dynamic>() : null),
      if (profitLoss) _fetch('/finance/profit-loss', null, (j) => this.profitLoss = j is Map ? j.cast<String, dynamic>() : null),
    ]);
    loaded = true;
    notifyListeners();
  }

  Future<void> _fetch(String path, Map<String, dynamic>? query, void Function(dynamic json) apply) async {
    try {
      apply(await _api.get(path, query: query));
    } on ApiException catch (e) {
      error ??= e.message;
    } catch (_) {
      // Keep what was there.
    }
  }

  Future<WriteResult> _write(Future<dynamic> Function() call) async {
    final result = await _api.write(call);
    if (result.success && !result.queued) await load();
    if (result.success && result.queued) notifyListeners();
    return result;
  }

  /// Any product sold (milk: Sell milk; Mouneh: its shop). [unitPrice]
  /// and [total] are in [currency]; LBP is converted on the server at
  /// [exchangeRate], or the farm's rate for the day when left out.
  Future<WriteResult> recordSale({
    required String productType,
    required String productLabel,
    double? quantity,
    String? unit,
    double? unitPrice,
    double? total,
    String currency = 'USD',
    double? exchangeRate,
    required DateTime soldAt,
    String? buyerName,
    required bool paid,
    String? reference,
    String? notes,
  }) =>
      _write(() => _api.post('/finance/sales', body: {
            'product_type': productType,
            'product_label': productLabel.trim(),
            'quantity': ?quantity,
            if (unit != null && unit.trim().isNotEmpty) 'unit': unit.trim(),
            'unit_price': ?unitPrice,
            'total': ?total,
            'currency': currency,
            'exchange_rate': ?exchangeRate,
            'sold_at': soldAt.toUtc().toIso8601String(),
            if (buyerName != null && buyerName.trim().isNotEmpty) 'buyer_name': buyerName.trim(),
            'payment_status': paid ? 'paid' : 'pending',
            if (reference != null && reference.trim().isNotEmpty) 'reference': reference.trim(),
            if (notes != null && notes.trim().isNotEmpty) 'notes': notes.trim(),
          }));

  Future<WriteResult> markSalePaid(FinanceSale sale) => _write(() => _api.post('/finance/sales/${sale.id}/paid', body: <String, dynamic>{}));

  Future<WriteResult> cancelSale(FinanceSale sale, String reason) =>
      _write(() => _api.post('/finance/sales/${sale.id}/cancel', body: {'reason': reason}));

  /// An expense paid, or a bill to pay by [dueDate].
  Future<WriteResult> recordExpense({
    required String category,
    String? description,
    required double amount,
    String currency = 'USD',
    double? exchangeRate,
    required DateTime incurredAt,
    String? supplierName,
    required bool paid,
    DateTime? dueDate,
    String? reference,
    String? notes,
  }) =>
      _write(() => _api.post('/finance/expenses', body: {
            'category': category,
            if (description != null && description.trim().isNotEmpty) 'description': description.trim(),
            'amount': amount,
            'currency': currency,
            'exchange_rate': ?exchangeRate,
            'incurred_at': incurredAt.toUtc().toIso8601String(),
            if (supplierName != null && supplierName.trim().isNotEmpty) 'supplier_name': supplierName.trim(),
            'payment_status': paid ? 'paid' : 'pending',
            if (!paid && dueDate != null) 'due_date': DateTime.utc(dueDate.year, dueDate.month, dueDate.day, 12).toIso8601String(),
            if (reference != null && reference.trim().isNotEmpty) 'reference': reference.trim(),
            if (notes != null && notes.trim().isNotEmpty) 'notes': notes.trim(),
          }));

  Future<WriteResult> markExpensePaid(FinanceExpense e) => _write(() => _api.post('/finance/expenses/${e.id}/paid', body: <String, dynamic>{}));

  Future<WriteResult> cancelExpense(FinanceExpense e, String reason) =>
      _write(() => _api.post('/finance/expenses/${e.id}/cancel', body: {'reason': reason}));

  /// 1 USD = [lbpPerUsd] LBP from [since] (today when null).
  Future<WriteResult> setRate({required double lbpPerUsd, DateTime? since, String? notes}) =>
      _write(() => _api.post('/finance/exchange-rates', body: {
            'currency': 'LBP',
            'rate_per_usd': lbpPerUsd,
            if (since != null) 'effective_date': '${since.year.toString().padLeft(4, '0')}-${since.month.toString().padLeft(2, '0')}-${since.day.toString().padLeft(2, '0')}',
            if (notes != null && notes.trim().isNotEmpty) 'notes': notes.trim(),
          }));
}
