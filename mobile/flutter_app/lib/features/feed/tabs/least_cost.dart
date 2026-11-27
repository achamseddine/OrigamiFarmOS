import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/i18n/strings.dart';
import '../../../core/theme/colors.dart';
import '../../../core/theme/typography.dart';
import '../../../core/util/number_input.dart';
import '../../../core/widgets/form_dialog.dart';
import '../../../core/widgets/section_card.dart';
import '../../../core/widgets/status_pill.dart';
import '../../../domain/entities/feeding.dart';
import '../../../domain/entities/nutrition.dart';
import '../../../providers/access_provider.dart';
import '../../../providers/feeding_provider.dart';
import '../../../providers/nutrition_provider.dart';
import '../../health/pharmacy_tab.dart' show askReason;
import '../feed_workspace_screen.dart';
import 'nutrition_assessment.dart';

/// Least-cost drafts (master prompt Package 12) on Feed → Nutrition, on the
/// tablet and the web app: up to three drafts at today's prices, each
/// meeting every requirement — or *infeasible*, or *insufficient data* —
/// and the manager's approval of one, as a new draft version of the formula.

String _money(double v) => '\$${v.toStringAsFixed(2)}';

class LeastCostCard extends StatelessWidget {
  const LeastCostCard({super.key});

  @override
  Widget build(BuildContext context) {
    final nut = context.watch<NutritionProvider>();
    final access = context.watch<AccessProvider>();
    return SectionCard(
      key: const ValueKey('lc-card'),
      title: context.t('lcTitle'),
      subtitle: context.t('lcSubtitle'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (nuAssesses(access))
          FilledButton.tonalIcon(
            key: const ValueKey('lc-run'),
            onPressed: nut.sets.isEmpty ? null : () => showDialog<void>(context: context, builder: (_) => const _LeastCostDialog()),
            icon: const Icon(Icons.savings_outlined, size: 16),
            label: Text(context.t('lcRun')),
          ),
        for (final r in nut.runs)
          Material(
            type: MaterialType.transparency,
            child: InkWell(
              key: ValueKey('lc-r-${r.id}'),
              onTap: () => showLeastCostResult(context, r),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('${r.baseName ?? context.t('lcNoBase')}${r.baseVersion != null ? ' v${r.baseVersion}' : ''} · ${r.setCode} v${r.setVersion}',
                          style: FarmTypography.textTheme.titleSmall),
                      Text(
                        [
                          if (r.createdAt != null) feedDate(r.createdAt!),
                          if (r.drafts.isNotEmpty) context.t('lcDraftsN').replaceAll('{n}', '${r.drafts.length}'),
                          if (r.approvedDraft != null) context.t('lcApprovedShort').replaceAll('{d}', r.approvedDraft!),
                        ].join(' · '),
                        style: FarmTypography.textTheme.bodySmall,
                      ),
                    ]),
                  ),
                  StatusPill(label: context.t('lcStatus_${r.status}'), level: r.status == 'drafts' ? FarmStatusLevel.good : FarmStatusLevel.watch, dense: true),
                ]),
              ),
            ),
          ),
      ]),
    );
  }
}

Future<void> showLeastCostResult(BuildContext context, LeastCostRun run) => showDialog<void>(context: context, builder: (_) => _LeastCostResult(run: run));

class _LeastCostResult extends StatelessWidget {
  const _LeastCostResult({required this.run});
  final LeastCostRun run;

