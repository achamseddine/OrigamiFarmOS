import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/i18n/strings.dart';
import '../../../core/theme/colors.dart';
import '../../../core/theme/spacing.dart';
import '../../../core/theme/typography.dart';
import '../../../core/widgets/app_icon.dart';
import '../../../core/widgets/data_table_card.dart';
import '../../../core/widgets/kpi_card.dart';
import '../../../core/widgets/section_card.dart';
import '../../../domain/entities/feeding.dart';
import '../../../providers/access_provider.dart';
import '../../../providers/feeding_provider.dart';
import '../../../providers/livestock_provider.dart';
import '../feed_stock_dialogs.dart';
import '../feed_workspace_screen.dart';

/// Feed cost (§10, §23): what the last thirty days of feeding cost, by
/// animal or group and by feed, and what each batch cost to mix. Every
/// figure comes from lot unit costs consumed by real events — nothing here
/// is a standard cost multiplied by a plan.
class CostsTab extends StatelessWidget {
  const CostsTab({super.key});

  @override
  Widget build(BuildContext context) {
    final feeding = context.watch<FeedingProvider>();
    final livestock = context.watch<LivestockProvider>();
    final lang = Localizations.localeOf(context).languageCode;
    final costs = feeding.costs;
    final canEdit = context.watch<AccessProvider>().canManageFeed;
    // The prices every feeding is costed at (v0.8.3): the feeds first, then
    // the raw materials the mixes are costed from.
    final priced = [for (final p in feeding.products) if (p.status == 'active') p]
      ..sort((a, b) => a.isFeedable == b.isFeedable ? a.label(lang).compareTo(b.label(lang)) : (a.isFeedable ? -1 : 1));
    final missing = [for (final p in priced) if (p.isFeedable && p.currentUnitCost == null) p];

    return FeedTabScaffold(children: [
      SectionCard(
        key: const ValueKey('feed-prices'),
        title: context.t('feedPrices'),
        subtitle: context.t('feedPricesSubtitle'),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (missing.isNotEmpty) ...[
            Text(
              context.t('feedPricesMissing').replaceAll('{feeds}', missing.map((p) => p.label(lang)).join(', ')),
              key: const ValueKey('feed-prices-missing'),
              style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: FarmColors.warningInk),
            ),
            const SizedBox(height: 8),
          ],
          for (final p in priced) _PriceRow(product: p, lang: lang, canEdit: canEdit),
        ]),
      ),
      LayoutBuilder(builder: (context, c) {
        final perRow = c.maxWidth > 700 ? 3 : 2;
        final w = (c.maxWidth - FarmSpacing.md * (perRow - 1)) / perRow;
        final cards = [
          KpiCard(icon: FarmIcon.coins, label: '${context.t('feedingCost')} · ${costs.days} ${context.t('days')}', value: feedMoney(costs.totalFeedingCost), accent: FarmColors.gold),
          KpiCard(icon: FarmIcon.coins, label: context.t('dailyAverageCost'), value: feedMoney(costs.dailyAverage), accent: FarmColors.cedar2),
          KpiCard(icon: FarmIcon.inventory, label: context.t('batchCost'), value: feedMoney(costs.batchCostTotal), caption: '${costs.batches.length} ${context.t('batches').toLowerCase()}', accent: FarmColors.olive),
        ];
        return Wrap(spacing: FarmSpacing.md, runSpacing: FarmSpacing.md, children: [for (final k in cards) SizedBox(width: w, child: k)]);
      }),
      SectionCard(
        title: context.t('costBySubject'),
        subtitle: context.t('costBySubjectSubtitle'),
        child: costs.bySubject.isEmpty
            ? const FeedEmpty('noFeedingCostYet')
            : FarmDataTable(
                columns: [context.t('animalOrGroup'), context.t('species'), context.t('quantity'), context.t('cost'), context.t('costPerDay'), context.t('costPerLiter')],
                columnFlex: const [3, 2, 2, 2, 2, 2],
                rows: [
                  for (final row in costs.bySubject)
                    [
                      Text(row['name'] as String? ?? row['subject_id'] as String? ?? '', style: FarmTypography.textTheme.titleSmall, overflow: TextOverflow.ellipsis),
                      Text(livestock.speciesName(row['species'] as String? ?? '', lang), style: FarmTypography.textTheme.bodySmall),
                      Text('${feedNumber(_num(row['quantity']))} kg'),
                      Text(feedMoney(_num(row['cost'])), style: FarmTypography.textTheme.titleSmall),
                      Text(feedMoney(_num(row['cost']) / (costs.days < 1 ? 1 : costs.days)), style: FarmTypography.textTheme.bodySmall),
                      Text(row['cost_per_liter'] == null ? '—' : '\$${_num(row['cost_per_liter']).toStringAsFixed(3)}', style: FarmTypography.textTheme.bodySmall),
                    ],
                ],
              ),
      ),
      SectionCard(
        title: context.t('costByFeed'),
        child: costs.byProduct.isEmpty
            ? const FeedEmpty('noFeedingCostYet')
            : Column(children: [
                for (final row in costs.byProduct)
                  _ShareRow(
                    label: row['name'] as String? ?? feeding.productName(row['feed_product_id'] as String? ?? '', lang),
                    quantity: '${feedNumber(_num(row['quantity']))} ${row['unit'] ?? 'kg'}',
                    cost: _num(row['cost']),
                    share: costs.totalFeedingCost > 0 ? _num(row['cost']) / costs.totalFeedingCost : 0,
                  ),
              ]),
      ),
      SectionCard(
        title: context.t('batchCost'),
        subtitle: context.t('batchCostSubtitle'),
        child: costs.batches.isEmpty
            ? const FeedEmpty('noBatchesYet')
            : FarmDataTable(
                columns: [context.t('batchCode'), context.t('producedQuantity'), context.t('plannedCost'), context.t('actualCost'), context.t('unitCost')],
                columnFlex: const [3, 2, 2, 2, 2],
                rows: [
                  for (final b in costs.batches)
                    [
                      Text(b['batch_code'] as String? ?? '', style: FarmTypography.textTheme.titleSmall),
                      Text('${feedNumber(_num(b['actual_quantity']))} ${b['unit'] ?? 'kg'}'),
                      Text(b['planned_cost'] == null ? '—' : feedMoney(_num(b['planned_cost'])), style: FarmTypography.textTheme.bodySmall),
                      Text(feedMoney(_num(b['actual_cost'])), style: FarmTypography.textTheme.titleSmall),
                      Text(b['unit_cost'] == null ? '—' : '\$${_num(b['unit_cost']).toStringAsFixed(3)}/${b['unit'] ?? 'kg'}', style: FarmTypography.textTheme.bodySmall),
                    ],
                ],
              ),
      ),
    ]);
  }

  static double _num(Object? v) => (v as num?)?.toDouble() ?? 0;
}

