import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/widgets/app_icon.dart';
import '../../core/widgets/kpi_card.dart';
import '../../core/widgets/section_card.dart';
import '../../core/widgets/status_pill.dart';
import '../../domain/entities/mouneh.dart';
import '../../providers/mouneh_provider.dart';

/// Mouneh Dashboard (tech spec v0.5 §6, screen 1): "simple for a farm
/// manager, not an accountant" — cost per jar, selling price, margin,
/// stock remaining, units sold, batch status, all as clear cards.
class MounehDashboardTab extends StatelessWidget {
  const MounehDashboardTab({super.key, this.onNavigate});
  final ValueChanged<int>? onNavigate;

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<MounehProvider>();
    final profitability = provider.allProfitability;
    final bestSellers = [...profitability]..sort((a, b) => b.totalRevenue.compareTo(a.totalRevenue));
    final slowMovers = profitability.where((p) => p.recommendation == 'slow_mover').toList();

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LayoutBuilder(builder: (context, c) {
            final perRow = c.maxWidth > 900 ? 4 : 2;
            final w = (c.maxWidth - FarmSpacing.md * (perRow - 1)) / perRow;
            final cards = [
              KpiCard(icon: FarmIcon.inventory, label: 'Products', value: '${provider.products.length}', onTap: () => onNavigate?.call(1)),
              KpiCard(icon: FarmIcon.barn, label: 'Active Batches', value: '${provider.activeBatchCount}', onTap: () => onNavigate?.call(4)),
              KpiCard(icon: FarmIcon.harvestBasket, label: 'Stock Remaining', value: provider.totalFinishedUnits.toStringAsFixed(0), unit: 'units', onTap: () => onNavigate?.call(5)),
              KpiCard(icon: FarmIcon.money, label: 'Stock Value', value: '\$${provider.totalStockValue.toStringAsFixed(0)}'),
              KpiCard(icon: FarmIcon.chartLine, label: 'Revenue', value: '\$${provider.totalRevenue.toStringAsFixed(0)}', tint: FarmColors.success, onTap: () => onNavigate?.call(6)),
              KpiCard(icon: FarmIcon.report, label: 'Profit', value: '\$${provider.totalProfit.toStringAsFixed(0)}', tint: provider.totalProfit >= 0 ? FarmColors.success : FarmColors.danger),
            ];
            return Wrap(spacing: FarmSpacing.md, runSpacing: FarmSpacing.md, children: [for (final c2 in cards) SizedBox(width: w, child: c2)]);
          }),
          const SizedBox(height: FarmSpacing.md),
          LayoutBuilder(builder: (context, c) {
            final wide = c.maxWidth > kTabletBreakpoint;
            final best = SectionCard(
              title: 'Best Sellers',
              subtitle: 'Ranked by revenue',
              child: bestSellers.isEmpty
                  ? Text('No sales recorded yet.', style: FarmTypography.textTheme.bodySmall)
                  : Column(children: [for (final p in bestSellers.take(5)) _ProductRow(p: p)]),
            );
            final slow = SectionCard(
              title: 'Needs Attention',
              subtitle: 'Slow movers & pricing reviews',
              child: slowMovers.isEmpty
                  ? Text('Every product is selling at a healthy pace.', style: FarmTypography.textTheme.bodySmall)
                  : Column(children: [for (final p in slowMovers) _ProductRow(p: p)]),
            );
            if (!wide) return Column(children: [best, const SizedBox(height: FarmSpacing.md), slow]);
            return IntrinsicHeight(
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(child: best),
                const SizedBox(width: FarmSpacing.md),
                Expanded(child: slow),
              ]),
            );
          }),
          const SizedBox(height: FarmSpacing.md),
          SectionCard(
            title: 'Active Batches',
            child: provider.batches.where((b) => b.isInProgress).isEmpty
                ? Text('No batch in progress right now.', style: FarmTypography.textTheme.bodySmall)
                : Column(
                    children: [
                      for (final batch in provider.batches.where((b) => b.isInProgress))
                        _BatchRow(batch: batch, productName: provider.productById(batch.productId)?.name ?? batch.productId),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _ProductRow extends StatelessWidget {
  const _ProductRow({required this.p});
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
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(p.productName, style: FarmTypography.textTheme.titleSmall),
                Text('${p.unitsRemaining.toStringAsFixed(0)} units left · \$${p.avgUnitCost.toStringAsFixed(2)}/unit cost', style: FarmTypography.textTheme.bodySmall),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text('\$${p.totalRevenue.toStringAsFixed(0)}', style: FarmTypography.textTheme.titleSmall),
              StatusPill(label: recLabel, level: recLevel, dense: true),
            ],
          ),
        ],
      ),
    );
  }
}

class _BatchRow extends StatelessWidget {
  const _BatchRow({required this.batch, required this.productName});
  final ProductionBatch batch;
  final String productName;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('$productName — ${batch.batchCode}', style: FarmTypography.textTheme.titleSmall),
                Text('Planned ${batch.plannedQty.toStringAsFixed(0)} units · started ${_relative(batch.startedAt)}', style: FarmTypography.textTheme.bodySmall),
              ],
            ),
          ),
          if (batch.plannedUnitCost != null) Text('\$${batch.plannedUnitCost!.toStringAsFixed(2)}/unit planned', style: FarmTypography.textTheme.bodySmall),
        ],
      ),
    );
  }

  String _relative(DateTime dt) {
    final days = DateTime.now().difference(dt).inDays;
    if (days <= 0) return 'today';
    if (days == 1) return '1 day ago';
    return '$days days ago';
  }
}
