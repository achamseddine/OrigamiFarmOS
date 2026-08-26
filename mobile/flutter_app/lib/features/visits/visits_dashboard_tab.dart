import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/widgets/app_icon.dart';
import '../../core/widgets/kpi_card.dart';
import '../../core/widgets/section_card.dart';
import '../../core/widgets/status_pill.dart';
import '../../providers/visits_provider.dart';

/// Visitor Module Dashboard (tech spec v0.6 §6, screen 1) — sessions
/// coming up, bookings by status, lifetime visitor revenue and margin, and
/// what needs attention today.
class VisitsDashboardTab extends StatelessWidget {
  const VisitsDashboardTab({super.key, this.onNavigate});
  final ValueChanged<int>? onNavigate;

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<VisitsProvider>();
    final upcoming = provider.upcomingSessions;
    final report = provider.profitabilityFor();

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LayoutBuilder(builder: (context, c) {
            final perRow = c.maxWidth > 900 ? 4 : 2;
            final w = (c.maxWidth - FarmSpacing.md * (perRow - 1)) / perRow;
            final cards = [
              KpiCard(icon: FarmIcon.calendar, label: 'Upcoming Sessions', value: '${upcoming.length}', onTap: () => onNavigate?.call(5)),
              KpiCard(icon: FarmIcon.task, label: 'Draft Bookings', value: '${provider.draftBookingCount}', onTap: () => onNavigate?.call(4)),
              KpiCard(icon: FarmIcon.check, label: 'Confirmed', value: '${provider.confirmedBookingCount}', tint: FarmColors.success),
              KpiCard(icon: FarmIcon.eye, label: 'Checked In', value: '${provider.checkedInBookingCount}', onTap: () => onNavigate?.call(6)),
              KpiCard(icon: FarmIcon.money, label: 'Visitor Revenue', value: '\$${report.summary.visitorRevenue.toStringAsFixed(0)}', tint: FarmColors.success, onTap: () => onNavigate?.call(9)),
              KpiCard(icon: FarmIcon.report, label: 'Gross Margin', value: '\$${report.summary.grossMargin.toStringAsFixed(0)}', tint: report.summary.grossMargin >= 0 ? FarmColors.success : FarmColors.danger),
            ];
            return Wrap(spacing: FarmSpacing.md, runSpacing: FarmSpacing.md, children: [for (final c2 in cards) SizedBox(width: w, child: c2)]);
          }),
          const SizedBox(height: FarmSpacing.md),
          LayoutBuilder(builder: (context, c) {
            final wide = c.maxWidth > kTabletBreakpoint;
            final sessionsCard = SectionCard(
              title: 'Upcoming Sessions',
              subtitle: 'Configured opening days only — see Opening Calendar',
              child: upcoming.isEmpty
                  ? Text('No open sessions scheduled yet.', style: FarmTypography.textTheme.bodySmall)
                  : Column(children: [for (final s in upcoming.take(5)) _SessionRow(sessionId: s.id)]),
            );
            final attentionCard = SectionCard(
              title: 'Needs Attention',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (provider.draftBookingCount == 0 && provider.incidents.isEmpty)
                    Text('Nothing needs attention right now.', style: FarmTypography.textTheme.bodySmall)
                  else ...[
                    if (provider.draftBookingCount > 0)
                      _AttentionRow(text: '${provider.draftBookingCount} draft booking(s) awaiting confirmation.', level: FarmStatusLevel.watch),
                    if (provider.incidents.isNotEmpty)
                      _AttentionRow(text: '${provider.incidents.length} incident(s) logged this season.', level: FarmStatusLevel.alert),
                  ],
                ],
              ),
            );
            if (!wide) return Column(children: [sessionsCard, const SizedBox(height: FarmSpacing.md), attentionCard]);
            return IntrinsicHeight(
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(child: sessionsCard),
                const SizedBox(width: FarmSpacing.md),
                Expanded(child: attentionCard),
              ]),
            );
          }),
        ],
      ),
    );
  }
}

class _SessionRow extends StatelessWidget {
  const _SessionRow({required this.sessionId});
  final String sessionId;

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<VisitsProvider>();
    final session = provider.sessionById(sessionId);
    if (session == null) return const SizedBox.shrink();
    final guests = provider.bookingsForSession(sessionId).where((b) => b.status == 'confirmed' || b.status == 'checked_in' || b.status == 'completed').fold<int>(0, (sum, b) => sum + b.guestCount);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${session.date.day}/${session.date.month}/${session.date.year} · ${session.startTime}–${session.endTime}', style: FarmTypography.textTheme.titleSmall),
                Text('$guests of ${session.capacity} guests confirmed', style: FarmTypography.textTheme.bodySmall),
              ],
            ),
          ),
          StatusPill(label: session.status, level: session.status == 'open' ? FarmStatusLevel.good : FarmStatusLevel.neutral, dense: true),
        ],
      ),
    );
  }
}

class _AttentionRow extends StatelessWidget {
  const _AttentionRow({required this.text, required this.level});
  final String text;
  final FarmStatusLevel level;

  @override
  Widget build(BuildContext context) {
    final color = level == FarmStatusLevel.alert ? FarmColors.danger : FarmColors.statusWatch;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        Icon(level == FarmStatusLevel.alert ? Icons.error : Icons.remove_red_eye_outlined, size: 16, color: color),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: FarmTypography.textTheme.bodySmall)),
      ]),
    );
  }
}
