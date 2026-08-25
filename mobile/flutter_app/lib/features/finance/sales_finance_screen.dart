import 'package:flutter/material.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/widgets/app_icon.dart';
import '../../core/widgets/charts/line_trend_chart.dart';
import '../../core/widgets/kpi_card.dart';
import '../../core/widgets/section_card.dart';
import '../../data/demo/demo_data.dart';
import '../../domain/entities/finance.dart';

class SalesFinanceScreen extends StatelessWidget {
  const SalesFinanceScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final sales = DemoData.salesToday;
    final expenses = DemoData.expensesToday;
    final revenue = sales.fold<double>(0, (s, x) => s + x.amountUsd);
    final expenseTotal = expenses.fold<double>(0, (s, x) => s + x.amountUsd);
    final margin = revenue - expenseTotal;
    final cashCollected = sales.where((s) => s.paymentStatus == PaymentStatus.paid).fold<double>(0, (s, x) => s + x.amountUsd);
    final pending = revenue - cashCollected;

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
              KpiCard(icon: FarmIcon.money, label: context.t('revenueToday'), value: '\$${revenue.toStringAsFixed(0)}', trendLabel: '+8.4%', trendUp: true),
              KpiCard(icon: FarmIcon.report, label: context.t('expensesToday'), value: '\$${expenseTotal.toStringAsFixed(0)}', trendLabel: '+5.1%', trendUp: false),
              KpiCard(icon: FarmIcon.chartLine, label: context.t('grossMargin'), value: '\$${margin.toStringAsFixed(0)}', caption: '${(margin / revenue * 100).toStringAsFixed(1)}% margin'),
              KpiCard(icon: FarmIcon.inventory, label: context.t('cashCollected'), value: '\$${cashCollected.toStringAsFixed(0)}', caption: '${(cashCollected / revenue * 100).toStringAsFixed(0)}% of revenue'),
              KpiCard(icon: FarmIcon.calendar, label: context.t('pendingPayments'), value: '\$${pending.toStringAsFixed(0)}', caption: '${(pending / revenue * 100).toStringAsFixed(0)}% of revenue', tint: FarmColors.warning),
            ];
            return Wrap(spacing: FarmSpacing.md, runSpacing: FarmSpacing.md, children: [for (final c2 in cards) SizedBox(width: w, child: c2)]);
          }),
          const SizedBox(height: FarmSpacing.md),
          LayoutBuilder(builder: (context, c) {
            final wide = c.maxWidth > kTabletBreakpoint;
            final salesCard = SectionCard(
              title: context.t('salesBreakdown'),
              trailing: '${context.t('total')} \$${revenue.toStringAsFixed(0)}',
              child: Column(children: [for (final s in sales) _BreakdownRow(icon: _iconForProduct(s.productType), label: s.productLabel, amount: s.amountUsd, total: revenue)]),
            );
            final expenseCard = SectionCard(
              title: context.t('expenseBreakdown'),
              trailing: '${context.t('total')} \$${expenseTotal.toStringAsFixed(0)}',
              child: Column(children: [for (final e in expenses) _BreakdownRow(icon: _iconForExpense(e.category), label: _expenseLabel(e.category), amount: e.amountUsd, total: expenseTotal, danger: true)]),
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
                  LineTrendChart(values: DemoData.profitTrend7Days, labels: DemoData.profitTrend7DaysLabels, height: 140, color: FarmColors.success),
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
            final topProducts = SectionCard(
              title: context.t('topSellingProducts'),
              subtitle: 'by Revenue',
              trailing: context.t('viewAllProducts'),
              child: Column(
                children: [
                  for (var i = 0; i < DemoData.topSellingProducts.length; i++)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Row(children: [
                        Text('${i + 1}.', style: FarmTypography.textTheme.titleSmall),
                        const SizedBox(width: 8),
                        Expanded(child: Text(DemoData.topSellingProducts[i]['name'] as String, style: FarmTypography.textTheme.titleSmall)),
                        Text('\$${DemoData.topSellingProducts[i]['amount']}', style: FarmTypography.textTheme.titleSmall),
                        const SizedBox(width: 8),
                        Text('${DemoData.topSellingProducts[i]['pct']}%', style: const TextStyle(fontSize: 11, color: FarmColors.muted)),
                      ]),
                    ),
                ],
              ),
            );
            final insights = SectionCard(
              title: context.t('businessInsights'),
              child: Column(
                children: [
                  for (final insight in DemoData.businessInsights)
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
            if (!wide) return Column(children: [topProducts, const SizedBox(height: FarmSpacing.md), insights]);
            return Row(children: [Expanded(child: topProducts), const SizedBox(width: FarmSpacing.md), Expanded(child: insights)]);
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

  String _expenseLabel(String category) => category[0].toUpperCase() + category.substring(1);
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
