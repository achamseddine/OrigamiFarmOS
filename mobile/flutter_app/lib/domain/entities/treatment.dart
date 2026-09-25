/// Manager/veterinarian-gated diagnosis + treatment record. Constitution:
/// "Veterinarians diagnose and prescribe." Workers never write to this
/// entity's diagnosis field — see Observation for the worker-facing model.
class Treatment {
  const Treatment({
    required this.id,
    required this.entityType,
    required this.entityId,
    required this.medication,
    required this.dose,
    required this.route,
    required this.startAt,
    required this.responsibleUserId,
    this.diagnosis,
    this.endAt,
    this.withdrawalUntil,
    this.followUpAt,
    this.status = 'active',
    this.cost,
    this.notes,
  });

  final String id;
  final String entityType;
  final String entityId;
  final String medication;
  final String dose;
  final String route;
  final DateTime startAt;
  final String responsibleUserId;
  final String? diagnosis;
  final DateTime? endAt;
  final DateTime? withdrawalUntil;
  final DateTime? followUpAt;
  final String status;
  final double? cost;
  final String? notes;

  bool get requiresWithdrawal => withdrawalUntil != null;
}
