import 'package:flutter/foundation.dart';

import '../api/api_client.dart';

/// A period of farm days, both ends included.
@immutable
class ReportPeriod {
  const ReportPeriod(this.start, this.end);

  final DateTime start;
  final DateTime end;

  static DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

  factory ReportPeriod.lastDays(int days, {DateTime? today}) {
    final t = _day(today ?? DateTime.now());
    return ReportPeriod(t.subtract(Duration(days: days - 1)), t);
  }

  factory ReportPeriod.thisMonth({DateTime? today}) {
    final t = _day(today ?? DateTime.now());
    return ReportPeriod(DateTime(t.year, t.month), t);
  }

  factory ReportPeriod.lastMonth({DateTime? today}) {
    final t = _day(today ?? DateTime.now());
    final first = DateTime(t.year, t.month - 1);
    return ReportPeriod(first, DateTime(t.year, t.month).subtract(const Duration(days: 1)));
  }

  int get days => _day(end).difference(_day(start)).inDays + 1;

  String get startIso => _iso(start);
  String get endIso => _iso(end);

  static String _iso(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  String get key => '$startIso..$endIso';

  @override
  bool operator ==(Object other) => other is ReportPeriod && other.key == key;

  @override
  int get hashCode => key.hashCode;
}

/// The farm's reports (backend GET /reports/{milk,feed,herd,finance}):
/// computed by the server from the records for a period; the last answer
/// for each report and period is kept, so a report read once is there
/// offline too (the API client's cache).
class ReportsProvider extends ChangeNotifier {
  ReportsProvider({required ApiClient apiClient}) : _api = apiClient;

  final ApiClient _api;
  final Map<String, Map<String, dynamic>> _reports = {};
  final Map<String, String> _errors = {};
  final Set<String> _loading = {};

  static String _key(String kind, ReportPeriod p) => '$kind:${p.key}';

  Map<String, dynamic>? report(String kind, ReportPeriod p) => _reports[_key(kind, p)];
  String? error(String kind, ReportPeriod p) => _errors[_key(kind, p)];
  bool loading(String kind, ReportPeriod p) => _loading.contains(_key(kind, p));

  Future<void> load(String kind, ReportPeriod p, {bool force = false}) async {
    final key = _key(kind, p);
    if (_loading.contains(key) || (!force && _reports.containsKey(key))) return;
    _loading.add(key);
    _errors.remove(key);
    notifyListeners();
    try {
      final body = await _api.get('/reports/$kind', query: {'start': p.startIso, 'end': p.endIso});
      if (body is Map) {
        _reports[key] = body.cast<String, dynamic>();
      } else {
        _errors[key] = 'empty';
      }
    } on ApiException catch (e) {
      _errors[key] = e.message;
    } catch (e) {
      _errors[key] = '$e';
    } finally {
      _loading.remove(key);
      notifyListeners();
    }
  }
}
