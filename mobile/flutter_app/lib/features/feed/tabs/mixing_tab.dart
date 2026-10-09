import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/i18n/strings.dart';
import '../../../core/theme/colors.dart';
import '../../../core/theme/spacing.dart';
import '../../../core/theme/typography.dart';
import '../../../core/widgets/section_card.dart';
import '../../../core/widgets/status_pill.dart';
import '../../../domain/entities/access.dart';
import '../../../domain/entities/feeding.dart';
import '../../../providers/access_provider.dart';
import '../../../providers/feeding_provider.dart';
import '../../../providers/livestock_provider.dart';
import '../feed_workspace_screen.dart';
import 'mix_detail_sheet.dart';

/// The mixing screen (§17, FEED-SCHEMA §20): every run is a numbered mix
/// — one farm-wide sequence whatever it is intended for — opened from the
/// active formula at a chosen size (scaled targets, availability, planned
/// cost), then completed with the weights actually used and the lots they
/// came from. The actuals, not the targets, move stock and cost the mix;
/// the variance stays visible, and the mix timeline answers who ate it.
class MixingTab extends StatelessWidget {
  const MixingTab({super.key});

  @override
  Widget build(BuildContext context) {
    final feeding = context.watch<FeedingProvider>();
    final access = context.watch<AccessProvider>();
    final canCreate = access.canCreate(FarmModule.feedNutrition);
    final canApprove = access.can(FarmModule.feedNutrition, PermissionAction.approve);
    final open = feeding.batches.where((b) => b.isOpen).toList();
    final done = feeding.batches.where((b) => !b.isOpen).toList();

    return FeedTabScaffold(children: [
      SectionCard(
        title: context.t('openBatches'),
        subtitle: context.t('mixingSubtitle'),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (canCreate)
            FilledButton.icon(
              onPressed: feeding.formulas.any((f) => f.active != null) ? () => _showStartDialog(context) : null,
              icon: const Icon(Icons.add, size: 16),
              label: Text(context.t('startBatch')),
            ),
          if (open.isEmpty) const FeedEmpty('noOpenBatches'),
          for (final b in open) ...[const SizedBox(height: 10), _BatchCard(batch: b, canComplete: canCreate, canApprove: canApprove)],
        ]),
      ),
      SectionCard(
        title: context.t('completedBatches'),
        child: Column(children: [
          if (done.isEmpty) const FeedEmpty('noBatchesYet'),
          for (final b in done) ...[_BatchCard(batch: b, canComplete: false, canApprove: canApprove), const SizedBox(height: 10)],
        ]),
      ),
    ]);
  }
}

class _BatchCard extends StatelessWidget {
  const _BatchCard({required this.batch, required this.canComplete, required this.canApprove});
  final FeedBatch batch;
  final bool canComplete;
  final bool canApprove;

