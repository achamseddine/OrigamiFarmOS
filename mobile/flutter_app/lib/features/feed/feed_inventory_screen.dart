import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/widgets/app_icon.dart';
import '../../core/widgets/charts/line_trend_chart.dart';
import '../../core/widgets/data_table_card.dart';
import '../../core/widgets/kpi_card.dart';
import '../../core/widgets/section_card.dart';
import '../../core/widgets/status_pill.dart';
import '../../data/demo/demo_data.dart';
import '../../domain/entities/inventory.dart';
import '../../providers/feed_provider.dart';

class FeedInventoryScreen extends StatelessWidget {
  const FeedInventoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final items = context.watch<FeedProvider>().items;
    final totalStockMT = items.fold<double>(0, (sum, i) => sum + (i.unit == 'kg' ? i.currentQty : 0)) / 1000;
    final lowStock = items.where((i) => i.status != StockStatus.good).toList();
    final monthlyCost = items.fold<double>(0, (sum, i) => sum + (i.unitCost ?? 0) * i.currentQty * 0.3);

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(context.t('feedInventoryTitle'), style: FarmTypography.display(size: 28)),
          const SizedBox(height: 2),
          Text(context.t('feedInventorySubtitle'), style: FarmTypography.textTheme.bodyMedium),
          const SizedBox(height: FarmSpacing.md),
          LayoutBuilder(builder: (context, c) {
            final perRow = c.maxWidth > 900 ? 4 : 2;
            final w = (c.maxWidth - FarmSpacing.md * (perRow - 1)) / perRow;
            final cards = [
              KpiCard(icon: FarmIcon.inventory, label: context.t('totalFeedStock'), value: totalStockMT.toStringAsFixed(1), unit: 'MT', trendLabel: '+6.3%', trendUp: true),
              KpiCard(icon: FarmIcon.calendar, label: context.t('daysRemaining'), value: '24', unit: 'days', trendLabel: '-3 days', trendUp: false),
              KpiCard(icon: FarmIcon.warning, label: context.t('lowStockItems'), value: '${lowStock.length}', caption: context.t('viewAndReorder'), tint: FarmColors.warning),
              KpiCard(icon: FarmIcon.money, label: context.t('monthlyFeedCost'), value: '\$${monthlyCost.toStringAsFixed(0)}', trendLabel: '+8.7%', trendUp: false),
            ];
            return Wrap(spacing: FarmSpacing.md, runSpacing: FarmSpacing.md, children: [for (final c2 in cards) SizedBox(width: w, child: c2)]);
          }),
          const SizedBox(height: FarmSpacing.md),
          LayoutBuilder(builder: (context, c) {
            final wide = c.maxWidth > kTabletBreakpoint;
            final table = SectionCard(
              title: 'All Feed',
              child: FarmDataTable(
                columns: const ['Feed Item', 'Quantity', 'Reorder Level', 'Supplier', 'Status'],
                columnFlex: const [3, 2, 2, 2, 2],
                rows: [
                  for (final item in items)
                    [
                      Row(children: [
                        AppIcon(_iconFor(item.category), size: 16, color: FarmColors.cedar),
                        const SizedBox(width: 8),
                        Text(item.name, style: FarmTypography.textTheme.titleSmall),
                      ]),
                      Text('${item.currentQty.toStringAsFixed(0)} ${item.unit}'),
                      Text('${item.reorderLevel.toStringAsFixed(0)} ${item.unit}'),
                      Text(item.supplier, style: FarmTypography.textTheme.bodySmall),
                      StatusPill(
                        label: item.status == StockStatus.good ? context.t('statusGood') : context.t('statusLow'),
                        level: item.status == StockStatus.good ? FarmStatusLevel.good : FarmStatusLevel.watch,
                        dense: true,
                      ),
                    ],
                ],
              ),
            );
            final trend = SectionCard(
              title: context.t('feedConsumptionTrend'),
              child: LineTrendChart(
                values: DemoData.feedConsumptionTrendMT,
                secondaryValues: DemoData.feedConsumptionTrendLastMonthMT,
                labels: const ['Wk 1', 'Wk 7'],
                height: 200,
              ),
            );
            if (!wide) return Column(children: [table, const SizedBox(height: FarmSpacing.md), trend]);
            return IntrinsicHeight(
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(flex: 6, child: table),
                const SizedBox(width: FarmSpacing.md),
                Expanded(flex: 4, child: trend),
              ]),
            );
          }),
          const SizedBox(height: FarmSpacing.md),
          LayoutBuilder(builder: (context, c) {
            final wide = c.maxWidth > kTabletBreakpoint;
            final plan = SectionCard(
              title: context.t('todaysFeedingPlan'),
              trailing: context.t('viewFullPlan'),
              child: Column(
                children: [
                  for (final line in DemoData.feedingPlan) ...[
                    _FeedingPlanRow(line: line),
                    const Divider(height: 16, color: FarmColors.border),
                  ],
                ],
              ),
            );
            final reorder = SectionCard(
              title: context.t('reorderRecommendations'),
              child: Column(
                children: [
                  for (final item in lowStock) ...[
                    _ReorderCard(item: item),
                    const SizedBox(height: 10),
                  ],
                  if (lowStock.isEmpty)
                    Text('All feed items are above their reorder level.', style: FarmTypography.textTheme.bodySmall),
                ],
              ),
            );
            if (!wide) return Column(children: [plan, const SizedBox(height: FarmSpacing.md), reorder]);
            return IntrinsicHeight(
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(child: plan),
                const SizedBox(width: FarmSpacing.md),
                Expanded(child: reorder),
              ]),
            );
          }),
        ],
      ),
    );
  }

  FarmIcon _iconFor(String category) {
    switch (category) {
      case 'Medicine':
        return FarmIcon.medicine;
      case 'Minerals':
        return FarmIcon.inventory;
      default:
        return FarmIcon.feedBag;
    }
  }
}

