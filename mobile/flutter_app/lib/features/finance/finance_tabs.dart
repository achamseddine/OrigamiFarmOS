import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/widgets/app_icon.dart';
import '../../core/widgets/charts/bar_trend_chart.dart';
import '../../core/widgets/section_card.dart';
import '../../core/widgets/status_pill.dart';
import '../../core/widgets/ux_blocks.dart';
import '../../api/api_client.dart' show WriteResult;
import '../../domain/entities/finance.dart';
import '../../providers/access_provider.dart';
import '../../providers/finance_provider.dart';
import '../health/pharmacy_tab.dart' show askReason;
import '../production/milk_sales_ui.dart' show money;
import '../reports/report_docs.dart' show codeLabel;
import '../reports/reports_screen.dart' show ReportTableView;
import '../reports/report_export.dart' show ReportTable;
import 'finance_forms.dart';

String _d(DateTime d) {
  final l = d.toLocal();
  return '${l.day}/${l.month}/${l.year}';
}

/// What a sale's product is called: what was typed, or its kind.
String saleLabel(BuildContext context, FinanceSale s) {
  final label = s.productLabel ?? '';
  return switch (label) {
    'Raw milk' => context.t('msRawMilk'),
    'Raw milk (cancelled sale)' => context.t('msRawMilkCancelled'),
    '' => codeLabel(context, 'product_', s.productType),
    _ => label,
  };
}

/// "tray", "kg" in the person's language; a unit someone typed stays as it is.
String unitLabel(BuildContext context, String? unit) {
  if (unit == null || unit.isEmpty) return '';
  final key = 'finUnit_$unit';
  final label = context.t(key);
  return label == key ? unit : label;
}

Future<void> _act(BuildContext context, Future<WriteResult> Function() run, String doneKey) async {
  final result = await run();
  if (!context.mounted) return;
  if (result.success && !result.queued) refreshMoney(context);
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(result.success ? context.t(doneKey) : (result.error ?? context.t('couldNotSave')))));
}

class _Filter extends StatelessWidget {
  const _Filter({required this.options, required this.selected, required this.onSelect, required this.prefix});
  final List<String> options;
  final String selected;
  final ValueChanged<String> onSelect;
  final String prefix;

  @override
  Widget build(BuildContext context) => Wrap(spacing: 8, runSpacing: 6, children: [
        for (final o in options)
          ChoiceChip(key: ValueKey('$prefix-filter-$o'), label: Text(context.t('finFilter_$o')), selected: selected == o, onSelected: (_) => onSelect(o)),
      ]);
}

// ------------------------------------------------------------- sales
class FinanceSalesTab extends StatefulWidget {
  const FinanceSalesTab({super.key});

  @override
  State<FinanceSalesTab> createState() => _FinanceSalesTabState();
}

class _FinanceSalesTabState extends State<FinanceSalesTab> {
  String _filter = 'all';

  @override
  Widget build(BuildContext context) {
    final finance = context.watch<FinanceProvider>();
    final access = context.watch<AccessProvider>();
    final rows = [
      for (final s in finance.sales)
        if (_filter == 'all' || (_filter == 'unpaid' && s.owed) || (_filter == 'cancelled' && (s.cancelled || s.isReversal))) s,
    ];
    final total = rows.fold(0.0, (t, s) => t + s.amount);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionHeading(
        title: context.t('finSalesTitle'),
        subtitle: context.t('finSalesSub'),
        actions: [
          if (access.canRecordSale)
            FilledButton.icon(
              key: const ValueKey('finance-record-sale'),
              onPressed: () => showRecordSaleDialog(context),
              icon: const Icon(Icons.add, size: 18),
              label: Text(context.t('finRecordSale')),
            ),
        ],
      ),
      const SizedBox(height: FarmSpacing.sm),
      _Filter(options: const ['all', 'unpaid', 'cancelled'], selected: _filter, onSelect: (f) => setState(() => _filter = f), prefix: 'sales'),
      const SizedBox(height: FarmSpacing.sm),
      Text('${rows.length} · ${money(total, 'USD')}', style: FarmTypography.textTheme.bodySmall),
      const SizedBox(height: FarmSpacing.sm),
      if (rows.isEmpty)
        EmptyState(message: context.t('finNoSales'), icon: FarmIcon.money, compact: true)
      else
        for (final s in rows) FinanceSaleRow(sale: s),
    ]);
  }
}

