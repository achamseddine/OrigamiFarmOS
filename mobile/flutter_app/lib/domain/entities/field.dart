enum FieldStage { planted, growing, flowering, ripening, developing, mature }

class Field {
  const Field({
    required this.id,
    required this.name,
    required this.cropType,
    required this.stage,
    required this.estYieldKg,
    required this.nextHarvest,
    required this.healthLabel,
    this.photoPath,
  });

  final String id;
  final String name;
  final String cropType;
  final FieldStage stage;
  final double estYieldKg;
  final DateTime nextHarvest;
  final String healthLabel;
  final String? photoPath;

  String get stageLabel {
    switch (stage) {
      case FieldStage.planted:
        return 'Planted';
      case FieldStage.growing:
        return 'Growing';
      case FieldStage.flowering:
        return 'Flowering';
      case FieldStage.ripening:
        return 'Ripening';
      case FieldStage.developing:
        return 'Developing';
      case FieldStage.mature:
        return 'Mature';
    }
  }
}

class HarvestCalendarEntry {
  const HarvestCalendarEntry({
    required this.crop,
    required this.fieldLabel,
    required this.startDay,
    required this.span,
  });

  final String crop;
  final String fieldLabel;
  final int startDay; // index within the visible calendar window
  final int span; // number of days
}