/// One feed's share of the period's cost, as a bar the eye can compare.
class _ShareRow extends StatelessWidget {
  const _ShareRow({required this.label, required this.quantity, required this.cost, required this.share});
  final String label;
  final String quantity;
  final double cost;
  final double share;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(label, style: FarmTypography.textTheme.titleSmall)),
          Text(quantity, style: FarmTypography.textTheme.bodySmall),
          const SizedBox(width: 12),
          Text(feedMoney(cost), style: FarmTypography.textTheme.titleSmall),
        ]),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(value: share.clamp(0, 1), minHeight: 6, backgroundColor: FarmColors.mist, color: FarmColors.gold),
        ),
      ]),
    );
  }
}


/// One feed's price: what a unit costs when it is fed next, and its type.
class _PriceRow extends StatelessWidget {
  const _PriceRow({required this.product, required this.lang, required this.canEdit});
  final FeedProduct product;
  final String lang;
  final bool canEdit;

  @override
  Widget build(BuildContext context) {
    final noPrice = product.currentUnitCost == null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(product.label(lang), style: FarmTypography.textTheme.titleSmall, overflow: TextOverflow.ellipsis),
            Text(rationTypeLabel(context, product.rationType), style: FarmTypography.textTheme.bodySmall),
          ]),
        ),
        Text(
          feedPriceLabel(context, product),
          key: ValueKey('feed-price-${product.id}'),
          style: noPrice && product.isFeedable
              ? const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: FarmColors.warningInk)
              : FarmTypography.textTheme.titleSmall,
        ),
        if (canEdit)
          TextButton(
            key: ValueKey('feed-set-price-${product.id}'),
            onPressed: () => showFeedTypeAndPriceDialog(context, product),
            child: Text(context.t('setPrice')),
          ),
      ]),
    );
  }
}
