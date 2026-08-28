import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/widgets/app_icon.dart';
import '../../core/widgets/charts/line_trend_chart.dart';
import '../../core/widgets/photo_slot.dart';
import '../../core/widgets/section_card.dart';
import '../../core/widgets/status_pill.dart';
import '../../core/widgets/top_bar.dart';
import '../../domain/entities/animal.dart';
import '../../domain/entities/recommendation.dart';
import '../../providers/animals_provider.dart';
import '../../providers/recommendations_provider.dart';
import 'animal_quick_actions.dart';

/// Screen 4 — Animal Digital Twin. Pushed as a focused full-screen route
/// (no nav rail) — the Option C mockup itself drops the sidebar here in
/// favour of a "Back to Herd" header, so [AnimalDigitalTwinScreen] is a
/// plain [MaterialPageRoute] destination rather than an [AppShell] tab.
class AnimalDigitalTwinScreen extends StatelessWidget {
  const AnimalDigitalTwinScreen({super.key, required this.animalId});

  final String animalId;

  @override
  Widget build(BuildContext context) {
    final animal = context.watch<AnimalsProvider>().byId(animalId);

    return Scaffold(
      backgroundColor: FarmColors.stone,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: FarmSpacing.xl, vertical: FarmSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  TextButton.icon(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.chevron_left),
                    label: Text(context.t('backToHerd')),
                  ),
                  const Spacer(),
                  const TopBar(),
                ],
              ),
              Expanded(
                child: SingleChildScrollView(
                  child: LayoutBuilder(builder: (context, constraints) {
                    final wide = constraints.maxWidth > kTabletBreakpoint;
                    final left = _ProfileColumn(animal: animal);
                    final center = _HistoryColumn(animal: animal);
                    final right = _InsightsColumn(animal: animal);
                    if (!wide) {
                      return Column(children: [left, const SizedBox(height: FarmSpacing.md), center, const SizedBox(height: FarmSpacing.md), right]);
                    }
                    return IntrinsicHeight(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(width: 260, child: left),
                          const SizedBox(width: FarmSpacing.md),
                          Expanded(flex: 6, child: center),
                          const SizedBox(width: FarmSpacing.md),
                          SizedBox(width: 300, child: right),
                        ],
                      ),
                    );
                  }),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProfileColumn extends StatelessWidget {
  const _ProfileColumn({required this.animal});
  final Animal animal;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('${animal.name} #${animal.tag}', style: FarmTypography.display(size: 24)),
            const SizedBox(width: 8),
            StatusPill(label: context.t('active'), level: FarmStatusLevel.good, dense: true),
          ],
        ),
        const SizedBox(height: FarmSpacing.sm),
        AspectRatio(
          aspectRatio: 1.1,
          child: PhotoSlot(filePath: animal.photoPath, icon: _iconForSpecies(animal.species), label: animal.species.label),
        ),
        const SizedBox(height: FarmSpacing.md),
        SectionCard(
          padding: const EdgeInsets.all(FarmSpacing.md),
          child: Column(
            children: [
              _fact(context, context.t('species'), animal.species.label),
              _fact(context, context.t('breed'), animal.breed),
              _fact(context, context.t('age'), animal.ageLabel),
              _fact(context, context.t('location'), animal.location),
              _fact(context, context.t('healthScore'), '${animal.healthScore} / 100', valueColor: _scoreColor(animal.healthScore)),
              if (animal.pregnant)
                _fact(context, context.t('pregnancyStatus'), 'Confirmed (${animal.pregnancyDays} days)'),
              if (animal.lactating)
                _fact(context, context.t('lactationStatus'), 'Lactating — ${animal.lactationCycle ?? 1}'),
              const Divider(height: 20, color: FarmColors.border),
              _fact(context, context.t('earTag'), animal.tag),
              _fact(context, context.t('internalId'), 'COW-${animal.tag.padLeft(4, '0')}', last: true),
            ],
          ),
        ),
      ],
    );
  }

  Widget _fact(BuildContext context, String label, String value, {Color? valueColor, bool last = false}) {
    return Padding(
      padding: EdgeInsets.only(bottom: last ? 0 : 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: Text(label, style: FarmTypography.textTheme.bodySmall)),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: FarmTypography.textTheme.titleSmall?.copyWith(color: valueColor),
            ),
          ),
        ],
      ),
    );
  }

  Color _scoreColor(int score) {
    if (score >= 80) return FarmColors.success;
    if (score >= 60) return FarmColors.warning;
    return FarmColors.danger;
  }

  FarmIcon _iconForSpecies(AnimalSpecies s) => switch (s) {
        AnimalSpecies.cow => FarmIcon.cow,
        AnimalSpecies.goat => FarmIcon.goat,
        AnimalSpecies.sheep => FarmIcon.sheep,
        AnimalSpecies.horse => FarmIcon.horse,
        AnimalSpecies.layerHen || AnimalSpecies.turkey => FarmIcon.poultry,
        AnimalSpecies.duck => FarmIcon.duck,
      };
}