  Future<void> _approve(BuildContext context, FormulationDraft d) async {
    final note = await askReason(context, title: context.t('lcApproveTitle').replaceAll('{d}', d.key), label: context.t('lcApproveWhy'));
    if (note == null || !context.mounted) return;
    final r = await context.read<NutritionProvider>().approveDraft(run.id, d.key, note: note);
    if (!context.mounted) return;
    if (r.success) Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(r.success ? context.t(r.queued ? 'nuQueued' : 'lcApproved') : (r.error ?? context.t('couldNotSave')))));
  }

  @override
  Widget build(BuildContext context) {
    final small = FarmTypography.textTheme.bodySmall;
    final canApprove = nuManages(context.watch<AccessProvider>()) && run.approvedDraft == null;
    final lang = Localizations.localeOf(context).languageCode;
    return FarmFormDialog(
      key: const ValueKey('lc-result'),
      title: Text(context.t('lcTitle')),
      width: 600,
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          StatusPill(key: const ValueKey('lc-status'), label: context.t('lcStatus_${run.status}'), level: run.status == 'drafts' ? FarmStatusLevel.good : FarmStatusLevel.watch),
          const SizedBox(width: 8),
          Expanded(child: Text('${run.setCode} v${run.setVersion} · ${nuKg(run.batchKg)} kg', style: small)),
        ]),
        if (run.baseCostToday != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(context.t('lcBaseToday').replaceAll('{cost}', _money(run.baseCostToday!)), style: small),
          ),
        if (run.approvedDraft != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(context.t('lcApprovedLine').replaceAll('{d}', run.approvedDraft!).replaceAll('{note}', run.approvalNote ?? ''),
                key: const ValueKey('lc-approved'), style: const TextStyle(fontSize: 12, color: FarmColors.success)),
          ),
        if (run.missing.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text(context.t('nuMissing'), style: FarmTypography.textTheme.titleSmall?.copyWith(color: FarmColors.warning)),
          for (final m in run.missing) Text('• ${m.detail}', style: small),
          Text(context.t('lcNothingRun'), style: small),
        ],
        if (run.infeasible.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text(context.t('lcInfeasible'), style: FarmTypography.textTheme.titleSmall?.copyWith(color: FarmColors.warning)),
          for (final x in run.infeasible) Text('• $x', style: small),
        ],
        for (final d in run.drafts) ...[
          const Divider(height: 22),
          Row(children: [
            Expanded(child: Text('${d.key} · ${context.t('lcLabel_${d.label}')}', key: ValueKey('lc-d-${d.key}'), style: FarmTypography.textTheme.titleSmall)),
            Text('${_money(d.cost)} · ${_money(d.costPerKg)}/kg', style: FarmTypography.textTheme.titleSmall),
          ]),
          if (d.saving != null)
            Text(
              d.saving! >= 0
                  ? context.t('lcSaves').replaceAll('{cost}', _money(d.saving!))
                  : context.t('lcCostsMore').replaceAll('{cost}', _money(-d.saving!)),
              style: TextStyle(fontSize: 12, color: d.saving! >= 0 ? FarmColors.success : FarmColors.warning),
            ),
          if (d.changedKg != null) Text(context.t('lcChanged').replaceAll('{kg}', nuKg(d.changedKg!)), style: small),
          for (final l in d.lines)
            FeedKeyValue(l.name, '${nuKg(l.quantityKg)} kg · ${nuNum(l.inclusionPct)} %${l.cost != null ? ' · ${_money(l.cost!)}' : ''}'),
          if (d.premix != null) FeedKeyValue('${context.t('nuPremix')}: ${d.premix!.name}', '+ ${nuKg(d.premix!.quantityKg)} kg'),
          Wrap(spacing: 6, runSpacing: 4, children: [
            for (final n in d.nutrients)
              Chip(
                visualDensity: VisualDensity.compact,
                label: Text('${n.label(lang)} ${n.value == null ? '—' : nuNum(n.value!)} ${n.unit}', style: const TextStyle(fontSize: 12)),
              ),
          ]),
          if (canApprove)
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: OutlinedButton(key: ValueKey('lc-approve-${d.key}'), onPressed: () => _approve(context, d), child: Text(context.t('lcApprove'))),
            ),
        ],
        const SizedBox(height: 10),
        Text(context.t('lcPlanOnly'), style: const TextStyle(fontSize: 12, color: FarmColors.muted)),
      ]),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(context.t('close')))],
    );
  }
}

class _LeastCostDialog extends StatefulWidget {
  const _LeastCostDialog();

  @override
  State<_LeastCostDialog> createState() => _LeastCostDialogState();
}

class _LeastCostDialogState extends State<_LeastCostDialog> {
  String? _formulaId;
  String? _setId;
  String? _forageId;
  bool _feedOnly = false;
  bool _saving = false;
  String? _error;
  final _conc = TextEditingController();
  final _forageKg = TextEditingController();
  final _weight = TextEditingController();
  final _margin = TextEditingController(text: '3');

