import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
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
import '../../domain/entities/animal.dart';
import '../../domain/entities/production_records.dart';
import '../../providers/animals_provider.dart';
import '../../providers/production_provider.dart';

bool _isToday(DateTime d) {
  final now = DateTime.now();
  return d.year == now.year && d.month == now.month && d.day == now.day;
}

/// Sums [records] into one bucket per day for the last [days] days
/// (oldest first), keeping only records whose session matches [session].
/// Mirrors `ProductionProvider._sumByDay` but scoped to a single session
/// label, since the API doesn't split its own day-bucketed totals by
/// session.
List<double> _milkBySessionByDay(List<MilkRecord> records, String session, {int days = 7}) {
  final today = DateTime.now();
  final start = DateTime(today.year, today.month, today.day).subtract(Duration(days: days - 1));
  final buckets = List<double>.filled(days, 0);
  for (final r in records) {
    if (r.session != session) continue;
    final dayIndex = DateTime(r.recordedAt.year, r.recordedAt.month, r.recordedAt.day).difference(start).inDays;
    if (dayIndex >= 0 && dayIndex < days) buckets[dayIndex] += r.liters;
  }
  return buckets;
}

List<String> _last7DayLabels() => [for (var i = 6; i >= 0; i--) i == 0 ? 'Today' : (i == 1 ? 'Yesterday' : 'D-$i')];

class _Producer {
  const _Producer({required this.name, required this.breed, required this.liters});
  final String name;
  final String breed;
  final double liters;
}

List<_Producer> _topMilkProducers(List<MilkRecord> todaysRecords, AnimalsProvider animalsProvider, {int take = 5}) {
  if (animalsProvider.animals.isEmpty || todaysRecords.isEmpty) return [];
  final totals = <String, double>{};
  for (final r in todaysRecords) {
    totals[r.animalId] = (totals[r.animalId] ?? 0) + r.liters;
  }
  final entries = totals.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
  final result = <_Producer>[];
  for (final e in entries.take(take)) {
    final animal = animalsProvider.byId(e.key);
    result.add(_Producer(name: animal.name, breed: animal.breed, liters: e.value));
  }
  return result;
}

class MilkProductionScreen extends StatelessWidget {
  const MilkProductionScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final production = context.watch<ProductionProvider>();
    final animalsProvider = context.watch<AnimalsProvider>();
    final animals = animalsProvider.animals;
    final milkRecords = production.milkRecords;

    final morningByDay = _milkBySessionByDay(milkRecords, 'morning', days: 7);
    final eveningByDay = _milkBySessionByDay(milkRecords, 'evening', days: 7);
    final morningTotal = morningByDay.last;
    final eveningTotal = eveningByDay.last;
    final total = production.milkTodayL;
    final morningPct = total > 0 ? morningTotal / total * 100 : 0.0;
    final eveningPct = total > 0 ? eveningTotal / total * 100 : 0.0;

    final cowsLactating = animals.where((a) => a.species == AnimalSpecies.cow && a.lactating).length;
    final goatsLactating = animals.where((a) => a.species == AnimalSpecies.goat && a.lactating).length;
    final avgPerCow = cowsLactating > 0 ? total / cowsLactating : 0.0;

    final underWithdrawal = animals.where((a) => a.isUnderWithdrawal).toList();

    final todaysMilk = milkRecords.where((r) => _isToday(r.recordedAt)).toList();
    final producers = _topMilkProducers(todaysMilk, animalsProvider);

