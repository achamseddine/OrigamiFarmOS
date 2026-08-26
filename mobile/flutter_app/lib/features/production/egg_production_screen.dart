import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/widgets/app_icon.dart';
import '../../core/widgets/charts/line_trend_chart.dart';
import '../../core/widgets/kpi_card.dart';
import '../../core/widgets/photo_slot.dart';
import '../../core/widgets/section_card.dart';
import '../../core/widgets/status_pill.dart';
import '../../domain/entities/animal.dart';
import '../../providers/animals_provider.dart';
import '../../providers/production_provider.dart';

bool _isToday(DateTime d) {
  final now = DateTime.now();
  return d.year == now.year && d.month == now.month && d.day == now.day;
}

/// A poultry species group backing one "Flock Overview" card. There is no
/// backend model wiring individual birds (tracked as [Animal] digital
/// twins) to the `flocks`/`egg_records` tables the API keeps for egg
/// counts — the two are separate concepts server-side with no shared id
/// exposed to the client — so this only carries what's actually
/// computable client-side: how many birds of this species are on record
/// and their aggregate health, not an egg count.
class _PoultryGroup {
  const _PoultryGroup({required this.label, required this.icon, required this.count, required this.status});
  final String label;
  final FarmIcon icon;
  final int count;
  final AnimalHealthStatus status;
}

_PoultryGroup _groupFor(List<Animal> animals, AnimalSpecies species, String label, FarmIcon icon) {
  final group = animals.where((a) => a.species == species).toList();
  final status = group.isEmpty
      ? AnimalHealthStatus.healthy
      : group.any((a) => a.status == AnimalHealthStatus.underTreatment)
          ? AnimalHealthStatus.underTreatment
          : group.any((a) => a.status == AnimalHealthStatus.underObservation)
              ? AnimalHealthStatus.underObservation
              : AnimalHealthStatus.healthy;
  return _PoultryGroup(label: label, icon: icon, count: group.length, status: status);
}

class EggProductionScreen extends StatelessWidget {
  const EggProductionScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final production = context.watch<ProductionProvider>();
    final animals = context.watch<AnimalsProvider>().animals;
    final eggRecords = production.eggRecords;

    final eggsToday = production.eggsToday;
    final todaysRecords = eggRecords.where((r) => _isToday(r.recordedAt)).toList();
    final sellableToday = todaysRecords.fold<int>(0, (s, r) => s + r.sellableEggs);
    final brokenToday = todaysRecords.fold<int>(0, (s, r) => s + r.brokenEggs);
    final sellablePct = eggsToday > 0 ? sellableToday / eggsToday * 100 : 0.0;
    final brokenPct = eggsToday > 0 ? brokenToday / eggsToday * 100 : 0.0;
    final activeFlocks = eggRecords.map((r) => r.flockId).toSet().length;

    final eggs14 = production.eggsByDay(days: 14);
    final thisWeek = eggs14.sublist(7);
    final lastWeek = eggs14.sublist(0, 7);
    final thisWeekTotal = thisWeek.fold<double>(0, (a, b) => a + b);
    final lastWeekTotal = lastWeek.fold<double>(0, (a, b) => a + b);
    final hasTrendData = thisWeekTotal > 0 || lastWeekTotal > 0;
    final pctChange = lastWeekTotal > 0
        ? (thisWeekTotal - lastWeekTotal) / lastWeekTotal * 100
        : (thisWeekTotal > 0 ? 100.0 : 0.0);
    final eggDiff = thisWeekTotal - lastWeekTotal;

