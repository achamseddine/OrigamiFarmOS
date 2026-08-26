import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/widgets/kpi_card.dart';
import '../../core/widgets/app_icon.dart';
import '../../core/widgets/section_card.dart';
import '../../providers/mouneh_provider.dart';

/// Cost Preview (tech spec v0.5 §6, screen 4): "System calculates planned
/// cost per batch and per unit" — clear cards, not a spreadsheet: cost
/// per jar, selling price, margin, suggested price.
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

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionCard(
            child: Row(
              children: [
                Expanded(
                  flex: 2,
                  child: DropdownButtonFormField<String>(
                    value: _productId,
                    decoration: const InputDecoration(labelText: 'Product'),
                    items: [for (final p in provider.products) DropdownMenuItem(value: p.id, child: Text(p.name))],
                    onChanged: provider.products.isEmpty ? null : (v) => setState(() => _productId = v),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _outputQty,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(labelText: 'Output quantity (${product?.outputUnit ?? 'units'})'),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: FarmSpacing.md),
          if (breakdown == null)
            SectionCard(
              child: Text(
                product == null ? 'Create a product first.' : 'This product has no recipe yet — add one on the Recipes & Materials tab.',
                style: FarmTypography.textTheme.bodySmall,
              ),
            )
          else ...[
            LayoutBuilder(builder: (context, c) {
              final perRow = c.maxWidth > 900 ? 4 : 2;
              final w = (c.maxWidth - FarmSpacing.md * (perRow - 1)) / perRow;
              final cards = [
                KpiCard(icon: FarmIcon.money, label: 'Cost per ${product!.outputUnit}', value: '\$${breakdown.unitCost.toStringAsFixed(2)}'),
                KpiCard(icon: FarmIcon.chartLine, label: 'Total batch cost', value: '\$${breakdown.totalCost.toStringAsFixed(0)}'),
                if (suggestion != null) KpiCard(icon: FarmIcon.report, label: 'Suggested price', value: '\$${suggestion.suggestedPrice.toStringAsFixed(2)}', tint: FarmColors.success),
                if (product.targetPrice != null)
                  KpiCard(
                    icon: FarmIcon.scale,
                    label: 'Margin at your selling price',
                    value: '${(((product.targetPrice! - breakdown.unitCost) / product.targetPrice!) * 100).toStringAsFixed(0)}%',
                    tint: product.targetPrice! > breakdown.unitCost ? FarmColors.success : FarmColors.danger,
                  ),
              ];
              return Wrap(spacing: FarmSpacing.md, runSpacing: FarmSpacing.md, children: [for (final c2 in cards) SizedBox(width: w, child: c2)]);
            }),
            const SizedBox(height: FarmSpacing.md),
            SectionCard(
              title: 'Cost Breakdown',
              child: Column(
                children: [
                  _costRow('Raw materials', breakdown.materialCost),
                  _costRow('Packaging', breakdown.packagingCost),
                  _costRow('Labor', breakdown.laborCost),
                  _costRow('Overhead (utilities, transport, storage, fees)', breakdown.overheadCost),
                  if (breakdown.byproductCredit > 0) _costRow('Byproduct credit', -breakdown.byproductCredit),
                  const Divider(color: FarmColors.border),
                  _costRow('Total cost', breakdown.totalCost, bold: true),
                  _costRow('Cost per ${product!.outputUnit}', breakdown.unitCost, bold: true),
                ],
              ),
            ),
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
