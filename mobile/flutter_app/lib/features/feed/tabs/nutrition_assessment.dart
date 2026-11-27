import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/i18n/strings.dart';
import '../../../core/theme/colors.dart';
import '../../../core/theme/typography.dart';
import '../../../core/util/number_input.dart';
import '../../../core/widgets/form_dialog.dart';
import '../../../core/widgets/section_card.dart';
import '../../../core/widgets/status_pill.dart';
import '../../../domain/entities/access.dart';
import '../../../domain/entities/feeding.dart';
import '../../../domain/entities/nutrition.dart';
import '../../../providers/access_provider.dart';
import '../../../providers/feeding_provider.dart';
import '../../../providers/livestock_provider.dart';
import '../../../providers/nutrition_provider.dart';
import '../feed_workspace_screen.dart';

/// Nutrient requirements and the assessment of a formula (master prompt
/// Package 11), on the Feed → Nutrition tab of the tablet and the web app.
/// The server does every calculation and keeps every assessment as it was
/// computed; this shows them — the 1,210 kg base kept, the premix on top,
/// *insufficient data* when anything is unknown, never a ration.

bool nuManages(AccessProvider a) => a.can(FarmModule.feedNutrition, PermissionAction.approve);
bool nuAssesses(AccessProvider a) => a.canCreate(FarmModule.feedNutrition) || nuManages(a);

String nuNum(double v, [int digits = 2]) {
  final s = v.toStringAsFixed(digits);
  return s.contains('.') ? s.replaceFirst(RegExp(r'\.?0+$'), '') : s;
}

/// 1210 → "1,210" (the farm reads its mixes in kg, grouped).
String nuKg(double v) {
  final whole = v.truncateToDouble() == v;
  final text = whole ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
  final parts = text.split('.');
  final digits = parts[0];
  final b = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) b.write(',');
    b.write(digits[i]);
  }
  return parts.length > 1 ? '$b.${parts[1]}' : b.toString();
}

String nuRange(double? min, double? max, String unit) {
  if (min != null && max != null) return '${nuNum(min)}–${nuNum(max)} $unit';
  if (min != null) return '≥ ${nuNum(min)} $unit';
  return '≤ ${nuNum(max!)} $unit';
}

FarmStatusLevel nuLevel(String status) => switch (status) {
      'meets' || 'met' => FarmStatusLevel.good,
      'below' || 'above' || 'does_not_meet' => FarmStatusLevel.alert,
      _ => FarmStatusLevel.watch,
    };

/// The requirement sets and the assessments, above the feeds' analyses.
class NutritionAssessmentCards extends StatefulWidget {
  const NutritionAssessmentCards({super.key});

  @override
  State<NutritionAssessmentCards> createState() => _NutritionAssessmentCardsState();
}

