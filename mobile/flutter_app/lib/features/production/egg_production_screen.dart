import 'package:flutter/material.dart';
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
import '../../data/demo/demo_data.dart';
import '../../domain/entities/animal.dart';

class EggProductionScreen extends StatelessWidget {
  const EggProductionScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final layer = DemoData.layerFlock;
    final duck = DemoData.duckFlock;
    final turkey = DemoData.turkeyFlock;
    final eggsToday = layer.eggsToday + duck.eggsToday + turkey.eggsToday;

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
              KpiCard(icon: FarmIcon.egg, label: context.t('eggsToday'), value: '$eggsToday', trendLabel: '+8.6%', trendUp: true),
              KpiCard(icon: FarmIcon.egg, label: context.t('sellableEggs'), value: '${(eggsToday * 0.897).round()}', caption: '89.7% ${context.t('ofTotal')}'),
              KpiCard(icon: FarmIcon.warning, label: context.t('brokenEggs'), value: '${(eggsToday * 0.044).round()}', caption: '4.4% ${context.t('ofTotal')}', tint: FarmColors.warning),
              KpiCard(icon: FarmIcon.heart, label: context.t('flocksActive'), value: '3', caption: 'All healthy', tint: FarmColors.success),
              KpiCard(icon: FarmIcon.chartLine, label: context.t('productionVsLastWeek'), value: '+6.2%', trendLabel: '+341 eggs', trendUp: true),
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
                _FlockCard(name: context.t('layerFlock'), flock: layer, icon: FarmIcon.poultry),
                _FlockCard(name: context.t('duckFlock'), flock: duck, icon: FarmIcon.duck),
                _FlockCard(name: context.t('turkeyFlock'), flock: turkey, icon: FarmIcon.poultry),
              ];
              final insight = _KeyInsightCard(flock: duck);
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
                values: DemoData.eggProductionTrendThisWeek,
                secondaryValues: DemoData.eggProductionTrendLastWeek,
                labels: const ['May 6', 'May 12'],
                height: 210,
                color: FarmColors.olive,
              ),
            );
            final conversion = SectionCard(
              title: context.t('feedConversion'),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('2.35 kg', style: FarmTypography.textTheme.headlineMedium),
                  Text('Feed per dozen eggs', style: FarmTypography.textTheme.bodySmall),
                  const SizedBox(height: 10),
                  Text('${context.t('vsLastWeek')}: 2.48 kg', style: FarmTypography.textTheme.bodySmall),
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(color: FarmColors.tint(FarmColors.success, 0.14), borderRadius: BorderRadius.circular(FarmRadii.sm)),
                    child: const Text('Great job! Your feed efficiency is improving.', style: TextStyle(fontSize: 12, color: FarmColors.cedar2, fontWeight: FontWeight.w600)),
                  ),
                ],
              ),
            );
            final allocation = SectionCard(
              title: context.t('inventoryAllocation'),
              subtitle: context.t('today'),
              child: Column(
                children: [
                  _AllocationRow(label: 'Sold', value: 3412, pct: 58.4, icon: FarmIcon.tractor),
                  _AllocationRow(label: 'Kept (Farm Use)', value: 1102, pct: 18.9, icon: FarmIcon.inventory),
                  _AllocationRow(label: 'Consumed (Workers)', value: 428, pct: 7.3, icon: FarmIcon.egg),
                  _AllocationRow(label: 'Hatched', value: 650, pct: 11.1, icon: FarmIcon.egg),
                  _AllocationRow(label: 'Wasted', value: 250, pct: 4.3, icon: FarmIcon.warning),
                  const Divider(height: 18, color: FarmColors.border),
                  Row(children: [
                    Expanded(child: Text(context.t('total'), style: FarmTypography.textTheme.titleSmall)),
                    Text('$eggsToday', style: FarmTypography.textTheme.titleSmall),
                  ]),
                ],
              ),
            );
            if (!wide) return Column(children: [trend, const SizedBox(height: FarmSpacing.md), conversion, const SizedBox(height: FarmSpacing.md), allocation]);
            return IntrinsicHeight(
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(flex: 4, child: trend),
                const SizedBox(width: FarmSpacing.md),
                Expanded(flex: 3, child: conversion),
                const SizedBox(width: FarmSpacing.md),
                Expanded(flex: 3, child: allocation),
              ]),
            );
          }),
        ],
      ),
    );
  }
}

