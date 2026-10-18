import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/widgets/status_pill.dart';
import '../../domain/entities/emergency.dart';
import '../../emergency/offline_engine.dart';
import '../../providers/emergency_provider.dart';
import '../feed/feed_workspace_screen.dart' show feedDate, feedNumber;
import 'pharmacy_tab.dart' show askReason;

/// The result of a triage run on the tablet from the signed offline
/// package (§14), and the protocol walked step by step at the animal.
///
/// Everything on this screen says where it came from: the package and
/// its date, the version and its approval, the approved dose rule and
/// the stock snapshot. The person confirms each step as they do it; a
/// blocked step shows its reasons in red and the escalation banner, and
/// nothing after it can be confirmed. What was shown and done is then
/// recorded on the tablet and revalidated by the server at sync.
Future<void> showOfflineRunDialog(
  BuildContext context, {
  required OfflineTriageResult triage,
  required Map<String, dynamic> facts,
  required List<Map<String, dynamic>> signs,
  required String subjectType,
  required String subjectId,
  required String subjectName,
  String? notes,
}) =>
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _OfflineRunDialog(triage: triage, facts: facts, signs: signs, subjectType: subjectType, subjectId: subjectId, subjectName: subjectName, notes: notes),
    );

class _OfflineRunDialog extends StatefulWidget {
  const _OfflineRunDialog({required this.triage, required this.facts, required this.signs, required this.subjectType, required this.subjectId, required this.subjectName, this.notes});
  final OfflineTriageResult triage;
  final Map<String, dynamic> facts;
  final List<Map<String, dynamic>> signs;
  final String subjectType;
  final String subjectId;
  final String subjectName;
  final String? notes;

  @override
  State<_OfflineRunDialog> createState() => _OfflineRunDialogState();
}

class _OfflineRunDialogState extends State<_OfflineRunDialog> {
  /// The step entries of the offline-run payload, in the order done.
  final List<Map<String, dynamic>> _done = [];

  /// A medication step prepared but not yet confirmed, keyed by step id.
  final Map<String, OfflineDose> _prepared = {};
  final _weight = TextEditingController();
  final _heads = TextEditingController();
  final List<String> _blockedNotes = [];
  bool _saving = false;
  String? _error;

  OfflineProtocolVersion? get _version => widget.triage.match?.version;

  bool _isDone(String stepId) => _done.any((d) => d['protocol_step_id'] == stepId);

  /// The first step not yet done; null once the protocol is walked.
  ProtocolStepDef? get _next {
    final v = _version;
    if (v == null) return null;
    for (final s in v.steps) {
      if (!_isDone(s.id)) return s;
    }
    return null;
  }

  /// A blocked medication step ends the run at the animal: the rest of
  /// the protocol cannot be confirmed, the person escalates.
  bool get _escalatedAtAnimal => _blockedNotes.isNotEmpty;

  @override
  void dispose() {
    _weight.dispose();
    _heads.dispose();
    super.dispose();
  }

  String _nowIso() => DateTime.now().toUtc().toIso8601String();

