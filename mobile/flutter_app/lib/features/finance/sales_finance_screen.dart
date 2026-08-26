import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/widgets/app_icon.dart';
import '../../core/widgets/charts/line_trend_chart.dart';
import '../../core/widgets/kpi_card.dart';
import '../../core/widgets/section_card.dart';
import '../../providers/sales_provider.dart';

/// Sales & Finance (manager-only) is always-online now: [SalesProvider] is
/// already loaded once at app startup (see app/app.dart's `_DataLoader`),
/// backed by the real `/reports/daily-summary` + `/sales` + `/expenses`
/// endpoints instead of the old fabricated `DemoData` dataset.
///
/// `SalesProvider` is read-only — there is no create-a-sale/expense
/// endpoint yet, so the old "record a sale" flow this screen never actually
/// had a form for stays that way; nothing was removed here because nothing
/// like that existed on this screen to begin with.
class SalesFinanceScreen extends StatelessWidget {
  const SalesFinanceScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final sales = context.watch<SalesProvider>();
    final summary = sales.dailySummary;
    final revenue = sales.revenueToday;
    final expenseTotal = sales.expensesToday;
    final margin = sales.grossMargin;
    final cashCollected = sales.cashCollected;
    final pending = sales.pendingPayments;
    final salesBreakdown = List<Map<String, dynamic>>.from(summary?['sales_breakdown'] as List? ?? []);
    final expenseBreakdown = List<Map<String, dynamic>>.from(summary?['expense_breakdown'] as List? ?? []);
    final topProducts = sales.topSellingProducts;
    final insights = sales.businessInsights;
    final profitTrend = sales.profitTrend7Days();
    const profitTrendLabels = ['D-6', 'D-5', 'D-4', 'D-3', 'D-2', 'Yesterday', 'Today'];

