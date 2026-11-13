import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/widgets/app_icon.dart';
import '../../core/widgets/section_card.dart';
import '../../core/widgets/status_pill.dart';
import '../../core/widgets/ux_blocks.dart';
import '../../domain/entities/mouneh.dart';
import '../../providers/mouneh_provider.dart';

/// Mouneh Dashboard (tech spec v0.5 §6, screen 1): "simple for a farm
/// manager, not an accountant" — what sells, what needs a look, what is
/// being made. The figures sit above the tabs, on the module's header.
class MounehDashboardTab extends StatelessWidget {
  const MounehDashboardTab({super.key, this.onNavigate});

  /// Opens another tab by its index in `MounehTab`.
  final ValueChanged<int>? onNavigate;

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<MounehProvider>();
    final profitability = provider.allProfitability;
    final bestSellers = [...profitability.where((p) => p.totalRevenue > 0)]..sort((a, b) => b.totalRevenue.compareTo(a.totalRevenue));
    final attention = profitability.where((p) => p.recommendation == 'slow_mover' || p.recommendation == 'review_pricing').toList();
    final active = provider.batches.where((b) => b.isInProgress).toList();

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LayoutBuilder(builder: (context, c) {
            final best = SectionCard(
              title: context.t('mnBestSellers'),
              subtitle: context.t('mnBestSellersSub'),
              trailing: context.t('mnTabSales'),
              onTrailingTap: () => onNavigate?.call(6),
              child: bestSellers.isEmpty
                  ? EmptyState(message: context.t('mnNoSales'), icon: FarmIcon.money, compact: true)
                  : Column(children: [for (final p in bestSellers.take(5)) MounehProductRow(p: p)]),
            );
            final slow = SectionCard(
              title: context.t('mnAttention'),
              subtitle: context.t('mnAttentionSub'),
              child: attention.isEmpty
                  ? EmptyState(message: context.t('mnAttentionNone'), icon: FarmIcon.check, compact: true)
                  : Column(children: [for (final p in attention) MounehProductRow(p: p)]),
            );
            if (c.maxWidth < kTabletBreakpoint) return Column(children: [best, const SizedBox(height: FarmSpacing.md), slow]);
            return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: best),
              const SizedBox(width: FarmSpacing.md),
              Expanded(child: slow),
            ]);
          }),
          const SizedBox(height: FarmSpacing.md),
          SectionCard(
            title: context.t('mnActiveBatches'),
            trailing: context.t('mnTabBatches'),
            onTrailingTap: () => onNavigate?.call(4),
            child: active.isEmpty
                ? EmptyState(message: context.t('mnNoActiveBatch'), icon: FarmIcon.barn, compact: true)
                : Column(children: [
                    for (final batch in active) _BatchRow(batch: batch, productName: provider.productById(batch.productId)?.name ?? batch.productId),
                  ]),
          ),
          const SizedBox(height: FarmSpacing.md),
          NoticeBanner(text: context.t('mnProfitCaveat')),
        ],
      ),
    );
  }
}

/// "Continue production", "Slow mover", "Review pricing" — the server's
/// call on a product, in the reader's language.
String mounehRecommendationLabel(BuildContext context, String code) {
  final key = 'mnRec_$code';
  final label = context.t(key);
  return label == key ? code.replaceAll('_', ' ') : label;
}

FarmStatusLevel mounehRecommendationLevel(String code) => switch (code) {
      'continue_production' => FarmStatusLevel.good,
      'review_pricing' => FarmStatusLevel.alert,
      _ => FarmStatusLevel.watch,
    };

class MounehProductRow extends StatelessWidget {
  const MounehProductRow({super.key, required this.p});
  final MounehProductProfitability p;

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
                Text(p.productName, style: FarmTypography.textTheme.titleSmall),
                Text(
                  '${p.unitsRemaining.toStringAsFixed(0)} ${context.t('mnUnitsLeft')} · \$${p.avgUnitCost.toStringAsFixed(2)} ${context.t('mnCostPerUnit')}',
                  style: FarmTypography.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text('\$${p.totalRevenue.toStringAsFixed(0)}', style: FarmTypography.textTheme.titleSmall),
              StatusPill(label: mounehRecommendationLabel(context, p.recommendation), level: mounehRecommendationLevel(p.recommendation), dense: true),
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
    final days = DateTime.now().difference(batch.startedAt).inDays;
    final when = days <= 0 ? context.t('twToday') : (days == 1 ? context.t('twYesterday') : '$days ${context.t('twDaysAgo')}');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('$productName — ${batch.batchCode}', style: FarmTypography.textTheme.titleSmall),
                Text('${context.t('mnPlanned')} ${batch.plannedQty.toStringAsFixed(0)} · ${context.t('mnStarted')} $when', style: FarmTypography.textTheme.bodySmall),
              ],
            ),
          ),
          if (batch.plannedUnitCost != null)
            Text('\$${batch.plannedUnitCost!.toStringAsFixed(2)} ${context.t('mnPlannedPerUnit')}', style: FarmTypography.textTheme.bodySmall),
        ],
      ),
    );
  }
}