  @override
  Widget build(BuildContext context) {
    final b = batch;
    final lang = Localizations.localeOf(context).languageCode;
    final livestock = context.watch<LivestockProvider>();
    return Container(
      decoration: BoxDecoration(color: FarmColors.stone, borderRadius: BorderRadius.circular(FarmRadii.md)),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 14),
        childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
        title: Text('${b.numberPending ? context.t('pendingMixNumber') : b.label} — ${b.productName ?? ''}', style: FarmTypography.textTheme.titleSmall),
        subtitle: Text(
          [
            if (b.formulaCode != null) '${b.formulaCode} v${b.formulaVersion}',
            if (b.intendedSpeciesCode != null) '${context.t('intendedFor')} ${livestock.speciesName(b.intendedSpeciesCode!, lang)}${b.intendedManagementProfile != null ? ' · ${b.intendedManagementProfile}' : ''}',
            '${feedNumber(b.actualQuantity ?? b.targetQuantity ?? 0)} ${b.unit}',
            feedDate(b.productionDate ?? b.producedAt ?? b.startedAt),
            if (b.operatorName != null) b.operatorName!,
            if (b.unitCost != null) '${feedMoney(b.unitCost!)}/${b.unit}',
          ].join(' · '),
          style: FarmTypography.textTheme.bodySmall,
        ),
        trailing: StatusPill(label: context.t('batch_${b.status}'), level: feedStatusLevel(b.status), dense: true),
        children: [
          for (final c in b.components)
            FeedKeyValue(
              '${c.productName ?? c.feedProductId}${c.lotCode != null ? ' · ${c.lotCode}' : ''}',
              b.isOpen
                  ? '${context.t('target')} ${feedNumber(c.targetQuantity ?? 0)} ${c.unit}'
                  : '${feedNumber(c.actualQuantity ?? 0)} ${c.unit}${c.cost != null ? ' · ${feedMoney(c.cost!)}' : ''}',
            ),
          if (b.variance.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(context.t('variance'), style: const TextStyle(fontSize: 11, color: FarmColors.muted, fontWeight: FontWeight.w700, letterSpacing: 0.4)),
            for (final v in b.variance)
              FeedKeyValue(
                context.read<FeedingProvider>().productName(v['feed_product_id'] as String, Localizations.localeOf(context).languageCode),
                '${(v['variance'] as num?)?.toDouble().toStringAsFixed(1) ?? '—'} ${v['unit'] ?? ''}${v['variance_pct'] != null ? ' (${(v['variance_pct'] as num).toStringAsFixed(1)}%)' : ''}',
                valueColor: ((v['variance'] as num?)?.abs() ?? 0) > 0 ? FarmColors.warningInk : null,
              ),
          ],
          if (b.plannedCost != null) FeedKeyValue(context.t('plannedCost'), feedMoney(b.plannedCost!)),
          if (b.actualCost != null) FeedKeyValue(context.t('actualCost'), feedMoney(b.actualCost!), bold: true),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            if (b.isOpen && canComplete)
              FilledButton.icon(onPressed: () => _showCompleteDialog(context, b), icon: const Icon(Icons.check, size: 16), label: Text(context.t('completeBatch'))),
            if (!b.numberPending)
              OutlinedButton.icon(onPressed: () => showMixDetailSheet(context, b), icon: const Icon(Icons.timeline, size: 16), label: Text(context.t('mixTimeline'))),
            if (b.status == 'completed' && canApprove)
              OutlinedButton.icon(onPressed: () => _quarantine(context, b), icon: const Icon(Icons.block, size: 16), label: Text(context.t('quarantine'))),
          ]),
        ],
      ),
    );
  }

  Future<void> _quarantine(BuildContext context, FeedBatch b) async {
    final reason = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final c = TextEditingController();
        return AlertDialog(
          title: Text('${ctx.t('quarantine')} — ${b.label}'),
          content: TextField(controller: c, autofocus: true, decoration: InputDecoration(labelText: ctx.t('reasonPrompt'))),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text(ctx.t('cancel'))),
            FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: Text(ctx.t('save'))),
          ],
        );
      },
    );
    if (reason == null || reason.isEmpty || !context.mounted) return;
    final result = await context.read<FeedingProvider>().quarantineBatch(b.id, reason);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(result.success ? context.t('saved') : (result.error ?? context.t('couldNotSave')))));
  }
}

// -------------------------------------------------------------- start
Future<void> _showStartDialog(BuildContext context) => showDialog<void>(context: context, builder: (_) => const _StartBatchDialog());

class _StartBatchDialog extends StatefulWidget {
  const _StartBatchDialog();
  @override
  State<_StartBatchDialog> createState() => _StartBatchDialogState();
}

