import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/widgets/ux_blocks.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/widgets/section_card.dart';
import '../../core/widgets/status_pill.dart';
import '../../domain/entities/mouneh.dart';
import '../../providers/mouneh_provider.dart';
import '../../core/widgets/directional_icon.dart';

/// Product Builder Wizard (tech spec v0.5 §6, screen 2): create ANY
/// value-added farm product — Makdous, Labneh, Kishk, Jam, or a custom
/// name the manager types. Nothing here is a fixed enum of product types.
class ProductBuilderTab extends StatefulWidget {
  const ProductBuilderTab({super.key});

  @override
  State<ProductBuilderTab> createState() => _ProductBuilderTabState();
}

class _ProductBuilderTabState extends State<ProductBuilderTab> {
  int _step = 0;
  final _formKey = GlobalKey<FormState>();

  final _name = TextEditingController();
  final _category = TextEditingController(text: 'Mouneh');
  String _outputUnit = 'jar';
  final _customUnit = TextEditingController();
  final _batchSize = TextEditingController(text: '100');
  final _shelfLife = TextEditingController();
  final _warehouseRules = TextEditingController();
  final _lowStockThreshold = TextEditingController();
  final _targetPrice = TextEditingController();
  final _wholesalePrice = TextEditingController();
  final _targetMargin = TextEditingController(text: '40');

  bool _saving = false;
  String? _error;
  String? _createdProductName;