class _NutritionAssessmentCardsState extends State<NutritionAssessmentCards> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<NutritionProvider>().load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final nut = context.watch<NutritionProvider>();
    final access = context.watch<AccessProvider>();
    final lang = Localizations.localeOf(context).languageCode;
    final manages = nuManages(access);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionCard(
        key: const ValueKey('nu-assessments'),
        title: context.t('nuAssessTitle'),
        subtitle: context.t('nuAssessSubtitle'),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (nuAssesses(access))
            FilledButton.icon(
              key: const ValueKey('nu-assess'),
              onPressed: nut.sets.isEmpty ? null : () => showDialog<void>(context: context, builder: (_) => const _AssessDialog()),
              icon: const Icon(Icons.fact_check_outlined, size: 16),
              label: Text(context.t('nuAssess')),
            ),
          if (nut.sets.isEmpty && nut.loaded) Padding(padding: const EdgeInsets.only(top: 6), child: Text(context.t('nuNeedSet'), style: FarmTypography.textTheme.bodySmall)),
          for (final a in nut.assessments)
            // A Material of its own: the card's coloured box would hide the tap's ripple.
            Material(
              type: MaterialType.transparency,
              child: InkWell(
                key: ValueKey('nu-a-${a.id}'),
                onTap: () => showAssessmentResult(context, a),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(children: [
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('${a.formulaName} v${a.formulaVersion} · ${a.setCode} v${a.setVersion}', style: FarmTypography.textTheme.titleSmall),
                        Text([if (a.createdAt != null) feedDate(a.createdAt!), if (a.createdByName != null) a.createdByName!].join(' · '),
                            style: FarmTypography.textTheme.bodySmall),
                      ]),
                    ),
                    StatusPill(label: context.t('nuStatus_${a.status}'), level: nuLevel(a.status), dense: true),
                  ]),
                ),
              ),
            ),
        ]),
      ),
      const SizedBox(height: 12),
      SectionCard(
        key: const ValueKey('nu-requirements'),
        title: context.t('nuReqTitle'),
        subtitle: context.t('nuReqSubtitle'),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (manages)
            OutlinedButton.icon(
              key: const ValueKey('nu-req-add'),
              onPressed: () => showDialog<void>(context: context, builder: (_) => const _RequirementDialog()),
              icon: const Icon(Icons.add, size: 16),
              label: Text(context.t('nuReqAdd')),
            ),
          if (nut.sets.isEmpty) const FeedEmpty('nuReqNone'),
          for (final s in nut.sets)
            Padding(
              key: ValueKey('nu-set-${s.id}'),
              padding: const EdgeInsets.only(top: 10),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(child: Text('${s.code} v${s.version} · ${s.name}', style: FarmTypography.textTheme.titleSmall)),
                  if (manages)
                    TextButton(
                      key: ValueKey('nu-req-revise-${s.id}'),
                      onPressed: () => showDialog<void>(context: context, builder: (_) => _RequirementDialog(revising: s)),
                      child: Text(context.t('nuReqRevise')),
                    ),
                ]),
                Text(
                  [
                    s.speciesCode,
                    if (s.stage != null) s.stage!,
                    if (s.referenceWeightKg != null) '${nuNum(s.referenceWeightKg!)} kg',
                    if (s.expectedDmiKg != null) context.t('nuDmiShort').replaceAll('{kg}', nuNum(s.expectedDmiKg!)),
                  ].join(' · '),
                  style: FarmTypography.textTheme.bodySmall,
                ),
                Text('${context.t('nuSource')}: ${s.sourceReference}', style: const TextStyle(fontSize: 12, color: FarmColors.muted)),
                Wrap(spacing: 6, runSpacing: 4, children: [
                  for (final v in s.values) Chip(visualDensity: VisualDensity.compact, label: Text('${v.label(lang)} ${nuRange(v.min, v.max, v.unit)}', style: const TextStyle(fontSize: 12))),
                ]),
              ]),
            ),
        ]),
      ),
    ]);
  }
}

// ------------------------------------------------------------------ the assessment
Future<void> showAssessmentResult(BuildContext context, NutritionAssessment a) =>
    showDialog<void>(context: context, builder: (_) => _AssessmentResult(assessment: a));

class _AssessmentResult extends StatelessWidget {
  const _AssessmentResult({required this.assessment});
  final NutritionAssessment assessment;

