import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/widgets/app_icon.dart';
import '../../core/widgets/charts/line_trend_chart.dart';
import '../../core/theme/farm_icon_map.dart';
import '../../core/widgets/hero_band.dart';
import '../../core/widgets/kpi_card.dart';
import '../../core/widgets/module_workspace.dart';
import '../../core/widgets/section_card.dart';
import '../../providers/access_provider.dart';
import '../../providers/finance_provider.dart';
import '../../providers/sales_provider.dart';
import '../production/milk_sales_ui.dart';
import 'finance_forms.dart';
import 'finance_tabs.dart';
import '../reports/report_docs.dart' show codeLabel;
import '../reports/reports_screen.dart' show openReport;

/// Sales & Finance. Today's figures come from [SalesProvider]
/// (`/reports/daily-summary`, loaded at sign-in); the sales, expenses,
/// what is owed and profit and loss from [FinanceProvider] (`/finance/*`).
/// Milk is sold from here as from the Milk page (v0.7.9). The full picture
/// for any period is the Finance report.
enum FinanceTab { today, sales, expenses, owed, profitLoss }

/// Sales & Finance (v0.8.0): today's figures, every sale, expenses and
/// bills, who owes what, and profit and loss — one page with its tabs, on
/// the tablet and the web. The band records a sale, an expense or bill,
/// sells milk, and sets the USD / LBP rate.
class SalesFinanceScreen extends StatefulWidget {
  const SalesFinanceScreen({super.key, this.initialTab = FinanceTab.today});

  final FinanceTab initialTab;

  @override
  State<SalesFinanceScreen> createState() => _SalesFinanceScreenState();
}

class _SalesFinanceScreenState extends State<SalesFinanceScreen> {
  late FinanceTab _tab = widget.initialTab;

  static const _labels = {
    FinanceTab.today: 'finTabToday',
    FinanceTab.sales: 'finTabSales',
    FinanceTab.expenses: 'finTabExpenses',
    FinanceTab.owed: 'finTabOwed',
    FinanceTab.profitLoss: 'finTabProfitLoss',
  };

  bool _asked = false;

  @override
  Widget build(BuildContext context) {
    final access = context.watch<AccessProvider>();
    final finance = context.watch<FinanceProvider>();
    final rates = finance.rates;
    // The books load the first time the page is drawn for someone who may
    // see money (once their permissions are known); later changes reload them.
    if (!_asked && !finance.loaded && (access.canSeeSales || access.canSeeExpenses || access.canSeeProfitLoss)) {
      _asked = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          context.read<FinanceProvider>().load(sales: access.canSeeSales, expenses: access.canSeeExpenses, profitLoss: access.canSeeProfitLoss);
        }
      });
    }
    final tabs = [
      FinanceTab.today,
      if (access.canSeeSales) FinanceTab.sales,
      if (access.canSeeExpenses) FinanceTab.expenses,
      if (access.canSeeSales || access.canSeeExpenses) FinanceTab.owed,
      if (access.canSeeProfitLoss) FinanceTab.profitLoss,
    ];
    final tab = tabs.contains(_tab) ? _tab : tabs.first;
    final canReport = access.canReadReport('finance');
    return ModuleWorkspace(
      header: [
        // The "compare with yesterday" button that used to sit here did
        // nothing when tapped; the seven-day profit chart is the
        // comparison, so the dead control is gone rather than moved.
        HeroBand(
          eyebrow: context.t('ebFinance'),
          title: context.t('finTitle'),
          subtitle: context.t('finSubtitle'),
          icon: FarmIcon.coins,
          scenery: false,
          trailing: rates.lbpPerUsd == null
              ? null
              : ActionChip(
                  key: const ValueKey('finance-rate-chip'),
                  avatar: const Icon(Icons.currency_exchange, size: 18),
                  label: Text('1 USD = ${grouped(rates.lbpPerUsd!)} LBP'),
                  onPressed: () => showExchangeRateDialog(context),
                ),
          actions: [
            if (access.canRecordSale)
              HeroAction(
                key: const ValueKey('finance-hero-sale'),
                primary: true,
                icon: FarmIconMap.add,
                label: context.t('finRecordSale'),
                onPressed: () => showRecordSaleDialog(context),
              ),
            if (access.canRecordExpense)
              HeroAction(
                key: const ValueKey('finance-hero-expense'),
                icon: FarmIcon.report,
                label: context.t('finRecordExpense'),
                onPressed: () => showRecordExpenseDialog(context),
              ),
            if (access.canSellMilk)
              HeroAction(
                key: const ValueKey('finance-sell-milk'),
                icon: FarmIcon.milkBottle,
                label: context.t('msSellMilk'),
                onPressed: () => showSellMilkDialog(context),
              ),
            if (access.canSetExchangeRate || (rates.lbpPerUsd == null && access.canSeeMoney))
              HeroAction(
                key: const ValueKey('finance-hero-rate'),
                icon: FarmIcon.money,
                label: context.t('finExchangeRate'),
                onPressed: () => showExchangeRateDialog(context),
              ),
            if (canReport)
              HeroAction(key: const ValueKey('finance-report'), icon: FarmIcon.report, label: context.t('rpFinanceReport'), onPressed: () => openReport(context, 'finance')),
          ],
        ),
      ],
      labels: [for (final t in tabs) context.t(_labels[t]!)],
      selected: tabs.indexOf(tab),
      onSelect: (i) => setState(() => _tab = tabs[i]),
      tabBuilder: (context, i) => switch (tabs[i]) {
        FinanceTab.today => const FinanceTodayTab(),
        FinanceTab.sales => const FinanceSalesTab(),
        FinanceTab.expenses => const FinanceExpensesTab(),
        FinanceTab.owed => const FinanceOwedTab(),
        FinanceTab.profitLoss => const FinanceProfitLossTab(),
      },
    );
  }
}