class FinanceSaleRow extends StatelessWidget {
  const FinanceSaleRow({super.key, required this.sale});
  final FinanceSale sale;

  @override
  Widget build(BuildContext context) {
    final s = sale;
    final access = context.watch<AccessProvider>();
    final pill = s.isReversal
        ? StatusPill(label: context.t('finReversal'), level: FarmStatusLevel.neutral, dense: true)
        : s.cancelled
            ? StatusPill(label: context.t('msCancelled'), level: FarmStatusLevel.neutral, dense: true)
            : StatusPill(
                label: context.t(s.paid ? 'msPaid' : (s.partlyPaid ? 'finPartPaid' : 'msToBePaid')),
                level: s.paid ? FarmStatusLevel.good : FarmStatusLevel.watch,
                dense: true);
    final q = s.quantity;
    final qty = q == null ? '' : ' · ${q == q.roundToDouble() ? q.toStringAsFixed(0) : q.toStringAsFixed(2)} ${unitLabel(context, s.unit)}'.trimRight();
    return Container(
      key: ValueKey('finance-sale-${s.id}'),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(color: FarmColors.card, borderRadius: BorderRadius.circular(10), border: Border.all(color: FarmColors.border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Text(
              '${saleLabel(context, s)}$qty',
              style: FarmTypography.textTheme.titleSmall?.copyWith(decoration: s.cancelled ? TextDecoration.lineThrough : null),
            ),
          ),
          const SizedBox(width: 8),
          Text(financeAmount(s), style: FarmTypography.textTheme.titleSmall),
          const SizedBox(width: 8),
          pill,
        ]),
        Text(
          [
            _d(s.soldAt),
            if ((s.buyerName ?? '').isNotEmpty) s.buyerName!,
            if (s.partlyPaid && s.owed) '${context.t('mnOwed')} ${money(s.due, 'USD')}',
            if (s.reference != null) '#${s.reference}',
            if (s.cancelReason != null) '${context.t('reason')}: ${s.cancelReason}',
            if (s.pending) context.t('msWaitingSync'),
          ].join(' · '),
          style: FarmTypography.textTheme.bodySmall,
        ),
        if (!s.cancelled && !s.isReversal && !s.pending && ((!s.paid && access.canRecordSale) || access.canCancelSale))
          Wrap(alignment: WrapAlignment.end, spacing: 4, children: [
            if (!s.paid && access.canRecordSale)
              TextButton(
                key: ValueKey('finance-sale-paid-${s.id}'),
                onPressed: () => _act(context, () => context.read<FinanceProvider>().markSalePaid(s), 'msMarkedPaid'),
                child: Text(context.t('msMarkPaid')),
              ),
            if (access.canCancelSale)
              TextButton(
                key: ValueKey('finance-sale-cancel-${s.id}'),
                onPressed: () async {
                  final why = await askReason(context, title: context.t('msCancelSale'), label: context.t('msCancelWhy'));
                  if (why == null || !context.mounted) return;
                  await _act(context, () => context.read<FinanceProvider>().cancelSale(s, why), 'finSaleCancelled');
                },
                child: Text(context.t('msCancelSale')),
              ),
          ]),
      ]),
    );
  }
}

// ---------------------------------------------------------- expenses
class FinanceExpensesTab extends StatefulWidget {
  const FinanceExpensesTab({super.key});

  @override
  State<FinanceExpensesTab> createState() => _FinanceExpensesTabState();
}

class _FinanceExpensesTabState extends State<FinanceExpensesTab> {
  String _filter = 'all';

