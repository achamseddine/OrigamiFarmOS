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

/// Formulas and their versions (§5–§7): the recipe family, the immutable
/// compositions, which one is active, which are locked by a batch, and
/// the calculated nutrient profile of the active one.
class FormulasTab extends StatelessWidget {
  const FormulasTab({super.key});

  @override
  Widget build(BuildContext context) {
    final feeding = context.watch<FeedingProvider>();
    final access = context.watch<AccessProvider>();
    final lang = Localizations.localeOf(context).languageCode;
    final canCreate = access.canCreate(FarmModule.feedNutrition);

    return FeedTabScaffold(children: [
      SectionCard(
        title: context.t('formulas'),
        subtitle: context.t('formulasSubtitle'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (canCreate)
              FilledButton.icon(
                onPressed: feeding.farmProduced.isEmpty ? null : () => showFormulaDialog(context),
                icon: const Icon(Icons.add, size: 16),
                label: Text(context.t('newFormula')),
              ),
            if (feeding.farmProduced.isEmpty) const FeedEmpty('noFarmProducedFeeds'),
            if (feeding.formulas.isEmpty) const FeedEmpty('noFormulasYet'),
            for (final f in feeding.formulas) ...[
              const SizedBox(height: 10),
              _FormulaCard(formula: f, lang: lang, canCreate: canCreate),
            ],
          ],
        ),
      ),
    ]);
  }
}

class _FormulaCard extends StatefulWidget {
  const _FormulaCard({required this.formula, required this.lang, required this.canCreate});
  final FeedFormula formula;
  final String lang;
  final bool canCreate;

  @override
  State<_FormulaCard> createState() => _FormulaCardState();
}

class _FormulaCardState extends State<_FormulaCard> {
  Map<String, dynamic>? _nutrients;
  bool _loadingNutrients = false;

  Future<void> _loadNutrients() async {
    final active = widget.formula.active;
    if (active == null) return;
    setState(() => _loadingNutrients = true);
    final body = await context.read<FeedingProvider>().formulaNutrients(widget.formula.id, active.version);
    if (!mounted) return;
    setState(() {
      _nutrients = body;
      _loadingNutrients = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final f = widget.formula;
    final active = f.active;
    final livestock = context.watch<LivestockProvider>();
    return Container(
      decoration: BoxDecoration(color: FarmColors.stone, borderRadius: BorderRadius.circular(FarmRadii.md)),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 14),
        childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
        title: Text(f.name, style: FarmTypography.textTheme.titleSmall),
        subtitle: Text(
          [
            f.productName ?? f.code,
            f.speciesCode == null ? context.t('anySpecies') : livestock.speciesName(f.speciesCode!, widget.lang),
            if (active != null) 'v${active.version} · ${feedNumber(active.batchSize)} ${active.unit}',
          ].join(' · '),
          style: FarmTypography.textTheme.bodySmall,
        ),
        trailing: active == null ? null : StatusPill(label: 'v${active.version}', level: FarmStatusLevel.good, dense: true),
        children: [
          if (active != null) ...[
            Text(context.t('components'), style: const TextStyle(fontSize: 11, color: FarmColors.muted, fontWeight: FontWeight.w700, letterSpacing: 0.4)),
            for (final c in active.components)
              FeedKeyValue(
                c.productName ?? c.feedProductId,
                '${feedNumber(c.targetQuantity)} ${c.unit}${c.targetPercentage != null ? ' · ${c.targetPercentage!.toStringAsFixed(1)}%' : ''}',
              ),
            if (active.plannedCost != null) FeedKeyValue(context.t('plannedCost'), '${feedMoney(active.plannedCost!)} / ${feedNumber(active.batchSize)} ${active.unit}', bold: true),
            const SizedBox(height: 8),
          ],
          Text(context.t('versions'), style: const TextStyle(fontSize: 11, color: FarmColors.muted, fontWeight: FontWeight.w700, letterSpacing: 0.4)),
          for (final v in f.versions.reversed)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(children: [
                Expanded(child: Text('v${v.version} — ${feedNumber(v.batchSize)} ${v.unit}${v.notes != null ? ' · ${v.notes}' : ''}', style: FarmTypography.textTheme.bodyMedium, overflow: TextOverflow.ellipsis)),
                if (v.locked) ...[const Icon(Icons.lock_outline, size: 14, color: FarmColors.muted), const SizedBox(width: 6)],
                StatusPill(label: context.t('version_${v.status}'), level: feedStatusLevel(v.status), dense: true),
              ]),
            ),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            if (widget.canCreate && active != null)
              OutlinedButton.icon(
                onPressed: () => showFormulaDialog(context, formula: f),
                icon: const Icon(Icons.add, size: 16),
                label: Text(context.t('newVersion')),
              ),
            if (active != null)
              OutlinedButton.icon(
                onPressed: _loadingNutrients ? null : _loadNutrients,
                icon: const Icon(Icons.science_outlined, size: 16),
                label: Text(context.t('calculatedNutrients')),
              ),
          ]),
          if (_nutrients != null) ...[
            const SizedBox(height: 8),
            _NutrientTable(body: _nutrients!, nutrients: context.read<FeedingProvider>().nutrients, lang: widget.lang),
          ],
        ],
      ),
    );
  }
}

