import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../auth/session_controller.dart';
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
import '../../domain/entities/inventory.dart';
import '../../domain/entities/task.dart';
import '../../providers/feed_provider.dart';
import '../../providers/production_provider.dart';
import '../../providers/tasks_provider.dart';

/// Screen 2 — Morning Briefing Dashboard. The default route after login
/// (tech spec §2 "Morning first: default route after login is Morning
/// Briefing").
///
/// There is no dedicated provider for this screen (by design — one screen,
/// one endpoint): it fetches `GET /morning-briefing` directly, the same
/// "fetch in initState, store in local State, render with a loading
/// fallback" pattern used by `SettingsScreen._loadFarm`. The KPI strip and
/// priorities come straight from that response; the animal/feed alert cards
/// and the milk/egg trend cards reuse the already-loaded `FeedProvider` /
/// `ProductionProvider` instead of a second fetch. The old fabricated
/// weekly-weather widget had no real backend source and is gone entirely;
/// the fixed "Today's Timeline" schedule is now built from the briefing's
/// own (real, farm-specific) `tasks` list sorted by due time.
class MorningBriefingScreen extends StatefulWidget {
  const MorningBriefingScreen({super.key});

  @override
  State<MorningBriefingScreen> createState() => _MorningBriefingScreenState();
}

class _MorningBriefingScreenState extends State<MorningBriefingScreen> {
  Map<String, dynamic>? _briefing;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final session = context.read<SessionController>();
    try {
      final farmId = session.user!.farmId;
      final json = await session.apiClient.get('/morning-briefing', query: {'farm_id': farmId}) as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _briefing = json;
        _error = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = 'Could not load the morning briefing.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final briefing = _briefing;
    if (briefing == null) {
      return Center(child: Text(_error ?? 'Loading…', style: FarmTypography.textTheme.bodyMedium));
    }

    final kpis = Map<String, dynamic>.from(briefing['kpis'] as Map? ?? {});
    final priorities = List<Map<String, dynamic>>.from(briefing['priorities'] as List? ?? []);
    final tasksTimeline = List<Map<String, dynamic>>.from(briefing['tasks'] as List? ?? []);
    final session = context.read<SessionController>();
    var managerName = (briefing['manager_name'] as String?)?.trim() ?? '';
    if (managerName.isEmpty) managerName = session.user?.name ?? '';

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const AppIcon(FarmIcon.sun, size: 24, color: FarmColors.gold),
              const SizedBox(width: 8),
              Text('${context.t('goodMorning')}, $managerName', style: FarmTypography.display(size: 26)),
            ],
          ),
          const SizedBox(height: 2),
          Text(context.t('morningSubline'), style: FarmTypography.textTheme.bodyMedium),
          const SizedBox(height: FarmSpacing.lg),
          _KpiStrip(kpis: kpis),
          const SizedBox(height: FarmSpacing.lg),
          LayoutBuilder(builder: (context, constraints) {
            final wide = constraints.maxWidth > kTabletBreakpoint;
            final columns = <Widget>[
              _PrioritiesCard(priorities: priorities),
              Column(children: [_AnimalAlertsCard(priorities: priorities), const SizedBox(height: FarmSpacing.md), const _FeedWarningsCard()]),
              const Column(children: [_MilkTodayCard(), SizedBox(height: FarmSpacing.md), _EggProductionCard()]),
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
          _TimelineCard(tasks: tasksTimeline),
        ],
      ),
    );
  }
}

class _KpiStrip extends StatelessWidget {
  const _KpiStrip({required this.kpis});
  final Map<String, dynamic> kpis;