/// Today: the day's revenue, expenses and margin, what sold and what was
/// spent, the week's profit, the milk tank and its sales.
class FinanceTodayTab extends StatelessWidget {
  const FinanceTodayTab({super.key});

  @override
  Widget build(BuildContext context) {
    final sales = context.watch<SalesProvider>();
    final access = context.watch<AccessProvider>();
    final canReport = access.canReadReport('finance');
    void report() => openReport(context, 'finance');
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
    final profitTrendLabels = ['-6', '-5', '-4', '-3', '-2', context.t('yesterday'), context.t('today')];

    String pctOfRevenue(double amount, {int decimals = 0}) => revenue == 0 ? '—' : '${(amount / revenue * 100).toStringAsFixed(decimals)}%';

    return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LayoutBuilder(builder: (context, c) {
            final perRow = c.maxWidth > 1100 ? 5 : (c.maxWidth > 700 ? 3 : 2);
            final w = (c.maxWidth - FarmSpacing.md * (perRow - 1)) / perRow;
            final cards = [
              KpiCard(icon: FarmIcon.money, label: context.t('revenueToday'), value: '\$${revenue.toStringAsFixed(0)}'),
              KpiCard(icon: FarmIcon.report, label: context.t('expensesToday'), value: '\$${expenseTotal.toStringAsFixed(0)}'),
              KpiCard(icon: FarmIcon.chartLine, label: context.t('grossMargin'), value: '\$${margin.toStringAsFixed(0)}', caption: '${pctOfRevenue(margin, decimals: 1)} ${context.t('finMarginWord')}'),
              KpiCard(icon: FarmIcon.inventory, label: context.t('cashCollected'), value: '\$${cashCollected.toStringAsFixed(0)}', caption: '${pctOfRevenue(cashCollected)} ${context.t('finOfRevenue')}'),
              KpiCard(icon: FarmIcon.calendar, label: context.t('pendingPayments'), value: '\$${pending.toStringAsFixed(0)}', caption: '${pctOfRevenue(pending)} ${context.t('finOfRevenue')}', tint: FarmColors.warning),
            ];
            return Wrap(spacing: FarmSpacing.md, runSpacing: FarmSpacing.md, children: [for (final c2 in cards) SizedBox(width: w, child: c2)]);
          }),
          const SizedBox(height: FarmSpacing.md),
          // The milk sold and still to be paid — sell, mark paid, cancel.
          if (access.canSellMilk || access.canCancelMilkSale) ...[
            const MilkTankCard(),
            const SizedBox(height: FarmSpacing.md),
          ],
          LayoutBuilder(builder: (context, c) {
            final wide = c.maxWidth > kTabletBreakpoint;
            final salesCard = SectionCard(
              title: context.t('salesBreakdown'),
              trailing: '${context.t('total')} \$${revenue.toStringAsFixed(0)}',
              child: salesBreakdown.isEmpty
                  ? Text(context.t('finNoSales'), style: FarmTypography.textTheme.bodySmall)
                  : Column(children: [
                      for (final s in salesBreakdown)
                        _BreakdownRow(
                          icon: _iconForProduct(s['product_type'] as String? ?? ''),
                          label: codeLabel(context, 'product_', s['product_type'] as String? ?? ''),
                          amount: (s['amount'] as num?)?.toDouble() ?? 0,
                          total: revenue,
                        ),
                    ]),
            );
            final expenseCard = SectionCard(
              title: context.t('expenseBreakdown'),
              trailing: '${context.t('total')} \$${expenseTotal.toStringAsFixed(0)}',
              child: expenseBreakdown.isEmpty
                  ? Text(context.t('finNoExpenses'), style: FarmTypography.textTheme.bodySmall)
                  : Column(children: [
                      for (final e in expenseBreakdown)
                        _BreakdownRow(
                          icon: _iconForExpense(e['category'] as String? ?? ''),
                          label: codeLabel(context, 'expense_', e['category'] as String? ?? ''),
                          amount: (e['amount'] as num?)?.toDouble() ?? 0,
                          total: expenseTotal,
                          danger: true,
                        ),
                    ]),
            );
            final profitCard = SectionCard(
              title: context.t('profitTrend'),
              trailing: canReport ? context.t('viewReport') : null,
              onTrailingTap: canReport ? report : null,
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
              subtitle: context.t('finByRevenue'),
              trailing: canReport ? context.t('viewAllProducts') : null,
              onTrailingTap: canReport ? report : null,
              child: topProducts.isEmpty
                  ? Text(context.t('finNoSales'), style: FarmTypography.textTheme.bodySmall)
                  : Column(
                      children: [
                        for (var i = 0; i < topProducts.length; i++)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            child: Row(children: [
                              Text('${i + 1}.', style: FarmTypography.textTheme.titleSmall),
                              const SizedBox(width: 8),
                              Expanded(child: Text(_productLabel(context, topProducts[i]['product_label'] as String?), style: FarmTypography.textTheme.titleSmall)),
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
                  ? Text(context.t('finNoInsights'), style: FarmTypography.textTheme.bodySmall)
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
      );
  }

  /// The farm server names a milk sale "Raw milk"; other names were typed.
  static String _productLabel(BuildContext context, String? label) => switch (label ?? '') {
        'Raw milk' => context.t('msRawMilk'),
        'Raw milk (cancelled sale)' => context.t('msRawMilkCancelled'),
        '' => '—',
        final other => other,
      };

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
