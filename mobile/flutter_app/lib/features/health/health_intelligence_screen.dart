import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/widgets/app_icon.dart';
import '../../core/widgets/section_card.dart';
import '../../core/widgets/status_pill.dart';
import '../../domain/entities/recommendation.dart';
import '../../providers/recommendations_provider.dart';
import '../../providers/tasks_provider.dart';

class HealthIntelligenceScreen extends StatefulWidget {
  const HealthIntelligenceScreen({super.key});

  @override
  State<HealthIntelligenceScreen> createState() => _HealthIntelligenceScreenState();
}

class _HealthIntelligenceScreenState extends State<HealthIntelligenceScreen> {
  int _tab = 0;
  String? _selectedId;

  @override
  Widget build(BuildContext context) {
    final recommendations = context.watch<RecommendationsProvider>().recommendations;
    final alerts = recommendations.where((r) => r.category == RecommendationCategory.health).toList();
    final selected =
        alerts.isEmpty ? null : alerts.firstWhere((r) => r.id == _selectedId, orElse: () => alerts.first);
    final tasksProvider = context.watch<TasksProvider>();
    final taskCreated = selected != null && tasksProvider.tasks.any((t) => t.sourceId == selected.id);

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(context.t('healthIntelligenceTitle'), style: FarmTypography.display(size: 28)),
          const SizedBox(height: 2),
          Text(context.t('healthIntelligenceSubtitle'), style: FarmTypography.textTheme.bodyMedium),
          const SizedBox(height: FarmSpacing.md),
          Row(
            children: [
              _Tab(label: context.t('currentAlerts'), count: alerts.length, selected: _tab == 0, onTap: () => setState(() => _tab = 0)),
              const SizedBox(width: FarmSpacing.lg),
              _Tab(label: context.t('allAnimals'), selected: _tab == 1, onTap: () => setState(() => _tab = 1)),
              const SizedBox(width: FarmSpacing.lg),
              _Tab(label: context.t('trends'), selected: _tab == 2, onTap: () => setState(() => _tab = 2)),
              const SizedBox(width: FarmSpacing.lg),
              _Tab(label: context.t('insights'), selected: _tab == 3, onTap: () => setState(() => _tab = 3)),
            ],
          ),
          const Divider(height: 24, color: FarmColors.border),
          if (_tab != 0)
            _PlaceholderTab(tab: _tab)
          else if (selected == null)
            const SectionCard(
              child: SizedBox(
                height: 160,
                child: Center(child: Text('No health alerts right now.')),
              ),
            )
          else ...[
            LayoutBuilder(builder: (context, c) {
              final wide = c.maxWidth > kTabletBreakpoint;
              final list = SectionCard(
                padding: const EdgeInsets.all(FarmSpacing.sm),
                child: Column(
                  children: [
                    for (final rec in alerts) ...[
                      _AlertRow(rec: rec, selected: rec.id == selected.id, onTap: () => setState(() => _selectedId = rec.id)),
                      const SizedBox(height: 6),
                    ],
                    Align(alignment: Alignment.centerLeft, child: TextButton(onPressed: () {}, child: Text(context.t('viewAllAlerts')))),
                  ],
                ),
              );
              final detail = _DetailCard(rec: selected, taskCreated: taskCreated);
              if (!wide) return Column(children: [list, const SizedBox(height: FarmSpacing.md), detail]);
              return IntrinsicHeight(
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(flex: 4, child: list),
                  const SizedBox(width: FarmSpacing.md),
                  Expanded(flex: 6, child: detail),
                ]),
              );
            }),
            const SizedBox(height: FarmSpacing.md),
            SectionCard(
              title: context.t('fromObservationToRecommendation'),
              child: LayoutBuilder(builder: (context, c) {
                final wide = c.maxWidth > 640;
                final steps = [
                  _ChainStep(icon: FarmIcon.eye, title: context.t('observationStep'), body: '1 Observation', bullets: const ['Raw data from sensors, logs, field observations.']),
                  _ChainStep(icon: FarmIcon.chartLine, title: context.t('knowledgeStep'), body: 'Knowledge', bullets: const ['AI models + farm history turn data into insight.']),
                  _ChainStep(icon: FarmIcon.check, title: context.t('recommendationStep'), body: 'Recommendation', bullets: const ['Explainable, actionable next steps.']),
                ];
                if (!wide) {
                  return Column(children: [for (final s in steps) ...[s, const SizedBox(height: 8)]]);
                }
                return Row(children: [
                  for (var i = 0; i < steps.length; i++) ...[
                    Expanded(child: steps[i]),
                    if (i != steps.length - 1) const Padding(padding: EdgeInsets.symmetric(horizontal: 6), child: Icon(Icons.arrow_forward, color: FarmColors.muted)),
                  ],
                ]);
              }),
            ),
            const SizedBox(height: FarmSpacing.md),
            Container(
              padding: const EdgeInsets.all(FarmSpacing.md),
              decoration: BoxDecoration(color: FarmColors.mist, borderRadius: BorderRadius.circular(FarmRadii.md)),
              child: Row(children: [
                const Icon(Icons.verified_outlined, color: FarmColors.cedar2, size: 18),
                const SizedBox(width: 10),
                Expanded(child: Text(context.t('evidenceFooter'), style: FarmTypography.textTheme.bodySmall)),
                TextButton(onPressed: () {}, child: const Text('Learn more about our models')),
              ]),
            ),
          ],
        ],
      ),
    );
  }
}

