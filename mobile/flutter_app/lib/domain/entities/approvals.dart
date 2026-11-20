/// Work an employee sent to the farm manager (backend
/// app/services/approval_service.py): a numbered feed mix, or a correction
/// to a milk record or a feeding. Nothing it describes has happened until
/// it is approved.
class ApprovalRequest {
  const ApprovalRequest({
    required this.id,
    required this.kind,
    required this.moduleCode,
    required this.status,
    required this.summary,
    required this.requestedBy,
    this.requestedByName,
    required this.requestedAt,
    this.subjectType,
    this.subjectId,
    this.targetId,
    this.payload = const {},
    this.reason,
    this.decidedByName,
    this.decidedAt,
    this.decisionNote,
    this.resultType,
    this.resultId,
  });

  final String id;

  /// feed_mix | milk_correction | feeding_correction
  final String kind;
  final String moduleCode;

  /// pending | approved | rejected | cancelled
  final String status;
  final String summary;
  final String requestedBy;
  final String? requestedByName;
  final DateTime requestedAt;
  final String? subjectType;
  final String? subjectId;
  final String? targetId;
  final Map<String, dynamic> payload;
  final String? reason;
  final String? decidedByName;
  final DateTime? decidedAt;
  final String? decisionNote;
  final String? resultType;
  final String? resultId;

  bool get pending => status == 'pending';

  factory ApprovalRequest.fromJson(Map<String, dynamic> j) => ApprovalRequest(
        id: j['id'] as String,
        kind: j['kind'] as String? ?? '',
        moduleCode: j['module_code'] as String? ?? '',
        status: j['status'] as String? ?? 'pending',
        summary: j['summary'] as String? ?? '',
        requestedBy: j['requested_by'] as String? ?? '',
        requestedByName: j['requested_by_name'] as String?,
        requestedAt: DateTime.tryParse(j['requested_at'] as String? ?? '') ?? DateTime.now(),
        subjectType: j['subject_type'] as String?,
        subjectId: j['subject_id'] as String?,
        targetId: j['target_id'] as String?,
        payload: (j['payload'] as Map?)?.cast<String, dynamic>() ?? const {},
        reason: j['reason'] as String?,
        decidedByName: j['decided_by_name'] as String?,
        decidedAt: DateTime.tryParse(j['decided_at'] as String? ?? ''),
        decisionNote: j['decision_note'] as String?,
        resultType: j['result_type'] as String?,
        resultId: j['result_id'] as String?,
      );
}

/// A request to buy (backend procurement: purchase requisitions). Asked
/// by an employee, approved or rejected by the manager; a delivery is then
/// recorded against it. An approved request is not yet stock.
class PurchaseRequest {
  const PurchaseRequest({
    required this.id,
    required this.number,
    required this.status,
    required this.requestedBy,
    this.requestedByName,
    required this.requestedAt,
    this.neededBy,
    this.justification,
    this.decisionNote,
    this.lines = const [],
  });

  final String id;
  final String number;

  /// draft | submitted | approved | rejected | cancelled | ordered | received
  final String status;
  final String requestedBy;
  final String? requestedByName;
  final DateTime requestedAt;
  final DateTime? neededBy;
  final String? justification;
  final String? decisionNote;
  final List<PurchaseRequestLine> lines;

  /// Waiting for the manager.
  bool get waiting => status == 'submitted' || status == 'draft';

  /// Approved and not yet delivered: a delivery may be recorded against it.
  bool get deliverable => status == 'approved' || status == 'ordered';

  String get what => lines.isEmpty
      ? number
      : '${lines.first.itemName ?? '—'} × ${_n(lines.first.quantity)} ${lines.first.unit}${lines.length > 1 ? ' +${lines.length - 1}' : ''}';

  factory PurchaseRequest.fromJson(Map<String, dynamic> j) {
    final approvals = (j['approvals'] as List<dynamic>? ?? const []).cast<Map<String, dynamic>>();
    return PurchaseRequest(
      id: j['id'] as String,
      number: j['requisition_no'] as String? ?? '',
      status: j['status'] as String? ?? 'draft',
      requestedBy: j['requested_by'] as String? ?? '',
      requestedByName: j['requested_by_name'] as String?,
      requestedAt: DateTime.tryParse('${j['requested_at'] ?? ''}') ?? DateTime.now(),
      neededBy: DateTime.tryParse('${j['needed_by'] ?? ''}'),
      justification: j['justification'] as String?,
      decisionNote: approvals.isEmpty ? null : approvals.last['comments'] as String?,
      lines: [for (final l in (j['lines'] as List<dynamic>? ?? const [])) PurchaseRequestLine.fromJson(l as Map<String, dynamic>)],
    );
  }
}

class PurchaseRequestLine {
  const PurchaseRequestLine({required this.inventoryItemId, this.itemName, required this.quantity, required this.unit, required this.status});
  final String inventoryItemId;
  final String? itemName;
  final double quantity;
  final String unit;
  final String status;

  factory PurchaseRequestLine.fromJson(Map<String, dynamic> j) => PurchaseRequestLine(
        inventoryItemId: j['inventory_item_id'] as String? ?? '',
        itemName: j['item_name'] as String?,
        quantity: (j['requested_quantity'] as num?)?.toDouble() ?? 0,
        unit: j['uom_code'] as String? ?? 'kg',
        status: j['status'] as String? ?? 'open',
      );
}

String _n(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