    String pctOfRevenue(double amount, {int decimals = 0}) => revenue == 0 ? '—' : '${(amount / revenue * 100).toStringAsFixed(decimals)}%';

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Row(children: [
                  const AppIcon(FarmIcon.sun, size: 22, color: FarmColors.gold),
                  const SizedBox(width: 8),
                  Text(context.t('dailySummaryTitle'), style: FarmTypography.display(size: 26)),
                ]),
              ),
              OutlinedButton.icon(onPressed: () {}, icon: const Icon(Icons.bar_chart, size: 16), label: Text(context.t('compareWithYesterday'))),
            ],
          ),
          const SizedBox(height: FarmSpacing.md),
          LayoutBuilder(builder: (context, c) {
            final perRow = c.maxWidth > 1100 ? 5 : (c.maxWidth > 700 ? 3 : 2);
            final w = (c.maxWidth - FarmSpacing.md * (perRow - 1)) / perRow;
            final cards = [
              KpiCard(icon: FarmIcon.money, label: context.t('revenueToday'), value: '\$${revenue.toStringAsFixed(0)}'),
              KpiCard(icon: FarmIcon.report, label: context.t('expensesToday'), value: '\$${expenseTotal.toStringAsFixed(0)}'),
              KpiCard(icon: FarmIcon.chartLine, label: context.t('grossMargin'), value: '\$${margin.toStringAsFixed(0)}', caption: '${pctOfRevenue(margin, decimals: 1)} margin'),
              KpiCard(icon: FarmIcon.inventory, label: context.t('cashCollected'), value: '\$${cashCollected.toStringAsFixed(0)}', caption: '${pctOfRevenue(cashCollected)} of revenue'),
              KpiCard(icon: FarmIcon.calendar, label: context.t('pendingPayments'), value: '\$${pending.toStringAsFixed(0)}', caption: '${pctOfRevenue(pending)} of revenue', tint: FarmColors.warning),
            ];
            return Wrap(spacing: FarmSpacing.md, runSpacing: FarmSpacing.md, children: [for (final c2 in cards) SizedBox(width: w, child: c2)]);
          }),
          const SizedBox(height: FarmSpacing.md),
          LayoutBuilder(builder: (context, c) {
            final wide = c.maxWidth > kTabletBreakpoint;
            final salesCard = SectionCard(
              title: context.t('salesBreakdown'),
              trailing: '${context.t('total')} \$${revenue.toStringAsFixed(0)}',
              child: salesBreakdown.isEmpty
                  ? Text('No sales recorded yet.', style: FarmTypography.textTheme.bodySmall)
                  : Column(children: [
                      for (final s in salesBreakdown)
                        _BreakdownRow(
                          icon: _iconForProduct(s['product_type'] as String? ?? ''),
                          label: _productTypeLabel(s['product_type'] as String? ?? '—'),
                          amount: (s['amount'] as num?)?.toDouble() ?? 0,
                          total: revenue,
                        ),
                    ]),
            );
            final expenseCard = SectionCard(
              title: context.t('expenseBreakdown'),
              trailing: '${context.t('total')} \$${expenseTotal.toStringAsFixed(0)}',
              child: expenseBreakdown.isEmpty
                  ? Text('No expenses recorded yet.', style: FarmTypography.textTheme.bodySmall)
                  : Column(children: [
                      for (final e in expenseBreakdown)
                        _BreakdownRow(
                          icon: _iconForExpense(e['category'] as String? ?? ''),
                          label: _expenseLabel(e['category'] as String? ?? '—'),
                          amount: (e['amount'] as num?)?.toDouble() ?? 0,
                          total: expenseTotal,
                          danger: true,
                        ),
                    ]),
            );
            final profitCard = SectionCard(
              title: context.t('profitTrend'),
              trailing: context.t('viewReport'),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('\$${margin.toStringAsFixed(0)}', style: FarmTypography.textTheme.headlineMedium),
                  Text(context.t('today'), style: FarmTypography.textTheme.bodySmall),
                  const SizedBox(height: 8),
                  LineTrendChart(values: profitTrend, labels: profitTrendLabels, height: 140, color: FarmColors.success),
                ],
              ),
            );
            if (!wide) return Column(children: [salesCard, const SizedBox(height: FarmSpacing.md), expenseCard, const SizedBox(height: FarmSpacing.md), profitCard]);
            return IntrinsicHeight(
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(child: salesCard),
                const SizedBox(width: FarmSpacing.md),
                Expanded(child: expenseCard),
                const SizedBox(width: FarmSpacing.md),
                Expanded(child: profitCard),
              ]),
            );
          }),
          const SizedBox(height: FarmSpacing.md),
          LayoutBuilder(builder: (context, c) {
            final wide = c.maxWidth > kTabletBreakpoint;
            final topProductsCard = SectionCard(
              title: context.t('topSellingProducts'),
              subtitle: 'by Revenue',
              trailing: context.t('viewAllProducts'),
              child: topProducts.isEmpty
                  ? Text('No sales recorded yet.', style: FarmTypography.textTheme.bodySmall)
                  : Column(
                      children: [
                        for (var i = 0; i < topProducts.length; i++)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            child: Row(children: [
                              Text('${i + 1}.', style: FarmTypography.textTheme.titleSmall),
                              const SizedBox(width: 8),
                              Expanded(child: Text(topProducts[i]['product_label'] as String? ?? '—', style: FarmTypography.textTheme.titleSmall)),
                              Text('\$${((topProducts[i]['amount'] as num?)?.toDouble() ?? 0).toStringAsFixed(0)}', style: FarmTypography.textTheme.titleSmall),
                              const SizedBox(width: 8),
                              Text(pctOfRevenue((topProducts[i]['amount'] as num?)?.toDouble() ?? 0, decimals: 1), style: const TextStyle(fontSize: 11, color: FarmColors.muted)),
                            ]),
                          ),
                      ],
                    ),
            );
            final insightsCard = SectionCard(
              title: context.t('businessInsights'),
              child: insights.isEmpty
                  ? Text('No insights yet.', style: FarmTypography.textTheme.bodySmall)
                  : Column(
                      children: [
                        for (final insight in insights)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Icon(Icons.lightbulb_outline, size: 16, color: FarmColors.gold),
                                const SizedBox(width: 8),
                                Expanded(child: Text(insight, style: FarmTypography.textTheme.bodySmall)),
                              ],
                            ),
                          ),
                      ],
                    ),
            );
            if (!wide) return Column(children: [topProductsCard, const SizedBox(height: FarmSpacing.md), insightsCard]);
            return Row(children: [Expanded(child: topProductsCard), const SizedBox(width: FarmSpacing.md), Expanded(child: insightsCard)]);
          }),
        ],
      ),
    );
  }

  FarmIcon _iconForProduct(String type) {
    switch (type) {
      case 'milk':
        return FarmIcon.milkBottle;
      case 'eggs':
        return FarmIcon.egg;
      case 'produce':
        return FarmIcon.leaf;
      case 'animals':
        return FarmIcon.cow;
      default:
        return FarmIcon.inventory;
    }
  }

  FarmIcon _iconForExpense(String category) {
    switch (category) {
      case 'feed':
        return FarmIcon.feedBag;
      case 'medicine':
        return FarmIcon.medicine;
      case 'labor':
        return FarmIcon.location;
      case 'fuel':
        return FarmIcon.tractor;
      default:
        return FarmIcon.report;
    }
  }

  String _productTypeLabel(String type) =>
      type.isEmpty ? '—' : type.split('_').map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}').join(' ');

  String _expenseLabel(String category) => category.isEmpty ? '—' : category[0].toUpperCase() + category.substring(1);
}

class _BreakdownRow extends StatelessWidget {
  const _BreakdownRow({required this.icon, required this.label, required this.amount, required this.total, this.danger = false});
  final FarmIcon icon;
  final String label;
  final double amount;
  final double total;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final pct = total == 0 ? 0.0 : amount / total * 100;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        AppIcon(icon, size: 15, color: danger ? FarmColors.danger : FarmColors.cedar),
        const SizedBox(width: 8),
        Expanded(child: Text(label, style: FarmTypography.textTheme.titleSmall)),
        Text('\$${amount.toStringAsFixed(0)}', style: FarmTypography.textTheme.titleSmall),
        const SizedBox(width: 8),
        SizedBox(width: 42, child: Text('${pct.toStringAsFixed(1)}%', textAlign: TextAlign.right, style: const TextStyle(fontSize: 11, color: FarmColors.muted))),
      ]),
    );
  }
}