class _PlaceholderTab extends StatelessWidget {
  const _PlaceholderTab({required this.tab});
  final int tab;

  @override
  Widget build(BuildContext context) {
    final labels = ['', context.t('allAnimals'), context.t('trends'), context.t('insights')];
    return SectionCard(
      child: SizedBox(
        height: 220,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.insights_outlined, size: 32, color: FarmColors.muted),
              const SizedBox(height: 8),
              Text('${labels[tab]} — coming soon in this build.', style: FarmTypography.textTheme.bodyMedium),
            ],
          ),
        ),
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({required this.label, required this.selected, required this.onTap, this.count});
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final int? count;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: selected ? FarmColors.cedar : Colors.transparent, width: 2))),
        child: Row(children: [
          Text(label, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14.5, color: selected ? FarmColors.cedar : FarmColors.muted)),
          if (count != null) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: const BoxDecoration(color: FarmColors.danger, borderRadius: BorderRadius.all(Radius.circular(999))),
              child: Text('$count', style: const TextStyle(color: Colors.white, fontSize: 10.5, fontWeight: FontWeight.w700)),
            ),
          ],
        ]),
      ),
    );
  }
}

class _AlertRow extends StatelessWidget {
  const _AlertRow({required this.rec, required this.selected, required this.onTap});
  final Recommendation rec;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final level = switch (rec.priority) {
      RecommendationPriority.high => FarmStatusLevel.alert,
      RecommendationPriority.medium => FarmStatusLevel.watch,
      RecommendationPriority.low || RecommendationPriority.info => FarmStatusLevel.good,
    };
    final priorityLabel = switch (rec.priority) {
      RecommendationPriority.high => context.t('priorityHigh').toUpperCase(),
      RecommendationPriority.medium => context.t('priorityMedium').toUpperCase(),
      RecommendationPriority.low => context.t('priorityLow').toUpperCase(),
      RecommendationPriority.info => context.t('priorityInfo').toUpperCase(),
    };
    return Material(
      color: selected ? FarmColors.tint(FarmColors.danger, 0.06) : FarmColors.card,
      borderRadius: BorderRadius.circular(FarmRadii.sm),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(FarmRadii.sm),
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(FarmRadii.sm),
            border: Border.all(color: selected ? FarmColors.danger.withOpacity(0.4) : FarmColors.border),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(color: FarmColors.tint(_iconColor(level), 0.16), shape: BoxShape.circle),
                child: Center(child: AppIcon(_iconFor(rec.category), size: 18, color: _iconColor(level))),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    StatusPill(label: priorityLabel, level: level, dense: true),
                    const SizedBox(height: 4),
                    Text(rec.entityLabel, style: FarmTypography.textTheme.titleSmall),
                    Text(rec.title, style: FarmTypography.textTheme.bodySmall),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Color _iconColor(FarmStatusLevel l) => switch (l) {
        FarmStatusLevel.alert => FarmColors.danger,
        FarmStatusLevel.watch => FarmColors.warning,
        FarmStatusLevel.good => FarmColors.success,
        FarmStatusLevel.info => FarmColors.cedar2,
        FarmStatusLevel.neutral => FarmColors.muted,
      };

  FarmIcon _iconFor(RecommendationCategory c) => switch (c) {
        RecommendationCategory.health => FarmIcon.heart,
        RecommendationCategory.feed => FarmIcon.feedBag,
        RecommendationCategory.egg => FarmIcon.egg,
        RecommendationCategory.withdrawal => FarmIcon.warning,
        RecommendationCategory.harvest => FarmIcon.leaf,
        RecommendationCategory.finance => FarmIcon.money,
      };
}

class _DetailCard extends StatelessWidget {
  const _DetailCard({required this.rec, required this.taskCreated});
  final Recommendation rec;
  final bool taskCreated;

