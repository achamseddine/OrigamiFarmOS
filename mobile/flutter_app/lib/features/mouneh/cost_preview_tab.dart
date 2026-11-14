import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/widgets/app_icon.dart';
import '../../core/widgets/kpi_card.dart';
import '../../core/widgets/section_card.dart';
import '../../core/widgets/ux_blocks.dart';
import '../../providers/mouneh_provider.dart';

/// Cost Preview (tech spec v0.5 §6, screen 4): "System calculates planned
/// cost per batch and per unit" — clear cards, not a spreadsheet: cost
/// per jar, total batch cost, a suggested price, the margin at the
/// farm's own price. A preview, from the recipe and today's material
/// costs; what a batch really cost comes from what it actually used.
class CostPreviewTab extends StatefulWidget {
  const CostPreviewTab({super.key});

  @override
  State<CostPreviewTab> createState() => _CostPreviewTabState();
}

class _CostPreviewTabState extends State<CostPreviewTab> {
  String? _productId;
  final _outputQty = TextEditingController(text: '100');

  @override
  void dispose() {
    _outputQty.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<MounehProvider>();
    _productId ??= provider.products.isNotEmpty ? provider.products.first.id : null;
    final product = _productId == null ? null : provider.productById(_productId!);
    final qty = double.tryParse(_outputQty.text) ?? 0;
    final breakdown = (_productId != null && qty > 0) ? provider.previewCost(_productId!, qty) : null;
    final suggestion = (_productId != null && qty > 0) ? provider.suggestedPriceFor(_productId!, qty) : null;
    final unit = product?.outputUnit ?? context.t('mnUnits');

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeading(eyebrow: context.t('mnTabCost'), title: context.t('mnCostTitle'), subtitle: context.t('mnCostSub')),
          const SizedBox(height: FarmSpacing.md),
          SectionCard(
            child: Row(
              children: [
                Expanded(
                  flex: 2,
                  child: DropdownButtonFormField<String>(
                    isExpanded: true,
                    initialValue: _productId,
                    decoration: InputDecoration(labelText: context.t('mnColProduct')),
                    items: [for (final p in provider.products) DropdownMenuItem(value: p.id, child: Text(p.name))],
                    onChanged: provider.products.isEmpty ? null : (v) => setState(() => _productId = v),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _outputQty,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(labelText: '${context.t('mnOutputQty')} ($unit)'),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: FarmSpacing.md),
          if (breakdown == null)
            SectionCard(
              child: EmptyState(
                icon: FarmIcon.money,
                message: context.t(product == null ? 'mnNeedProduct' : 'mnNeedRecipe'),
              ),
            )
          else ...[
            EqualGrid(minTileWidth: 200, children: [
              KpiCard(icon: FarmIcon.money, label: '${context.t('mnCostPer')} $unit', value: '\$${breakdown.unitCost.toStringAsFixed(2)}'),
              KpiCard(icon: FarmIcon.chartLine, label: context.t('mnBatchCost'), value: '\$${breakdown.totalCost.toStringAsFixed(0)}'),
              if (suggestion != null)
                KpiCard(icon: FarmIcon.report, label: context.t('mnSuggestedPrice'), value: '\$${suggestion.suggestedPrice.toStringAsFixed(2)}', tint: FarmColors.success),
              if (product!.targetPrice != null)
                KpiCard(
                  icon: FarmIcon.scale,
                  label: context.t('mnMarginAtPrice'),
                  value: '${(((product.targetPrice! - breakdown.unitCost) / product.targetPrice!) * 100).toStringAsFixed(0)}%',
                  tint: product.targetPrice! > breakdown.unitCost ? FarmColors.success : FarmColors.danger,
                ),
            ]),
            const SizedBox(height: FarmSpacing.md),
            SectionCard(
              title: context.t('mnBreakdown'),
              child: Column(
                children: [
                  _costRow(context.t('mnRawMaterials'), breakdown.materialCost),
                  _costRow(context.t('mnPackaging'), breakdown.packagingCost),
                  _costRow(context.t('mnLabor'), breakdown.laborCost),
                  _costRow(context.t('mnOverhead'), breakdown.overheadCost),
                  if (breakdown.byproductCredit > 0) _costRow(context.t('mnByproductCredit'), -breakdown.byproductCredit),
                  const Divider(color: FarmColors.border),
                  _costRow(context.t('mnTotalCost'), breakdown.totalCost, bold: true),
                  _costRow('${context.t('mnCostPer')} $unit', breakdown.unitCost, bold: true),
                ],
              ),
            ),
            const SizedBox(height: FarmSpacing.md),
            NoticeBanner(text: context.t('mnCostCaveat')),
          ],
        ],
      ),
    );
  }

  Widget _costRow(String label, double value, {bool bold = false}) {
    final style = bold ? FarmTypography.textTheme.titleSmall : FarmTypography.textTheme.bodyMedium;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(child: Text(label, style: style)),
          Text('\$${value.toStringAsFixed(2)}', style: style),
        ],
      ),
    );
  }
}