  @override
  void dispose() {
    for (final c in [_conc, _forageKg, _weight, _margin]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save(List<FeedFormula> formulas) async {
    FormulaVersion? version;
    for (final f in formulas) {
      if (f.id == _formulaId) version = f.active;
    }
    if (version == null || _setId == null) {
      setState(() => _error = context.t('nuChooseFormulaAndSet'));
      return;
    }
    final forageKg = parseLocalizedDouble(_forageKg.text);
    setState(() {
      _saving = true;
      _error = null;
    });
    final (result, run) = await context.read<NutritionProvider>().leastCost({
      'requirement_set_id': _setId,
      'base_formula_version_id': version.id,
      'concentrate_kg_per_head': ?parseLocalizedDouble(_conc.text),
      'forages': [
        if (!_feedOnly && _forageId != null && forageKg != null && forageKg > 0) {'feed_product_id': _forageId, 'as_fed_kg': forageKg},
      ],
      'no_forage': _feedOnly,
      'body_weight_kg': ?parseLocalizedDouble(_weight.text),
      'margin_pct': ?parseLocalizedDouble(_margin.text),
    });
    if (!mounted) return;
    if (!result.success) {
      setState(() {
        _saving = false;
        _error = result.error;
      });
      return;
    }
    Navigator.of(context).pop();
    if (run != null) {
      await showLeastCostResult(context, run);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.t('nuQueued'))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final feeding = context.watch<FeedingProvider>();
    final sets = context.watch<NutritionProvider>().sets;
    final lang = Localizations.localeOf(context).languageCode;
    final formulas = [for (final f in feeding.formulas) if (f.active != null) f];
    final forages = [for (final p in feeding.products) if (p.status == 'active' && (p.category == 'forage' || p.rationType == 'silage' || p.rationType == 'hay_straw')) p];
    TextField number(String key, TextEditingController c, String label, {String? helper}) => TextField(
          key: ValueKey(key),
          controller: c,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(labelText: label, helperText: helper, helperMaxLines: 2),
        );
    return FarmFormDialog(
      title: Text(context.t('lcRun')),
      width: 520,
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(context.t('lcHelp'), style: FarmTypography.textTheme.bodySmall),
        DropdownButtonFormField<String>(
          key: const ValueKey('lc-formula'),
          isExpanded: true,
          value: _formulaId,
          decoration: InputDecoration(labelText: context.t('nuFormula')),
          items: [
            for (final f in formulas)
              DropdownMenuItem(value: f.id, child: Text('${f.name} v${f.active!.version} · ${nuKg(f.active!.batchSize)} ${f.active!.unit}', overflow: TextOverflow.ellipsis)),
          ],
          onChanged: (v) => setState(() => _formulaId = v),
        ),
        DropdownButtonFormField<String>(
          key: const ValueKey('lc-set'),
          isExpanded: true,
          value: _setId,
          decoration: InputDecoration(labelText: context.t('nuReqSet')),
          items: [for (final s in sets) DropdownMenuItem(value: s.id, child: Text('${s.code} v${s.version} · ${s.name}', overflow: TextOverflow.ellipsis))],
          onChanged: (v) => setState(() => _setId = v),
        ),
        number('lc-conc', _conc, context.t('nuConcPerHead'), helper: context.t('nuUnknownHelp')),
        SwitchListTile(
          key: const ValueKey('lc-only'),
          contentPadding: EdgeInsets.zero,
          value: _feedOnly,
          onChanged: (v) => setState(() => _feedOnly = v),
          title: Text(context.t('nuFeedOnly')),
        ),
        if (!_feedOnly)
          Row(children: [
            Expanded(
              flex: 3,
              child: DropdownButtonFormField<String>(
                key: const ValueKey('lc-forage'),
                isExpanded: true,
                value: _forageId,
                decoration: InputDecoration(labelText: context.t('nuForage')),
                items: [for (final p in forages) DropdownMenuItem(value: p.id, child: Text(p.label(lang), overflow: TextOverflow.ellipsis))],
                onChanged: (v) => setState(() => _forageId = v),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(flex: 2, child: number('lc-forage-kg', _forageKg, context.t('nuForageKg'))),
          ]),
        Row(children: [
          Expanded(child: number('lc-weight', _weight, context.t('nuBodyWeight'))),
          const SizedBox(width: 10),
          Expanded(child: number('lc-margin', _margin, context.t('lcMargin'))),
        ]),
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: const TextStyle(color: FarmColors.danger))),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(context.t('cancel'))),
        FilledButton(key: const ValueKey('lc-save'), onPressed: _saving ? null : () => _save(formulas), child: Text(context.t('lcFind'))),
      ],
    );
  }
}