  @override
  Widget build(BuildContext context) {
    final level = switch (rec.priority) {
      RecommendationPriority.high => FarmStatusLevel.alert,
      RecommendationPriority.medium => FarmStatusLevel.watch,
      RecommendationPriority.low || RecommendationPriority.info => FarmStatusLevel.good,
    };
    final priorityLabel = switch (rec.priority) {
      RecommendationPriority.high => context.t('priorityHigh'),
      RecommendationPriority.medium => context.t('priorityMedium'),
      RecommendationPriority.low => context.t('priorityLow'),
      RecommendationPriority.info => context.t('priorityInfo'),
    };
    return SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              StatusPill(label: '${priorityLabel.toUpperCase()} PRIORITY', level: level),
              const Spacer(),
              Column(children: [
                SizedBox(
                  width: 48,
                  height: 48,
                  child: Stack(alignment: Alignment.center, children: [
                    CircularProgressIndicator(value: rec.confidence, strokeWidth: 4, backgroundColor: FarmColors.mist, color: FarmColors.cedar),
                    Text('${rec.confidencePct}%', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800)),
                  ]),
                ),
                Text(context.t('confidence'), style: const TextStyle(fontSize: 10, color: FarmColors.muted)),
              ]),
            ],
          ),
          const SizedBox(height: 10),
          Text(rec.entityLabel, style: FarmTypography.textTheme.bodySmall),
          Text(rec.title, style: FarmTypography.display(size: 22)),
          const SizedBox(height: 12),
          Text(context.t('whyWereConcerned'), style: FarmTypography.textTheme.titleSmall),
          const SizedBox(height: 8),
          LayoutBuilder(builder: (context, c) {
            final perRow = c.maxWidth > 560 ? 4 : 2;
            final w = (c.maxWidth - 8 * (perRow - 1)) / perRow;
            return Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [for (final e in rec.evidence) SizedBox(width: w, child: _EvidenceTile(evidence: e))],
            );
          }),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: FarmColors.tint(FarmColors.success, 0.1), borderRadius: BorderRadius.circular(FarmRadii.sm)),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.shield_outlined, color: FarmColors.cedar2, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(context.t('suggestedAction'), style: FarmTypography.textTheme.titleSmall),
                      const SizedBox(height: 2),
                      Text(rec.suggestedAction, style: FarmTypography.textTheme.bodySmall),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                FilledButton.icon(
                  onPressed: taskCreated
                      ? null
                      : () {
                          context.read<TasksProvider>().addFromRecommendation(
                                id: 'task-${rec.id}',
                                title: '${rec.title} — ${rec.entityLabel}',
                                category: 'From recommendation',
                                sourceId: rec.id,
                              );
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.t('createTask'))));
                        },
                  icon: Icon(taskCreated ? Icons.check : Icons.add_task, size: 16),
                  label: Text(taskCreated ? 'Task created' : context.t('createTask')),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _EvidenceTile extends StatelessWidget {
  const _EvidenceTile({required this.evidence});
  final RecommendationEvidence evidence;

  @override
  Widget build(BuildContext context) {
    final concerning = evidence.trendDown == true;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(FarmRadii.sm), border: Border.all(color: FarmColors.border)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(evidence.label, style: const TextStyle(fontSize: 11, color: FarmColors.muted)),
          const SizedBox(height: 2),
          Text(
            evidence.value,
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: concerning ? FarmColors.danger : FarmColors.ink),
          ),
        ],
      ),
    );
  }
}

class _ChainStep extends StatelessWidget {
  const _ChainStep({required this.icon, required this.title, required this.body, required this.bullets});
  final FarmIcon icon;
  final String title;
  final String body;
  final List<String> bullets;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(FarmSpacing.md),
      decoration: BoxDecoration(color: FarmColors.mist, borderRadius: BorderRadius.circular(FarmRadii.md)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: const BoxDecoration(color: FarmColors.card, shape: BoxShape.circle),
            child: Center(child: AppIcon(icon, size: 16, color: FarmColors.cedar)),
          ),
          const SizedBox(height: 8),
          Text(title, style: FarmTypography.textTheme.labelSmall),
          Text(body, style: FarmTypography.textTheme.titleSmall),
          const SizedBox(height: 6),
          for (final b in bullets) Text('• $b', style: const TextStyle(fontSize: 11.5, color: FarmColors.muted)),
        ],
      ),
    );
  }
}
