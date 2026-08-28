import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/widgets/alert_card.dart';
import '../../core/widgets/app_icon.dart';
import '../../core/widgets/charts/line_trend_chart.dart';
import '../../core/widgets/kpi_card.dart';
import '../../core/widgets/section_card.dart';
import '../../core/widgets/status_pill.dart';
import '../../data/demo/demo_data.dart';
import '../../domain/entities/recommendation.dart';
import '../../domain/entities/task.dart';
import '../../providers/recommendations_provider.dart';
import '../../providers/tasks_provider.dart';

/// Screen 2 — Morning Briefing Dashboard. The default route after login
/// (tech spec §2 "Morning first: default route after login is Morning
/// Briefing").
class MorningBriefingScreen extends StatelessWidget {
  const MorningBriefingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final recommendations = context.watch<RecommendationsProvider>().recommendations;
    final openAlerts = recommendations
        .where((r) => r.priority == RecommendationPriority.high || r.priority == RecommendationPriority.medium)
        .length;

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const AppIcon(FarmIcon.sun, size: 24, color: FarmColors.gold),
              const SizedBox(width: 8),
              Text('${context.t('goodMorning')}, ${DemoData.managerName}', style: FarmTypography.display(size: 26)),
            ],
          ),
          const SizedBox(height: 2),
          Text(context.t('morningSubline'), style: FarmTypography.textTheme.bodyMedium),
          const SizedBox(height: FarmSpacing.lg),
          _KpiStrip(openAlerts: openAlerts),
          const SizedBox(height: FarmSpacing.lg),
          LayoutBuilder(builder: (context, constraints) {
            final wide = constraints.maxWidth > kTabletBreakpoint;
            final columns = <Widget>[
              _PrioritiesCard(),
              Column(children: const [_AnimalAlertsCard(), SizedBox(height: FarmSpacing.md), _FeedWarningsCard()]),
              Column(children: const [_MilkTodayCard(), SizedBox(height: FarmSpacing.md), _EggProductionCard()]),
              const _TasksCard(),
            ];
            if (!wide) {
              return Column(
                children: [for (final c in columns) ...[c, const SizedBox(height: FarmSpacing.md)]],
              );
            }
            return IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(flex: 5, child: columns[0]),
                  const SizedBox(width: FarmSpacing.md),
                  Expanded(flex: 4, child: columns[1]),
                  const SizedBox(width: FarmSpacing.md),
                  Expanded(flex: 4, child: columns[2]),
                  const SizedBox(width: FarmSpacing.md),
                  Expanded(flex: 4, child: columns[3]),
                ],
              ),
            );
          }),
          const SizedBox(height: FarmSpacing.md),
          LayoutBuilder(builder: (context, constraints) {
            final wide = constraints.maxWidth > kTabletBreakpoint;
            final weather = const _WeatherCard();
            final timeline = const _TimelineCard();
            if (!wide) {
              return Column(children: [weather, const SizedBox(height: FarmSpacing.md), timeline]);
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 4, child: weather),
                const SizedBox(width: FarmSpacing.md),
                Expanded(flex: 6, child: timeline),
              ],
            );
          }),
        ],
      ),
    );
  }
}

class _KpiStrip extends StatelessWidget {
  const _KpiStrip({required this.openAlerts});
  final int openAlerts;

  @override
  Widget build(BuildContext context) {
    final tasksDue = context.watch<TasksProvider>().openCount;
    return LayoutBuilder(builder: (context, constraints) {
      final perRow = constraints.maxWidth > 1100 ? 6 : (constraints.maxWidth > 720 ? 3 : 2);
      final cardWidth = (constraints.maxWidth - FarmSpacing.md * (perRow - 1)) / perRow;
      final cards = [
        KpiCard(icon: FarmIcon.cow, label: context.t('kpiAnimals'), value: '${DemoData.animalSummary['total']}'),
        KpiCard(icon: FarmIcon.milkBottle, label: context.t('kpiMilkToday'), value: '592', unit: context.t('liters'), trendLabel: '+8%', trendUp: true),
        KpiCard(icon: FarmIcon.egg, label: context.t('kpiEggsToday'), value: '5,842', trendLabel: '+12%', trendUp: true),
        KpiCard(icon: FarmIcon.leaf, label: context.t('kpiActiveCrops'), value: '6'),
        KpiCard(
          icon: FarmIcon.warning,
          label: context.t('kpiOpenAlerts'),
          value: '$openAlerts',
          tint: FarmColors.danger,
          caption: context.t('needsAttention'),
        ),
        KpiCard(icon: FarmIcon.task, label: context.t('kpiTasksDue'), value: '$tasksDue', caption: context.t('today')),
      ];
      return Wrap(
        spacing: FarmSpacing.md,
        runSpacing: FarmSpacing.md,
        children: [for (final c in cards) SizedBox(width: cardWidth, child: c)],
      );
    });
  }
}