class _NutrientTable extends StatelessWidget {
  const _NutrientTable({required this.body, required this.nutrients, required this.lang});
  final Map<String, dynamic> body;
  final List<NutrientDef> nutrients;
  final String lang;

  @override
  Widget build(BuildContext context) {
    final values = (body['values'] as List<dynamic>? ?? const []).cast<Map<String, dynamic>>();
    final missing = (body['missing_profiles'] as List<dynamic>? ?? const []).cast<String>();
    String nameOf(String code) {
      for (final n in nutrients) {
        if (n.code == code) return n.label(lang);
      }
      return code;
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      FeedKeyValue(context.t('coverage'), '${body['coverage_pct'] ?? 0}% · ${context.t('basis_${body['basis'] ?? 'as_fed'}')}'),
      for (final v in values) FeedKeyValue(nameOf(v['nutrient_code'] as String), '${v['value']} ${v['unit']}'),
      if (missing.isNotEmpty) Text('${context.t('noProfilesYet')} ${missing.join(', ')}', style: const TextStyle(fontSize: 12, color: FarmColors.warningInk)),
    ]);
  }
}

// ------------------------------------------------------------- dialog
/// New formula, or a new version of an existing one (the components of
/// the active version are the starting point).
Future<void> showFormulaDialog(BuildContext context, {FeedFormula? formula}) {
  return showDialog<void>(context: context, builder: (_) => _FormulaDialog(formula: formula));
}

class _ComponentLine {
  _ComponentLine({this.productId, double? quantity}) : quantity = TextEditingController(text: quantity == null ? '' : feedNumber(quantity));
  String? productId;
  final TextEditingController quantity;
}

class _FormulaDialog extends StatefulWidget {
  const _FormulaDialog({this.formula});
  final FeedFormula? formula;
  @override
  State<_FormulaDialog> createState() => _FormulaDialogState();
}

class _FormulaDialogState extends State<_FormulaDialog> {
  late final _name = TextEditingController(text: widget.formula?.name ?? '');
  late final _batchSize = TextEditingController(text: feedNumber(widget.formula?.active?.batchSize ?? 1000));
  final _notes = TextEditingController();
  late String? _productId = widget.formula?.feedProductId;
  late String? _species = widget.formula?.speciesCode;
  late final List<_ComponentLine> _lines = [
    for (final c in widget.formula?.active?.components ?? const <FormulaComponent>[]) _ComponentLine(productId: c.feedProductId, quantity: c.targetQuantity),
    if (widget.formula == null) _ComponentLine(),
  ];
  bool _saving = false;
  String? _error;

  bool get _isVersion => widget.formula != null;

  @override
  void dispose() {
    _name.dispose();
    _batchSize.dispose();
    _notes.dispose();
    for (final l in _lines) {
      l.quantity.dispose();
    }
    super.dispose();
  }

  double get _total => _lines.fold(0.0, (s, l) => s + (double.tryParse(l.quantity.text) ?? 0));