    final layerGroup = _groupFor(animals, AnimalSpecies.layerHen, context.t('layerFlock'), FarmIcon.poultry);
    final duckGroup = _groupFor(animals, AnimalSpecies.duck, context.t('duckFlock'), FarmIcon.duck);
    final turkeyGroup = _groupFor(animals, AnimalSpecies.turkey, context.t('turkeyFlock'), FarmIcon.poultry);

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(context.t('eggProductionTitle'), style: FarmTypography.display(size: 28)),
          const SizedBox(height: 2),
          Text(context.t('eggProductionSubtitle'), style: FarmTypography.textTheme.bodyMedium),
          const SizedBox(height: FarmSpacing.md),
          LayoutBuilder(builder: (context, c) {
            final perRow = c.maxWidth > 1100 ? 5 : (c.maxWidth > 700 ? 3 : 2);
            final w = (c.maxWidth - FarmSpacing.md * (perRow - 1)) / perRow;
            final cards = [
              KpiCard(icon: FarmIcon.egg, label: context.t('eggsToday'), value: '$eggsToday'),
              KpiCard(icon: FarmIcon.egg, label: context.t('sellableEggs'), value: '$sellableToday', caption: '${sellablePct.toStringAsFixed(1)}% ${context.t('ofTotal')}'),
              KpiCard(icon: FarmIcon.warning, label: context.t('brokenEggs'), value: '$brokenToday', caption: '${brokenPct.toStringAsFixed(1)}% ${context.t('ofTotal')}', tint: brokenToday > 0 ? FarmColors.warning : null),
              KpiCard(icon: FarmIcon.heart, label: context.t('flocksActive'), value: '$activeFlocks', caption: activeFlocks == 0 ? 'No flocks reporting yet' : null, tint: activeFlocks == 0 ? null : FarmColors.success),
              KpiCard(
                icon: FarmIcon.chartLine,
                label: context.t('productionVsLastWeek'),
                value: hasTrendData ? '${pctChange >= 0 ? '+' : ''}${pctChange.toStringAsFixed(1)}%' : '—',
                trendLabel: hasTrendData ? '${eggDiff >= 0 ? '+' : ''}${eggDiff.toStringAsFixed(0)} eggs' : null,
                trendUp: pctChange >= 0,
              ),
            ];
            return Wrap(spacing: FarmSpacing.md, runSpacing: FarmSpacing.md, children: [for (final c2 in cards) SizedBox(width: w, child: c2)]);
          }),
          const SizedBox(height: FarmSpacing.md),
          SectionCard(
            title: context.t('flockOverview'),
            subtitle: context.t('flockOverviewSubtitle'),
            child: LayoutBuilder(builder: (context, c) {
              final wide = c.maxWidth > kTabletBreakpoint;
              final cards = [
                _FlockCard(group: layerGroup),
                _FlockCard(group: duckGroup),
                _FlockCard(group: turkeyGroup),
              ];
              final insight = _WeeklyInsightCard(pctChange: pctChange, eggDiff: eggDiff, hasTrendData: hasTrendData);
              if (!wide) {
                return Column(children: [for (final c2 in cards) ...[c2, const SizedBox(height: FarmSpacing.md)], insight]);
              }
              return IntrinsicHeight(
                child: Row(children: [
                  for (final c2 in cards) ...[Expanded(child: c2), const SizedBox(width: FarmSpacing.md)],
                  Expanded(child: insight),
                ]),
              );
            }),
          ),
          const SizedBox(height: FarmSpacing.md),
          LayoutBuilder(builder: (context, c) {
            final wide = c.maxWidth > kTabletBreakpoint;
            final trend = SectionCard(
              title: context.t('productionTrend'),
              child: LineTrendChart(
                values: thisWeek,
                secondaryValues: lastWeek,
                labels: const ['7 days ago', 'Today'],
                height: 210,
                color: FarmColors.olive,
              ),
            );
            final allocation = SectionCard(
              title: context.t('inventoryAllocation'),
              subtitle: context.t('today'),
              child: eggsToday == 0
                  ? Text('No eggs recorded today.', style: FarmTypography.textTheme.bodySmall)
                  : Column(
                      children: [
                        _AllocationRow(label: context.t('sellableEggs'), value: sellableToday, pct: sellablePct, icon: FarmIcon.egg),
                        _AllocationRow(label: context.t('brokenEggs'), value: brokenToday, pct: brokenPct, icon: FarmIcon.warning),
                        const Divider(height: 18, color: FarmColors.border),
                        Row(children: [
                          Expanded(child: Text(context.t('total'), style: FarmTypography.textTheme.titleSmall)),
                          Text('$eggsToday', style: FarmTypography.textTheme.titleSmall),
                        ]),
                      ],
                    ),
            );
            if (!wide) return Column(children: [trend, const SizedBox(height: FarmSpacing.md), allocation]);
            return IntrinsicHeight(
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(flex: 6, child: trend),
                const SizedBox(width: FarmSpacing.md),
                Expanded(flex: 4, child: allocation),
              ]),
            );
          }),
        ],
      ),
    );
  }
}

class _FlockCard extends StatelessWidget {
  const _FlockCard({required this.group});
  final _PoultryGroup group;

