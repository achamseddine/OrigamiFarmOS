import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/widgets/data_table_card.dart';
import '../../core/widgets/kpi_card.dart';
import '../../core/widgets/app_icon.dart';
import '../../core/widgets/section_card.dart';
import '../../providers/visits_provider.dart';

enum _Scope { allTime, session, dateRange }

/// Visitor Profitability Report (tech spec v0.6 §6, screen 10 / §9
/// "Analytics formulas") — every formula computed from granular
/// package/activity/retail components, never from a booking's stored
/// summary field (see `VisitsProvider.profitabilityFor`'s doc comment).
class VisitorProfitabilityTab extends StatefulWidget {
  const VisitorProfitabilityTab({super.key});

  @override
  State<VisitorProfitabilityTab> createState() => _VisitorProfitabilityTabState();
}

class _VisitorProfitabilityTabState extends State<VisitorProfitabilityTab> {
  _Scope _scope = _Scope.allTime;
  String? _sessionId;
  DateTime _start = DateTime.now().subtract(const Duration(days: 30));
  DateTime _end = DateTime.now().add(const Duration(days: 30));

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<VisitsProvider>();
    final report = switch (_scope) {
      _Scope.allTime => provider.profitabilityFor(),
      _Scope.session => provider.profitabilityFor(sessionId: _sessionId),
      _Scope.dateRange => provider.profitabilityFor(start: _start, end: _end),
    };
    final summary = report.summary;

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionCard(
            title: 'Scope',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(spacing: 8, children: [
                  ChoiceChip(label: const Text('All time'), selected: _scope == _Scope.allTime, onSelected: (_) => setState(() => _scope = _Scope.allTime)),
                  ChoiceChip(label: const Text('One session'), selected: _scope == _Scope.session, onSelected: (_) => setState(() => _scope = _Scope.session)),
                  ChoiceChip(label: const Text('Date range'), selected: _scope == _Scope.dateRange, onSelected: (_) => setState(() => _scope = _Scope.dateRange)),
                ]),
                if (_scope == _Scope.session) ...[
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    value: _sessionId,
                    decoration: const InputDecoration(labelText: 'Session'),
                    items: [for (final s in provider.sessions) DropdownMenuItem(value: s.id, child: Text('${s.date.day}/${s.date.month}/${s.date.year} · ${s.startTime}–${s.endTime}'))],
                    onChanged: (v) => setState(() => _sessionId = v),
                  ),
                ],
                if (_scope == _Scope.dateRange) ...[
                  const SizedBox(height: 12),
                  Row(children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () async {
                          final picked = await showDatePicker(context: context, initialDate: _start, firstDate: DateTime.now().subtract(const Duration(days: 365)), lastDate: DateTime.now().add(const Duration(days: 365)));
                          if (picked != null) setState(() => _start = picked);
                        },
                        child: Text('From ${_start.day}/${_start.month}/${_start.year}'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () async {
                          final picked = await showDatePicker(context: context, initialDate: _end, firstDate: DateTime.now().subtract(const Duration(days: 365)), lastDate: DateTime.now().add(const Duration(days: 365)));
                          if (picked != null) setState(() => _end = picked);
                        },
                        child: Text('To ${_end.day}/${_end.month}/${_end.year}'),
                      ),
                    ),
                  ]),
                ],
              ],
            ),
          ),
          const SizedBox(height: FarmSpacing.md),
          LayoutBuilder(builder: (context, c) {
            final perRow = c.maxWidth > 900 ? 4 : 2;
            final w = (c.maxWidth - FarmSpacing.md * (perRow - 1)) / perRow;
            final cards = [
              KpiCard(icon: FarmIcon.money, label: 'Visitor Revenue', value: '\$${summary.visitorRevenue.toStringAsFixed(0)}', tint: FarmColors.success),
              KpiCard(icon: FarmIcon.report, label: 'Direct Visit Cost', value: '\$${summary.directVisitCost.toStringAsFixed(0)}'),
              KpiCard(icon: FarmIcon.chartLine, label: 'Gross Margin', value: '\$${summary.grossMargin.toStringAsFixed(0)}', tint: summary.grossMargin >= 0 ? FarmColors.success : FarmColors.danger),
              KpiCard(icon: FarmIcon.eye, label: 'Checked-in Visitors', value: '${summary.checkedInVisitors}'),
              KpiCard(icon: FarmIcon.money, label: 'Revenue / Visitor', value: '\$${summary.revenuePerVisitor.toStringAsFixed(2)}'),
              KpiCard(icon: FarmIcon.inventory, label: 'Retail Conversion', value: '${summary.retailConversionPct.toStringAsFixed(0)}%'),
              KpiCard(icon: FarmIcon.harvestBasket, label: 'Avg Basket Value', value: '\$${summary.averageBasketValue.toStringAsFixed(2)}'),
            ];
            return Wrap(spacing: FarmSpacing.md, runSpacing: FarmSpacing.md, children: [for (final c2 in cards) SizedBox(width: w, child: c2)]);
          }),
          const SizedBox(height: FarmSpacing.md),
          SectionCard(
            title: 'Revenue & Cost Breakdown',
            child: Wrap(spacing: 24, runSpacing: 10, children: [
              _stat('Package revenue', '\$${summary.packageRevenue.toStringAsFixed(2)}'),
              _stat('Activity revenue', '\$${summary.activityRevenue.toStringAsFixed(2)}'),
              _stat('Retail revenue', '\$${summary.retailRevenue.toStringAsFixed(2)}'),
              _stat('Staff cost', '\$${summary.staffCost.toStringAsFixed(2)}'),
              _stat('Cleaning & utilities', '\$${summary.cleaningUtilitiesCost.toStringAsFixed(2)}'),
              _stat('Other costs', '\$${summary.otherCost.toStringAsFixed(2)}'),
            ]),
          ),
          const SizedBox(height: FarmSpacing.md),
          SectionCard(
            title: 'Package Profitability',
            child: report.packageProfitability.isEmpty
                ? Text('No completed visits in this scope yet.', style: FarmTypography.textTheme.bodySmall)
                : FarmDataTable(
                    columns: const ['Package', 'Revenue', 'Allocated cost', 'Profitability'],
                    rows: [
                      for (final p in report.packageProfitability)
                        [
                          Text(p.packageName, style: FarmTypography.textTheme.titleSmall),
                          Text('\$${p.revenue.toStringAsFixed(2)}'),
                          Text('\$${p.allocatedCost.toStringAsFixed(2)}'),
                          Text('\$${p.profitability.toStringAsFixed(2)}', style: TextStyle(color: p.profitability >= 0 ? FarmColors.success : FarmColors.danger, fontWeight: FontWeight.w700)),
                        ],
                    ],
                  ),
          ),
          const SizedBox(height: FarmSpacing.md),
          SectionCard(
            title: 'Activity Utilization',
            subtitle: 'Sold slots ÷ available slots',
            child: report.activityUtilization.isEmpty
                ? Text('No activities booked in this scope yet.', style: FarmTypography.textTheme.bodySmall)
                : FarmDataTable(
                    columns: const ['Activity', 'Sold', 'Available', 'Utilization'],
                    rows: [
                      for (final a in report.activityUtilization)
                        [
                          Text(a.activityName, style: FarmTypography.textTheme.titleSmall),
                          Text('${a.soldSlots}'),
                          Text('${a.availableSlots}'),
                          Text('${a.utilizationPct.toStringAsFixed(0)}%'),
                        ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _stat(String label, String value) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 10.5, color: FarmColors.muted)),
          Text(value, style: FarmTypography.textTheme.bodyMedium),
        ],
      );
}
