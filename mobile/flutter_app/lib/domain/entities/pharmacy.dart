/// The farm pharmacy as the tablet reads it
/// (database/MEDICINE-PHARMACY-SCHEMA.md): what the farm owns, in which
/// lot and until when, what is *eligible* to use, the manager's own
/// essential-stock thresholds, the alerts those produce, and every dose
/// bound to the exact lot it came from.
///
/// Stock figures are the server's: eligible is computed from lot facts,
/// never kept on the tablet. A stock alert is a logistics finding, not
/// treatment advice.
library;

double? _dn(Object? v) => (v as num?)?.toDouble();
double _d(Object? v, [double fallback = 0]) => (v as num?)?.toDouble() ?? fallback;
int _i(Object? v, [int fallback = 0]) => (v as num?)?.toInt() ?? fallback;
DateTime? _dt(Object? v) => v == null ? null : DateTime.tryParse(v as String);
List<Map<String, dynamic>> _maps(Object? v) => [for (final e in v as List<dynamic>? ?? const []) e as Map<String, dynamic>];
List<String> _strings(Object? v) => [for (final e in v as List<dynamic>? ?? const []) e.toString()];
Map<String, dynamic> _map(Object? v) => (v as Map<String, dynamic>?) ?? const {};

/// `GET /pharmacy/summary`.
class PharmacySummary {
  const PharmacySummary({
    required this.medicines,
    required this.essential,
    required this.byStatus,
    required this.openAlerts,
    required this.unseenAlerts,
    required this.alertsByType,
    required this.expiringSoon,
    required this.storageExceptions,
    required this.openRequisitions,
  });

  final int medicines;
  final int essential;
  final Map<String, int> byStatus;
  final int openAlerts;
  final int unseenAlerts;
  final Map<String, int> alertsByType;
  final int expiringSoon;
  final int storageExceptions;
  final int openRequisitions;

  static const empty = PharmacySummary(medicines: 0, essential: 0, byStatus: {}, openAlerts: 0, unseenAlerts: 0, alertsByType: {}, expiringSoon: 0, storageExceptions: 0, openRequisitions: 0);

  /// Medicines below the farm's own minimum, critical or out.
  int get short => (byStatus['LOW'] ?? 0) + (byStatus['CRITICAL'] ?? 0) + (byStatus['OUT'] ?? 0);

  factory PharmacySummary.fromJson(Map<String, dynamic> json) => PharmacySummary(
        medicines: _i(json['medicines']),
        essential: _i(json['essential']),
        byStatus: {for (final e in _map(json['by_status']).entries) e.key: _i(e.value)},
        openAlerts: _i(json['open_alerts']),
        unseenAlerts: _i(json['unseen_alerts']),
        alertsByType: {for (final e in _map(json['alerts_by_type']).entries) e.key: _i(e.value)},
        expiringSoon: _i(json['expiring_soon']),
        storageExceptions: _i(json['storage_exceptions']),
        openRequisitions: _i(json['open_requisitions']),
      );
}

class MedicineCategory {
  const MedicineCategory({required this.id, required this.code, required this.name, this.nameAr});
  final String id;
  final String code;
  final String name;
  final String? nameAr;

  String label(String lang) => lang == 'ar' && nameAr != null && nameAr!.isNotEmpty ? nameAr! : name;

  factory MedicineCategory.fromJson(Map<String, dynamic> json) =>
      MedicineCategory(id: json['id'] as String, code: json['code'] as String, name: json['name'] as String? ?? '', nameAr: json['name_ar'] as String?);
}

