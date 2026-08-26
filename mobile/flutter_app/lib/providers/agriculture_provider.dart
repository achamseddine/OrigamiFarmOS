import 'package:flutter/foundation.dart';
import '../api/api_client.dart';
import '../domain/entities/crop.dart';

/// Fields, crop types, plantings and daily harvest (tech spec §14–§17).
///
/// Fields themselves are read through [ProductionProvider] (they back the
/// Produce screen's field cards); this provider owns the agricultural
/// *writes* and the crop/planting data that has no other home.
class AgricultureProvider extends ChangeNotifier {
  AgricultureProvider({required ApiClient apiClient}) : _api = apiClient;

  final ApiClient _api;
  List<Crop> _crops = [];
  List<CropPlanting> _plantings = [];
  bool loading = false;

  List<Crop> get crops => List.unmodifiable(_crops);
  List<CropPlanting> get plantings => List.unmodifiable(_plantings);

  List<CropPlanting> plantingsForField(String fieldId) => _plantings.where((p) => p.fieldId == fieldId).toList();

  Crop? cropById(String id) {
    for (final c in _crops) {
      if (c.id == id) return c;
    }
    return null;
  }

  String cropName(String id) => cropById(id)?.name ?? id;

  Future<void> load() async {
    loading = true;
    notifyListeners();
    try {
      final results = await Future.wait([
        _api.get('/crops'),
        _api.get('/crop-plantings'),
      ]);
      _crops = (results[0] as List<dynamic>).map((e) => Crop.fromJson(e as Map<String, dynamic>)).toList();
      _plantings = (results[1] as List<dynamic>).map((e) => CropPlanting.fromJson(e as Map<String, dynamic>)).toList();
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  // ------------------------------------------------------------- Fields
  Future<WriteResult> createField(Map<String, dynamic> body) async {
    return _api.write(() => _api.post('/fields', body: body));
  }

  Future<WriteResult> updateField(String fieldId, Map<String, dynamic> body) async {
    return _api.write(() => _api.patch('/fields/$fieldId', body: body));
  }

  // -------------------------------------------------------- Crop types
  /// Tech spec §16: crop types are farm data, so an authorized user adds
  /// whatever this farm actually grows rather than picking from a list
  /// baked into the app.
  Future<WriteResult> createCrop({required String name, String? category, int? defaultCycleDays}) async {
    final result = await _api.write(() => _api.post('/crops', body: {
          'name': name,
          'category': category,
          'default_cycle_days': defaultCycleDays,
        }));
    if (result.success) await load();
    return result;
  }

  Future<WriteResult> archiveCrop(String cropId) async {
    final result = await _api.write(() => _api.delete('/crops/$cropId'));
    if (result.success) await load();
    return result;
  }

  // ---------------------------------------------------------- Plantings
  Future<WriteResult> createPlanting(Map<String, dynamic> body) async {
    final result = await _api.write(() => _api.post('/crop-plantings', body: body));
    if (result.success) await load();
    return result;
  }

  Future<WriteResult> updatePlanting(String plantingId, Map<String, dynamic> body) async {
    final result = await _api.write(() => _api.patch('/crop-plantings/$plantingId', body: body));
    if (result.success) await load();
    return result;
  }

  // ------------------------------------------------------------ Harvest
  /// Records the day's pick (tech spec §17). The backend moves the
  /// sellable part into real inventory, so the Produce screen's
  /// "ready for sale" figure is stock that exists.
  Future<WriteResult> recordHarvest({
    required String fieldId,
    String? plantingId,
    String? cropId,
    String? productName,
    required double totalQuantity,
    double? sellableQuantity,
    double wasteQuantity = 0,
    String unit = 'kg',
    String? destination,
    String? notes,
  }) async {
    final result = await _api.write(() => _api.post('/harvest', body: {
          'field_id': fieldId,
          'planting_id': plantingId,
          'crop_id': cropId,
          'product_name': productName,
          'total_quantity': totalQuantity,
          'sellable_quantity': sellableQuantity,
          'waste_quantity': wasteQuantity,
          'unit': unit,
          'destination': destination,
          'notes': notes,
        }));
    if (result.success) await load();
    return result;
  }
}
