import 'package:flutter/foundation.dart';
import '../api/api_client.dart';

class SaleRecord {
  const SaleRecord({required this.id, this.productLabel, required this.productType, required this.amount, required this.paymentStatus, required this.soldAt});
  final String id;
  final String? productLabel;
  final String productType;
  final double amount;
  final String paymentStatus;
  final DateTime soldAt;

  factory SaleRecord.fromJson(Map<String, dynamic> json) => SaleRecord(
        id: json['id'] as String,
        productLabel: json['product_label'] as String?,
        productType: json['product_type'] as String,
        amount: (json['amount'] as num).toDouble(),
        paymentStatus: json['payment_status'] as String,
        soldAt: DateTime.parse(json['sold_at'] as String),
      );
}

class ExpenseRecord {
  const ExpenseRecord({required this.id, required this.category, required this.amount, required this.incurredAt});
  final String id;
  final String category;
  final double amount;
  final DateTime incurredAt;

  factory ExpenseRecord.fromJson(Map<String, dynamic> json) => ExpenseRecord(
        id: json['id'] as String,
        category: json['category'] as String,
        amount: (json['amount'] as num).toDouble(),
        incurredAt: DateTime.parse(json['incurred_at'] as String),
      );
}

/// Sales & Finance (manager-only). `dailySummary` is the backend's own
/// aggregation (today's revenue/expenses/margin/breakdowns/insights —
/// see reports_service.build_daily_summary); the raw sale/expense lists
/// are only fetched to build a simple day-by-day profit trend, since the
/// summary endpoint is a single-day snapshot.
class SalesProvider extends ChangeNotifier {
  SalesProvider({required ApiClient apiClient, required String farmId})
      : _api = apiClient,
        _farmId = farmId;

  final ApiClient _api;
  final String _farmId;
  Map<String, dynamic>? dailySummary;
  List<SaleRecord> _sales = [];
  List<ExpenseRecord> _expenses = [];
  bool loading = false;

  double get revenueToday => (dailySummary?['revenue_today'] as num?)?.toDouble() ?? 0;
  double get expensesToday => (dailySummary?['expenses_today'] as num?)?.toDouble() ?? 0;
  double get grossMargin => (dailySummary?['gross_margin'] as num?)?.toDouble() ?? 0;
  double get cashCollected => (dailySummary?['cash_collected'] as num?)?.toDouble() ?? 0;
  double get pendingPayments => (dailySummary?['pending_payments'] as num?)?.toDouble() ?? 0;
  List<Map<String, dynamic>> get topSellingProducts => List<Map<String, dynamic>>.from(dailySummary?['top_selling_products'] as List? ?? []);
  List<String> get businessInsights => List<String>.from(dailySummary?['business_insights'] as List? ?? []);

  List<double> profitTrend7Days() {
    final today = DateTime.now();
    final start = DateTime(today.year, today.month, today.day).subtract(const Duration(days: 6));
    final buckets = List<double>.filled(7, 0);
    for (final s in _sales) {
      final idx = DateTime(s.soldAt.year, s.soldAt.month, s.soldAt.day).difference(start).inDays;
      if (idx >= 0 && idx < 7) buckets[idx] += s.amount;
    }
    for (final e in _expenses) {
      final idx = DateTime(e.incurredAt.year, e.incurredAt.month, e.incurredAt.day).difference(start).inDays;
      if (idx >= 0 && idx < 7) buckets[idx] -= e.amount;
    }
    return buckets;
  }

  Future<void> load() async {
    loading = true;
    notifyListeners();
    try {
      final results = await Future.wait([
        _api.get('/reports/daily-summary', query: {'farm_id': _farmId}),
        _api.get('/sales', query: {'farm_id': _farmId}),
        _api.get('/expenses', query: {'farm_id': _farmId}),
      ]);
      dailySummary = results[0] as Map<String, dynamic>;
      _sales = (results[1] as List<dynamic>).map((e) => SaleRecord.fromJson(e as Map<String, dynamic>)).toList();
      _expenses = (results[2] as List<dynamic>).map((e) => ExpenseRecord.fromJson(e as Map<String, dynamic>)).toList();
    } finally {
      loading = false;
      notifyListeners();
    }
  }
}