  @override
  Widget build(BuildContext context) {
    final a = assessment;
    final lang = Localizations.localeOf(context).languageCode;
    final small = FarmTypography.textTheme.bodySmall;
    return FarmFormDialog(
      key: const ValueKey('nu-result'),
      title: Text('${a.formulaName} v${a.formulaVersion}'),
      width: 560,
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          StatusPill(key: const ValueKey('nu-result-status'), label: context.t('nuStatus_${a.status}'), level: nuLevel(a.status)),
          const SizedBox(width: 8),
          Expanded(child: Text('${a.setCode} v${a.setVersion} · ${a.setSource}', style: small)),
        ]),
        const SizedBox(height: 12),
        // The mass balance: the formula's own quantities, the premix on top.
        Text(context.t('nuMix'), style: FarmTypography.textTheme.titleSmall),
        for (final c in a.components)
          FeedKeyValue('${c.name}${c.profileSource == null ? ' · ${context.t('nuNoAnalysis')}' : ''}', '${nuKg(c.quantityKg)} kg · ${nuNum(c.inclusionPct)} %'),
        FeedKeyValue(context.t('nuBaseTotal'), '${nuKg(a.baseTotalKg)} kg', bold: true),
        if (a.premix != null) ...[
          FeedKeyValue('${context.t('nuPremix')}: ${a.premix!.name}', '+ ${nuKg(a.premix!.quantityKg)} kg · ${nuNum(a.premix!.inclusionPct)} %'),
          FeedKeyValue(context.t('nuWithPremix'), '${nuKg(a.totalKg)} kg', bold: true),
        ],
        if (a.mixDryMatterKg != null)
          FeedKeyValue(context.t('nuDryMatter'), '${nuKg(a.mixDryMatterKg!)} kg · ${nuNum(a.mixDmPct ?? 0, 1)} %'),
        const Divider(height: 20),
        if (a.missing.isNotEmpty) ...[
          Text(context.t('nuMissing'), key: const ValueKey('nu-missing'), style: FarmTypography.textTheme.titleSmall?.copyWith(color: FarmColors.warning)),
          for (final m in a.missing) Padding(padding: const EdgeInsets.only(top: 2), child: Text('• ${m.detail}', style: small)),
          const Divider(height: 20),
        ],
        Text(context.t('nuRation'), style: FarmTypography.textTheme.titleSmall),
        if (a.dryMatterIntakeKg != null)
          FeedKeyValue(
            context.t('nuDmi'),
            '${nuNum(a.dryMatterIntakeKg!)} kg${a.expectedDmiKg != null ? ' (${context.t('nuExpected')} ${nuNum(a.expectedDmiKg!)} kg)' : ''}',
          ),
        for (final n in a.rationNutrients)
          Padding(
            key: ValueKey('nu-r-${n.code}'),
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(children: [
              Expanded(child: Text('${n.label(lang)} · ${nuRange(n.min, n.max, n.unit)}', style: small)),
              Text(n.value == null ? '—' : '${nuNum(n.value!)} ${n.unit}', style: FarmTypography.textTheme.bodyMedium),
              const SizedBox(width: 8),
              StatusPill(label: context.t('nuStatus_${n.status}'), level: nuLevel(n.status), dense: true),
            ]),
          ),
        const Divider(height: 20),
        Text(
          a.recommendation ?? context.t('nuNoRecommendation'),
          key: const ValueKey('nu-recommendation'),
          style: TextStyle(fontSize: 13, color: a.recommendation == null ? FarmColors.warning : null),
        ),
        const SizedBox(height: 8),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: Text(context.t('nuMixNutrients'), style: FarmTypography.textTheme.titleSmall),
          children: [
            for (final n in a.mixNutrients)
              FeedKeyValue(
                n.label(lang),
                '${n.asFed == null ? '—' : nuNum(n.asFed!)} ${context.t('nuAsFed')} · ${n.dryMatter == null ? '—' : nuNum(n.dryMatter!)} ${context.t('nuOnDm')}'
                '${n.coveragePct < 100 ? ' · ${context.t('nuCoverage').replaceAll('{pct}', nuNum(n.coveragePct, 1))}' : ''}',
              ),
          ],
        ),
      ]),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(context.t('close')))],
    );
  }
}

class _AssessDialog extends StatefulWidget {
  const _AssessDialog();

  @override
  State<_AssessDialog> createState() => _AssessDialogState();
}

class _AssessDialogState extends State<_AssessDialog> {
  String? _formulaId;
  String? _setId;
  String? _forageId;
  String? _premixId;
  bool _feedOnly = false;
  bool _withPremix = false;
  bool _saving = false;
  String? _error;
  final _conc = TextEditingController();
  final _forageKg = TextEditingController();
  final _weight = TextEditingController();
  final _premixKg = TextEditingController();

