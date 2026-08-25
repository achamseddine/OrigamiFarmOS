import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/widgets/data_table_card.dart';
import '../../core/widgets/section_card.dart';
import '../../core/widgets/status_pill.dart';
import '../../providers/mouneh_provider.dart';

/// Finished Goods Warehouse (tech spec v0.5 §6, screen 6): units produced,
/// sold, remaining, reserved, expired, damaged — per batch, per product.
class FinishedGoodsTab extends StatelessWidget {
  const FinishedGoodsTab({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<MounehProvider>();
    final rows = [...provider.finishedGoods]..sort((a, b) => (a.expiryDate ?? DateTime(9999)).compareTo(b.expiryDate ?? DateTime(9999)));

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Finished Goods Warehouse', style: FarmTypography.textTheme.titleLarge),
          const SizedBox(height: 2),
          Text('Everything currently sitting in storage, batch by batch.', style: FarmTypography.textTheme.bodySmall),
          const SizedBox(height: FarmSpacing.md),
          SectionCard(
            child: rows.isEmpty
                ? Text('No finished goods yet — complete a production batch first.', style: FarmTypography.textTheme.bodySmall)
                : FarmDataTable(
                    columns: const ['Product', 'Batch', 'Location', 'Produced', 'Available', 'Sold', 'Unit Cost', 'Expiry'],
                    columnFlex: const [2, 2, 2, 1, 1, 1, 1, 2],
                    rows: [
                      for (final r in rows)
                        [
                          Text(provider.productById(r.productId)?.name ?? r.productId, style: FarmTypography.textTheme.titleSmall),
                          Text(provider.batches.where((b) => b.id == r.batchId).map((b) => b.batchCode).firstOrNull ?? '—', style: FarmTypography.textTheme.bodySmall),
                          Text(r.warehouseLocation ?? '—', style: FarmTypography.textTheme.bodySmall),
                          Text(r.quantityProduced.toStringAsFixed(0)),
                          _availabilityCell(r.quantityAvailable, provider.productById(r.productId)?.lowStockThreshold),
                          Text(r.quantitySold.toStringAsFixed(0)),
                          Text('\$${r.unitCost.toStringAsFixed(2)}'),
                          Text(r.expiryDate == null ? '—' : _dateLabel(r.expiryDate!), style: FarmTypography.textTheme.bodySmall),
                        ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _availabilityCell(double qty, double? threshold) {
    final low = threshold != null && qty <= threshold;
    if (!low) return Text(qty.toStringAsFixed(0), style: FarmTypography.textTheme.titleSmall);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Text(qty.toStringAsFixed(0), style: FarmTypography.textTheme.titleSmall),
      const SizedBox(width: 6),
      const StatusPill(label: 'Low', level: FarmStatusLevel.watch, dense: true),
    ]);
  }

  String _dateLabel(DateTime dt) => '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