  @override
  Widget build(BuildContext context) {
    final finance = context.watch<FinanceProvider>();
    final access = context.watch<AccessProvider>();
    final today = DateTime.now();
    final rows = [
      for (final e in finance.expenses)
        if (_filter == 'all' || (_filter == 'to_pay' && e.toPay) || (_filter == 'overdue' && e.overdue(today)) || (_filter == 'cancelled' && e.cancelled)) e,
    ];
    final total = rows.where((e) => !e.cancelled).fold(0.0, (t, e) => t + e.amount);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionHeading(
        title: context.t('finExpensesTitle'),
        subtitle: context.t('finExpensesSub'),
        actions: [
          if (access.canRecordExpense)
            FilledButton.icon(
              key: const ValueKey('finance-record-expense'),
              onPressed: () => showRecordExpenseDialog(context),
              icon: const Icon(Icons.add, size: 18),
              label: Text(context.t('finRecordExpense')),
            ),
        ],
      ),
      const SizedBox(height: FarmSpacing.sm),
      _Filter(options: const ['all', 'to_pay', 'overdue', 'cancelled'], selected: _filter, onSelect: (f) => setState(() => _filter = f), prefix: 'expenses'),
      const SizedBox(height: FarmSpacing.sm),
      Text('${rows.length} · ${money(total, 'USD')}', style: FarmTypography.textTheme.bodySmall),
      const SizedBox(height: FarmSpacing.sm),
      if (rows.isEmpty)
        EmptyState(message: context.t('finNoExpenses'), icon: FarmIcon.report, compact: true)
      else
        for (final e in rows) FinanceExpenseRow(expense: e),
    ]);
  }
}

class FinanceExpenseRow extends StatelessWidget {
  const FinanceExpenseRow({super.key, required this.expense});
  final FinanceExpense expense;

  @override
  Widget build(BuildContext context) {
    final e = expense;
    final access = context.watch<AccessProvider>();
    final overdue = e.overdue(DateTime.now());
    final pill = e.cancelled
        ? StatusPill(label: context.t('msCancelled'), level: FarmStatusLevel.neutral, dense: true)
        : e.paid
            ? StatusPill(label: context.t('finPaid'), level: FarmStatusLevel.good, dense: true)
            : StatusPill(label: context.t(overdue ? 'finOverdue' : 'finBillToPay'), level: overdue ? FarmStatusLevel.alert : FarmStatusLevel.watch, dense: true);
    return Container(
      key: ValueKey('finance-expense-${e.id}'),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(color: FarmColors.card, borderRadius: BorderRadius.circular(10), border: Border.all(color: FarmColors.border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Text(
              [codeLabel(context, 'expense_', e.category), if ((e.description ?? '').isNotEmpty) e.description!].join(' · '),
              style: FarmTypography.textTheme.titleSmall?.copyWith(decoration: e.cancelled ? TextDecoration.lineThrough : null),
            ),
          ),
          const SizedBox(width: 8),
          Text(expenseAmount(e), style: FarmTypography.textTheme.titleSmall),
          const SizedBox(width: 8),
          pill,
        ]),
        Text(
          [
            _d(e.incurredAt),
            if ((e.supplierName ?? '').isNotEmpty) e.supplierName!,
            if (e.partlyPaid && e.toPay) '${context.t('finPaidSoFar')} ${money(e.amountPaid, 'USD')} · ${context.t('payStillOwed')} ${money(e.owed, 'USD')}',
            if (e.stockPurchase) context.t('finStockPurchase'),
            if (e.toPay && e.dueDate != null) '${context.t('finDueDate')}: ${_d(e.dueDate!)}',
            if (e.reference != null) '#${e.reference}',
            if (e.cancelReason != null) '${context.t('reason')}: ${e.cancelReason}',
            if (e.pending) context.t('msWaitingSync'),
          ].join(' · '),
          style: FarmTypography.textTheme.bodySmall,
        ),
        if (!e.cancelled && !e.pending && ((e.toPay && access.canRecordExpense) || access.canCancelExpense))
          Wrap(alignment: WrapAlignment.end, spacing: 4, children: [
            if (e.toPay && access.canRecordExpense)
              TextButton(
                key: ValueKey('finance-expense-pay-${e.id}'),
                onPressed: () => showPayBillDialog(context, e),
                child: Text(context.t('finPayPart')),
              ),
            if (e.toPay && access.canRecordExpense)
              TextButton(
                key: ValueKey('finance-expense-paid-${e.id}'),
                onPressed: () => _act(context, () => context.read<FinanceProvider>().markExpensePaid(e), 'finBillPaid'),
                child: Text(context.t('finMarkBillPaid')),
              ),
            if (access.canCancelExpense)
              TextButton(
                key: ValueKey('finance-expense-cancel-${e.id}'),
                onPressed: () async {
                  final why = await askReason(context, title: context.t('finCancelExpense'), label: context.t('finCancelExpenseWhy'));
                  if (why == null || !context.mounted) return;
                  await _act(context, () => context.read<FinanceProvider>().cancelExpense(e, why), 'finExpenseCancelled');
                },
                child: Text(context.t('finCancelExpense')),
              ),
          ]),
      ]),
    );
  }
}