class _StartBatchDialogState extends State<_StartBatchDialog> {
  String? _formulaId;
  String? _speciesCode;
  String? _profile;
  final _size = TextEditingController();
  final _code = TextEditingController();
  final _mixer = TextEditingController();
  Map<String, dynamic>? _scaled;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _size.dispose();
    _code.dispose();
    _mixer.dispose();
    super.dispose();
  }

  Future<void> _preview() async {
    final feeding = context.read<FeedingProvider>();
    final formula = feeding.formulas.where((f) => f.id == _formulaId).firstOrNull;
    final size = double.tryParse(_size.text);
    if (formula?.active == null || size == null || size <= 0) return;
    final body = await feeding.scale(formula!.id, formula.active!.version, size);
    if (mounted) setState(() => _scaled = body);
  }

  Future<void> _submit() async {
    final size = double.tryParse(_size.text.trim());
    if (_formulaId == null || size == null || size <= 0) {
      setState(() => _error = context.t('valueMustBePositive'));
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final result = await context.read<FeedingProvider>().startBatch({
      'formula_id': _formulaId, 'target_quantity': size, if (_code.text.trim().isNotEmpty) 'batch_code': _code.text.trim(),
      if (_speciesCode != null) 'intended_species_code': _speciesCode,
      if (_profile != null) 'intended_management_profile': _profile,
      if (_mixer.text.trim().isNotEmpty) 'mixer_asset_id': _mixer.text.trim(),
    });
    if (!mounted) return;
    if (result.success) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.t('batchStarted'))));
      return;
    }
    setState(() {
      _saving = false;
      _error = result.error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final feeding = context.watch<FeedingProvider>();
    final livestock = context.watch<LivestockProvider>();
    final lang = Localizations.localeOf(context).languageCode;
    final formulas = feeding.formulas.where((f) => f.active != null).toList();
    final lines = (_scaled?['components'] as List<dynamic>? ?? const []).cast<Map<String, dynamic>>();
    final profiles = _speciesCode == null ? const <String>[] : (livestock.speciesByCode(_speciesCode!)?.profiles ?? const <String>[]);
    return AlertDialog(
      title: Text(context.t('startBatch')),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            DropdownButtonFormField<String>(
              value: _formulaId,
              isExpanded: true,
              decoration: InputDecoration(labelText: context.t('formula')),
              items: [for (final f in formulas) DropdownMenuItem(value: f.id, child: Text('${f.name} · v${f.active!.version}', overflow: TextOverflow.ellipsis))],
              onChanged: (v) {
                setState(() {
                  _formulaId = v;
                  final f = formulas.where((x) => x.id == v).firstOrNull;
                  if (f != null && _size.text.isEmpty) _size.text = feedNumber(f.active!.batchSize);
                  // The formula's species is the default intended use; the
                  // mixer may narrow it (a profile) or say another species,
                  // which the usage policy then checks on the server.
                  if (f != null && f.speciesCode != null) {
                    _speciesCode = f.speciesCode;
                    _profile = null;
                  }
                });
                _preview();
              },
            ),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  value: _speciesCode,
                  isExpanded: true,
                  decoration: InputDecoration(labelText: context.t('intendedFor')),
                  items: [for (final s in livestock.species) DropdownMenuItem(value: s.code, child: Text(s.name(lang), overflow: TextOverflow.ellipsis))],
                  onChanged: (v) => setState(() {
                    _speciesCode = v;
                    _profile = null;
                  }),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: DropdownButtonFormField<String>(
                  value: profiles.contains(_profile) ? _profile : null,
                  isExpanded: true,
                  decoration: InputDecoration(labelText: context.t('managementProfile')),
                  items: [for (final p in profiles) DropdownMenuItem(value: p, child: Text(p, overflow: TextOverflow.ellipsis))],
                  onChanged: profiles.isEmpty ? null : (v) => setState(() => _profile = v),
                ),
              ),
            ]),
            const SizedBox(height: 10),
            TextField(controller: _mixer, decoration: InputDecoration(labelText: context.t('mixer'))),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _size,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(labelText: '${context.t('batchSize')} (kg)'),
                  onChanged: (_) => _preview(),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(child: TextField(controller: _code, decoration: InputDecoration(labelText: context.t('batchCode')))),
            ]),
            if (lines.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(context.t('scaledTargets'), style: const TextStyle(fontSize: 11, color: FarmColors.muted, fontWeight: FontWeight.w700, letterSpacing: 0.4)),
              for (final l in lines)
                FeedKeyValue(
                  l['product_name'] as String? ?? '',
                  '${feedNumber((l['target_quantity'] as num).toDouble())} ${l['unit']} · ${context.t('available').toLowerCase()} ${feedNumber((l['available'] as num?)?.toDouble() ?? 0)}',
                  valueColor: ((l['available'] as num?)?.toDouble() ?? 0) < (l['target_quantity'] as num).toDouble() ? FarmColors.danger : null,
                ),
              if (_scaled?['planned_cost'] != null) FeedKeyValue(context.t('plannedCost'), feedMoney((_scaled!['planned_cost'] as num).toDouble()), bold: true),
            ],
            if (_error != null) ...[const SizedBox(height: 8), Text(_error!, style: const TextStyle(color: FarmColors.danger, fontSize: 12.5))],
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(context.t('cancel'))),
        FilledButton(onPressed: _saving ? null : _submit, child: Text(context.t('startBatch'))),
      ],
    );
  }
}