class _FeedingPlanRow extends StatelessWidget {
  const _FeedingPlanRow({required this.line});
  final FeedingPlanLine line;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: const BoxDecoration(color: FarmColors.mist, shape: BoxShape.circle),
          child: const Center(child: AppIcon(FarmIcon.cow, size: 16, color: FarmColors.cedar)),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(line.groupLabel, style: FarmTypography.textTheme.titleSmall),
              Text(line.subLabel, style: FarmTypography.textTheme.bodySmall),
            ],
          ),
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text('${line.quantityKg.toStringAsFixed(0)} kg', style: FarmTypography.textTheme.titleSmall),
            Text('${line.perHeadKg} kg/head', style: const TextStyle(fontSize: 10.5, color: FarmColors.muted)),
          ],
        ),
      ],
    );
  }
}

class _ReorderCard extends StatelessWidget {
  const _ReorderCard({required this.item});
  final InventoryItem item;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: FarmColors.tint(FarmColors.warning, 0.1),
        borderRadius: BorderRadius.circular(FarmRadii.sm),
        border: Border.all(color: FarmColors.warning.withOpacity(0.3)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.name, style: FarmTypography.textTheme.titleSmall),
                Text('${context.t('current')}: ${item.currentQty.toStringAsFixed(0)} ${item.unit}', style: FarmTypography.textTheme.bodySmall),
                Text(
                  '${context.t('shortBy')} ${item.shortfall.toStringAsFixed(0)} ${item.unit}',
                  style: const TextStyle(fontSize: 11.5, color: FarmColors.danger, fontWeight: FontWeight.w700),
                ),
              ],
            ),
          ),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(0, 40), padding: const EdgeInsets.symmetric(horizontal: 14)),
            onPressed: () async {
              await context.read<FeedProvider>().recordPurchase(itemId: item.id, quantityKg: item.shortfall + item.reorderLevel * 0.2);
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.t('savedOffline'))));
            },
            child: Text(context.t('reorderNow')),
          ),
        ],
      ),
    );
  }
}
