import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/widgets/data_table_card.dart';
import '../../core/widgets/section_card.dart';
import '../../core/widgets/status_pill.dart';
import '../../domain/entities/mouneh.dart';
import '../../providers/mouneh_provider.dart';

/// Sales & Profitability Dashboard (tech spec v0.5 §6, screen 7): record a
/// sale, see it reduce stock and compute profit immediately, and review
/// per-product profitability with a continue/slow-mover/review-pricing call.
class SalesProfitabilityTab extends StatefulWidget {
  const SalesProfitabilityTab({super.key});

  @override
  State<SalesProfitabilityTab> createState() => _SalesProfitabilityTabState();
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
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionCard(
            title: 'Record a Sale',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
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
                  Expanded(child: TextField(controller: _quantity, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Quantity'))),
                  const SizedBox(width: 12),
                  Expanded(child: TextField(controller: _unitPrice, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Unit price (\$)'))),
                ]),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(child: TextField(controller: _discount, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Discount (\$)'))),
                  const SizedBox(width: 12),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      value: _channel,
                      decoration: const InputDecoration(labelText: 'Channel'),
                      items: [for (final c in kMounehSaleChannels) DropdownMenuItem(value: c, child: Text(c[0].toUpperCase() + c.substring(1)))],
                      onChanged: (v) => setState(() => _channel = v ?? _channel),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: (_saving || _productId == null) ? null : _submit,
                      child: _saving ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Record Sale'),
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
            title: 'Profitability by Product',
            child: profitability.isEmpty
                ? Text('No products yet.', style: FarmTypography.textTheme.bodySmall)
                : Column(children: [for (final p in profitability) _ProfitabilityRow(p: p)]),
          ),
          const SizedBox(height: FarmSpacing.md),
          SectionCard(
            title: 'Recent Sales',
            child: sales.isEmpty
                ? Text('No sales recorded yet.', style: FarmTypography.textTheme.bodySmall)
                : FarmDataTable(
                    columns: const ['Product', 'Qty', 'Unit Price', 'Channel', 'Revenue', 'Profit'],
                    columnFlex: const [2, 1, 1, 1, 1, 1],
                    rows: [
                      for (final s in sales.take(20))
                        [
                          Text(provider.productById(s.productId)?.name ?? s.productId, style: FarmTypography.textTheme.titleSmall),
                          Text(s.quantity.toStringAsFixed(0)),
                          Text('\$${s.unitPrice.toStringAsFixed(2)}'),
                          Text(s.channel),
                          Text('\$${s.revenue.toStringAsFixed(2)}'),
                          Text('\$${s.margin.toStringAsFixed(2)}', style: TextStyle(color: s.margin >= 0 ? FarmColors.success : FarmColors.danger, fontWeight: FontWeight.w700)),
                        ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _submit() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    final result = await context.read<MounehProvider>().recordSale(
          productId: _productId!,
          quantity: double.tryParse(_quantity.text) ?? 0,
          unitPrice: double.tryParse(_unitPrice.text) ?? 0,
          discount: double.tryParse(_discount.text) ?? 0,
          channel: _channel,
        );
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (result.success) {
        _quantity.text = '1';
        _discount.text = '0';
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Sale recorded — stock and profit updated.')));
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
    final recLabel = switch (p.recommendation) {
      'continue_production' => 'Continue production',
      'slow_mover' => 'Slow mover',
      'review_pricing' => 'Review pricing',
      _ => p.recommendation,
    };
    final recLevel = switch (p.recommendation) {
      'continue_production' => FarmStatusLevel.good,
      'review_pricing' => FarmStatusLevel.alert,
      _ => FarmStatusLevel.watch,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(child: Text(p.productName, style: FarmTypography.textTheme.titleSmall)),
            StatusPill(label: recLabel, level: recLevel, dense: true),
          ]),
          const SizedBox(height: 6),
          Wrap(spacing: 20, runSpacing: 4, children: [
            _stat('Cost/unit', '\$${p.avgUnitCost.toStringAsFixed(2)}'),
            _stat('Avg sale price', '\$${p.avgSalePrice.toStringAsFixed(2)}'),
            _stat('Gross margin', '${p.grossMarginPct.toStringAsFixed(0)}%'),
            _stat('Units sold', p.unitsSold.toStringAsFixed(0)),
            _stat('Units remaining', p.unitsRemaining.toStringAsFixed(0)),
            _stat('Velocity', '${p.salesVelocityPerDay.toStringAsFixed(1)}/day'),
          ]),
          const Divider(height: 16, color: FarmColors.border),
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