  @override
  Widget build(BuildContext context) {
    final animals = (kpis['animals'] as num?)?.toInt() ?? 0;
    final milkToday = (kpis['milk_today_l'] as num?)?.toDouble() ?? 0;
    final eggsToday = (kpis['eggs_today'] as num?)?.toInt() ?? 0;
    final activeFields = (kpis['active_fields'] as num?)?.toInt() ?? 0;
    final openAlerts = (kpis['open_alerts'] as num?)?.toInt() ?? 0;
    final tasksDue = (kpis['tasks_due'] as num?)?.toInt() ?? 0;
    return LayoutBuilder(builder: (context, constraints) {
      final perRow = constraints.maxWidth > 1100 ? 6 : (constraints.maxWidth > 720 ? 3 : 2);
      final cardWidth = (constraints.maxWidth - FarmSpacing.md * (perRow - 1)) / perRow;
      final cards = [
        KpiCard(icon: FarmIcon.cow, label: context.t('kpiAnimals'), value: '$animals'),
        KpiCard(icon: FarmIcon.milkBottle, label: context.t('kpiMilkToday'), value: milkToday.toStringAsFixed(0), unit: context.t('liters')),
        KpiCard(icon: FarmIcon.egg, label: context.t('kpiEggsToday'), value: '$eggsToday'),
        KpiCard(icon: FarmIcon.leaf, label: context.t('kpiActiveCrops'), value: '$activeFields'),
        KpiCard(
          icon: FarmIcon.warning,
          label: context.t('kpiOpenAlerts'),
          value: '$openAlerts',
          tint: openAlerts > 0 ? FarmColors.danger : null,
          caption: openAlerts > 0 ? context.t('needsAttention') : null,
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

FarmIcon _iconForCategory(String category) => switch (category) {
      'health' => FarmIcon.heart,
      'feed' => FarmIcon.feedBag,
      'egg' => FarmIcon.egg,
      'withdrawal' => FarmIcon.warning,
      'harvest' => FarmIcon.leaf,
      'finance' => FarmIcon.money,
      _ => FarmIcon.warning,
    };

FarmStatusLevel _levelForPriority(String priority) => switch (priority) {
      'high' => FarmStatusLevel.alert,
      'medium' => FarmStatusLevel.watch,
      _ => FarmStatusLevel.good,
    };

class _PrioritiesCard extends StatelessWidget {
  const _PrioritiesCard({required this.priorities});
  final List<Map<String, dynamic>> priorities;

  @override
  Widget build(BuildContext context) {
    final top = priorities.take(4).toList();
    return SectionCard(
      title: context.t('todaysPriorities'),
      child: top.isEmpty
          ? Text('No priorities right now.', style: FarmTypography.textTheme.bodySmall)
          : Column(
              children: [
                for (final rec in top) ...[
                  AlertCard(
                    icon: _iconForCategory(rec['category'] as String? ?? ''),
                    title: rec['title'] as String? ?? '—',
                    eyebrow: rec['entity_label'] as String?,
                    level: _levelForPriority(rec['priority'] as String? ?? ''),
                    onTap: () {},
                  ),
                  const SizedBox(height: 8),
                ],
              ],
            ),
    );
  }
}

class _AnimalAlertsCard extends StatelessWidget {
  const _AnimalAlertsCard({required this.priorities});
  final List<Map<String, dynamic>> priorities;

  @override
  Widget build(BuildContext context) {
    final animalAlerts = priorities.where((p) => p['category'] == 'health').take(2).toList();
    return SectionCard(
      title: context.t('animalAlerts'),
      trailing: context.t('viewAll'),
      child: animalAlerts.isEmpty
          ? Text('No animal alerts right now.', style: FarmTypography.textTheme.bodySmall)
          : Column(
              children: [
                for (var i = 0; i < animalAlerts.length; i++) ...[
                  AlertCard(
                    icon: FarmIcon.cow,
                    title: animalAlerts[i]['entity_label'] as String? ?? (animalAlerts[i]['title'] as String? ?? '—'),
                    level: _levelForPriority(animalAlerts[i]['priority'] as String? ?? ''),
                    evidence: [animalAlerts[i]['title'] as String? ?? ''],
                  ),
                  if (i != animalAlerts.length - 1) const SizedBox(height: 8),
                ],
              ],
            ),
    );
  }
}

class _FeedWarningsCard extends StatelessWidget {
  const _FeedWarningsCard();

  @override
  Widget build(BuildContext context) {
    final items = context.watch<FeedProvider>().items.where((i) => i.status != StockStatus.good).toList();
    return SectionCard(
      title: context.t('feedWarnings'),
      trailing: context.t('manageFeed'),
      child: items.isEmpty
          ? Text('No feed warnings right now.', style: FarmTypography.textTheme.bodySmall)
          : AlertCard(
              icon: FarmIcon.feedBag,
              title: 'Low feed: ${items.first.name}',
              level: items.first.status == StockStatus.critical ? FarmStatusLevel.alert : FarmStatusLevel.watch,
              evidence: ['${items.first.currentQty.toStringAsFixed(1)} ${items.first.unit} remaining', 'Reorder recommended'],
            ),
    );
  }
}

class _MilkTodayCard extends StatelessWidget {
  const _MilkTodayCard();

  @override
  Widget build(BuildContext context) {
    final production = context.watch<ProductionProvider>();
    final trend = production.milkByDay();
    final today = production.milkTodayL;
    final yesterday = trend.length > 1 ? trend[trend.length - 2] : 0.0;
    final delta = today - yesterday;
    return SectionCard(
      title: context.t('milkToday'),
      trailing: context.t('viewMilkHistory'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          RichText(
            text: TextSpan(
              children: [
                TextSpan(text: '${today.toStringAsFixed(0)} ', style: FarmTypography.textTheme.headlineMedium),
                TextSpan(text: context.t('liters'), style: FarmTypography.textTheme.bodyMedium),
              ],
            ),
          ),
          Text(
            '${delta >= 0 ? '+' : ''}${delta.toStringAsFixed(0)} L ${context.t('vsYesterday')}',
            style: TextStyle(color: delta >= 0 ? FarmColors.success : FarmColors.danger, fontSize: 12, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          LineTrendChart(values: trend, height: 70, showDots: false),
        ],
      ),
    );
  }
}

class _EggProductionCard extends StatelessWidget {
  const _EggProductionCard();

  @override
  Widget build(BuildContext context) {
    final production = context.watch<ProductionProvider>();
    final trend = production.eggsByDay();
    final today = production.eggsToday;
    final yesterday = trend.length > 1 ? trend[trend.length - 2] : 0.0;
    final delta = today - yesterday;
    return SectionCard(
      title: context.t('eggProduction'),
      trailing: context.t('viewEggHistory'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$today', style: FarmTypography.textTheme.headlineMedium),
          Text(
            '${delta >= 0 ? '+' : ''}${delta.toStringAsFixed(0)} ${context.t('vsYesterday')}',
            style: TextStyle(color: delta >= 0 ? FarmColors.success : FarmColors.danger, fontSize: 12, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          LineTrendChart(values: trend, height: 70, showDots: false, color: FarmColors.gold),
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
      child: tasks.isEmpty
          ? Text('No tasks yet.', style: FarmTypography.textTheme.bodySmall)
          : Column(
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

/// Real substitute for the old fixed "6 AM Milking / 9 AM Health Checks…"
/// fabricated schedule: the briefing's own `tasks` (every not-done task for
/// the farm today), sorted by due time.
class _TimelineCard extends StatelessWidget {
  const _TimelineCard({required this.tasks});
  final List<Map<String, dynamic>> tasks;

  @override
  Widget build(BuildContext context) {
    final sorted = [...tasks]..sort((a, b) {
        final ad = a['due_at'] as String?;
        final bd = b['due_at'] as String?;
        if (ad == null && bd == null) return 0;
        if (ad == null) return 1;
        if (bd == null) return -1;
        return ad.compareTo(bd);
      });
    final shown = sorted.take(8).toList();
    return SectionCard(
      title: context.t('todaysTimeline'),
      child: shown.isEmpty
          ? Text('No tasks scheduled for today.', style: FarmTypography.textTheme.bodySmall)
          : SizedBox(
              height: 84,
              child: Row(
                children: [
                  for (var i = 0; i < shown.length; i++) ...[
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
                          Text(_timeLabel(context, shown[i]['due_at'] as String?), style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
                          Text(
                            shown[i]['title'] as String? ?? '',
                            textAlign: TextAlign.center,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 10, color: FarmColors.muted),
                          ),
                        ],
                      ),
                    ),
                    if (i != shown.length - 1) const SizedBox(width: 2, child: Divider(color: FarmColors.border, height: 1)),
                  ],
                ],
              ),
            ),
    );
  }

  String _timeLabel(BuildContext context, String? dueAt) {
    if (dueAt == null) return '—';
    final dt = DateTime.tryParse(dueAt);
    if (dt == null) return '—';
    return TimeOfDay.fromDateTime(dt).format(context);
  }
}