  @override
  void dispose() {
    for (final c in [_conc, _forageKg, _weight, _premixKg]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save(List<FeedFormula> formulas) async {
    FeedFormula? formula;
    for (final f in formulas) {
      if (f.id == _formulaId) formula = f;
    }
    final version = formula?.active;
    if (version == null || _setId == null) {
      setState(() => _error = context.t('nuChooseFormulaAndSet'));
      return;
    }
    final premixKg = parseLocalizedDouble(_premixKg.text);
    if (_withPremix && (_premixId == null || premixKg == null || premixKg <= 0)) {
      setState(() => _error = context.t('nuPremixIncomplete'));
      return;
    }
    final forageKg = parseLocalizedDouble(_forageKg.text);
    setState(() {
      _saving = true;
      _error = null;
    });
    final (result, assessment) = await context.read<NutritionProvider>().assess({
      'formula_version_id': version.id,
      'requirement_set_id': _setId,
      'concentrate_kg_per_head': ?parseLocalizedDouble(_conc.text),
      'forages': [
        if (!_feedOnly && _forageId != null && forageKg != null && forageKg > 0) {'feed_product_id': _forageId, 'as_fed_kg': forageKg},
      ],
      'no_forage': _feedOnly,
      'body_weight_kg': ?parseLocalizedDouble(_weight.text),
      if (_withPremix) 'premix': {'feed_product_id': _premixId, 'quantity_kg': premixKg},
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
    if (assessment != null) {
      await showAssessmentResult(context, assessment);
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
      title: Text(context.t('nuAssess')),
      width: 520,
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(context.t('nuAssessHelp'), style: FarmTypography.textTheme.bodySmall),
        DropdownButtonFormField<String>(
          key: const ValueKey('nu-assess-formula'),
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
          key: const ValueKey('nu-assess-set'),
          isExpanded: true,
          value: _setId,
          decoration: InputDecoration(labelText: context.t('nuReqSet')),
          items: [for (final s in sets) DropdownMenuItem(value: s.id, child: Text('${s.code} v${s.version} · ${s.name}', overflow: TextOverflow.ellipsis))],
          onChanged: (v) => setState(() => _setId = v),
        ),
        number('nu-assess-conc', _conc, context.t('nuConcPerHead'), helper: context.t('nuUnknownHelp')),
        SwitchListTile(
          key: const ValueKey('nu-assess-only'),
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
                key: const ValueKey('nu-assess-forage'),
                isExpanded: true,
                value: _forageId,
                decoration: InputDecoration(labelText: context.t('nuForage')),
                items: [for (final p in forages) DropdownMenuItem(value: p.id, child: Text(p.label(lang), overflow: TextOverflow.ellipsis))],
                onChanged: (v) => setState(() => _forageId = v),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(flex: 2, child: number('nu-assess-forage-kg', _forageKg, context.t('nuForageKg'))),
          ]),
        number('nu-assess-weight', _weight, context.t('nuBodyWeight')),
        SwitchListTile(
          key: const ValueKey('nu-assess-premix'),
          contentPadding: EdgeInsets.zero,
          value: _withPremix,
          onChanged: (v) => setState(() => _withPremix = v),
          title: Text(context.t('nuAddPremix')),
          subtitle: Text(context.t('nuPremixHelp')),
        ),
        if (_withPremix)
          Row(children: [
            Expanded(
              flex: 3,
              child: DropdownButtonFormField<String>(
                key: const ValueKey('nu-assess-premix-product'),
                isExpanded: true,
                value: _premixId,
                decoration: InputDecoration(labelText: context.t('nuPremix')),
                items: [for (final p in feeding.ingredients) DropdownMenuItem(value: p.id, child: Text(p.label(lang), overflow: TextOverflow.ellipsis))],
                onChanged: (v) => setState(() => _premixId = v),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(flex: 2, child: number('nu-assess-premix-kg', _premixKg, context.t('nuPremixKg'))),
          ]),
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: const TextStyle(color: FarmColors.danger))),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(context.t('cancel'))),
        FilledButton(key: const ValueKey('nu-assess-save'), onPressed: _saving ? null : () => _save(formulas), child: Text(context.t('nuAssessNow'))),
      ],
    );
  }
}

// ------------------------------------------------------------------ requirement sets
class _RequirementDialog extends StatefulWidget {
  const _RequirementDialog({this.revising});

  /// A new version of this set (its own source; the old one kept, retired).
  final RequirementSet? revising;

  @override
  State<_RequirementDialog> createState() => _RequirementDialogState();
}

class _RequirementDialogState extends State<_RequirementDialog> {
  late final _code = TextEditingController(text: widget.revising?.code ?? '');
  late final _name = TextEditingController(text: widget.revising?.name ?? '');
  late final _stage = TextEditingController(text: widget.revising?.stage ?? '');
  late final _weight = TextEditingController(text: widget.revising?.referenceWeightKg == null ? '' : nuNum(widget.revising!.referenceWeightKg!));
  late final _dmi = TextEditingController(text: widget.revising?.expectedDmiKg == null ? '' : nuNum(widget.revising!.expectedDmiKg!));
  final _source = TextEditingController();
  late String? _species = widget.revising?.speciesCode;
  final Map<String, (TextEditingController, TextEditingController)> _bounds = {};
  bool _saving = false;
  String? _error;

  (TextEditingController, TextEditingController) _field(String code) => _bounds.putIfAbsent(code, () {
        RequirementValue? old;
        for (final v in widget.revising?.values ?? const <RequirementValue>[]) {
          if (v.code == code) old = v;
        }
        return (
          TextEditingController(text: old?.min == null ? '' : nuNum(old!.min!, 3)),
          TextEditingController(text: old?.max == null ? '' : nuNum(old!.max!, 3)),
        );
      });