class _QuickAction {
  const _QuickAction(this.icon, this.labelKey, this.onTap);
  final FarmIcon icon;
  final String labelKey;
  final VoidCallback onTap;
}

class _HistoryColumn extends StatelessWidget {
  const _HistoryColumn({required this.animal});
  final Animal animal;

  @override
  Widget build(BuildContext context) {
    final actions = <_QuickAction>[
      _QuickAction(FarmIcon.eye, 'observe', () => showObserveDialog(context, animal.id)),
      _QuickAction(FarmIcon.stethoscope, 'treat', () => showTreatDialog(context, animal)),
      _QuickAction(FarmIcon.feedBag, 'feed', () => showFeedDialog(context, animal)),
      _QuickAction(FarmIcon.milkBottle, 'milk', () => showMilkDialog(context, animal)),
      _QuickAction(FarmIcon.location, 'move', () => showMoveDialog(context, animal)),
      _QuickAction(FarmIcon.calendar, 'viewHistory', () {}),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LayoutBuilder(builder: (context, c) {
          final perRow = c.maxWidth > 560 ? 6 : 3;
          final w = (c.maxWidth - 8 * (perRow - 1)) / perRow;
          return Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [for (final a in actions) SizedBox(width: w, child: _ActionButton(action: a))],
          );
        }),
        const SizedBox(height: FarmSpacing.md),
        SectionCard(
          title: context.t('lifeHistory'),
          child: Column(
            children: [
              for (final entry in _timelineFor(animal)) ...[
                _TimelineRow(entry: entry),
                const Divider(height: 18, color: FarmColors.border),
              ],
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(onPressed: () {}, child: Text(context.t('viewFullHistory'))),
              ),
            ],
          ),
        ),
        const SizedBox(height: FarmSpacing.md),
        LayoutBuilder(builder: (context, c) {
          final wide = c.maxWidth > 560;
          final health = SectionCard(
            title: context.t('healthHistory'),
            trailing: context.t('viewAll'),
            child: Column(children: const [
              _HistoryLine(label: 'Mastitis', status: 'Resolved', date: 'May 12'),
              _HistoryLine(label: 'Lameness', status: 'Resolved', date: 'Apr 28'),
              _HistoryLine(label: 'Fever', status: 'Resolved', date: 'Apr 10'),
            ]),
          );
          final breeding = SectionCard(
            title: context.t('breeding'),
            trailing: context.t('viewAll'),
            child: Column(children: [
              _fact('AI Date', 'Feb 22, 2026'),
              _fact('Bull', 'Orion-ET'),
              _fact('Pregnancy', animal.pregnant ? 'Confirmed (${animal.pregnancyDays} days)' : '—'),
              _fact('Due Date', 'Sep 20, 2026', last: true),
            ]),
          );
          if (!wide) return Column(children: [health, const SizedBox(height: FarmSpacing.md), breeding]);
          return IntrinsicHeight(
            child: Row(children: [
              Expanded(child: health),
              const SizedBox(width: FarmSpacing.md),
              Expanded(child: breeding),
            ]),
          );
        }),
      ],
    );
  }

  Widget _fact(String label, String value, {bool last = false}) => Padding(
        padding: EdgeInsets.only(bottom: last ? 0 : 8),
        child: Row(children: [
          Expanded(child: Text(label, style: const TextStyle(fontSize: 12.5, color: FarmColors.muted))),
          Text(value, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
        ]),
      );

  List<_TimelineEntry> _timelineFor(Animal a) {
    final entries = <_TimelineEntry>[];
    if (a.milkTodayL != null) {
      entries.add(_TimelineEntry(FarmIcon.milkBottle, 'Milk recorded', '${a.milkTodayL!.toStringAsFixed(1)} L', 'Today, 7:15 AM'));
    }
    if (a.status == AnimalHealthStatus.underTreatment) {
      entries.add(const _TimelineEntry(FarmIcon.heart, 'Treatment completed', 'Mastitis — 3 day course', '2 days ago'));
    }
    if (a.weightKg != null) {
      entries.add(_TimelineEntry(FarmIcon.scale, 'Weight recorded', '${a.weightKg!.toStringAsFixed(0)} kg', '3 days ago'));
    }
    if (a.pregnant) {
      entries.add(_TimelineEntry(FarmIcon.pregnancy, 'Pregnancy confirmed', '${a.pregnancyDays} days', '5 days ago'));
    }
    entries.add(const _TimelineEntry(FarmIcon.feedBag, 'Feed change', 'Higher energy mix started', '1 week ago'));
    return entries;
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({required this.action});
  final _QuickAction action;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: FarmColors.card,
      borderRadius: BorderRadius.circular(FarmRadii.sm),
      child: InkWell(
        onTap: action.onTap,
        borderRadius: BorderRadius.circular(FarmRadii.sm),
        child: Container(
          constraints: const BoxConstraints(minHeight: kFarmTouchTarget),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(FarmRadii.sm), border: Border.all(color: FarmColors.border)),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppIcon(action.icon, size: 18, color: FarmColors.cedar),
              const SizedBox(height: 4),
              Text(context.t(action.labelKey), style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
    );
  }
}

class _TimelineEntry {
  const _TimelineEntry(this.icon, this.title, this.value, this.time);
  final FarmIcon icon;
  final String title;
  final String value;
  final String time;
}

class _TimelineRow extends StatelessWidget {
  const _TimelineRow({required this.entry});
  final _TimelineEntry entry;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: const BoxDecoration(color: FarmColors.mist, shape: BoxShape.circle),
          child: Center(child: AppIcon(entry.icon, size: 15, color: FarmColors.cedar)),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(entry.time, style: const TextStyle(fontSize: 11, color: FarmColors.muted)),
              Text(entry.title, style: FarmTypography.textTheme.titleSmall),
            ],
          ),
        ),
        Text(entry.value, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
      ],
    );
  }
}