/// One lot of a medicine: what it holds, until when, and — when it does
/// not count — why.
class MedicineLot {
  const MedicineLot({
    required this.id,
    required this.inventoryItemId,
    required this.lotCode,
    required this.sourceType,
    this.supplierLabel,
    this.locationId,
    this.receivedAt,
    this.expiryDate,
    required this.receivedQuantity,
    required this.acceptedQuantity,
    required this.rejectedQuantity,
    required this.quantityOnHand,
    required this.unit,
    this.unitCost,
    required this.status,
    required this.eligible,
    this.ineligibleReason,
    this.openedAt,
    this.useByAfterOpening,
    required this.storageStatus,
    required this.coldChainException,
    this.storageNote,
    this.quarantineReason,
    this.recalledAt,
    this.recallReference,
    this.reference,
    this.notes,
  });

  final String id;
  final String inventoryItemId;
  final String lotCode;
  final String sourceType;
  final String? supplierLabel;
  final String? locationId;
  final DateTime? receivedAt;
  final DateTime? expiryDate;
  final double receivedQuantity;
  final double acceptedQuantity;
  final double rejectedQuantity;
  final double quantityOnHand;
  final String unit;
  final double? unitCost;
  final String status;
  final bool eligible;
  final String? ineligibleReason;
  final DateTime? openedAt;
  final DateTime? useByAfterOpening;
  final String storageStatus;
  final bool coldChainException;
  final String? storageNote;
  final String? quarantineReason;
  final DateTime? recalledAt;
  final String? recallReference;
  final String? reference;
  final String? notes;

  /// The date the lot stops counting: the earlier of its expiry and its
  /// after-opening use-by.
  DateTime? get effectiveExpiry {
    if (expiryDate == null) return useByAfterOpening;
    if (useByAfterOpening == null) return expiryDate;
    return useByAfterOpening!.isBefore(expiryDate!) ? useByAfterOpening : expiryDate;
  }

  factory MedicineLot.fromJson(Map<String, dynamic> json) => MedicineLot(
        id: json['id'] as String,
        inventoryItemId: json['inventory_item_id'] as String? ?? '',
        lotCode: json['lot_code'] as String? ?? '',
        sourceType: json['source_type'] as String? ?? 'purchased',
        supplierLabel: json['supplier_label'] as String?,
        locationId: json['location_id'] as String?,
        receivedAt: _dt(json['received_at']),
        expiryDate: _dt(json['expiry_date']),
        receivedQuantity: _d(json['received_quantity']),
        acceptedQuantity: _d(json['accepted_quantity']),
        rejectedQuantity: _d(json['rejected_quantity']),
        quantityOnHand: _d(json['quantity_on_hand']),
        unit: json['unit'] as String? ?? '',
        unitCost: _dn(json['unit_cost']),
        status: json['status'] as String? ?? 'active',
        eligible: json['eligible'] as bool? ?? false,
        ineligibleReason: json['ineligible_reason'] as String?,
        openedAt: _dt(json['opened_at']),
        useByAfterOpening: _dt(json['use_by_after_opening']),
        storageStatus: json['storage_status'] as String? ?? 'COMPLIANT',
        coldChainException: json['cold_chain_exception'] as bool? ?? false,
        storageNote: json['storage_note'] as String?,
        quarantineReason: json['quarantine_reason'] as String?,
        recalledAt: _dt(json['recalled_at']),
        recallReference: json['recall_reference'] as String?,
        reference: json['reference'] as String?,
        notes: json['notes'] as String?,
      );
}

/// The farm's own thresholds for one medicine (§5): configuration, never
/// medical advice.
class PharmacyPolicy {
  const PharmacyPolicy({
    required this.id,
    required this.inventoryItemId,
    this.locationId,
    required this.essential,
    this.minimum,
    this.target,
    this.critical,
    this.minimumDaysCover,
    this.leadTimeDays,
    required this.alertEnabled,
    required this.expiryWarningDays,
    required this.autoDraftRequisition,
    required this.active,
    required this.version,
  });

  final String id;
  final String inventoryItemId;
  final String? locationId;
  final bool essential;
  final double? minimum;
  final double? target;
  final double? critical;
  final double? minimumDaysCover;
  final double? leadTimeDays;
  final bool alertEnabled;
  final int expiryWarningDays;
  final bool autoDraftRequisition;
  final bool active;
  final int version;