  Future<void> _submit() async {
    final size = double.tryParse(_batchSize.text.trim());
    final components = [
      for (final l in _lines)
        if (l.productId != null && (double.tryParse(l.quantity.text) ?? 0) > 0) {'feed_product_id': l.productId, 'target_quantity': double.parse(l.quantity.text)},
    ];
    if (size == null || size <= 0 || components.isEmpty || (!_isVersion && (_name.text.trim().isEmpty || _productId == null))) {
      setState(() => _error = context.t('formulaIncomplete'));
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final feeding = context.read<FeedingProvider>();
    final result = _isVersion
        ? await feeding.addFormulaVersion(widget.formula!.id, {'batch_size': size, 'components': components, if (_notes.text.trim().isNotEmpty) 'notes': _notes.text.trim()})
        : await feeding.createFormula({
            'name': _name.text.trim(), 'feed_product_id': _productId, 'species_code': _species, 'batch_size': size, 'components': components,
            if (_notes.text.trim().isNotEmpty) 'description': _notes.text.trim(),
          });
    if (!mounted) return;
    if (result.success) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.t(_isVersion ? 'versionCreated' : 'formulaCreated'))));
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
    final ingredients = feeding.ingredients;
    final size = double.tryParse(_batchSize.text) ?? 0;
    return AlertDialog(
      title: Text(_isVersion ? '${context.t('newVersion')} — ${widget.formula!.name}' : context.t('newFormula')),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (!_isVersion) ...[
              TextField(controller: _name, autofocus: true, decoration: InputDecoration(labelText: context.t('formula'))),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: _productId,
                    isExpanded: true,
                    decoration: InputDecoration(labelText: context.t('producesFeed')),
                    items: [for (final p in feeding.farmProduced) DropdownMenuItem(value: p.id, child: Text(p.label(lang), overflow: TextOverflow.ellipsis))],
                    onChanged: (v) => setState(() => _productId = v),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: DropdownButtonFormField<String?>(
                    value: _species,
                    isExpanded: true,
                    decoration: InputDecoration(labelText: context.t('forSpecies')),
                    items: [
                      DropdownMenuItem<String?>(value: null, child: Text(context.t('anySpecies'))),
                      for (final s in livestock.species) DropdownMenuItem<String?>(value: s.code, child: Text(s.name(lang))),
                    ],
                    onChanged: (v) => setState(() => _species = v),
                  ),
                ),
              ]),
              const SizedBox(height: 10),
            ],
            TextField(
              controller: _batchSize,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: '${context.t('batchSize')} (kg)'),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 10),
            Text(context.t('components'), style: const TextStyle(fontSize: 11, color: FarmColors.muted, fontWeight: FontWeight.w700, letterSpacing: 0.4)),
            for (var i = 0; i < _lines.length; i++)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(children: [
                  Expanded(
                    flex: 3,
                    child: DropdownButtonFormField<String>(
                      value: ingredients.any((p) => p.id == _lines[i].productId) ? _lines[i].productId : null,
                      isExpanded: true,
                      decoration: InputDecoration(labelText: context.t('ingredient')),
                      items: [for (final p in ingredients) DropdownMenuItem(value: p.id, child: Text(p.label(lang), overflow: TextOverflow.ellipsis))],
                      onChanged: (v) => setState(() => _lines[i].productId = v),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 2,
                    child: TextField(
                      controller: _lines[i].quantity,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: InputDecoration(labelText: context.t('targetQuantity'), suffixText: size > 0 ? '${((double.tryParse(_lines[i].quantity.text) ?? 0) / size * 100).toStringAsFixed(1)}%' : null),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  IconButton(
                    onPressed: _lines.length == 1 ? null : () => setState(() => _lines.removeAt(i).quantity.dispose()),
                    icon: const Icon(Icons.remove_circle_outline, size: 18, color: FarmColors.muted),
                  ),
                ]),
              ),
            TextButton.icon(onPressed: () => setState(() => _lines.add(_ComponentLine())), icon: const Icon(Icons.add, size: 16), label: Text(context.t('addComponent'))),
            FeedKeyValue(context.t('total'), '${feedNumber(_total)} / ${feedNumber(size)} kg', bold: true, valueColor: (size - _total).abs() > size * 0.02 ? FarmColors.danger : FarmColors.success),
            TextField(controller: _notes, decoration: InputDecoration(labelText: context.t('notes'))),
            if (_error != null) ...[const SizedBox(height: 8), Text(_error!, style: const TextStyle(color: FarmColors.danger, fontSize: 12.5))],
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(context.t('cancel'))),
        FilledButton(onPressed: _saving ? null : _submit, child: Text(context.t(_isVersion ? 'newVersion' : 'save'))),
      ],
    );
  }
}
