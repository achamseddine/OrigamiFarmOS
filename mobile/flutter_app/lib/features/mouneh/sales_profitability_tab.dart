import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/widgets/app_icon.dart';
import '../../core/widgets/data_table_card.dart';
import '../../core/widgets/section_card.dart';
import '../../core/widgets/status_pill.dart';
import '../../core/widgets/ux_blocks.dart';
import '../../domain/entities/mouneh.dart';
import '../../providers/mouneh_provider.dart';
import 'mouneh_dashboard_tab.dart' show mounehRecommendationLabel, mounehRecommendationLevel;

/// Sales & Profitability (tech spec v0.5 §6, screen 7): record a sale, see
/// it reduce stock and compute profit, and review each product with the
/// server's continue / slow-mover / review-pricing call.
class SalesProfitabilityTab extends StatefulWidget {
  const SalesProfitabilityTab({super.key});

  @override
  State<SalesProfitabilityTab> createState() => _SalesProfitabilityTabState();
}

String mounehChannelLabel(BuildContext context, String channel) {
  final key = 'mnCh_$channel';
  final label = context.t(key);
  return label == key ? channel : label;
}

class _SalesProfitabilityTabState extends State<SalesProfitabilityTab> {
  String? _productId;
  final _quantity = TextEditingController(text: '1');
  final _unitPrice = TextEditingController();
  final _discount = TextEditingController(text: '0');
  String _channel = 'retail';
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _quantity.dispose();
    _unitPrice.dispose();
    _discount.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<MounehProvider>();
    _productId ??= provider.products.isNotEmpty ? provider.products.first.id : null;
    if (_unitPrice.text.isEmpty && _productId != null) {
      final price = provider.productById(_productId!)?.targetPrice;
      if (price != null) _unitPrice.text = price.toString();
    }
    final sales = [...provider.sales]..sort((a, b) => b.soldAt.compareTo(a.soldAt));
    final profitability = provider.allProfitability;

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeading(eyebrow: context.t('mnTabSales'), title: context.t('mnSalesTitle'), subtitle: context.t('mnSalesSub')),
          const SizedBox(height: FarmSpacing.md),
          SectionCard(
            title: context.t('mnRecordSale'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
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
                  Expanded(child: TextField(controller: _quantity, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: context.t('mnQuantity')))),
                  const SizedBox(width: 12),
                  Expanded(child: TextField(controller: _unitPrice, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: '${context.t('mnUnitPrice')} (\$)'))),
                ]),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(child: TextField(controller: _discount, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: '${context.t('mnDiscount')} (\$)'))),
                  const SizedBox(width: 12),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      isExpanded: true,
                      initialValue: _channel,
                      decoration: InputDecoration(labelText: context.t('mnChannel')),
                      items: [for (final c in kMounehSaleChannels) DropdownMenuItem(value: c, child: Text(mounehChannelLabel(context, c)))],
                      onChanged: (v) => setState(() => _channel = v ?? _channel),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: (_saving || _productId == null) ? null : _submit,
                      child: _saving ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2)) : Text(context.t('mnRecordSale')),
                    ),
                  ),
                ]),
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(_error!, style: const TextStyle(color: FarmColors.danger, fontSize: 12.5)),
                ],
              ],
            ),
          ),
          const SizedBox(height: FarmSpacing.md),
          SectionCard(
            title: context.t('mnProfitability'),
            child: profitability.isEmpty
                ? EmptyState(message: context.t('mnNoProducts'), icon: FarmIcon.package, compact: true)
                : Column(children: [for (final p in profitability) _ProfitabilityRow(p: p)]),
          ),
          const SizedBox(height: FarmSpacing.md),
          SectionCard(
            title: context.t('mnRecentSales'),
            child: sales.isEmpty
                ? EmptyState(message: context.t('mnNoSales'), icon: FarmIcon.money, compact: true)
                : FarmDataTable(
                    columns: [
                      context.t('mnColProduct'), context.t('mnQuantity'), context.t('mnUnitPrice'), context.t('mnChannel'), context.t('mnRevenue'), context.t('mnProfit'),
                    ],
                    columnFlex: const [2, 1, 1, 1, 1, 1],
                    rows: [
                      for (final s in sales.take(20))
                        [
                          Text(provider.productById(s.productId)?.name ?? s.productId, style: FarmTypography.textTheme.titleSmall),
                          Text(s.quantity.toStringAsFixed(0)),
                          Text('\$${s.unitPrice.toStringAsFixed(2)}'),
                          Text(mounehChannelLabel(context, s.channel)),
                          Text('\$${s.revenue.toStringAsFixed(2)}'),
                          Text('\$${s.margin.toStringAsFixed(2)}', style: TextStyle(color: s.margin >= 0 ? FarmColors.success : FarmColors.danger, fontWeight: FontWeight.w700)),
                        ],
                    ],
                  ),
          ),
          const SizedBox(height: FarmSpacing.md),
          NoticeBanner(text: context.t('mnProfitCaveat')),
        ],
      ),
    );
  }

  Future<void> _submit() async {
    final qty = double.tryParse(_quantity.text.trim().replaceAll(',', '.'));
    final price = double.tryParse(_unitPrice.text.trim().replaceAll(',', '.'));
    if (qty == null || qty <= 0 || price == null || price < 0) {
      setState(() => _error = context.t('mnSaleInvalid'));
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final result = await context.read<MounehProvider>().recordSale(
          productId: _productId!,
          quantity: qty,
          unitPrice: price,
          discount: double.tryParse(_discount.text) ?? 0,
          channel: _channel,
        );
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (result.success) {
        _quantity.text = '1';
        _discount.text = '0';
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.t(result.queued ? 'workingOffline' : 'mnSaleRecorded'))));
      } else {
        _error = result.error;
      }
    });
  }
}

class _ProfitabilityRow extends StatelessWidget {
  const _ProfitabilityRow({required this.p});
  final MounehProductProfitability p;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: FarmColors.border))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(child: Text(p.productName, style: FarmTypography.textTheme.titleSmall)),
            StatusPill(label: mounehRecommendationLabel(context, p.recommendation), level: mounehRecommendationLevel(p.recommendation), dense: true),
          ]),
          const SizedBox(height: 6),
          Wrap(spacing: 20, runSpacing: 4, children: [
            _stat(context.t('mnCostPerUnitShort'), '\$${p.avgUnitCost.toStringAsFixed(2)}'),
            _stat(context.t('mnAvgSalePrice'), '\$${p.avgSalePrice.toStringAsFixed(2)}'),
            _stat(context.t('mnGrossMargin'), '${p.grossMarginPct.toStringAsFixed(0)}%'),
            _stat(context.t('mnUnitsSold'), p.unitsSold.toStringAsFixed(0)),
            _stat(context.t('mnUnitsRemaining'), p.unitsRemaining.toStringAsFixed(0)),
            _stat(context.t('mnVelocity'), '${p.salesVelocityPerDay.toStringAsFixed(1)}/${context.t('twPerDay')}'),
          ]),
        ],
      ),
    );
  }

  Widget _stat(String label, String value) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 10.5, color: FarmColors.muted)),
          Text(value, style: FarmTypography.textTheme.bodyMedium),
        ],
      );
}
