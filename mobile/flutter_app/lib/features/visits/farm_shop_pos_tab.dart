import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/widgets/data_table_card.dart';
import '../../core/widgets/section_card.dart';
import '../../domain/entities/visits.dart';
import '../../providers/feed_provider.dart';
import '../../providers/mouneh_provider.dart';
import '../../providers/visits_provider.dart';

enum _PosLineType { inventory, mouneh }

/// Farm Shop / Visitor POS (tech spec v0.6 §6, screen 8). RULE-VIS-006: a
/// visitor retail sale always deducts real stock — either a plain
/// [FeedProvider] inventory item, or Mouneh [MounehProvider] finished-goods
/// stock — and the sale then shows up in Sales & Finance the same way any
/// other core sale does.
class FarmShopPosTab extends StatefulWidget {
  const FarmShopPosTab({super.key});

  @override
  State<FarmShopPosTab> createState() => _FarmShopPosTabState();
}

class _FarmShopPosTabState extends State<FarmShopPosTab> {
  _PosLineType _lineType = _PosLineType.mouneh;
  String? _itemId;
  String? _bookingId;
  final _quantity = TextEditingController(text: '1');
  final _unitPrice = TextEditingController();
  String _channel = 'farm_shop';
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _quantity.dispose();
    _unitPrice.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_itemId == null) {
      setState(() => _error = 'Pick an item to sell.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final visits = context.read<VisitsProvider>();
    final booking = _bookingId == null ? null : visits.bookingById(_bookingId!);
    final quantity = double.tryParse(_quantity.text) ?? 0;
    final unitPrice = double.tryParse(_unitPrice.text) ?? 0;
    final result = _lineType == _PosLineType.inventory
        ? await visits.recordInventoryRetailSale(bookingId: _bookingId, visitorId: booking?.visitorId, channel: _channel, inventoryItemId: _itemId!, quantity: quantity, unitPrice: unitPrice)
        : await visits.recordMounehRetailSale(bookingId: _bookingId, visitorId: booking?.visitorId, channel: _channel, finishedGoodsStockId: _itemId!, quantity: quantity, unitPrice: unitPrice);
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (result.success) {
        _quantity.text = '1';
        _unitPrice.clear();
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Sale recorded — stock updated.')));
      } else {
        _error = result.error;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final visits = context.watch<VisitsProvider>();
    final feed = context.watch<FeedProvider>();
    final mouneh = context.watch<MounehProvider>();
    final checkedInBookings = visits.bookings.where((b) => b.status == 'checked_in' || b.status == 'completed').toList();
    final sales = [...visits.retailSales]..sort((a, b) => b.soldAt.compareTo(a.soldAt));

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionCard(
            title: 'Record a Sale',
            subtitle: 'Sells either a plain inventory item or a Mouneh finished-goods product — both deduct real stock.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  ChoiceChip(label: const Text('Mouneh product'), selected: _lineType == _PosLineType.mouneh, onSelected: (_) => setState(() {
                    _lineType = _PosLineType.mouneh;
                    _itemId = null;
                  })),
                  const SizedBox(width: 8),
                  ChoiceChip(label: const Text('Farm inventory item'), selected: _lineType == _PosLineType.inventory, onSelected: (_) => setState(() {
                    _lineType = _PosLineType.inventory;
                    _itemId = null;
                  })),
                ]),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(
                    flex: 2,
                    child: _lineType == _PosLineType.mouneh
                        ? DropdownButtonFormField<String>(
                            value: _itemId,
                            decoration: const InputDecoration(labelText: 'Product (finished-goods stock)'),
                            items: [
                              for (final s in mouneh.finishedGoods.where((s) => s.quantityAvailable > 0))
                                DropdownMenuItem(value: s.id, child: Text('${mouneh.productById(s.productId)?.name ?? s.productId} · ${s.quantityAvailable.toStringAsFixed(0)} left')),
                            ],
                            onChanged: (v) {
                              setState(() {
                                _itemId = v;
                                final stock = mouneh.finishedGoods.where((s) => s.id == v).firstOrNull;
                                final price = stock == null ? null : mouneh.productById(stock.productId)?.targetPrice;
                                if (price != null) _unitPrice.text = price.toString();
                              });
                            },
                          )
                        : DropdownButtonFormField<String>(
                            value: _itemId,
                            decoration: const InputDecoration(labelText: 'Inventory item'),
                            items: [for (final i in feed.items.where((i) => i.currentQty > 0)) DropdownMenuItem(value: i.id, child: Text('${i.name} · ${i.currentQty.toStringAsFixed(0)} ${i.unit} left'))],
                            onChanged: (v) {
                              setState(() {
                                _itemId = v;
                                final item = feed.items.where((i) => i.id == v).firstOrNull;
                                if (item?.unitCost != null) _unitPrice.text = item!.unitCost!.toString();
                              });
                            },
                          ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: TextField(controller: _quantity, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Quantity'))),
                  const SizedBox(width: 12),
                  Expanded(child: TextField(controller: _unitPrice, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Unit price (\$)'))),
                ]),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(
                    child: DropdownButtonFormField<String?>(
                      value: _bookingId,
                      decoration: const InputDecoration(labelText: 'Link to visitor booking (optional)'),
                      items: [
                        const DropdownMenuItem<String?>(value: null, child: Text('Walk-in / no booking')),
                        for (final b in checkedInBookings) DropdownMenuItem<String?>(value: b.id, child: Text(visits.visitorById(b.visitorId)?.fullName ?? b.id)),
                      ],
                      onChanged: (v) => setState(() => _bookingId = v),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      value: _channel,
                      decoration: const InputDecoration(labelText: 'Channel'),
                      items: [for (final c in kVisitRetailChannels) DropdownMenuItem(value: c, child: Text(c.replaceAll('_', ' ')))],
                      onChanged: (v) => setState(() => _channel = v ?? _channel),
                    ),
                  ),
                  const SizedBox(width: 12),
                  FilledButton(
                    onPressed: _saving ? null : _submit,
                    child: _saving ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Record Sale'),
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
            title: 'Recent Visitor Sales',
            child: sales.isEmpty
                ? Text('No visitor retail sales yet.', style: FarmTypography.textTheme.bodySmall)
                : FarmDataTable(
                    columns: const ['Visitor', 'Channel', 'Amount', 'Sold'],
                    columnFlex: const [2, 1, 1, 1],
                    rows: [
                      for (final s in sales.take(20))
                        [
                          Text(s.visitorId != null ? (visits.visitorById(s.visitorId!)?.fullName ?? s.visitorId!) : 'Walk-in'),
                          Text(s.channel.replaceAll('_', ' ')),
                          Text('\$${s.totalAmount.toStringAsFixed(2)}'),
                          Text('${s.soldAt.day}/${s.soldAt.month}'),
                        ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
