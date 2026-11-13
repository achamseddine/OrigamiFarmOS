import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/widgets/app_icon.dart';
import '../../core/widgets/hero_band.dart';
import '../../core/widgets/ux_blocks.dart';
import '../../core/widgets/section_card.dart';
import '../../core/widgets/status_pill.dart';
import '../../domain/entities/recommendation.dart';
import '../../providers/emergency_provider.dart';
import '../../providers/pharmacy_provider.dart';
import '../../providers/recommendations_provider.dart';
import '../../providers/tasks_provider.dart';
import '../../core/widgets/directional_icon.dart';
import '../../app/app_navigator.dart';
import '../navigation/entity_router.dart';
import '../../core/theme/farm_icon_map.dart';
import '../../domain/entities/access.dart';
import '../../providers/access_provider.dart';
import '../../providers/health_records_provider.dart';
import '../animals/animal_quick_actions.dart' show showObserveDialog;
import 'emergency_tab.dart';
import 'health_cases.dart';
import 'health_overview.dart';
import 'pharmacy_tab.dart';

class HealthIntelligenceScreen extends StatefulWidget {
  const HealthIntelligenceScreen({super.key});

  @override
  State<HealthIntelligenceScreen> createState() => _HealthIntelligenceScreenState();
}

/// The Health screen's tabs. The first is the V3 prototype's command
/// centre; the others are the records behind it. The old "All animals",
/// "Trends" and "Insights" tabs said "coming soon" and are gone.
enum HealthTab { overview, recommendations, cases, pharmacy, emergency }

class _HealthIntelligenceScreenState extends State<HealthIntelligenceScreen> {
  HealthTab _tab = HealthTab.overview;
  String? _selectedId;
  bool _allCases = false;