class _PrioritiesCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final recommendations = context.watch<RecommendationsProvider>().recommendations;
    return SectionCard(
      title: context.t('todaysPriorities'),
      child: Column(
        children: [
          for (final rec in recommendations.take(4)) ...[
            AlertCard(
              icon: _iconFor(rec.category),
              title: rec.title,
              eyebrow: rec.entityLabel,
              evidence: [rec.rationale.split('.').first],
              level: _levelFor(rec.priority),
              onTap: () {},
            ),
            const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }

  FarmIcon _iconFor(RecommendationCategory c) => switch (c) {
        RecommendationCategory.health => FarmIcon.heart,
        RecommendationCategory.feed => FarmIcon.feedBag,
        RecommendationCategory.egg => FarmIcon.egg,
        RecommendationCategory.withdrawal => FarmIcon.warning,
        RecommendationCategory.harvest => FarmIcon.leaf,
        RecommendationCategory.finance => FarmIcon.money,
      };

  FarmStatusLevel _levelFor(RecommendationPriority p) => switch (p) {
        RecommendationPriority.high => FarmStatusLevel.alert,
        RecommendationPriority.medium => FarmStatusLevel.watch,
        RecommendationPriority.low || RecommendationPriority.info => FarmStatusLevel.good,
      };
}

class _AnimalAlertsCard extends StatelessWidget {
  const _AnimalAlertsCard();

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: context.t('animalAlerts'),
      trailing: context.t('viewAll'),
      child: Column(
        children: const [
          AlertCard(
            icon: FarmIcon.cow,
            title: 'Luna #214',
            level: FarmStatusLevel.watch,
            evidence: ['Low activity detected', 'Since 6:15 AM'],
            trailingLabel: 'Low',
          ),
          SizedBox(height: 8),
          AlertCard(
            icon: FarmIcon.cow,
            title: 'Rasha #189',
            level: FarmStatusLevel.alert,
            evidence: ['Health check overdue', 'Due since 2 days ago'],
            trailingLabel: 'Overdue',
          ),
        ],
      ),
    );
  }
}

class _FeedWarningsCard extends StatelessWidget {
  const _FeedWarningsCard();

  @override
  Widget build(BuildContext context) {
    final item = DemoData.feedInventory.first;
    return SectionCard(
      title: context.t('feedWarnings'),
      trailing: context.t('manageFeed'),
      child: AlertCard(
        icon: FarmIcon.feedBag,
        title: 'Low feed: ${item.name}',
        level: FarmStatusLevel.watch,
        evidence: ['${item.currentQty.toStringAsFixed(1)} kg remaining', 'Reorder recommended'],
      ),
    );
  }
}

class _MilkTodayCard extends StatelessWidget {
  const _MilkTodayCard();

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: context.t('milkToday'),
      trailing: context.t('viewMilkHistory'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          RichText(
            text: TextSpan(
              children: [
                TextSpan(text: '592 ', style: FarmTypography.textTheme.headlineMedium),
                TextSpan(text: context.t('liters'), style: FarmTypography.textTheme.bodyMedium),
              ],
            ),
          ),
          Text('+47 L ${context.t('vsYesterday')}', style: const TextStyle(color: FarmColors.success, fontSize: 12, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          LineTrendChart(
            values: List.generate(7, (i) => DemoData.milkLast7DaysMorning[i] + DemoData.milkLast7DaysEvening[i]),
            height: 70,
            showDots: false,
          ),
        ],
      ),
    );
  }
}

class _EggProductionCard extends StatelessWidget {
  const _EggProductionCard();

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: context.t('eggProduction'),
      trailing: context.t('viewEggHistory'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('312', style: FarmTypography.textTheme.headlineMedium),
          Text('+8% ${context.t('vsLastWeek')}', style: const TextStyle(color: FarmColors.success, fontSize: 12, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          const LineTrendChart(values: [260, 270, 265, 288, 275, 300, 312], height: 70, showDots: false, color: FarmColors.gold),
        ],
      ),
    );
  }
}