  factory PharmacyPolicy.fromJson(Map<String, dynamic> json) => PharmacyPolicy(
        id: json['id'] as String,
        inventoryItemId: json['inventory_item_id'] as String? ?? '',
        locationId: json['location_id'] as String?,
        essential: json['essential'] as bool? ?? false,
        minimum: _dn(json['minimum_stock_base']),
        target: _dn(json['target_stock_base']),
        critical: _dn(json['critical_stock_base']),
        minimumDaysCover: _dn(json['minimum_days_cover']),
        leadTimeDays: _dn(json['lead_time_days']),
        alertEnabled: json['alert_enabled'] as bool? ?? true,
        expiryWarningDays: _i(json['expiry_warning_days'], 60),
        autoDraftRequisition: json['auto_draft_requisition'] as bool? ?? false,
        active: json['active'] as bool? ?? true,
        version: _i(json['version'], 1),
      );
}

/// A deduplicated pharmacy finding (§8). Acknowledging records that it
/// was seen; only the stock condition clearing (or an explained close)
/// resolves it.
class PharmacyAlert {
  const PharmacyAlert({
    required this.id,
    required this.inventoryItemId,
    this.medicineName,
    this.unit,
    required this.alertType,
    required this.severity,
    required this.status,
    this.detectedAt,
    this.eligible,
    this.minimum,
    this.target,
    this.earliestExpiry,
    this.expiringQuantity,
    this.recommendedReorder,
    required this.explanation,
    this.acknowledgedAt,
    this.resolvedAt,
    this.resolutionNote,
    this.requisitionTaskId,
  });

  final String id;
  final String inventoryItemId;
  final String? medicineName;
  final String? unit;
  final String alertType;
  final String severity;
  final String status;
  final DateTime? detectedAt;
  final double? eligible;
  final double? minimum;
  final double? target;
  final DateTime? earliestExpiry;
  final double? expiringQuantity;
  final double? recommendedReorder;
  final String explanation;
  final DateTime? acknowledgedAt;
  final DateTime? resolvedAt;
  final String? resolutionNote;
  final String? requisitionTaskId;

  bool get isOpen => status == 'open';
  bool get isResolved => status == 'resolved';

  /// A shortage the buyer can act on with a draft requisition.
  bool get isShortage => const {'BELOW_MINIMUM_STOCK', 'CRITICAL_STOCK', 'OUT_OF_STOCK', 'LOW_DAYS_COVER'}.contains(alertType);

  factory PharmacyAlert.fromJson(Map<String, dynamic> json) => PharmacyAlert(
        id: json['id'] as String,
        inventoryItemId: json['inventory_item_id'] as String? ?? '',
        medicineName: json['medicine_name'] as String?,
        unit: json['unit'] as String?,
        alertType: json['alert_type'] as String? ?? '',
        severity: json['severity'] as String? ?? 'medium',
        status: json['status'] as String? ?? 'open',
        detectedAt: _dt(json['detected_at']),
        eligible: _dn(json['eligible_available_base']),
        minimum: _dn(json['minimum_stock_base']),
        target: _dn(json['target_stock_base']),
        earliestExpiry: _dt(json['earliest_expiry_date']),
        expiringQuantity: _dn(json['expiring_quantity']),
        recommendedReorder: _dn(json['recommended_reorder_base']),
        explanation: json['explanation'] as String? ?? '',
        acknowledgedAt: _dt(json['acknowledged_at']),
        resolvedAt: _dt(json['resolved_at']),
        resolutionNote: json['resolution_note'] as String?,
        requisitionTaskId: json['requisition_task_id'] as String?,
      );
}