class _HistoryLine extends StatelessWidget {
  const _HistoryLine({required this.label, required this.status, required this.date});
  final String label;
  final String status;
  final String date;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          const Icon(Icons.check_circle, size: 15, color: FarmColors.success),
          const SizedBox(width: 8),
          Expanded(child: Text(label, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600))),
          Text(status, style: const TextStyle(fontSize: 11, color: FarmColors.success)),
          const SizedBox(width: 8),
          Text(date, style: const TextStyle(fontSize: 11, color: FarmColors.muted)),
        ],
      ),
    );
  }
}

class _InsightsColumn extends StatelessWidget {
  const _InsightsColumn({required this.animal});
  final Animal animal;

  @override
  Widget build(BuildContext context) {
    final rec = context
        .watch<RecommendationsProvider>()
        .recommendations
        .where((r) => r.entityLabel.contains(animal.name) || r.entityLabel.contains(animal.tag))
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionCard(
          title: context.t('milkTrend'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${(animal.milkTodayL ?? 18.6).toStringAsFixed(1)} ${context.t('liters')}', style: FarmTypography.textTheme.headlineMedium),
              const Text('-7.5% vs last 7 days', style: TextStyle(color: FarmColors.danger, fontSize: 12, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              const LineTrendChart(values: [20.1, 19.8, 20.3, 19.4, 19.0, 18.8, 18.6], height: 90, showDots: false),
            ],
          ),
        ),
        const SizedBox(height: FarmSpacing.md),
        SectionCard(
          title: context.t('feedIntake'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('17.2 kg', style: FarmTypography.textTheme.headlineMedium),
              const Text('+2.4% vs last 7 days', style: TextStyle(color: FarmColors.success, fontSize: 12, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              const LineTrendChart(values: [16.2, 16.5, 16.9, 16.6, 17.0, 16.8, 17.2], height: 90, showDots: false, color: FarmColors.olive),
            ],
          ),
        ),
        const SizedBox(height: FarmSpacing.md),
        SectionCard(
          title: context.t('financialSnapshot'),
          child: Column(children: [
            _money(context, 'Milk Revenue', 142.68),
            _money(context, 'Cost (Feed + Care)', -58.34),
            const Divider(height: 18, color: FarmColors.border),
            _money(context, 'Net', 84.34, bold: true),
          ]),
        ),
        const SizedBox(height: FarmSpacing.md),
        SectionCard(
          title: context.t('aiRecommendation'),
          child: rec.isEmpty
              ? Text('No active recommendations for this animal.', style: FarmTypography.textTheme.bodySmall)
              : _RecommendationSummary(rec: rec.first),
        ),
      ],
    );
  }

  Widget _money(BuildContext context, String label, double value, {bool bold = false}) {
    final positive = value >= 0;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        Expanded(child: Text(label, style: const TextStyle(fontSize: 12.5, color: FarmColors.muted))),
        Text(
          '${positive ? '' : '-'}\$${value.abs().toStringAsFixed(2)}',
          style: TextStyle(fontSize: 13, fontWeight: bold ? FontWeight.w800 : FontWeight.w600),
        ),
      ]),
    );
  }
}

class _RecommendationSummary extends StatelessWidget {
  const _RecommendationSummary({required this.rec});
  final Recommendation rec;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Expanded(child: Text(rec.title, style: FarmTypography.textTheme.titleSmall)),
          StatusPill(label: '${rec.confidencePct}%', level: FarmStatusLevel.info, dense: true),
        ]),
        const SizedBox(height: 6),
        Text(rec.rationale, style: FarmTypography.textTheme.bodySmall),
        const SizedBox(height: 6),
        Text('Recommendation: ${rec.suggestedAction}', style: FarmTypography.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w700, color: FarmColors.ink)),
      ],
    );
  }
}