class _TasksCard extends StatelessWidget {
  const _TasksCard();

  @override
  Widget build(BuildContext context) {
    final tasks = context.watch<TasksProvider>().tasks;
    return SectionCard(
      title: context.t('todaysTasks'),
      trailing: context.t('viewAll'),
      child: Column(
        children: [
          for (final task in tasks) ...[
            _TaskRow(task: task),
            const SizedBox(height: 4),
          ],
        ],
      ),
    );
  }
}

class _TaskRow extends StatelessWidget {
  const _TaskRow({required this.task});
  final FarmTask task;

  @override
  Widget build(BuildContext context) {
    final done = task.status == TaskStatus.done;
    return InkWell(
      onTap: () => context.read<TasksProvider>().toggle(task.id),
      borderRadius: BorderRadius.circular(FarmRadii.xs),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              done ? Icons.check_circle : Icons.radio_button_unchecked,
              size: 20,
              color: done ? FarmColors.success : FarmColors.muted,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    task.title,
                    style: FarmTypography.textTheme.titleSmall?.copyWith(
                      decoration: done ? TextDecoration.lineThrough : null,
                      color: done ? FarmColors.muted : FarmColors.ink,
                    ),
                  ),
                  Text(task.category, style: FarmTypography.textTheme.bodySmall),
                ],
              ),
            ),
            Text(
              TimeOfDay.fromDateTime(task.dueAt).format(context),
              style: const TextStyle(fontSize: 12, color: FarmColors.muted, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}

class _WeatherCard extends StatelessWidget {
  const _WeatherCard();

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: context.t('weatherInBekaaValley'),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.wb_sunny, color: FarmColors.gold, size: 32),
              Text('18°C', style: FarmTypography.textTheme.headlineMedium),
              const Text('Sunny', style: TextStyle(color: FarmColors.muted)),
              const Text('Feels like 18°', style: TextStyle(fontSize: 11, color: FarmColors.muted)),
            ],
          ),
          const SizedBox(width: FarmSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(children: [
                  Icon(Icons.air, size: 14, color: FarmColors.muted),
                  SizedBox(width: 4),
                  Text('Wind  8 km/h NE', style: TextStyle(fontSize: 12, color: FarmColors.muted)),
                ]),
                const SizedBox(height: 4),
                const Row(children: [
                  Icon(Icons.water_drop_outlined, size: 14, color: FarmColors.muted),
                  SizedBox(width: 4),
                  Text('Humidity  54%', style: TextStyle(fontSize: 12, color: FarmColors.muted)),
                ]),
                const SizedBox(height: 10),
                Row(
                  children: [
                    for (final w in DemoData.weeklyWeather)
                      Expanded(
                        child: Column(
                          children: [
                            Text(w['day'] as String, style: const TextStyle(fontSize: 11, color: FarmColors.muted)),
                            Icon(
                              w['condition'] == 'sun'
                                  ? Icons.wb_sunny_outlined
                                  : (w['condition'] == 'rain' ? Icons.water_drop_outlined : Icons.cloud_outlined),
                              size: 16,
                              color: FarmColors.cedar2,
                            ),
                            Text('${w['hi']}°/${w['lo']}°', style: const TextStyle(fontSize: 10.5)),
                          ],
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TimelineCard extends StatelessWidget {
  const _TimelineCard();

  @override
  Widget build(BuildContext context) {
    final timeline = DemoData.todaysTimeline;
    return SectionCard(
      title: context.t('todaysTimeline'),
      child: SizedBox(
        height: 84,
        child: Row(
          children: [
            for (var i = 0; i < timeline.length; i++) ...[
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      width: 34,
                      height: 34,
                      decoration: const BoxDecoration(color: FarmColors.mist, shape: BoxShape.circle),
                      child: Center(child: Icon(Icons.circle, size: 8, color: FarmColors.cedar)),
                    ),
                    const SizedBox(height: 6),
                    Text(timeline[i]['time']!, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
                    Text(timeline[i]['label']!, textAlign: TextAlign.center, style: const TextStyle(fontSize: 10, color: FarmColors.muted)),
                  ],
                ),
              ),
              if (i != timeline.length - 1)
                const SizedBox(width: 2, child: Divider(color: FarmColors.border, height: 1)),
            ],
          ],
        ),
      ),
    );
  }
}
