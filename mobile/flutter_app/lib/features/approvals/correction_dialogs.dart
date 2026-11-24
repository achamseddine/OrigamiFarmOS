import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/typography.dart';
import '../../core/util/number_input.dart';
import '../../core/util/record_dates.dart';
import '../../core/widgets/form_dialog.dart';
import '../../core/widgets/ux_blocks.dart';
import '../../domain/entities/feeding.dart';
import '../../domain/entities/production_records.dart';
import '../../providers/access_provider.dart';
import '../../providers/animals_provider.dart';
import '../../providers/approvals_provider.dart';
import '../../providers/feeding_provider.dart';
import '../../providers/production_provider.dart';
import '../production/milk_sessions.dart';

/// Correcting a milk record or a feeding already on file (v0.7.8).
///
/// The farm manager corrects it directly; anyone else sends the correction
/// with a reason, and it is applied only when the manager approves it
/// (backend approval_service). Either way the record keeps its history:
/// the milk record's before/after is in the audit log; a feeding is undone
/// (its stock returns) and what was really fed is recorded in its place.
Future<void> showCorrectMilkDialog(BuildContext context, MilkRecord record) =>
    showDialog<void>(context: context, builder: (_) => _CorrectMilkDialog(record: record));

Future<void> showCorrectFeedingDialog(BuildContext context, FeedingEvent event) =>
    showDialog<void>(context: context, builder: (_) => _CorrectFeedingDialog(event: event));

const _destinations = ['stored', 'sold', 'processed', 'consumed', 'withheld'];

String _n(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

bool _sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;

String _sessionLabel(BuildContext context, String session) => switch (session) {
      'morning' => context.t('sessionMorning'),
      'evening' => milkSessionLabel(context, 'evening'),
      'midday' => context.t('sessionMidday'),
      _ => session,
    };

class _CorrectMilkDialog extends StatefulWidget {
  const _CorrectMilkDialog({required this.record});
  final MilkRecord record;

  @override
  State<_CorrectMilkDialog> createState() => _CorrectMilkDialogState();
}

class _CorrectMilkDialogState extends State<_CorrectMilkDialog> {
  late final _liters = TextEditingController(text: _n(widget.record.liters));
  final _reason = TextEditingController();
  late String _session = widget.record.session;
  late String _destination = _destinations.contains(widget.record.destination) ? widget.record.destination : 'stored';
  late DateTime _day = widget.record.recordedAt.toLocal();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _liters.dispose();
    _reason.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final r = widget.record;
    final liters = parseLocalizedDouble(_liters.text);
    if (liters == null || liters < 0) {
      setState(() => _error = context.t('valueMustBePositive'));
      return;
    }
    final changes = <String, dynamic>{
      if (liters != r.liters) 'liters': liters,
      if (_session != r.session) 'session': _session,
      if (_destination != r.destination) 'destination': _destination,
      if (!_sameDay(_day, r.recordedAt.toLocal())) 'recorded_at': milkingInstant(_day, _session).toUtc().toIso8601String(),
    };
    if (changes.isEmpty) {
      setState(() => _error = context.t('crNothingChanged'));
      return;
    }
    if (_reason.text.trim().isEmpty) {
      setState(() => _error = context.t('crSayWhy'));
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final direct = context.read<AccessProvider>().canCorrectMilk;
    final approvals = context.read<ApprovalsProvider>();
    final result = direct
        ? await approvals.correctMilk(r.id, changes, _reason.text.trim())
        : await approvals.requestMilkCorrection(r.id, changes, _reason.text.trim());
    if (!mounted) return;
    if (result.success) {
      if (direct && !result.queued) {
        context.read<ProductionProvider>().load();
        context.read<AnimalsProvider>().load();
      }
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(context.t(result.queued ? 'apSentOffline' : (direct ? 'crCorrected' : 'crSentForApproval'))),
      ));
      return;
    }
    setState(() {
      _saving = false;
      _error = result.error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.record;
    final direct = context.watch<AccessProvider>().canCorrectMilk;
    final waiting = context.watch<ApprovalsProvider>().pendingFor(r.id);
    final animal = context.read<AnimalsProvider>().find(r.animalId);
    final l = r.recordedAt.toLocal();
    return FarmFormDialog(
      title: Text('${context.t('crCorrectMilk')} — ${animal?.name ?? ''}'),
      width: 520,
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('${context.t('crOnRecord')}: ${l.day}/${l.month}/${l.year} · ${_sessionLabel(context, r.session)} · ${_n(r.liters)} L · ${context.t(r.destination)}',
            style: FarmTypography.textTheme.bodyMedium),
        const SizedBox(height: 12),
        if (waiting != null) ...[
          NoticeBanner(key: const ValueKey('correction-waiting'), title: context.t('crAlreadyWaiting'), text: waiting.summary),
          const SizedBox(height: 12),
        ] else if (!direct) ...[
          NoticeBanner(key: const ValueKey('correction-goes-to-manager'), title: context.t('apGoesToManager'), text: context.t('crManagerApproves')),
          const SizedBox(height: 12),
        ],
        TextField(
          controller: _liters,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(labelText: '${context.t('quantity')} (${context.t('liters')})', suffixText: 'L'),
        ),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          // The farm's two milkings; midday only on a record that has it.
          for (final s in ['morning', if (r.session == 'midday') 'midday', 'evening'])
            ChoiceChip(label: Text(_sessionLabel(context, s)), selected: _session == s, onSelected: (_) => setState(() => _session = s)),
        ]),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          initialValue: _destination,
          isExpanded: true,
          decoration: InputDecoration(labelText: context.t('destination')),
          items: [for (final d in _destinations) DropdownMenuItem(value: d, child: Text(context.t(d)))],
          onChanged: (v) => setState(() => _destination = v ?? _destination),
        ),
        const SizedBox(height: 12),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: RecordDateButton(label: context.t('milkedOn'), value: _day, maxDaysBack: 60, onPicked: (d) => setState(() => _day = d)),
        ),
        const SizedBox(height: 12),
        TextField(controller: _reason, maxLines: 2, decoration: InputDecoration(labelText: context.t('crWhy'), hintText: context.t('crWhyHint'))),
        if (_error != null) ...[const SizedBox(height: 8), Text(_error!, style: const TextStyle(color: FarmColors.danger, fontSize: 12.5))],
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(context.t('cancel'))),
        FilledButton(
          onPressed: _saving || waiting != null ? null : _submit,
          child: _saving
              ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : Text(context.t(direct ? 'crSaveCorrection' : 'apSendToManager')),
        ),
      ],
    );
  }
}

