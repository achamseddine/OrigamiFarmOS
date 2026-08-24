import 'package:flutter/material.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/widgets/app_icon.dart';
import '../../core/widgets/charts/bar_trend_chart.dart';
import '../../core/widgets/kpi_card.dart';
import '../../core/widgets/photo_slot.dart';
import '../../core/widgets/section_card.dart';
import '../../core/widgets/status_pill.dart';
import '../../data/demo/demo_data.dart';

class MilkProductionScreen extends StatelessWidget {
  const MilkProductionScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final morningTotal = DemoData.milkLast7DaysMorning.last;
    final eveningTotal = DemoData.milkLast7DaysEvening.last;
    final total = morningTotal + eveningTotal;
    final underWithdrawal = DemoData.animals.where((a) => a.isUnderWithdrawal).toList();

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(context.t('milkProductionTitle'), style: FarmTypography.display(size: 28)),
          const SizedBox(height: 2),
          Text(context.t('milkProductionSubtitle'), style: FarmTypography.textTheme.bodyMedium),
          const SizedBox(height: FarmSpacing.md),
          LayoutBuilder(builder: (context, c) {
            final perRow = c.maxWidth > 1100 ? 5 : (c.maxWidth > 700 ? 3 : 2);
            final w = (c.maxWidth - FarmSpacing.md * (perRow - 1)) / perRow;
            final cards = [
              KpiCard(icon: FarmIcon.milkBottle, label: context.t('milkToday'), value: total.toStringAsFixed(0), unit: context.t('liters'), trendLabel: '+8%', trendUp: true),
              KpiCard(icon: FarmIcon.sun, label: context.t('morningSession'), value: morningTotal.toStringAsFixed(0), unit: context.t('liters'), caption: '53% of total'),
              KpiCard(icon: FarmIcon.leaf, label: context.t('eveningSession'), value: eveningTotal.toStringAsFixed(0), unit: context.t('liters'), caption: '47% of total'),
              KpiCard(icon: FarmIcon.cow, label: context.t('averagePerCow'), value: (total / 32).toStringAsFixed(1), unit: context.t('liters'), caption: '32 cows milked'),
              KpiCard(icon: FarmIcon.warning, label: context.t('underWithdrawal'), value: '${underWithdrawal.length}', caption: context.t('milkNotForSale'), tint: FarmColors.warning),
            ];
            return Wrap(spacing: FarmSpacing.md, runSpacing: FarmSpacing.md, children: [for (final c2 in cards) SizedBox(width: w, child: c2)]);
          }),
          const SizedBox(height: FarmSpacing.md),
          LayoutBuilder(builder: (context, c) {
            final wide = c.maxWidth > kTabletBreakpoint;
            final chart = SectionCard(
              title: context.t('milkProductionLast7Days'),
              child: BarTrendChart(
                bars: [
                  for (var i = 0; i < 7; i++)
                    BarGroup(
                      label: DemoData.milkLast7DaysLabels[i],
                      segments: [DemoData.milkLast7DaysMorning[i], DemoData.milkLast7DaysEvening[i]],
                    ),
                ],
                overlayLine: [for (var i = 0; i < 7; i++) DemoData.milkLast7DaysMorning[i] + DemoData.milkLast7DaysEvening[i]],
                height: 230,
              ),
            );
            final producers = SectionCard(
              title: context.t('topMilkProducersToday'),
              trailing: context.t('viewAll'),
              child: Column(
                children: [
                  for (var i = 0; i < DemoData.topMilkProducers.length; i++) ...[
                    _ProducerRow(rank: i + 1, data: DemoData.topMilkProducers[i]),
                    const Divider(height: 16, color: FarmColors.border),
                  ],
                  Align(alignment: Alignment.centerLeft, child: TextButton(onPressed: () {}, child: Text(context.t('seeAllAnimals')))),
                ],
              ),
            );
            final withdrawal = SectionCard(
              child: underWithdrawal.isEmpty
                  ? Text('No animals are currently under withdrawal.', style: FarmTypography.textTheme.bodySmall)
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          const Icon(Icons.warning_amber_rounded, color: FarmColors.danger, size: 20),
                          const SizedBox(width: 8),
                          Text(context.t('underWithdrawalWarning'), style: FarmTypography.textTheme.titleSmall?.copyWith(color: FarmColors.danger)),
                        ]),
                        const SizedBox(height: 6),
                        Text(context.t('cannotBeSoldToday'), style: FarmTypography.textTheme.bodySmall),
                        const SizedBox(height: 10),
                        for (final a in underWithdrawal)
                          Row(children: [
                            SizedBox(width: 40, height: 40, child: PhotoSlot(icon: FarmIcon.goat, filePath: a.photoPath)),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(a.name, style: FarmTypography.textTheme.titleSmall),
                                  Text('${context.t('reason')}: ${a.withdrawalReason ?? '—'}', style: FarmTypography.textTheme.bodySmall),
                                ],
                              ),
                            ),
                          ]),
                        const SizedBox(height: 10),
                        OutlinedButton(onPressed: () {}, child: Text(context.t('viewAnimalRecord'))),
                      ],
                    ),
            );
            if (!wide) {
              return Column(children: [chart, const SizedBox(height: FarmSpacing.md), producers, const SizedBox(height: FarmSpacing.md), withdrawal]);
            }
            return IntrinsicHeight(
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(flex: 5, child: chart),
                const SizedBox(width: FarmSpacing.md),
                Expanded(flex: 3, child: producers),
                const SizedBox(width: FarmSpacing.md),
                Expanded(flex: 3, child: withdrawal),
              ]),
            );
          }),
          const SizedBox(height: FarmSpacing.md),
          LayoutBuilder(builder: (context, c) {
            final wide = c.maxWidth > kTabletBreakpoint;
            final sessions = SectionCard(
              title: context.t('sessionOverview'),
              child: Row(children: [
                Expanded(child: _SessionTile(icon: FarmIcon.sun, label: context.t('morningSession'), value: morningTotal, sub: '32 cows • 12 goats')),
                const SizedBox(width: 10),
                Expanded(child: _SessionTile(icon: FarmIcon.sun, label: context.t('eveningSession'), value: eveningTotal, sub: '32 cows • 12 goats')),
              ]),
            );
            final quality = SectionCard(
              title: context.t('milkQuality'),
              trailing: context.t('viewQualityDetails'),
              child: const Row(children: [
                Expanded(child: _QualityMetric(label: 'Fat', value: '3.8%', status: 'Excellent')),
                Expanded(child: _QualityMetric(label: 'Protein', value: '3.2%', status: 'Good')),
                Expanded(child: _QualityMetric(label: 'SCC', value: '142', status: 'Excellent')),
              ]),
            );
            final destination = SectionCard(
              title: context.t('milkDestinationToday'),
              trailing: context.t('viewDestinationDetails'),
              child: Row(children: [
                Expanded(child: _DestinationTile(icon: FarmIcon.milkBottle, label: context.t('stored'), value: '210 L', pct: '35%')),
                Expanded(child: _DestinationTile(icon: FarmIcon.tractor, label: context.t('sold'), value: '250 L', pct: '42%')),
                Expanded(child: _DestinationTile(icon: FarmIcon.inventory, label: context.t('processed'), value: '100 L', pct: '17%')),
                Expanded(child: _DestinationTile(icon: FarmIcon.leaf, label: context.t('consumed'), value: '32 L', pct: '6%')),
              ]),
            );
            if (!wide) {
              return Column(children: [sessions, const SizedBox(height: FarmSpacing.md), quality, const SizedBox(height: FarmSpacing.md), destination]);
            }
            return Column(children: [
              Row(children: [Expanded(child: sessions), const SizedBox(width: FarmSpacing.md), Expanded(child: quality)]),
              const SizedBox(height: FarmSpacing.md),
              destination,
            ]);
          }),
        ],
      ),
    );
  }
}