    double destTotal(String dest) => todaysMilk.where((r) => r.destination == dest).fold(0.0, (s, r) => s + r.liters);
    final storedL = destTotal('stored');
    final soldL = destTotal('sold');
    final processedL = destTotal('processed');
    final consumedL = destTotal('consumed');
    final destSum = storedL + soldL + processedL + consumedL;
    double destPct(double v) => destSum > 0 ? v / destSum * 100 : 0.0;

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
              KpiCard(icon: FarmIcon.milkBottle, label: context.t('milkToday'), value: total.toStringAsFixed(0), unit: context.t('liters')),
              KpiCard(icon: FarmIcon.sun, label: context.t('morningSession'), value: morningTotal.toStringAsFixed(0), unit: context.t('liters'), caption: '${morningPct.toStringAsFixed(0)}% of total'),
              KpiCard(icon: FarmIcon.leaf, label: context.t('eveningSession'), value: eveningTotal.toStringAsFixed(0), unit: context.t('liters'), caption: '${eveningPct.toStringAsFixed(0)}% of total'),
              KpiCard(icon: FarmIcon.cow, label: context.t('averagePerCow'), value: avgPerCow.toStringAsFixed(1), unit: context.t('liters'), caption: '$cowsLactating cows milked'),
              KpiCard(icon: FarmIcon.warning, label: context.t('underWithdrawal'), value: '${underWithdrawal.length}', caption: context.t('milkNotForSale'), tint: underWithdrawal.isEmpty ? null : FarmColors.warning),
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
                      label: _last7DayLabels()[i],
                      segments: [morningByDay[i], eveningByDay[i]],
                    ),
                ],
                overlayLine: [for (var i = 0; i < 7; i++) morningByDay[i] + eveningByDay[i]],
                height: 230,
              ),
            );
            final producersCard = SectionCard(
              title: context.t('topMilkProducersToday'),
              trailing: context.t('viewAll'),
              child: Column(
                children: [
                  if (producers.isEmpty)
                    Text('No milk recorded today yet.', style: FarmTypography.textTheme.bodySmall)
                  else
                    for (var i = 0; i < producers.length; i++) ...[
                      _ProducerRow(rank: i + 1, producer: producers[i]),
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
              return Column(children: [chart, const SizedBox(height: FarmSpacing.md), producersCard, const SizedBox(height: FarmSpacing.md), withdrawal]);
            }
            return IntrinsicHeight(
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(flex: 5, child: chart),
                const SizedBox(width: FarmSpacing.md),
                Expanded(flex: 3, child: producersCard),
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
                Expanded(child: _SessionTile(icon: FarmIcon.sun, label: context.t('morningSession'), value: morningTotal, sub: '$cowsLactating cows • $goatsLactating goats')),
                const SizedBox(width: 10),
                Expanded(child: _SessionTile(icon: FarmIcon.sun, label: context.t('eveningSession'), value: eveningTotal, sub: '$cowsLactating cows • $goatsLactating goats')),
              ]),
            );
            final destination = SectionCard(
              title: context.t('milkDestinationToday'),
              trailing: context.t('viewDestinationDetails'),
              child: destSum == 0
                  ? Text('No milk recorded today yet.', style: FarmTypography.textTheme.bodySmall)
                  : Row(children: [
                      Expanded(child: _DestinationTile(icon: FarmIcon.milkBottle, label: context.t('stored'), value: '${storedL.toStringAsFixed(0)} L', pct: '${destPct(storedL).toStringAsFixed(0)}%')),
                      Expanded(child: _DestinationTile(icon: FarmIcon.tractor, label: context.t('sold'), value: '${soldL.toStringAsFixed(0)} L', pct: '${destPct(soldL).toStringAsFixed(0)}%')),
                      Expanded(child: _DestinationTile(icon: FarmIcon.inventory, label: context.t('processed'), value: '${processedL.toStringAsFixed(0)} L', pct: '${destPct(processedL).toStringAsFixed(0)}%')),
                      Expanded(child: _DestinationTile(icon: FarmIcon.leaf, label: context.t('consumed'), value: '${consumedL.toStringAsFixed(0)} L', pct: '${destPct(consumedL).toStringAsFixed(0)}%')),
                    ]),
            );
            if (!wide) {
              return Column(children: [sessions, const SizedBox(height: FarmSpacing.md), destination]);
            }
            return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: sessions),
              const SizedBox(width: FarmSpacing.md),
              Expanded(child: destination),
            ]);
          }),
        ],
      ),
    );
  }
}

class _ProducerRow extends StatelessWidget {
  const _ProducerRow({required this.rank, required this.producer});
  final int rank;
  final _Producer producer;

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      SizedBox(width: 22, child: Text('$rank', style: FarmTypography.textTheme.titleSmall)),
      const SizedBox(width: 6),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(producer.name, style: FarmTypography.textTheme.titleSmall),
            Text(producer.breed, style: FarmTypography.textTheme.bodySmall),
          ],
        ),
      ),
      Text('${producer.liters.toStringAsFixed(1)} ${context.t('liters')}', style: FarmTypography.textTheme.titleSmall),
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
          StatusPill(
            label: value > 0 ? context.t('completed') : 'No entries yet',
            level: value > 0 ? FarmStatusLevel.good : FarmStatusLevel.neutral,
            dense: true,
          ),
        ],
      ),
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