  @override
  Widget build(BuildContext context) {
    final level = switch (group.status) {
      AnimalHealthStatus.healthy => FarmStatusLevel.good,
      AnimalHealthStatus.underObservation => FarmStatusLevel.watch,
      AnimalHealthStatus.underTreatment => FarmStatusLevel.alert,
    };
    final statusLabel = switch (group.status) {
      AnimalHealthStatus.healthy => 'Healthy',
      AnimalHealthStatus.underObservation => 'Watch',
      AnimalHealthStatus.underTreatment => 'Alert',
    };
    return Container(
      padding: const EdgeInsets.all(FarmSpacing.md),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(FarmRadii.md), border: Border.all(color: FarmColors.border)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            SizedBox(width: 44, height: 44, child: PhotoSlot(icon: group.icon)),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(group.label, style: FarmTypography.textTheme.titleSmall),
                  StatusPill(label: group.count == 0 ? 'No birds' : statusLabel, level: group.count == 0 ? FarmStatusLevel.neutral : level, dense: true),
                ],
              ),
            ),
          ]),
          const SizedBox(height: 10),
          Text('${group.count}', style: FarmTypography.textTheme.titleLarge),
          Text(context.t('birds'), style: FarmTypography.textTheme.bodySmall),
        ],
      ),
    );
  }
}

/// Farm-wide (not per-flock) week-over-week egg production comparison,
/// computed from [ProductionProvider.eggsByDay] — real numbers, unlike the
/// scripted "duck flock down 22%" narrative this replaces, which can't be
/// reproduced because egg records aren't attributable to a poultry species
/// client-side (see [_PoultryGroup]).
class _WeeklyInsightCard extends StatelessWidget {
  const _WeeklyInsightCard({required this.pctChange, required this.eggDiff, required this.hasTrendData});
  final double pctChange;
  final double eggDiff;
  final bool hasTrendData;

  @override
  Widget build(BuildContext context) {
    if (!hasTrendData) {
      return Container(
        padding: const EdgeInsets.all(FarmSpacing.md),
        decoration: BoxDecoration(
          color: FarmColors.tint(FarmColors.muted, 0.12),
          borderRadius: BorderRadius.circular(FarmRadii.md),
          border: Border.all(color: FarmColors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.info_outline, size: 16, color: FarmColors.muted),
              const SizedBox(width: 6),
              Text(context.t('keyInsight'), style: FarmTypography.textTheme.labelMedium),
            ]),
            const SizedBox(height: 8),
            Text('No egg production recorded yet.', style: FarmTypography.textTheme.bodySmall),
          ],
        ),
      );
    }
    final down = pctChange < 0;
    final accent = down ? FarmColors.clay : FarmColors.success;
    return Container(
      padding: const EdgeInsets.all(FarmSpacing.md),
      decoration: BoxDecoration(
        color: FarmColors.tint(down ? FarmColors.gold : FarmColors.success, 0.2),
        borderRadius: BorderRadius.circular(FarmRadii.md),
        border: Border.all(color: accent.withOpacity(0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(down ? Icons.trending_down : Icons.trending_up, size: 16, color: accent),
            const SizedBox(width: 6),
            Text(context.t('keyInsight'), style: FarmTypography.textTheme.labelMedium?.copyWith(color: accent)),
          ]),
          const SizedBox(height: 8),
          Text(down ? 'Egg production down' : 'Egg production up', style: FarmTypography.textTheme.bodyMedium),
          Text('${pctChange.abs().toStringAsFixed(0)}%', style: FarmTypography.display(size: 34, color: accent)),
          Text(context.t('vsLastWeek'), style: FarmTypography.textTheme.bodySmall),
          const SizedBox(height: 8),
          Text(
            down ? 'Review flock feed, water, and living conditions across all poultry.' : 'Great job! Keep up current feeding and care routines.',
            style: FarmTypography.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _AllocationRow extends StatelessWidget {
  const _AllocationRow({required this.label, required this.value, required this.pct, required this.icon});
  final String label;
  final int value;
  final double pct;
  final FarmIcon icon;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(children: [
        AppIcon(icon, size: 15, color: FarmColors.cedar),
        const SizedBox(width: 8),
        Expanded(child: Text(label, style: const TextStyle(fontSize: 12.5))),
        Text('$value', style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
        const SizedBox(width: 8),
        SizedBox(width: 42, child: Text('${pct.toStringAsFixed(1)}%', textAlign: TextAlign.right, style: const TextStyle(fontSize: 11, color: FarmColors.muted))),
      ]),
    );
  }
}