class _CorrectFeedingDialog extends StatefulWidget {
  const _CorrectFeedingDialog({required this.event});
  final FeedingEvent event;

  @override
  State<_CorrectFeedingDialog> createState() => _CorrectFeedingDialogState();
}

class _CorrectFeedingDialogState extends State<_CorrectFeedingDialog> {
  late final List<TextEditingController> _qty = [for (final c in widget.event.components) TextEditingController(text: _n(c.quantityOffered))];
  final _reason = TextEditingController();
  bool _undoAll = false;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    for (final c in _qty) {
      c.dispose();
    }
    _reason.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final e = widget.event;
    final components = <Map<String, dynamic>>[];
    if (!_undoAll) {
      for (var i = 0; i < e.components.length; i++) {
        final q = parseLocalizedDouble(_qty[i].text);
        if (q == null || q < 0) {
          setState(() => _error = context.t('valueMustBePositive'));
          return;
        }
        if (q > 0) components.add({'feed_product_id': e.components[i].feedProductId, 'quantity_offered': q, 'unit': e.components[i].unit});
      }
      final same = components.length == e.components.length &&
          [for (var i = 0; i < components.length; i++) components[i]['quantity_offered'] == e.components[i].quantityOffered].every((x) => x);
      if (same) {
        setState(() => _error = context.t('crNothingChanged'));
        return;
      }
    }
    if (_reason.text.trim().isEmpty) {
      setState(() => _error = context.t('crSayWhy'));
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final direct = context.read<AccessProvider>().canCorrectFeeding;
    final approvals = context.read<ApprovalsProvider>();
    final result = direct
        ? await approvals.correctFeeding(e.id, components, _reason.text.trim())
        : await approvals.requestFeedingCorrection(e.id, components, _reason.text.trim());
    if (!mounted) return;
    if (result.success) {
      if (direct && !result.queued) context.read<FeedingProvider>().afterFeedingCorrected(e.subjectId);
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(context.t(result.queued ? 'apSentOffline' : (direct ? 'crCorrected' : 'crSentForApproval'))),
      ));
      return;
    }
    setState(() {
      _saving = false;
      _error = result.error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.event;
    final feeding = context.watch<FeedingProvider>();
    final lang = Localizations.localeOf(context).languageCode;
    final direct = context.watch<AccessProvider>().canCorrectFeeding;
    final waiting = context.watch<ApprovalsProvider>().pendingFor(e.id);
    final l = e.occurredAt.toLocal();
    return FarmFormDialog(
      title: Text(context.t('crCorrectFeeding')),
      width: 520,
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('${context.t('crOnRecord')}: ${l.day}/${l.month}/${l.year} · ${context.t('event_${e.eventType}')}', style: FarmTypography.textTheme.bodyMedium),
        const SizedBox(height: 12),
        if (waiting != null) ...[
          NoticeBanner(key: const ValueKey('correction-waiting'), title: context.t('crAlreadyWaiting'), text: waiting.summary),
          const SizedBox(height: 12),
        ] else if (!direct) ...[
          NoticeBanner(key: const ValueKey('correction-goes-to-manager'), title: context.t('apGoesToManager'), text: context.t('crManagerApproves')),
          const SizedBox(height: 12),
        ],
        Material(
          type: MaterialType.transparency,
          child: CheckboxListTile(
            key: const ValueKey('undo-all'),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: _undoAll,
            title: Text(context.t('crUndoAll')),
            subtitle: Text(context.t('crUndoAllSub'), style: FarmTypography.textTheme.bodySmall),
            onChanged: (v) => setState(() => _undoAll = v ?? false),
          ),
        ),
        if (!_undoAll)
          for (var i = 0; i < e.components.length; i++) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _qty[i],
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: feeding.productName(e.components[i].feedProductId, lang),
                suffixText: e.components[i].unit,
                helperText: '${context.t('crWasRecorded')} ${_n(e.components[i].quantityOffered)} ${e.components[i].unit}',
              ),
            ),
          ],
        const SizedBox(height: 12),
        TextField(controller: _reason, maxLines: 2, decoration: InputDecoration(labelText: context.t('crWhy'), hintText: context.t('crWhyHint'))),
        if (_error != null) ...[const SizedBox(height: 8), Text(_error!, style: const TextStyle(color: FarmColors.danger, fontSize: 12.5))],
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(context.t('cancel'))),
        FilledButton(
          onPressed: _saving || waiting != null ? null : _submit,
          child: _saving
              ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : Text(context.t(direct ? 'crSaveCorrection' : 'apSendToManager')),
        ),
      ],
    );
  }
}