// --------------------------------------------------------- who owes what
class FinanceOwedTab extends StatelessWidget {
  const FinanceOwedTab({super.key});

  @override
  Widget build(BuildContext context) {
    final finance = context.watch<FinanceProvider>();
    final access = context.watch<AccessProvider>();
    final today = DateTime.now();
    final unpaid = finance.unpaidSales;
    final bills = finance.billsToPay;
    final owedToUs = unpaid.fold(0.0, (t, s) => t + s.due);
    final weOwe = bills.fold(0.0, (t, e) => t + e.owed);
    final overdue = bills.where((e) => e.overdue(today)).fold(0.0, (t, e) => t + e.owed);
    Widget figure(String key, String label, String value, {Color? color}) => Container(
          key: ValueKey(key),
          padding: const EdgeInsets.all(FarmSpacing.md),
          decoration: BoxDecoration(color: FarmColors.card, borderRadius: FarmRadii.card),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: FarmTypography.textTheme.labelMedium?.copyWith(color: FarmColors.muted)),
            const SizedBox(height: 4),
            Text(value, style: FarmTypography.textTheme.headlineMedium?.copyWith(color: color)),
          ]),
        );
    final byBuyer = <String, ({String name, double amount, int count})>{};
    for (final s in unpaid) {
      final name = (s.buyerName ?? '').trim().isEmpty ? context.t('finNoName') : s.buyerName!.trim();
      final k = name.toLowerCase();
      final b = byBuyer[k];
      byBuyer[k] = (name: name, amount: (b?.amount ?? 0) + s.due, count: (b?.count ?? 0) + 1);
    }
    final bySupplier = <String, ({String name, double amount, int count})>{};
    for (final e in bills) {
      final name = (e.supplierName ?? '').trim().isEmpty ? context.t('finNoName') : e.supplierName!.trim();
      final k = name.toLowerCase();
      final b = bySupplier[k];
      bySupplier[k] = (name: name, amount: (b?.amount ?? 0) + e.owed, count: (b?.count ?? 0) + 1);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      EqualGrid(minTileWidth: 200, maxColumns: 3, spacing: FarmSpacing.sm, children: [
        if (access.canSeeSales) figure('owed-to-us', context.t('finOwedToUs'), money(owedToUs, 'USD'), color: FarmColors.warning),
        if (access.canSeeExpenses) figure('we-owe', context.t('finWeOwe'), money(weOwe, 'USD')),
        if (access.canSeeExpenses) figure('overdue', context.t('finOverdueBills'), money(overdue, 'USD'), color: overdue > 0 ? FarmColors.danger : null),
      ]),
      const SizedBox(height: FarmSpacing.md),
      if (access.canSeeSales)
        SectionCard(
          title: context.t('finCustomersOwe'),
          subtitle: context.t('finCustomersOweSub'),
          child: unpaid.isEmpty
              ? Text(context.t('finNobodyOwes'), style: FarmTypography.textTheme.bodySmall)
              : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  ReportTableView(
                    table: ReportTable(
                      title: '',
                      columns: [context.t('msBuyer'), context.t('rpSales'), context.t('rpAmount')],
                      numeric: const {1, 2},
                      flex: const [3, 1, 1],
                      rows: [
                        for (final b in (byBuyer.values.toList()..sort((a, b) => b.amount.compareTo(a.amount))))
                          [b.name, '${b.count}', money(b.amount, 'USD')],
                      ],
                    ),
                  ),
                  if (access.canReceivePayment) ...[
                    const SizedBox(height: FarmSpacing.sm),
                    // One payment for all of a buyer's sales — the collector's week.
                    Wrap(spacing: 8, runSpacing: 8, children: [
                      for (final b in byBuyer.values)
                        if (b.name != context.t('finNoName'))
                          OutlinedButton.icon(
                            key: ValueKey('receive-payment-${b.name}'),
                            onPressed: () => showReceivePaymentDialog(context, buyer: b.name),
                            icon: const Icon(Icons.payments_outlined, size: 18),
                            label: Text('${context.t('payReceiveFrom')} ${b.name}'),
                          ),
                    ]),
                  ],
                  const SizedBox(height: FarmSpacing.md),
                  for (final s in unpaid) FinanceSaleRow(sale: s),
                ]),
        ),
      if (access.canSeeSales && access.canSeeExpenses) const SizedBox(height: FarmSpacing.md),
      if (access.canSeeExpenses)
        SectionCard(
          title: context.t('finFarmOwes'),
          subtitle: context.t('finFarmOwesSub'),
          child: bills.isEmpty
              ? Text(context.t('finNoBills'), style: FarmTypography.textTheme.bodySmall)
              : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  ReportTableView(
                    table: ReportTable(
                      title: '',
                      columns: [context.t('finPaidTo'), context.t('finBills'), context.t('rpAmount')],
                      numeric: const {1, 2},
                      flex: const [3, 1, 1],
                      rows: [
                        for (final b in (bySupplier.values.toList()..sort((a, b) => b.amount.compareTo(a.amount))))
                          [b.name, '${b.count}', money(b.amount, 'USD')],
                      ],
                    ),
                  ),
                  const SizedBox(height: FarmSpacing.md),
                  for (final e in (bills.toList()..sort((a, b) => (a.dueDate ?? a.incurredAt).compareTo(b.dueDate ?? b.incurredAt)))) FinanceExpenseRow(expense: e),
                ]),
        ),
    ]);
  }
}

