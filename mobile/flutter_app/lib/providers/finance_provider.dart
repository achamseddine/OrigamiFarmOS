import 'dart:async';
import 'package:flutter/foundation.dart';
import '../data/demo/demo_data.dart';
import '../data/local/entity_mappers.dart';
import '../data/remote/api_exception.dart';
import '../data/remote/farmos_api.dart';
import '../data/remote/session_manager.dart';
import '../domain/entities/finance.dart';

/// Today's sales and expenses for the Sales & Finance screen. Starts on
/// [DemoData] (demo mode); [refresh] pulls the real `GET /sales` and
/// `GET /expenses` lists once signed in. Read-only cache — no SQLite
/// table, since nothing here needs to survive being read offline the way
/// an operational write (an observation, a milk record) does; going
/// offline just means this screen shows the last successful fetch.
class FinanceProvider extends ChangeNotifier {
  FinanceProvider({required SessionManager session, required FarmosApi api})
      : _session = session,
        _api = api,
        _sales = List.of(DemoData.salesToday),
        _expenses = List.of(DemoData.expensesToday) {
    unawaited(refresh());
  }

  final SessionManager _session;
  final FarmosApi _api;
  List<Sale> _sales;
  List<Expense> _expenses;

  List<Sale> get salesToday => List.unmodifiable(_sales);
  List<Expense> get expensesToday => List.unmodifiable(_expenses);

  Future<void> refresh() async {
    final farmId = _session.farmId;
    if (!_session.isLoggedIn || farmId == null) return;
    try {
      final sales = await _api.listSales(farmId);
      final expenses = await _api.listExpenses(farmId);
      _sales = sales.map((s) => saleFromJson(s as Map<String, dynamic>)).toList();
      _expenses = expenses.map((e) => expenseFromJson(e as Map<String, dynamic>)).toList();
      notifyListeners();
    } on ApiOfflineException {
      // Keep whatever was last loaded (demo data or a previous fetch).
    } on ApiException {
      // Same: a rejected request shouldn't blank out a working screen.
    }
  }
}