class _FlockCard extends StatelessWidget {
  const _FlockCard({required this.name, required this.flock, required this.icon});
  final String name;
  final Flock flock;
  final FarmIcon icon;

  @override
  Widget build(BuildContext context) {
    final level = switch (flock.status) {
      AnimalHealthStatus.healthy => FarmStatusLevel.good,
      AnimalHealthStatus.underObservation => FarmStatusLevel.watch,
      AnimalHealthStatus.underTreatment => FarmStatusLevel.alert,
    };
    final trendUp = flock.vsLastWeekPct >= 0;
    return Container(
      padding: const EdgeInsets.all(FarmSpacing.md),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(FarmRadii.md), border: Border.all(color: FarmColors.border)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            SizedBox(width: 44, height: 44, child: PhotoSlot(icon: icon)),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name, style: FarmTypography.textTheme.titleSmall),
                  StatusPill(
                    label: level == FarmStatusLevel.good ? 'Healthy' : (level == FarmStatusLevel.watch ? 'Watch' : 'Alert'),
                    level: level,
                    dense: true,
                  ),
                ],
              ),
            ),
          ]),
          const SizedBox(height: 10),
          Text('${flock.count}', style: FarmTypography.textTheme.titleLarge),
          Text(context.t('birds'), style: FarmTypography.textTheme.bodySmall),
          const SizedBox(height: 8),
          Text('${flock.eggsToday}', style: FarmTypography.textTheme.headlineMedium),
          Text(context.t('eggsToday'), style: FarmTypography.textTheme.bodySmall),
          const SizedBox(height: 4),
          Row(children: [
            Icon(trendUp ? Icons.trending_up : Icons.trending_down, size: 14, color: trendUp ? FarmColors.success : FarmColors.danger),
            const SizedBox(width: 2),
            Text(
              '${trendUp ? '+' : ''}${flock.vsLastWeekPct.toStringAsFixed(1)}% ${context.t('vsLastWeek')}',
              style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: trendUp ? FarmColors.success : FarmColors.danger),
            ),
          ]),
        ],
      ),
    );
  }
}

class _KeyInsightCard extends StatelessWidget {
  const _KeyInsightCard({required this.flock});
  final Flock flock;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(FarmSpacing.md),
      decoration: BoxDecoration(
        color: FarmColors.tint(FarmColors.gold, 0.2),
        borderRadius: BorderRadius.circular(FarmRadii.md),
        border: Border.all(color: FarmColors.gold.withOpacity(0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.trending_up, size: 16, color: FarmColors.clay),
            const SizedBox(width: 6),
            Text(context.t('keyInsight'), style: FarmTypography.textTheme.labelMedium?.copyWith(color: FarmColors.clay)),
          ]),
          const SizedBox(height: 8),
          Text('Duck flock down', style: FarmTypography.textTheme.bodyMedium),
          Text('${flock.vsLastWeekPct.abs().toStringAsFixed(0)}%', style: FarmTypography.display(size: 34, color: FarmColors.clay)),
          Text('${context.t('vsLastWeek')}', style: FarmTypography.textTheme.bodySmall),
          const SizedBox(height: 8),
          Text('Investigate feed intake and water temperature.', style: FarmTypography.textTheme.bodySmall),
          const SizedBox(height: 10),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: FarmColors.cedar),
            onPressed: () {},
            child: Text(context.t('viewRecommendations')),
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
