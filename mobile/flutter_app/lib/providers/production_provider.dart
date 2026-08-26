import 'package:flutter/foundation.dart';
import '../api/api_client.dart';
import '../domain/entities/field.dart';
import '../domain/entities/production_records.dart';

/// Milk, egg, harvest and field history — backs the Milk/Egg/Produce
/// screens' trend charts and "today" totals with real recorded data
/// instead of a static demo dataset.
class ProductionProvider extends ChangeNotifier {
  ProductionProvider({required ApiClient apiClient, required String farmId})
      : _api = apiClient,
        _farmId = farmId;

  final ApiClient _api;
  final String _farmId;
  List<Field> _fields = [];
  List<MilkRecord> _milk = [];
  List<EggRecord> _eggs = [];
  List<HarvestRecord> _harvest = [];
  bool loading = false;

  List<Field> get fields => List.unmodifiable(_fields);
  List<MilkRecord> get milkRecords => List.unmodifiable(_milk);
  List<EggRecord> get eggRecords => List.unmodifiable(_eggs);
  List<HarvestRecord> get harvestRecords => List.unmodifiable(_harvest);
  Field? fieldById(String id) {
    for (final f in _fields) {
      if (f.id == id) return f;
    }
    return null;
  }

  bool _isToday(DateTime d) {
    final now = DateTime.now();
    return d.year == now.year && d.month == now.month && d.day == now.day;
  }

  double get milkTodayL => _milk.where((r) => _isToday(r.recordedAt)).fold(0.0, (sum, r) => sum + r.liters);
  int get eggsToday => _eggs.where((r) => _isToday(r.recordedAt)).fold(0, (sum, r) => sum + r.totalEggs);

  /// One point per of the last [days] days, oldest first — for a simple
  /// trend sparkline; a day with no records is 0, not omitted.
  List<double> milkByDay({int days = 7}) => _sumByDay(_milk.map((r) => (r.recordedAt, r.liters)), days);
  List<double> eggsByDay({int days = 7}) => _sumByDay(_eggs.map((r) => (r.recordedAt, r.totalEggs.toDouble())), days);

  List<double> _sumByDay(Iterable<(DateTime, double)> points, int days) {
    final today = DateTime.now();
    final start = DateTime(today.year, today.month, today.day).subtract(Duration(days: days - 1));
    final buckets = List<double>.filled(days, 0);
    for (final (date, value) in points) {
      final dayIndex = DateTime(date.year, date.month, date.day).difference(start).inDays;
      if (dayIndex >= 0 && dayIndex < days) buckets[dayIndex] += value;
    }
    return buckets;
  }

  Future<void> load() async {
    loading = true;
    notifyListeners();
    try {
      final results = await Future.wait([
        _api.get('/production/fields', query: {'farm_id': _farmId}),
        _api.get('/production/milk', query: {'farm_id': _farmId, 'days': 30}),
        _api.get('/production/eggs', query: {'farm_id': _farmId, 'days': 30}),
        _api.get('/production/harvest', query: {'farm_id': _farmId, 'days': 90}),
      ]);
      _fields = (results[0] as List<dynamic>).map((e) => Field.fromJson(e as Map<String, dynamic>)).toList();
      _milk = (results[1] as List<dynamic>).map((e) => MilkRecord.fromJson(e as Map<String, dynamic>)).toList();
      _eggs = (results[2] as List<dynamic>).map((e) => EggRecord.fromJson(e as Map<String, dynamic>)).toList();
      _harvest = (results[3] as List<dynamic>).map((e) => HarvestRecord.fromJson(e as Map<String, dynamic>)).toList();
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<WriteResult> recordMilk({required String animalId, required String session, required double liters, String destination = 'stored'}) async {
    final result = await _api.write(() => _api.post('/production/milk', body: {'animal_id': animalId, 'session': session, 'liters': liters, 'destination': destination}));
    if (result.success) await load();
    return result;
  }

  Future<WriteResult> recordEggs({required String flockId, required int totalEggs, int sellableEggs = 0, int brokenEggs = 0, int consumed = 0, int hatched = 0, int wasted = 0}) async {
    final result = await _api.write(() => _api.post('/production/eggs', body: {
          'flock_id': flockId,
          'total_eggs': totalEggs,
          'sellable_eggs': sellableEggs,
          'broken_eggs': brokenEggs,
          'consumed': consumed,
          'hatched': hatched,
          'wasted': wasted,
        }));
    if (result.success) await load();
    return result;
  }

  Future<WriteResult> recordHarvest({required String fieldId, required String productName, required double quantity, String unit = 'kg', double wasteQty = 0, String? destination}) async {
    final result = await _api.write(() => _api.post('/production/harvest', body: {
          'field_id': fieldId,
          'product_name': productName,
          'quantity': quantity,
          'unit': unit,
          'waste_qty': wasteQty,
          'destination': destination,
        }));
    if (result.success) await load();
    return result;
  }
}