// ---------------------------------------------------------- profit & loss
const _activities = ['dairy', 'poultry', 'livestock', 'crops', 'mouneh', 'visits', 'general'];

String costLineLabel(BuildContext context, String line) {
  if (line.startsWith('expense:')) return codeLabel(context, 'expense_', line.substring(8));
  return codeLabel(context, 'finLine_', line);
}

String monthLabel(BuildContext context, String ym) {
  final parts = ym.split('-');
  if (parts.length != 2) return ym;
  return '${context.t('month_${int.parse(parts[1])}')} ${parts[0]}';
}

class FinanceProfitLossTab extends StatelessWidget {
  const FinanceProfitLossTab({super.key});

  @override
  Widget build(BuildContext context) {
    final pl = context.watch<FinanceProvider>().profitLoss;
    if (pl == null) {
      return EmptyState(message: context.t('finPlLoading'), icon: FarmIcon.chartLine, compact: true);
    }
    double v(Object? x) => (x as num?)?.toDouble() ?? 0;
    final totals = (pl['totals'] as Map?)?.cast<String, dynamic>() ?? const {};
    final months = [for (final m in (pl['months'] as List<dynamic>? ?? const [])) (m as Map).cast<String, dynamic>()];
    final activities = [for (final a in (pl['by_activity'] as List<dynamic>? ?? const [])) (a as Map).cast<String, dynamic>()];
    final lines = [for (final l in (pl['cost_lines'] as List<dynamic>? ?? const [])) (l as Map).cast<String, dynamic>()];
    final profit = v(totals['profit']);
    Widget figure(String key, String label, double value, {bool signed = false}) => Container(
          key: ValueKey('pl-$key'),
          padding: const EdgeInsets.all(FarmSpacing.md),
          decoration: BoxDecoration(color: FarmColors.card, borderRadius: FarmRadii.card),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: FarmTypography.textTheme.labelMedium?.copyWith(color: FarmColors.muted)),
            const SizedBox(height: 4),
            Text(money(value, 'USD'),
                style: FarmTypography.textTheme.headlineMedium?.copyWith(color: signed ? (value < 0 ? FarmColors.danger : FarmColors.success) : null)),
          ]),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('${context.t('rpPeriod')}: ${monthLabel(context, months.isEmpty ? '' : months.first['month'] as String)} – ${monthLabel(context, months.isEmpty ? '' : months.last['month'] as String)}',
          style: FarmTypography.textTheme.bodySmall),
      const SizedBox(height: FarmSpacing.sm),
      EqualGrid(minTileWidth: 170, maxColumns: 5, spacing: FarmSpacing.sm, children: [
        figure('revenue', context.t('rpRevenue'), v(totals['revenue'])),
        figure('costs', context.t('finCosts'), v(totals['costs'])),
        figure('profit', context.t('finProfit'), profit, signed: true),
        figure('cash-in', context.t('finCashIn'), v(totals['cash_in'])),
        figure('cash-out', context.t('finCashOut'), v(totals['cash_out'])),
      ]),
      const SizedBox(height: FarmSpacing.md),
      SectionCard(
        title: context.t('finProfitPerMonth'),
        child: months.every((m) => v(m['revenue']) == 0 && v(m['costs']) == 0)
            ? Text(context.t('rpNothingInPeriod'), style: FarmTypography.textTheme.bodySmall)
            : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                BarTrendChart(
                  height: 170,
                  segmentColors: const [FarmColors.olive],
                  bars: [for (final m in months) BarGroup(label: '${int.parse((m['month'] as String).split('-')[1])}', segments: [v(m['revenue'])])],
                  overlayLine: [for (final m in months) v(m['costs'])],
                  overlayColor: FarmColors.danger,
                ),
                const SizedBox(height: 6),
                Wrap(spacing: FarmSpacing.md, children: [
                  _Legend(color: FarmColors.olive, label: context.t('rpRevenue')),
                  _Legend(color: FarmColors.danger, label: context.t('finCosts')),
                ]),
              ]),
      ),
      const SizedBox(height: FarmSpacing.md),
      SectionCard(
        title: context.t('finMonthByMonth'),
        child: ReportTableView(
          table: ReportTable(
            title: '',
            columns: [context.t('finMonth'), context.t('rpRevenue'), context.t('finCosts'), context.t('finProfit'), context.t('finCashIn'), context.t('finCashOut')],
            numeric: const {1, 2, 3, 4, 5},
            flex: const [2, 1, 1, 1, 1, 1],
            rows: [
              for (final m in months.reversed)
                [monthLabel(context, m['month'] as String), money(v(m['revenue']), 'USD'), money(v(m['costs']), 'USD'), money(v(m['profit']), 'USD'),
                 money(v(m['cash_in']), 'USD'), money(v(m['cash_out']), 'USD')],
            ],
          ),
        ),
      ),
      const SizedBox(height: FarmSpacing.md),
      SectionCard(
        title: context.t('finByActivity'),
        subtitle: context.t('finByActivitySub'),
        child: ReportTableView(
          table: ReportTable(
            title: '',
            columns: [context.t('finActivity'), context.t('rpRevenue'), context.t('finCosts'), context.t('finProfit')],
            numeric: const {1, 2, 3},
            flex: const [2, 1, 1, 1],
            rows: [
              for (final a in (activities.toList()..sort((x, y) => _activities.indexOf(x['activity'] as String).compareTo(_activities.indexOf(y['activity'] as String)))))
                [codeLabel(context, 'finActivity_', a['activity'] as String), money(v(a['revenue']), 'USD'), money(v(a['costs']), 'USD'), money(v(a['profit']), 'USD')],
            ],
          ),
        ),
      ),
      const SizedBox(height: FarmSpacing.md),
      SectionCard(
        title: context.t('finWhereMoneyWent'),
        subtitle: context.t('finWhereMoneyWentSub'),
        child: ReportTableView(
          table: ReportTable(
            title: '',
            columns: [context.t('rpCategory'), context.t('rpAmount')],
            numeric: const {1},
            rows: [for (final l in lines) [costLineLabel(context, l['line'] as String), money(v(l['amount']), 'USD')]],
          ),
        ),
      ),
    ]);
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.color, required this.label});
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 12, height: 12, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3))),
        const SizedBox(width: 6),
        Text(label, style: FarmTypography.textTheme.bodySmall),
      ]);
}