  @override
  void dispose() {
    for (final c in [_code, _name, _stage, _weight, _dmi, _source]) {
      c.dispose();
    }
    for (final pair in _bounds.values) {
      pair.$1.dispose();
      pair.$2.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final values = [
      for (final e in _bounds.entries)
        if (parseLocalizedDouble(e.value.$1.text) != null || parseLocalizedDouble(e.value.$2.text) != null)
          {'nutrient_code': e.key, 'min_value': ?parseLocalizedDouble(e.value.$1.text), 'max_value': ?parseLocalizedDouble(e.value.$2.text)},
    ];
    if (_source.text.trim().isEmpty) return setState(() => _error = context.t('nuSourceNeeded'));
    if (values.isEmpty) return setState(() => _error = context.t('nuValuesNeeded'));
    final revising = widget.revising;
    if (revising == null && (_code.text.trim().isEmpty || _name.text.trim().isEmpty || _species == null)) {
      return setState(() => _error = context.t('nuReqIncomplete'));
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final body = <String, dynamic>{
      if (revising == null) ...{'code': _code.text.trim(), 'species_code': _species},
      'name': _name.text.trim(),
      if (_stage.text.trim().isNotEmpty) 'production_stage': _stage.text.trim(),
      'reference_body_weight_kg': ?parseLocalizedDouble(_weight.text),
      'expected_dmi_kg': ?parseLocalizedDouble(_dmi.text),
      'source_reference': _source.text.trim(),
      'values': values,
    };
    final provider = context.read<NutritionProvider>();
    final result = revising == null ? await provider.createSet(body) : await provider.revise(revising.id, body);
    if (!mounted) return;
    if (result.success) {
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.t(result.queued ? 'nuQueued' : 'nuReqSaved'))));
      return;
    }
    setState(() {
      _saving = false;
      _error = result.error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final nutrients = [for (final n in context.watch<FeedingProvider>().nutrients) if (n.code != 'DM' && n.code != 'MOISTURE') n];
    final species = context.watch<LivestockProvider>().species;
    final lang = Localizations.localeOf(context).languageCode;
    final revising = widget.revising;
    return FarmFormDialog(
      title: Text(revising == null ? context.t('nuReqAdd') : '${context.t('nuReqRevise')} · ${revising.code} v${revising.version + 1}'),
      width: 560,
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (revising == null) ...[
          Row(children: [
            Expanded(child: TextField(key: const ValueKey('nu-req-code'), controller: _code, decoration: InputDecoration(labelText: context.t('nuCode')))),
            const SizedBox(width: 10),
            Expanded(
              child: DropdownButtonFormField<String>(
                key: const ValueKey('nu-req-species'),
                isExpanded: true,
                value: _species,
                decoration: InputDecoration(labelText: context.t('nuSpecies')),
                items: [for (final s in species) DropdownMenuItem(value: s.code, child: Text(lang == 'ar' ? s.nameAr : s.nameEn))],
                onChanged: (v) => setState(() => _species = v),
              ),
            ),
          ]),
        ],
        TextField(key: const ValueKey('nu-req-name'), controller: _name, decoration: InputDecoration(labelText: context.t('nuName'))),
        Row(children: [
          Expanded(child: TextField(key: const ValueKey('nu-req-stage'), controller: _stage, decoration: InputDecoration(labelText: context.t('nuStage')))),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              key: const ValueKey('nu-req-weight'),
              controller: _weight,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(labelText: context.t('nuRefWeight')),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              key: const ValueKey('nu-req-dmi'),
              controller: _dmi,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(labelText: context.t('nuExpectedDmi')),
            ),
          ),
        ]),
        TextField(
          key: const ValueKey('nu-req-source'),
          controller: _source,
          decoration: InputDecoration(labelText: context.t('nuSource'), helperText: context.t('nuSourceHelp'), helperMaxLines: 2),
        ),
        const SizedBox(height: 10),
        Text(context.t('nuValuesHelp'), style: FarmTypography.textTheme.bodySmall),
        for (final n in nutrients)
          Row(children: [
            Expanded(flex: 3, child: Text('${n.label(lang)} (${n.unit})', style: const TextStyle(fontSize: 13))),
            Expanded(
              flex: 2,
              child: TextField(
                key: ValueKey('nu-req-min-${n.code}'),
                controller: _field(n.code).$1,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(labelText: context.t('nuMin'), isDense: true),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 2,
              child: TextField(
                key: ValueKey('nu-req-max-${n.code}'),
                controller: _field(n.code).$2,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(labelText: context.t('nuMax'), isDense: true),
              ),
            ),
          ]),
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: const TextStyle(color: FarmColors.danger))),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(context.t('cancel'))),
        FilledButton(key: const ValueKey('nu-req-save'), onPressed: _saving ? null : _save, child: Text(context.t('save'))),
      ],
    );
  }
}