  @override
  void dispose() {
    for (final c in [_name, _category, _customUnit, _batchSize, _shelfLife, _warehouseRules, _lowStockThreshold, _targetPrice, _wholesalePrice, _targetMargin]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeading(eyebrow: context.t('mnTabProducts'), title: context.t('mnNewProductTitle'), subtitle: context.t('mnNewProductSub')),
          const SizedBox(height: FarmSpacing.md),
          _StepIndicator(step: _step),
          const SizedBox(height: FarmSpacing.md),
          SectionCard(
            child: Form(
              key: _formKey,
              child: _step == 0 ? _basicsStep() : (_step == 1 ? _pricingStep() : _reviewStep()),
            ),
          ),
          const SizedBox(height: FarmSpacing.md),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (_step > 0)
                OutlinedButton(onPressed: _saving ? null : () => setState(() => _step -= 1), child: Text(context.t('mnBack'))),
              const SizedBox(width: 10),
              if (_step < 2)
                FilledButton(
                  onPressed: () {
                    if (_step == 0 && !(_formKey.currentState?.validate() ?? false)) return;
                    setState(() => _step += 1);
                  },
                  child: Text(context.t('mnNext')),
                )
              else
                FilledButton(
                  onPressed: _saving ? null : _submit,
                  child: _saving ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2)) : Text(context.t('mnCreateProduct')),
                ),
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: const TextStyle(color: FarmColors.danger, fontSize: 12.5)),
          ],
          if (_createdProductName != null) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: FarmColors.tint(FarmColors.success, 0.12), borderRadius: BorderRadius.circular(FarmRadii.sm)),
              child: Text(
                '"$_createdProductName" ${context.t('mnCreatedDraft')}',
                style: FarmTypography.textTheme.bodySmall,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _basicsStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(context.t('mnStepBasics'), style: FarmTypography.textTheme.titleMedium),
        const SizedBox(height: FarmSpacing.md),
        TextFormField(
          controller: _name,
          decoration: InputDecoration(labelText: context.t('mnProductName'), hintText: context.t('mnProductNameHint')),
          validator: (v) => (v == null || v.trim().isEmpty) ? context.t('mnRequired') : null,
        ),
        const SizedBox(height: 12),
        TextFormField(controller: _category, decoration: InputDecoration(labelText: context.t('mnCategory'), hintText: context.t('mnCategoryHint'))),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          initialValue: _outputUnit,
          decoration: InputDecoration(labelText: context.t('mnOutputUnit')),
          items: [for (final u in kMounehOutputUnits) DropdownMenuItem(value: u, child: Text(context.t('mnU_$u')))],
          onChanged: (v) => setState(() => _outputUnit = v ?? _outputUnit),
        ),
        if (_outputUnit == 'custom') ...[
          const SizedBox(height: 12),
          TextFormField(controller: _customUnit, decoration: InputDecoration(labelText: context.t('mnCustomUnit'))),
        ],
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: TextFormField(controller: _batchSize, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: context.t('mnDefaultBatch')))),
          const SizedBox(width: 12),
          Expanded(child: TextFormField(controller: _shelfLife, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: context.t('mnShelfLife')))),
        ]),
        const SizedBox(height: 12),
        TextFormField(controller: _warehouseRules, maxLines: 2, decoration: InputDecoration(labelText: context.t('mnStorageRules'))),
      ],
    );
  }

  Widget _pricingStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(context.t('mnStepPricingTitle'), style: FarmTypography.textTheme.titleMedium),
        const SizedBox(height: FarmSpacing.md),
        Row(children: [
          Expanded(child: TextFormField(controller: _targetPrice, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: '${context.t('mnSellingPrice')} (\$)'))),
          const SizedBox(width: 12),
          Expanded(child: TextFormField(controller: _wholesalePrice, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: '${context.t('mnWholesalePrice')} (\$)'))),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: TextFormField(controller: _targetMargin, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: context.t('mnTargetMargin')))),
          const SizedBox(width: 12),
          Expanded(child: TextFormField(controller: _lowStockThreshold, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: context.t('mnLowStock')))),
        ]),
        const SizedBox(height: 8),
        Text(context.t('mnPricingNote'), style: FarmTypography.textTheme.bodySmall),
      ],
    );
  }

  Widget _reviewStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(context.t('mnStepReview'), style: FarmTypography.textTheme.titleMedium),
        const SizedBox(height: FarmSpacing.md),
        _reviewRow(context.t('mnProductName'), _name.text),
        _reviewRow(context.t('mnCategory'), _category.text),
        _reviewRow(context.t('mnOutputUnit'), _outputUnit == 'custom' ? _customUnit.text : context.t('mnU_$_outputUnit')),
        _reviewRow(context.t('mnDefaultBatch'), _batchSize.text),
        _reviewRow(context.t('mnShelfLife'), _shelfLife.text.isEmpty ? '—' : _shelfLife.text),
        _reviewRow(context.t('mnSellingPrice'), _targetPrice.text.isEmpty ? '—' : '\$${_targetPrice.text}'),
        _reviewRow(context.t('mnWholesalePrice'), _wholesalePrice.text.isEmpty ? '—' : '\$${_wholesalePrice.text}'),
        _reviewRow(context.t('mnTargetMargin'), '${_targetMargin.text.isEmpty ? '0' : _targetMargin.text}%'),
      ],
    );
  }

  Widget _reviewRow(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          SizedBox(width: 160, child: Text(label, style: FarmTypography.textTheme.bodySmall)),
          Expanded(child: Text(value.isEmpty ? '—' : value, style: FarmTypography.textTheme.titleSmall)),
        ]),
      );

  double? _parse(String s) => s.trim().isEmpty ? null : double.tryParse(s.trim());

  Future<void> _submit() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    final result = await context.read<MounehProvider>().createProduct(
          name: _name.text.trim(),
          category: _category.text.trim().isEmpty ? 'general' : _category.text.trim(),
          outputUnit: _outputUnit,
          customOutputUnitLabel: _outputUnit == 'custom' && _customUnit.text.trim().isNotEmpty ? _customUnit.text.trim() : null,
          defaultBatchSize: _parse(_batchSize.text) ?? 1,
          shelfLifeDays: _parse(_shelfLife.text)?.toInt(),
          warehouseRules: _warehouseRules.text.trim().isEmpty ? null : _warehouseRules.text.trim(),
          lowStockThreshold: _parse(_lowStockThreshold.text),
          targetPrice: _parse(_targetPrice.text),
          wholesalePrice: _parse(_wholesalePrice.text),
          targetMarginPct: _parse(_targetMargin.text),
        );
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (result.success) {
        _createdProductName = _name.text.trim();
        _step = 0;
        _name.clear();
        _category.text = 'Mouneh';
        _outputUnit = 'jar';
        _customUnit.clear();
        _batchSize.text = '100';
        _shelfLife.clear();
        _warehouseRules.clear();
        _lowStockThreshold.clear();
        _targetPrice.clear();
        _wholesalePrice.clear();
        _targetMargin.text = '40';
      } else {
        _error = result.error;
      }
    });
  }
}

class _StepIndicator extends StatelessWidget {
  const _StepIndicator({required this.step});
  final int step;
  static const _labels = ['mnStepBasics', 'mnStepPricing', 'mnStepReview'];

  @override
  Widget build(BuildContext context) {
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      runSpacing: 6,
      children: [
        for (var i = 0; i < _labels.length; i++) ...[
          StatusPill(
            label: '${i + 1}. ${context.t(_labels[i])}',
            level: i == step ? FarmStatusLevel.info : (i < step ? FarmStatusLevel.good : FarmStatusLevel.neutral),
          ),
          if (i != _labels.length - 1) const Padding(padding: EdgeInsets.symmetric(horizontal: 6), child: ForwardChevron(size: 16, color: FarmColors.muted)),
        ],
      ],
    );
  }
}