/// One dose actually given, bound to the exact lot (§11).
class MedicationAdministration {
  const MedicationAdministration({
    required this.id,
    required this.subjectType,
    required this.subjectId,
    this.subjectName,
    this.species,
    this.treatmentId,
    this.protocolRunStepId,
    required this.inventoryItemId,
    this.medicineName,
    required this.lotId,
    this.lotCode,
    required this.doseQuantity,
    required this.doseUnit,
    required this.routeCode,
    required this.headCount,
    required this.quantityConsumed,
    required this.unit,
    this.administeredAt,
    this.administeredByName,
    this.withdrawalMilkUntil,
    this.withdrawalMeatUntil,
    this.reason,
    this.notes,
    required this.status,
  });

  final String id;
  final String subjectType;
  final String subjectId;
  final String? subjectName;
  final String? species;
  final String? treatmentId;
  final String? protocolRunStepId;
  final String inventoryItemId;
  final String? medicineName;
  final String lotId;
  final String? lotCode;
  final double doseQuantity;
  final String doseUnit;
  final String routeCode;
  final int headCount;
  final double quantityConsumed;
  final String unit;
  final DateTime? administeredAt;
  final String? administeredByName;
  final DateTime? withdrawalMilkUntil;
  final DateTime? withdrawalMeatUntil;
  final String? reason;
  final String? notes;
  final String status;

  bool get isReversed => status == 'reversed';

  factory MedicationAdministration.fromJson(Map<String, dynamic> json) => MedicationAdministration(
        id: json['id'] as String,
        subjectType: json['subject_type'] as String? ?? 'animal',
        subjectId: json['subject_id'] as String? ?? '',
        subjectName: json['subject_name'] as String?,
        species: json['species'] as String?,
        treatmentId: json['treatment_id'] as String?,
        protocolRunStepId: json['protocol_run_step_id'] as String?,
        inventoryItemId: json['inventory_item_id'] as String? ?? '',
        medicineName: json['medicine_name'] as String?,
        lotId: json['inventory_lot_id'] as String? ?? '',
        lotCode: json['lot_code'] as String?,
        doseQuantity: _d(json['dose_quantity']),
        doseUnit: json['dose_unit'] as String? ?? '',
        routeCode: json['route_code'] as String? ?? '',
        headCount: _i(json['head_count'], 1),
        quantityConsumed: _d(json['quantity_consumed']),
        unit: json['unit'] as String? ?? '',
        administeredAt: _dt(json['administered_at']),
        administeredByName: json['administered_by_name'] as String?,
        withdrawalMilkUntil: _dt(json['withdrawal_milk_until']),
        withdrawalMeatUntil: _dt(json['withdrawal_meat_until']),
        reason: json['reason'] as String?,
        notes: json['notes'] as String?,
        status: json['status'] as String? ?? 'recorded',
      );
}

/// A stocked medicine with its live stock picture (§10): the dashboard
/// row, and — from the detail endpoint — its lots, policies, alerts and
/// recent administrations.
class Medicine {
  const Medicine({
    required this.inventoryItemId,
    required this.name,
    required this.unit,
    this.genericName,
    this.brandName,
    required this.dosageForm,
    this.strengthValue,
    this.strengthUom,
    required this.routes,
    required this.prescriptionRequired,
    required this.antimicrobial,
    required this.controlled,
    required this.coldChainRequired,
    this.openedShelfLifeDays,
    this.defaultPackSize,
    this.packUom,
    required this.speciesCodes,
    required this.withdrawalRules,
    required this.active,
    required this.categoryCodes,
    required this.categoryNames,
    required this.eligibleAvailable,
    required this.onHand,
    required this.expired,
    required this.quarantined,
    required this.storageExceptionQuantity,
    required this.lotCount,
    this.earliestExpiry,
    required this.expiringQuantity,
    required this.storageException,
    required this.status,
    this.policy,
    required this.recommendedReorder,
    required this.openAlerts,
    required this.openRequisition,
    required this.averageDailyUse,
    required this.lots,
    required this.alerts,
    required this.administrations,
  });