// ----------------------------------------------------------- complete
Future<void> _showCompleteDialog(BuildContext context, FeedBatch batch) => showDialog<void>(context: context, builder: (_) => _CompleteBatchDialog(batch: batch));

class _ActualLine {
  _ActualLine(this.component) : quantity = TextEditingController(text: feedNumber(component.targetQuantity ?? 0));
  final BatchComponent component;
  final TextEditingController quantity;
  String? lotId;
}

class _CompleteBatchDialog extends StatefulWidget {
  const _CompleteBatchDialog({required this.batch});
  final FeedBatch batch;
  @override
  State<_CompleteBatchDialog> createState() => _CompleteBatchDialogState();
}

class _CompleteBatchDialogState extends State<_CompleteBatchDialog> {
  late final List<_ActualLine> _lines = [for (final c in widget.batch.components) _ActualLine(c)];
  late final _output = TextEditingController(text: feedNumber(widget.batch.targetQuantity ?? 0));
  final _notes = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    for (final l in _lines) {
      l.quantity.dispose();
    }
    _output.dispose();
    _notes.dispose();
    super.dispose();
  }

  double get _weighed => _lines.fold(0.0, (s, l) => s + (double.tryParse(l.quantity.text) ?? 0));

  Future<void> _submit() async {
    final output = double.tryParse(_output.text.trim());
    if (output == null || output <= 0) {
      setState(() => _error = context.t('valueMustBePositive'));
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final result = await context.read<FeedingProvider>().completeBatch(widget.batch.id, {
      'actual_quantity': output,
      'actuals': [
        for (final l in _lines)
          {'feed_product_id': l.component.feedProductId, 'actual_quantity': double.tryParse(l.quantity.text) ?? 0, if (l.lotId != null) 'lot_id': l.lotId},
      ],
      if (_notes.text.trim().isNotEmpty) 'notes': _notes.text.trim(),
    });
    if (!mounted) return;
    if (result.success) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.t('batchCompleted'))));
      return;
    }
    setState(() {
      _saving = false;
      _error = result.error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final feeding = context.watch<FeedingProvider>();
    final output = double.tryParse(_output.text) ?? 0;
    return AlertDialog(
      title: Text('${context.t('completeBatch')} — ${widget.batch.label}'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final l in _lines) ...[
              Row(children: [
                Expanded(
                  flex: 3,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(l.component.productName ?? l.component.feedProductId, style: FarmTypography.textTheme.titleSmall),
                    Text('${context.t('target')} ${feedNumber(l.component.targetQuantity ?? 0)} ${l.component.unit}', style: FarmTypography.textTheme.bodySmall),
                  ]),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: l.quantity,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(labelText: context.t('actual'), suffixText: l.component.unit),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 3,
                  child: DropdownButtonFormField<String?>(
                    value: l.lotId,
                    isExpanded: true,
                    decoration: InputDecoration(labelText: context.t('selectLot')),
                    items: [
                      DropdownMenuItem<String?>(value: null, child: Text(context.t('fifo'))),
                      for (final lot in feeding.lotsFor(l.component.feedProductId).where((x) => x.usable))
                        DropdownMenuItem<String?>(value: lot.id, child: Text('${lot.lotCode} · ${feedNumber(lot.quantityOnHand)}', overflow: TextOverflow.ellipsis)),
                    ],
                    onChanged: (v) => setState(() => l.lotId = v),
                  ),
                ),
              ]),
              const SizedBox(height: 8),
            ],
            TextField(
              controller: _output,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: '${context.t('producedQuantity')} (${widget.batch.unit})'),
              onChanged: (_) => setState(() {}),
            ),
            FeedKeyValue(context.t('weighedIn'), '${feedNumber(_weighed)} ${widget.batch.unit}', valueColor: (_weighed - output).abs() > (output * 0.1).clamp(1, double.infinity) ? FarmColors.danger : FarmColors.success),
            TextField(controller: _notes, decoration: InputDecoration(labelText: context.t('notes'))),
            if (_error != null) ...[const SizedBox(height: 8), Text(_error!, style: const TextStyle(color: FarmColors.danger, fontSize: 12.5))],
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(context.t('cancel'))),
        FilledButton(onPressed: _saving ? null : _submit, child: Text(context.t('completeBatch'))),
      ],
    );
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    for (final e in this) {
      return e;
    }
    return null;
  }
}
