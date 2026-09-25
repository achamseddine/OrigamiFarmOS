/// Mirrors the backend's `FieldOut` (schemas/production.py) — every field
/// past `id`/`name` is optional because the real `fields` table leaves
/// them nullable; there is no fabricated "health label", since the
/// backend has no signal for one.
class Field {
  const Field({
    required this.id,
    required this.name,
    this.cropType,
    this.areaValue,
    this.areaUnit,
    this.stage,
    this.expectedHarvestDate,
    this.estYieldKg,
    this.fieldCode,
    this.locationLabel,
    this.soilType,
    this.irrigationMethod,
    this.status = 'active',
    this.notes,
  });

  final String id;
  final String name;
  final String? cropType;
  final double? areaValue;
  final String? areaUnit;
  final String? stage;
  final DateTime? expectedHarvestDate;
  final double? estYieldKg;
  final String? fieldCode;
  final String? locationLabel;
  final String? soilType;
  final String? irrigationMethod;
  final String status;
  final String? notes;

  /// "4,200 m²" — the label the Produce screen shows under a field's name.
  String? get areaLabel {
    if (areaValue == null) return null;
    final unit = switch (areaUnit) {
      'm2' => 'm²',
      'dunam' => 'dunam',
      'hectare' => 'ha',
      'acre' => 'ac',
      _ => areaUnit ?? '',
    };
    final value = areaValue! % 1 == 0 ? areaValue!.toStringAsFixed(0) : areaValue!.toStringAsFixed(1);
    return '$value $unit'.trim();
  }

  factory Field.fromJson(Map<String, dynamic> json) => Field(
        id: json['id'] as String,
        name: json['name'] as String,
        cropType: json['crop_type'] as String?,
        areaValue: (json['area_value'] as num?)?.toDouble(),
        areaUnit: json['area_unit'] as String?,
        stage: json['stage'] as String?,
        expectedHarvestDate: json['expected_harvest_date'] != null ? DateTime.parse(json['expected_harvest_date'] as String) : null,
        estYieldKg: (json['est_yield_kg'] as num?)?.toDouble(),
        fieldCode: json['field_code'] as String?,
        locationLabel: json['location_label'] as String?,
        soilType: json['soil_type'] as String?,
        irrigationMethod: json['irrigation_method'] as String?,
        status: json['status'] as String? ?? 'active',
        notes: json['notes'] as String?,
      );
}