  final String inventoryItemId;
  final String name;
  final String unit;
  final String? genericName;
  final String? brandName;
  final String dosageForm;
  final double? strengthValue;
  final String? strengthUom;
  final List<String> routes;
  final bool prescriptionRequired;
  final bool antimicrobial;
  final bool controlled;
  final bool coldChainRequired;
  final int? openedShelfLifeDays;
  final double? defaultPackSize;
  final String? packUom;
  final List<String> speciesCodes;
  final Map<String, dynamic> withdrawalRules;
  final bool active;
  final List<String> categoryCodes;
  final List<String> categoryNames;
  final double eligibleAvailable;
  final double onHand;
  final double expired;
  final double quarantined;
  final double storageExceptionQuantity;
  final int lotCount;
  final DateTime? earliestExpiry;
  final double expiringQuantity;
  final bool storageException;

  /// OK | LOW | CRITICAL | OUT, from the farm's own thresholds.
  final String status;
  final PharmacyPolicy? policy;
  final double recommendedReorder;
  final List<Map<String, dynamic>> openAlerts;
  final bool openRequisition;
  final double averageDailyUse;
  final List<MedicineLot> lots;
  final List<PharmacyAlert> alerts;
  final List<MedicationAdministration> administrations;

  bool get essential => policy?.essential ?? false;
  bool get isShort => status != 'OK';

  factory Medicine.fromJson(Map<String, dynamic> json) {
    final stock = _map(json['stock']);
    return Medicine(
      inventoryItemId: json['inventory_item_id'] as String,
      name: json['name'] as String? ?? '',
      unit: json['unit'] as String? ?? '',
      genericName: json['generic_name'] as String?,
      brandName: json['brand_name'] as String?,
      dosageForm: json['dosage_form'] as String? ?? 'other',
      strengthValue: _dn(json['strength_value']),
      strengthUom: json['strength_uom'] as String?,
      routes: _strings(json['administration_routes']),
      prescriptionRequired: json['prescription_required'] as bool? ?? false,
      antimicrobial: json['antimicrobial'] as bool? ?? false,
      controlled: json['controlled_medicine'] as bool? ?? false,
      coldChainRequired: json['cold_chain_required'] as bool? ?? false,
      openedShelfLifeDays: (json['opened_shelf_life_days'] as num?)?.toInt(),
      defaultPackSize: _dn(json['default_pack_size']),
      packUom: json['pack_uom'] as String?,
      speciesCodes: _strings(json['species_codes']),
      withdrawalRules: _map(json['withdrawal_rules']),
      active: json['active'] as bool? ?? true,
      categoryCodes: [for (final c in _maps(json['categories'])) c['code'] as String],
      categoryNames: [for (final c in _maps(json['categories'])) c['name'] as String? ?? c['code'] as String],
      eligibleAvailable: _d(json['eligible_available']),
      onHand: _d(json['on_hand']),
      expired: _d(stock['expired']),
      quarantined: _d(stock['quarantined']),
      storageExceptionQuantity: _d(stock['storage_exception']),
      lotCount: _i(json['lot_count']),
      earliestExpiry: _dt(json['earliest_expiry']),
      expiringQuantity: _d(json['expiring_quantity']),
      storageException: json['storage_exception'] as bool? ?? false,
      status: json['status'] as String? ?? 'OK',
      policy: json['policy'] == null ? null : PharmacyPolicy.fromJson(json['policy'] as Map<String, dynamic>),
      recommendedReorder: _d(json['recommended_reorder']),
      openAlerts: _maps(json['open_alerts']),
      openRequisition: json['open_requisition'] as bool? ?? false,
      averageDailyUse: _d(json['average_daily_use']),
      lots: [for (final l in _maps(json['lots'])) MedicineLot.fromJson(l)],
      alerts: [for (final a in _maps(json['alerts'])) PharmacyAlert.fromJson(a)],
      administrations: [for (final a in _maps(json['administrations'])) MedicationAdministration.fromJson(a)],
    );
  }
}
