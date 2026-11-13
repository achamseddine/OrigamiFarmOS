import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/widgets/app_icon.dart';
import '../../core/widgets/data_table_card.dart';
import '../../core/widgets/section_card.dart';
import '../../core/widgets/status_pill.dart';
import '../../core/widgets/ux_blocks.dart';
import '../../providers/mouneh_provider.dart';
import '../feed/feed_workspace_screen.dart' show feedDate;

/// Finished Goods Warehouse (tech spec v0.5 §6, screen 6): units produced,
/// sold and available — per batch, per product — soonest expiry first.
class FinishedGoodsTab extends StatelessWidget {
  const FinishedGoodsTab({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<MounehProvider>();
    final rows = [...provider.finishedGoods]..sort((a, b) => (a.expiryDate ?? DateTime(9999)).compareTo(b.expiryDate ?? DateTime(9999)));
    final soon = DateTime.now().add(const Duration(days: 30));

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeading(eyebrow: context.t('mnTabStock'), title: context.t('mnStockTitle'), subtitle: context.t('mnStockSub')),
          const SizedBox(height: FarmSpacing.md),
          SectionCard(
            child: rows.isEmpty
                ? EmptyState(message: context.t('mnNoStock'), icon: FarmIcon.inventory)
                : FarmDataTable(
                    columns: [
                      context.t('mnColProduct'), context.t('mnColBatch'), context.t('mnColLocation'), context.t('mnColProduced'),
                      context.t('mnColAvailable'), context.t('mnColSold'), context.t('mnColUnitCost'), context.t('mnColExpiry'),
                    ],
                    columnFlex: const [2, 2, 2, 1, 1, 1, 1, 2],
                    rows: [
                      for (final r in rows)
                        [
                          Text(provider.productById(r.productId)?.name ?? r.productId, style: FarmTypography.textTheme.titleSmall),
                          Text(provider.batches.where((b) => b.id == r.batchId).map((b) => b.batchCode).firstOrNull ?? '—', style: FarmTypography.textTheme.bodySmall),
                          Text(r.warehouseLocation ?? '—', style: FarmTypography.textTheme.bodySmall),
                          Text(r.quantityProduced.toStringAsFixed(0)),
                          _availability(context, r.quantityAvailable, provider.productById(r.productId)?.lowStockThreshold),
                          Text(r.quantitySold.toStringAsFixed(0)),
                          Text('\$${r.unitCost.toStringAsFixed(2)}'),
                          r.expiryDate == null
                              ? Text('—', style: FarmTypography.textTheme.bodySmall)
                              : r.expiryDate!.isBefore(soon)
                                  ? Align(
                                      alignment: AlignmentDirectional.centerStart,
                                      child: StatusPill(
                                        label: feedDate(r.expiryDate!),
                                        level: r.expiryDate!.isBefore(DateTime.now()) ? FarmStatusLevel.alert : FarmStatusLevel.watch,
                                        dense: true,
                                      ),
                                    )
                                  : Text(feedDate(r.expiryDate!), style: FarmTypography.textTheme.bodySmall),
                        ],
                    ],
                  ),
          ),
          const SizedBox(height: FarmSpacing.md),
          NoticeBanner(tone: NoticeTone.info, text: context.t('mnStockNote')),
        ],
      ),
    );
  }

  Widget _availability(BuildContext context, double qty, double? threshold) {
    final low = threshold != null && qty <= threshold;
    if (!low) return Text(qty.toStringAsFixed(0), style: FarmTypography.textTheme.titleSmall);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Text(qty.toStringAsFixed(0), style: FarmTypography.textTheme.titleSmall),
      const SizedBox(width: 6),
      StatusPill(label: context.t('mnLow'), level: FarmStatusLevel.watch, dense: true),
    ]);
  }
}
