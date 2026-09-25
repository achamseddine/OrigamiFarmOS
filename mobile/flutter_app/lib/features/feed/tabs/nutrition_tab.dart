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
import '../feed_workspace_screen.dart';

/// Nutrient profiles (§8): what each feed declares, what the lab measured,
/// side by side — a lab result never overwrites the declaration. Values
/// are rows keyed by the nutrient catalog, so a new analyte needs no
/// screen change.
class NutritionTab extends StatelessWidget {
  const NutritionTab({super.key});

  @override
  Widget build(BuildContext context) {
    final feeding = context.watch<FeedingProvider>();
    final access = context.watch<AccessProvider>();
    final lang = Localizations.localeOf(context).languageCode;
    final canCreate = access.canCreate(FarmModule.feedNutrition);
    return FeedTabScaffold(children: [
      SectionCard(
        title: context.t('nutrition'),
        subtitle: context.t('nutritionSubtitle'),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (canCreate)
            FilledButton.icon(onPressed: () => _showAnalysisDialog(context), icon: const Icon(Icons.science_outlined, size: 16), label: Text(context.t('addLabAnalysis'))),
          if (feeding.products.isEmpty) const FeedEmpty('noFeedItems'),
          for (final p in feeding.products) ...[const SizedBox(height: 10), _ProfilesCard(product: p, lang: lang)],
        ]),
      ),
    ]);
  }
}

class _ProfilesCard extends StatefulWidget {
  const _ProfilesCard({required this.product, required this.lang});
  final FeedProduct product;
  final String lang;
  @override
  State<_ProfilesCard> createState() => _ProfilesCardState();
}

class _ProfilesCardState extends State<_ProfilesCard> {
  List<NutrientProfile>? _profiles;

  Future<void> _load() async {
    if (_profiles != null) return;
    final rows = await context.read<FeedingProvider>().profilesFor('feed_product', widget.product.id);
    if (mounted) setState(() => _profiles = rows);
  }

  @override
  Widget build(BuildContext context) {
    final nutrients = context.read<FeedingProvider>().nutrients;
    String nameOf(String code) {
      for (final n in nutrients) {
        if (n.code == code) return n.label(widget.lang);
      }
      return code;
    }

    return Container(
      decoration: BoxDecoration(color: FarmColors.stone, borderRadius: BorderRadius.circular(FarmRadii.md)),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 14),
        childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
        onExpansionChanged: (open) {
          if (open) _load();
        },
        title: Text(widget.product.label(widget.lang), style: FarmTypography.textTheme.titleSmall),
        subtitle: Text(widget.product.category ?? '', style: FarmTypography.textTheme.bodySmall),
        children: [
          if (_profiles == null) const Padding(padding: EdgeInsets.all(8), child: Center(child: SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))))
          else if (_profiles!.isEmpty) const FeedEmpty('noProfilesYet')
          else
            for (final p in _profiles!) ...[
              Row(children: [
                StatusPill(label: context.t('profileSource_${p.sourceType}'), level: p.sourceType == 'lab' ? FarmStatusLevel.good : FarmStatusLevel.neutral, dense: true),
                const SizedBox(width: 6),
                Text('${context.t('basis_${p.basis}')} · ${feedDate(p.effectiveAt)}${p.reference != null ? ' · ${p.reference}' : ''}', style: FarmTypography.textTheme.bodySmall),
              ]),
              for (final v in p.values) FeedKeyValue(nameOf(v['nutrient_code'] as String), '${v['value']} ${v['unit']}'),
              const SizedBox(height: 8),
            ],
        ],
      ),
    );
  }
}

Future<void> _showAnalysisDialog(BuildContext context) => showDialog<void>(context: context, builder: (_) => const _AnalysisDialog());

class _AnalysisDialog extends StatefulWidget {
  const _AnalysisDialog();
  @override
  State<_AnalysisDialog> createState() => _AnalysisDialogState();
}

class _AnalysisDialogState extends State<_AnalysisDialog> {
  String? _productId;
  String _basis = 'as_fed';
  String _source = 'lab';
  final _reference = TextEditingController();
  final Map<String, TextEditingController> _values = {};
  bool _saving = false;
  String? _error;

  TextEditingController _field(String code) => _values.putIfAbsent(code, TextEditingController.new);

  @override
  void dispose() {
    _reference.dispose();
    for (final c in _values.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    final values = [
      for (final e in _values.entries)
        if (double.tryParse(e.value.text) != null) {'nutrient_code': e.key, 'value': double.parse(e.value.text)},
    ];
    if (_productId == null || values.isEmpty) {
      setState(() => _error = context.t('analysisIncomplete'));
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final result = await context.read<FeedingProvider>().recordNutrientProfile({
      'subject_type': 'feed_product', 'subject_id': _productId, 'basis': _basis, 'source_type': _source,
      if (_reference.text.trim().isNotEmpty) 'reference': _reference.text.trim(), 'values': values,
    });
    if (!mounted) return;
    if (result.success) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.t('analysisRecorded'))));
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
    final lang = Localizations.localeOf(context).languageCode;
    return AlertDialog(
      title: Text(context.t('addLabAnalysis')),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            DropdownButtonFormField<String>(
              value: _productId,
              isExpanded: true,
              decoration: InputDecoration(labelText: context.t('feedItem')),
              items: [for (final p in feeding.products) DropdownMenuItem(value: p.id, child: Text(p.label(lang), overflow: TextOverflow.ellipsis))],
              onChanged: (v) => setState(() => _productId = v),
            ),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  value: _source,
                  decoration: InputDecoration(labelText: context.t('sourceType')),
                  items: [DropdownMenuItem(value: 'lab', child: Text(context.t('profileSource_lab'))), DropdownMenuItem(value: 'declared', child: Text(context.t('profileSource_declared')))],
                  onChanged: (v) => setState(() => _source = v ?? _source),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: DropdownButtonFormField<String>(
                  value: _basis,
                  decoration: InputDecoration(labelText: context.t('basis')),
                  items: [DropdownMenuItem(value: 'as_fed', child: Text(context.t('basis_as_fed'))), DropdownMenuItem(value: 'dry_matter', child: Text(context.t('basis_dry_matter')))],
                  onChanged: (v) => setState(() => _basis = v ?? _basis),
                ),
              ),
            ]),
            const SizedBox(height: 10),
            TextField(controller: _reference, decoration: InputDecoration(labelText: context.t('labReference'))),
            const SizedBox(height: 10),
            Wrap(spacing: 10, runSpacing: 10, children: [
              for (final n in feeding.nutrients)
                SizedBox(
                  width: 140,
                  child: TextField(
                    controller: _field(n.code),
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(labelText: n.label(lang), suffixText: n.unit),
                  ),
                ),
            ]),
            if (_error != null) ...[const SizedBox(height: 8), Text(_error!, style: const TextStyle(color: FarmColors.danger, fontSize: 12.5))],
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(context.t('cancel'))),
        FilledButton(onPressed: _saving ? null : _submit, child: Text(context.t('save'))),
      ],
    );
  }
}