  /// A notification or priority card that names a health case, a pharmacy
  /// or an emergency record lands on the right tab — and a case or a
  /// medicine opens itself — rather than on a list the user then has to
  /// leave.
  void _consumeFocus(BuildContext context) {
    final navigator = context.watch<AppNavigator>();
    final type = navigator.focusEntityType;
    if (type == null) return;
    final isCase = type == 'health_case';
    final pharmacy = EntityRouter.pharmacyEntities.contains(type);
    final emergency = !isCase && EntityRouter.emergencyEntities.contains(type);
    if (!isCase && !pharmacy && !emergency) return;
    final id = navigator.focusEntityId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() => _tab = isCase ? HealthTab.cases : (pharmacy ? HealthTab.pharmacy : HealthTab.emergency));
      navigator.clearFocus();
      if (type == 'medicine_product' && id != null) showMedicineDetailDialog(this.context, id);
      if (isCase && id != null) {
        for (final c in this.context.read<HealthRecordsProvider>().cases) {
          if (c.id == id) showCaseSheet(this.context, c);
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final alerts = context.watch<RecommendationsProvider>().forCategory(RecommendationCategory.health);
    final pharmacyUnseen = context.watch<PharmacyProvider>().unseenAlerts.length;
    final emergencyLive = context.watch<EmergencyProvider>().escalated.length;
    final access = context.watch<AccessProvider>();
    final canCreate = access.canCreate(FarmModule.animalHealth);
    final health = context.watch<HealthRecordsProvider>();
    _consumeFocus(context);

    String counted(String key, int n) => n == 0 ? context.t(key) : '${context.t(key)} · $n';
    final labels = {
      HealthTab.overview: context.t('hlTabOverview'),
      HealthTab.recommendations: counted('hlTabRecommendations', alerts.length),
      HealthTab.cases: counted('hlTabCases', health.openCases.length),
      HealthTab.pharmacy: counted('phTab', pharmacyUnseen),
      HealthTab.emergency: counted('emTab', emergencyLive),
    };
    final tabs = HealthTab.values;

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          HeroBand(
            eyebrow: context.t('hlEyebrow'),
            title: context.t('healthIntelligenceTitle'),
            subtitle: context.t('healthIntelligenceSubtitle'),
            icon: FarmIcon.stethoscope,
            actions: [
              if (canCreate) HeroAction(primary: true, icon: FarmIconMap.add, label: context.t('hcOpenCase'), onPressed: () => showOpenCaseForm(context)),
              HeroAction(icon: FarmIcon.eye, label: context.t('twRecordObservation'), onPressed: () => _observe(context)),
              if (canCreate) HeroAction(icon: FarmIcon.bell, label: context.t('emAssess'), onPressed: () => showAssessDialog(context)),
            ],
          ),
          const SizedBox(height: FarmSpacing.md),
          const HealthKpiRow(),
          const SizedBox(height: FarmSpacing.sm),
          UnderlineTabs(
            labels: [for (final t in tabs) labels[t]!],
            selected: tabs.indexOf(_tab),
            onSelect: (i) => setState(() => _tab = tabs[i]),
          ),
          const SizedBox(height: FarmSpacing.md),
          switch (_tab) {
            HealthTab.overview => HealthOverviewTab(onAllCases: () => setState(() => _tab = HealthTab.cases)),
            HealthTab.recommendations => _recommendations(context, alerts),
            HealthTab.cases => _cases(context, health),
            HealthTab.pharmacy => const PharmacyTab(),
            HealthTab.emergency => const EmergencyTab(),
          },
        ],
      ),
    );
  }

  /// Who was it? Then what was seen.
  Future<void> _observe(BuildContext context) async {
    final subject = await showSubjectPicker(context, title: context.t('twRecordObservation'));
    if (subject == null || !context.mounted) return;
    await showObserveDialog(context, subject.id);
    if (context.mounted) await context.read<HealthRecordsProvider>().load();
  }

  Widget _cases(BuildContext context, HealthRecordsProvider health) {
    final shown = _allCases ? ([...health.cases]..sort((a, b) => (b.openedAt ?? DateTime(2000)).compareTo(a.openedAt ?? DateTime(2000)))) : health.openCases;
    return SectionCard(
      title: context.t('hcCasesTitle'),
      subtitle: context.t('hcCasesSub'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Wrap(spacing: 8, children: [
          ChoiceChip(label: Text(context.t('hcFilterOpen')), selected: !_allCases, onSelected: (_) => setState(() => _allCases = false)),
          ChoiceChip(label: Text(context.t('hcFilterAll')), selected: _allCases, onSelected: (_) => setState(() => _allCases = true)),
        ]),
        const SizedBox(height: FarmSpacing.sm),
        if (shown.isEmpty)
          EmptyState(message: context.t(_allCases ? 'hcNoCases' : 'hcNoOpenCases'), icon: FarmIcon.heart)
        else
          for (final c in shown) CaseRow(healthCase: c),
      ]),
    );
  }

  Widget _recommendations(BuildContext context, List<Recommendation> alerts) {
    final selected = alerts.isEmpty ? null : alerts.firstWhere((r) => r.id == _selectedId, orElse: () => alerts.first);
    final taskCreated = selected != null && context.watch<TasksProvider>().tasks.any((t) => t.sourceId == selected.id);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (alerts.isEmpty)
        SectionCard(
          // The prototype's wording: an empty list is a statement about
          // the records, never about the herd.
          child: EmptyState(message: context.t('noHealthAlerts'), detail: context.t('hlNoAlertsCaveat'), icon: FarmIcon.heart),
        )
      else
        LayoutBuilder(builder: (context, c) {
          final wide = c.maxWidth > kTabletBreakpoint;
          final list = SectionCard(
            padding: const EdgeInsets.all(FarmSpacing.sm),
            child: Column(
              children: [
                for (final rec in alerts) ...[
                  _AlertRow(rec: rec, selected: rec.id == selected!.id, onTap: () => setState(() => _selectedId = rec.id)),
                  const SizedBox(height: 6),
                ],
              ],
            ),
          );
          final detail = _DetailCard(rec: selected!, taskCreated: taskCreated);
          if (!wide) return Column(children: [list, const SizedBox(height: FarmSpacing.md), detail]);
          // No IntrinsicHeight: the detail card lays its evidence out with
          // a LayoutBuilder, which cannot report an intrinsic height.
          return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(flex: 4, child: list),
            const SizedBox(width: FarmSpacing.md),
            Expanded(flex: 6, child: detail),
          ]);
        }),
      const SizedBox(height: FarmSpacing.md),
      NoticeBanner(text: context.t('twAiCaveat')),
      const SizedBox(height: FarmSpacing.md),
      SectionCard(
        title: context.t('fromObservationToRecommendation'),
        child: LayoutBuilder(builder: (context, c) {
          final wide = c.maxWidth > 640;
          final steps = [
            _ChainStep(icon: FarmIcon.eye, title: '1', body: context.t('observationStep'), bullets: [context.t('observationStepBody')]),
            _ChainStep(icon: FarmIcon.chartLine, title: '2', body: context.t('knowledgeStep'), bullets: [context.t('hlKnowledgeBody')]),
            _ChainStep(icon: FarmIcon.check, title: '3', body: context.t('recommendationStep'), bullets: [context.t('recommendationStepBody')]),
          ];
          if (!wide) {
            return Column(children: [for (final s in steps) ...[s, const SizedBox(height: 8)]]);
          }
          return Row(children: [
            for (var i = 0; i < steps.length; i++) ...[
              Expanded(child: steps[i]),
              if (i < steps.length - 1) const Padding(padding: EdgeInsets.symmetric(horizontal: 6), child: ForwardChevron(color: FarmColors.muted)),
            ],
          ]);
        }),
      ),
    ]);
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
      // The selected recommendation takes a wash of the alert colour; the
      // rest take the page's paper. No outlines either way.
      color: selected ? FarmColors.tint(FarmColors.danger, 0.12) : FarmColors.stone,
      borderRadius: BorderRadius.circular(FarmRadii.sm),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(FarmRadii.sm),
        child: Container(
          padding: const EdgeInsets.all(10),
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
                                title: '${rec.title} — ${rec.entityLabel}',
                                // Stays English: the server stores this
                                // category, nobody reads it on screen.
                                category: 'From recommendation',
                                sourceId: rec.id,
                              );
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.t('createTask'))));
                        },
                  icon: Icon(taskCreated ? Icons.check : Icons.add_task, size: 16),
                  label: Text(taskCreated ? context.t('taskCreated') : context.t('createTask')),
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
      decoration: BoxDecoration(color: FarmColors.stone, borderRadius: BorderRadius.circular(FarmRadii.sm)),
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
