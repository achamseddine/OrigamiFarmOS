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
  });

  final String id;
  final String name;
  final String? cropType;
  final double? areaValue;
  final String? areaUnit;
  final String? stage;
  final DateTime? expectedHarvestDate;
  final double? estYieldKg;

  factory Field.fromJson(Map<String, dynamic> json) => Field(
        id: json['id'] as String,
        name: json['name'] as String,
        cropType: json['crop_type'] as String?,
        areaValue: (json['area_value'] as num?)?.toDouble(),
        areaUnit: json['area_unit'] as String?,
        stage: json['stage'] as String?,
        expectedHarvestDate: json['expected_harvest_date'] != null ? DateTime.parse(json['expected_harvest_date'] as String) : null,
        estYieldKg: (json['est_yield_kg'] as num?)?.toDouble(),
      );
}
