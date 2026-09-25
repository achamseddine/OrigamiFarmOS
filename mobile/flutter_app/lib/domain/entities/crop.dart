/// Crop types and plantings (backend `app/schemas/agriculture.py`).
///
/// A crop type is farm data, not a fixed catalog — tech spec §16 is
/// explicit that the platform must not hard-code crop types, because a
/// Lebanese farm's list (freekeh, za'atar, olives) is not the same as
/// anyone else's.
library;

class Crop {
  const Crop({
    required this.id,
    required this.name,
    this.category,
    this.defaultCycleDays,
    this.active = true,
  });

  final String id;
  final String name;
  final String? category;

  /// Typical days from planting to harvest — used to pre-fill an expected
  /// harvest date so the farmer does not have to work it out.
  final int? defaultCycleDays;
  final bool active;

  factory Crop.fromJson(Map<String, dynamic> json) => Crop(
        id: json['id'] as String,
        name: json['name'] as String,
        category: json['category'] as String?,
        defaultCycleDays: json['default_cycle_days'] as int?,
        active: json['active'] as bool? ?? true,
      );
}

class CropPlanting {
  const CropPlanting({
    required this.id,
    required this.fieldId,
    required this.cropId,
    this.variety,
    this.plantedArea,
    this.areaUnit,
    this.plantedDate,
    this.expectedHarvestDate,
    this.expectedYieldKg,
    required this.stage,
    required this.status,
    this.notes,
  });

  final String id;
  final String fieldId;
  final String cropId;
  final String? variety;
  final double? plantedArea;
  final String? areaUnit;
  final DateTime? plantedDate;
  final DateTime? expectedHarvestDate;
  final double? expectedYieldKg;
  final String stage;
  final String status;
  final String? notes;

  int? get daysUntilHarvest =>
      expectedHarvestDate == null ? null : expectedHarvestDate!.difference(DateTime.now()).inDays;

  factory CropPlanting.fromJson(Map<String, dynamic> json) => CropPlanting(
        id: json['id'] as String,
        fieldId: json['field_id'] as String,
        cropId: json['crop_id'] as String,
        variety: json['variety'] as String?,
        plantedArea: (json['planted_area'] as num?)?.toDouble(),
        areaUnit: json['area_unit'] as String?,
        plantedDate: json['planted_date'] != null ? DateTime.parse(json['planted_date'] as String) : null,
        expectedHarvestDate:
            json['expected_harvest_date'] != null ? DateTime.parse(json['expected_harvest_date'] as String) : null,
        expectedYieldKg: (json['expected_yield_kg'] as num?)?.toDouble(),
        stage: json['stage'] as String? ?? 'planted',
        status: json['status'] as String? ?? 'active',
        notes: json['notes'] as String?,
      );
}

const List<String> kPlantingStages = [
  'planted',
  'growing',
  'flowering',
  'developing',
  'ripening',
  'mature',
  'harvested',
];

const List<String> kFieldStatuses = ['active', 'fallow', 'retired'];

const List<String> kCropCategories = ['vegetable', 'fruit', 'tree', 'herb', 'grain', 'other'];

const List<String> kAreaUnits = ['m2', 'dunam', 'hectare', 'acre'];

const List<String> kIrrigationMethods = ['drip', 'sprinkler', 'flood', 'rain_fed', 'manual'];