  @override
  Widget build(BuildContext context) {
    final t = widget.triage;
    final package = context.read<EmergencyProvider>().offlinePackage;
    final v = _version;
    final match = t.match;
    return AlertDialog(
      title: Text(context.t('emOfflineTitle')),
      content: SizedBox(
        width: 600,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              padding: const EdgeInsets.all(FarmSpacing.sm),
              decoration: BoxDecoration(color: FarmColors.tint(FarmColors.warning, 0.18), borderRadius: BorderRadius.circular(FarmRadii.sm)),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Icon(Icons.cloud_off, size: 18, color: FarmColors.warningInk),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${context.t('emOfflineBanner')}'
                    '${package?.generatedAt != null ? ' ${context.t('emOfflinePackageFrom')} ${feedDate(package!.generatedAt!)}' : ''}'
                    '${package?.stockAsOf != null ? ' (${context.t('emOfflineStockAsOf')} ${feedDate(package!.stockAsOf!)})' : ''}.',
                    style: FarmTypography.textTheme.bodySmall,
                  ),
                ),
              ]),
            ),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(child: Text(widget.subjectName, style: FarmTypography.textTheme.titleMedium)),
              StatusPill(label: context.t('emTriage_${t.triageLevel}'), level: _triageLevel(t.triageLevel), dense: true),
              const SizedBox(width: 6),
              StatusPill(label: context.t(t.escalated ? 'emStatus_escalated' : 'emStatus_offline'), level: t.escalated ? FarmStatusLevel.alert : FarmStatusLevel.watch, dense: true),
            ]),
            const SizedBox(height: 4),
            Text(
              widget.signs.map((s) => s['value_numeric'] != null ? '${s['code']} ${s['value_numeric']}' : (s['value_text'] != null ? '${s['code']} ${s['value_text']}' : '${s['code']}')).join(' · '),
              style: FarmTypography.textTheme.bodySmall?.copyWith(color: FarmColors.muted),
            ),
            if (t.escalated || _escalatedAtAnimal) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(FarmSpacing.sm),
                decoration: BoxDecoration(color: FarmColors.danger, borderRadius: BorderRadius.circular(FarmRadii.sm)),
                child: Row(children: [
                  const Icon(Icons.phone_in_talk, color: Colors.white, size: 20),
                  const SizedBox(width: 8),
                  Expanded(child: Text(context.t('emCallVet'), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700))),
                ]),
              ),
              const SizedBox(height: 6),
              for (final r in [...t.escalationReasons, ..._blockedNotes]) Text('• $r', style: FarmTypography.textTheme.bodySmall),
            ],
            const SizedBox(height: 8),
            Text(t.explanation, style: FarmTypography.textTheme.bodySmall),
            if (match != null && v != null) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(FarmSpacing.sm),
                decoration: BoxDecoration(color: FarmColors.sand, borderRadius: BorderRadius.circular(FarmRadii.sm)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Expanded(child: Text('${v.protocolTitle} · v${v.versionNo} · ${context.t('emApprovalRef')} ${v.approvalReference ?? '—'}', style: FarmTypography.textTheme.titleSmall)),
                    Text('${context.t('emMatch')} ${(match.score * 100).round()}% ≥ ${(v.minimumMatchConfidence * 100).round()}%', style: FarmTypography.textTheme.bodySmall),
                    const SizedBox(width: 6),
                    StatusPill(label: context.t('emEligibility_${match.eligibility}'), level: match.eligibility == 'ELIGIBLE' ? FarmStatusLevel.good : FarmStatusLevel.watch, dense: true),
                  ]),
                  if (v.approvedByName != null) Text('${context.t('emApprovedBy')} ${v.approvedByName}', style: FarmTypography.textTheme.bodySmall?.copyWith(color: FarmColors.muted)),
                  for (final w in match.warnings) Text('⚠ $w', style: FarmTypography.textTheme.bodySmall?.copyWith(color: FarmColors.warningInk)),
                  for (final o in match.outcomes)
                    if (o['checked'] == false) Text('⚠ ${o['message']}', style: FarmTypography.textTheme.bodySmall?.copyWith(color: FarmColors.warningInk)),
                ]),
              ),
              const SizedBox(height: 10),
              Text(context.t('emOfflineSteps'), style: FarmTypography.textTheme.titleSmall),
              for (final s in v.steps) _step(context, s),
            ],
            if (_error != null) ...[const SizedBox(height: 8), Text(_error!, style: const TextStyle(color: FarmColors.danger, fontSize: 12))],
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: _saving ? null : () => Navigator.pop(context), child: Text(context.t('cancel'))),
        FilledButton(
          onPressed: _saving ? null : _record,
          child: _saving
              ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : Text(t.escalated ? context.t('emOfflineRecordEscalation') : '${context.t('emOfflineRecord')} (${_done.length})'),
        ),
      ],
    );
  }

  FarmStatusLevel _triageLevel(String triage) => switch (triage) {
        'CRITICAL' || 'HIGH' => FarmStatusLevel.alert,
        'MODERATE' => FarmStatusLevel.watch,
        _ => FarmStatusLevel.neutral,
      };

  Widget _step(BuildContext context, ProtocolStepDef s) {
    final done = _done.where((d) => d['protocol_step_id'] == s.id).toList();
    final entry = done.isEmpty ? null : done.last;
    final status = entry?['status'] as String?;
    final isNext = _next?.id == s.id && !_escalatedAtAnimal;
    final prepared = _prepared[s.id];
    final med = s.medication;
    final icon = switch (status) {
      'completed' => Icons.check_circle,
      'skipped' => Icons.remove_circle_outline,
      _ => prepared != null && prepared.blocked ? Icons.block : (isNext ? Icons.play_circle_outline : Icons.radio_button_unchecked),
    };
    final color = switch (status) {
      'completed' => FarmColors.olive,
      _ => prepared != null && prepared.blocked ? FarmColors.danger : (isNext ? FarmColors.cedar2 : FarmColors.muted),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${s.stepNo}. ${s.title} · ${context.t('emStepType_${s.stepType}')}${s.required ? '' : ' · ${context.t('emOptional')}'}', style: FarmTypography.textTheme.titleSmall),
            Text(s.instructions, style: FarmTypography.textTheme.bodySmall),
            if (med != null)
              Text(
                '${med['medicine_name']} · ${med['route_code']} · ${med['dose_rule_type'] == 'FIXED' ? '${feedNumber(_num(med['fixed_dose_quantity']))} ${med['dose_unit']}' : '${_num(med['dose_per_weight_quantity'])} ${med['dose_unit']}/${med['weight_unit']}'}'
                '${med['minimum_dose_quantity'] != null || med['maximum_dose_quantity'] != null ? ' · ${context.t('emApprovedRange')} ${_n(med['minimum_dose_quantity'])}–${_n(med['maximum_dose_quantity'])} ${med['dose_unit']}' : ''}',
                style: FarmTypography.textTheme.bodySmall?.copyWith(color: FarmColors.cedar2),
              ),
            if (prepared != null && prepared.doseQuantity != null && !prepared.blocked)
              Container(
                margin: const EdgeInsets.only(top: 4),
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(color: FarmColors.sand, borderRadius: BorderRadius.circular(6)),
                child: Text(
                  '${context.t('emPreparedDose')}: ${feedNumber(prepared.doseQuantity!)} ${prepared.doseUnit} ${prepared.routeCode}'
                  '${prepared.weightUsedKg != null ? ' · ${prepared.weightUsedKg!.toStringAsFixed(0)} kg (${prepared.weightSource})' : ''}'
                  '${prepared.headCount != 1 ? ' × ${prepared.headCount}' : ''} · ${context.t('phLot')} ${prepared.lot?.lotCode ?? '—'}',
                  style: FarmTypography.textTheme.bodySmall,
                ),
              ),
            if (prepared != null) for (final p in prepared.problems) Text('⛔ $p', style: FarmTypography.textTheme.bodySmall?.copyWith(color: FarmColors.danger)),
            if (prepared != null && prepared.blocked) Text(context.t('emOfflineBlocked'), style: FarmTypography.textTheme.bodySmall?.copyWith(color: FarmColors.danger, fontWeight: FontWeight.w700)),
            if (entry?['skip_reason'] != null) Text('${context.t('emSkipped')}: ${entry!['skip_reason']}', style: FarmTypography.textTheme.bodySmall?.copyWith(color: FarmColors.muted)),
            if (isNext && s.isMedication && (prepared == null || prepared.blocked == false) && prepared == null) ...[
              const SizedBox(height: 6),
              Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                if (med?['dose_rule_type'] == 'PER_WEIGHT')
                  SizedBox(
                    width: 160,
                    child: TextField(controller: _weight, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: context.t('emWeightKg'), helperText: context.t('emWeightHelp'), isDense: true)),
                  ),
                if (widget.subjectType == 'group')
                  SizedBox(width: 120, child: TextField(controller: _heads, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: context.t('headCount'), isDense: true))),
              ]),
            ],
          ]),
        ),
        if (isNext && status == null)
          Wrap(spacing: 4, children: [
            if (s.isMedication && prepared == null) OutlinedButton(onPressed: () => _prepare(s), child: Text(context.t('emPrepare'))),
            if (s.isMedication && prepared != null && !prepared.blocked) FilledButton(onPressed: () => _confirmDose(s, prepared), child: Text(context.t('emOfflineGiven'))),
            if (!s.isMedication) FilledButton(onPressed: () => _complete(s), child: Text(context.t('emOfflineDone'))),
            if (!s.required && (prepared == null || !prepared.blocked)) TextButton(onPressed: () => _skip(s), child: Text(context.t('emSkip'))),
          ]),
      ]),
    );
  }

  static double _num(Object? v) => (v as num?)?.toDouble() ?? 0;
  static String _n(Object? v) => v == null ? '—' : feedNumber(_num(v));

  void _prepare(ProtocolStepDef s) {
    final package = context.read<EmergencyProvider>().offlinePackage!;
    final weight = double.tryParse(_weight.text.trim());
    final heads = int.tryParse(_heads.text.trim());
    final earlier = [for (final d in _done) if (d['protocol_step_id'] == s.id && d['status'] == 'completed') d];
    final dose = prepareOfflineDose(step: s, package: package, facts: widget.facts, enteredWeightKg: weight, headCount: heads, earlierDoses: earlier);
    setState(() {
      _prepared[s.id] = dose;
      _error = null;
      if (dose.blocked) {
        // The step cannot be confirmed; the protocol ends here and the
        // person escalates. It is recorded as what it was.
        _blockedNotes.add('${context.t('emStepType_MEDICATION')} ${s.stepNo}: ${dose.problems.join('; ')}');
        _done.add({'protocol_step_id': s.id, 'status': 'skipped', 'skip_reason': 'blocked offline: ${dose.problems.join('; ')}', 'occurred_at': _nowIso(), 'result': dose.toResult()});
      }
    });
  }

  Future<void> _confirmDose(ProtocolStepDef s, OfflineDose dose) async {
    final notes = await askReason(context, title: context.t('emOfflineGiven'), label: context.t('emConfirmGiven'));
    if (notes == null || !mounted) return;
    setState(() {
      _done.add({
        'protocol_step_id': s.id,
        'status': 'completed',
        'occurred_at': _nowIso(),
        'result': {...dose.toResult(), 'offline': true},
        'medication': {'dose_quantity': dose.doseQuantity, 'dose_unit': dose.doseUnit, 'lot_id': dose.lot?.lotId, 'weight_used_kg': dose.weightUsedKg, 'head_count': dose.headCount},
        if (notes.isNotEmpty) 'notes': notes,
      });
      _prepared.remove(s.id);
      _weight.clear();
    });
  }

  void _complete(ProtocolStepDef s) => setState(() => _done.add({'protocol_step_id': s.id, 'status': 'completed', 'occurred_at': _nowIso(), 'result': const {'offline': true}}));

  Future<void> _skip(ProtocolStepDef s) async {
    final reason = await askReason(context, title: context.t('emSkip'), label: context.t('reason'));
    if (reason == null || !mounted) return;
    setState(() => _done.add({'protocol_step_id': s.id, 'status': 'skipped', 'skip_reason': reason, 'occurred_at': _nowIso()}));
  }

  Future<void> _record() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    final messenger = ScaffoldMessenger.maybeOf(context);
    final notes = [if (widget.notes != null && widget.notes!.isNotEmpty) widget.notes!, if (_blockedNotes.isNotEmpty) 'escalated at the animal: ${_blockedNotes.join(' | ')}'].join(' — ');
    final result = await context.read<EmergencyProvider>().recordOfflineRun(
          subjectType: widget.subjectType,
          subjectId: widget.subjectId,
          signs: widget.signs,
          triage: widget.triage,
          steps: _done,
          notes: notes.isEmpty ? null : notes,
        );
    if (!mounted) return;
    if (result.success) {
      Navigator.pop(context);
      messenger?.showSnackBar(SnackBar(content: Text(context.t('emOfflineRecorded'))));
    } else {
      setState(() {
        _saving = false;
        _error = result.error ?? context.t('couldNotSave');
      });
    }
  }
}