class _ProducerRow extends StatelessWidget {
  const _ProducerRow({required this.rank, required this.data});
  final int rank;
  final Map<String, Object> data;

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      SizedBox(width: 22, child: Text('$rank', style: FarmTypography.textTheme.titleSmall)),
      const SizedBox(width: 6),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(data['name'] as String, style: FarmTypography.textTheme.titleSmall),
            Text(data['breed'] as String, style: FarmTypography.textTheme.bodySmall),
          ],
        ),
      ),
      Text('${data['liters']} ${context.t('liters')}', style: FarmTypography.textTheme.titleSmall),
    ]);
  }
}

class _SessionTile extends StatelessWidget {
  const _SessionTile({required this.icon, required this.label, required this.value, required this.sub});
  final FarmIcon icon;
  final String label;
  final double value;
  final String sub;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(FarmRadii.sm), border: Border.all(color: FarmColors.border)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [AppIcon(icon, size: 16), const SizedBox(width: 6), Text(label, style: FarmTypography.textTheme.bodySmall)]),
          const SizedBox(height: 6),
          Text('${value.toStringAsFixed(0)} ${context.t('liters')}', style: FarmTypography.textTheme.headlineMedium),
          Text(sub, style: const TextStyle(fontSize: 11, color: FarmColors.muted)),
          const SizedBox(height: 8),
          StatusPill(label: context.t('completed'), level: FarmStatusLevel.good, dense: true),
        ],
      ),
    );
  }
}

class _QualityMetric extends StatelessWidget {
  const _QualityMetric({required this.label, required this.value, required this.status});
  final String label;
  final String value;
  final String status;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: FarmTypography.textTheme.bodySmall),
        Text(value, style: FarmTypography.textTheme.headlineMedium),
        Text(status, style: const TextStyle(fontSize: 11, color: FarmColors.success, fontWeight: FontWeight.w700)),
      ],
    );
  }
}

class _DestinationTile extends StatelessWidget {
  const _DestinationTile({required this.icon, required this.label, required this.value, required this.pct});
  final FarmIcon icon;
  final String label;
  final String value;
  final String pct;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppIcon(icon, size: 18, color: FarmColors.cedar),
        const SizedBox(height: 6),
        Text(value, style: FarmTypography.textTheme.titleLarge),
        Text(label, style: FarmTypography.textTheme.bodySmall),
        Text(pct, style: const TextStyle(fontSize: 11, color: FarmColors.muted)),
      ],
    );
  }
}
