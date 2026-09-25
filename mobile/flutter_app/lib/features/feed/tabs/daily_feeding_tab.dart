import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/i18n/strings.dart';
import '../../../core/theme/colors.dart';
import '../../../core/theme/farm_icon_map.dart';
import '../../../core/theme/spacing.dart';
import '../../../core/theme/typography.dart';
import '../../../core/widgets/app_icon.dart';
import '../../../core/widgets/section_card.dart';
import '../../../core/widgets/status_pill.dart';
import '../../../domain/entities/access.dart';
import '../../../domain/entities/feeding.dart';
import '../../../providers/access_provider.dart';
import '../../../providers/feeding_provider.dart';
import '../../../providers/livestock_provider.dart';
import '../feed_workspace_screen.dart';
import '../feeding_event_dialog.dart';

/// Today's feeding (§9, §17): every group and individually assigned
/// animal with its program and planned quantities, the farm-wide totals
/// against what has been fed so far, and a one-tap "record delivery" that
/// opens the feeding dialog with the line's plan filled in.
class DailyFeedingTab extends StatelessWidget {
  const DailyFeedingTab({super.key});

  @override
  Widget build(BuildContext context) {
    final feeding = context.watch<FeedingProvider>();
    final access = context.watch<AccessProvider>();
    final livestock = context.watch<LivestockProvider>();
    final lang = Localizations.localeOf(context).languageCode;
    final canRecord = access.canCreate(FarmModule.feedNutrition);
    final plan = feeding.dailyPlan;

    return FeedTabScaffold(children: [
      SectionCard(
        title: context.t('plannedToday'),
        subtitle: plan.date.isEmpty ? null : plan.date,
        child: plan.totals.isEmpty
            ? const FeedEmpty('noPlanToday')
            : Column(children: [
                for (final t in plan.totals)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: Row(children: [
                      Expanded(child: Text(t.productName ?? feeding.productName(t.feedProductId, lang), style: FarmTypography.textTheme.titleSmall)),
                      _Figure(context.t('plannedToday'), '${feedNumber(t.dailyTotal)} ${t.unit}'),
                      _Figure(context.t('fedToday'), '${feedNumber(t.fedToday ?? 0)} ${t.unit}', color: FarmColors.success),
                      _Figure(context.t('remainingToday'), '${feedNumber(t.remainingToday ?? (t.dailyTotal - (t.fedToday ?? 0)))} ${t.unit}',
                          color: (t.remainingToday ?? 1) > 0 ? FarmColors.warningInk : FarmColors.success),
                    ]),
                  ),
              ]),
      ),
      SectionCard(
        title: context.t('dailyFeeding'),
        subtitle: context.t('dailyFeedingSubtitle'),
        child: plan.lines.isEmpty
            ? const FeedEmpty('noPlanToday')
            : Column(children: [
                for (final line in plan.lines) ...[
                  _PlanLineCard(line: line, canRecord: canRecord, speciesName: livestock.speciesName(line.species, lang), icon: FarmIconMap.species(livestock.speciesIcon(line.species)), lang: lang),
                  const SizedBox(height: 10),
                ],
              ]),
      ),
    ]);
  }
}

class _Figure extends StatelessWidget {
  const _Figure(this.label, this.value, {this.color});
  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsetsDirectional.only(start: 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(label, style: const TextStyle(fontSize: 10.5, color: FarmColors.muted)),
          Text(value, style: FarmTypography.textTheme.titleSmall?.copyWith(color: color)),
        ]),
      );
}

class _PlanLineCard extends StatelessWidget {
  const _PlanLineCard({required this.line, required this.canRecord, required this.speciesName, required this.icon, required this.lang});
  final DailyPlanLine line;
  final bool canRecord;
  final String speciesName;
  final FarmIcon icon;
  final String lang;

  @override
  Widget build(BuildContext context) {
    final program = line.program;
    return Container(
      padding: const EdgeInsets.all(FarmSpacing.md),
      decoration: BoxDecoration(color: FarmColors.stone, borderRadius: BorderRadius.circular(FarmRadii.md)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 36,
            height: 36,
            decoration: const BoxDecoration(color: FarmColors.mist, shape: BoxShape.circle),
            child: Center(child: AppIcon(icon, size: 16, color: FarmColors.cedar)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(line.name, style: FarmTypography.textTheme.titleSmall),
              Text(
                [speciesName, if (line.subjectType == 'group') '${line.headCount} ${context.t('headCount').toLowerCase()}', if (program != null) program.label(lang)].join(' · '),
                style: FarmTypography.textTheme.bodySmall,
              ),
            ]),
          ),
          if (program != null && program.isInherited) StatusPill(label: context.t('inherited'), level: FarmStatusLevel.info, dense: true),
          if (line.reviewRequired) ...[const SizedBox(width: 6), StatusPill(label: context.t('reviewRequired'), level: FarmStatusLevel.watch, dense: true)],
        ]),
        const SizedBox(height: 8),
        for (final t in line.dailyTargets) FeedKeyValue(t.productName ?? t.feedProductId, '${feedNumber(t.dailyTotal)} ${t.unit}'),
        for (final w in line.warnings) Padding(padding: const EdgeInsets.only(top: 4), child: Text(w, style: const TextStyle(fontSize: 12, color: FarmColors.warningInk))),
        if (canRecord && line.dailyTargets.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(spacing: 8, children: [
            FilledButton.icon(
              onPressed: () => showFeedingEventDialog(
                context,
                subjectType: line.subjectType, subjectId: line.subjectId, subjectName: line.name, headCount: line.headCount,
                initialLines: linesFromTargets(line.dailyTargets, fraction: program == null ? 1 : 1 / program.feedingsPerDay),
              ),
              icon: const Icon(Icons.check, size: 16),
              label: Text(program == null || program.feedingsPerDay <= 1 ? context.t('recordDelivery') : '${context.t('recordDelivery')} · 1/${program.feedingsPerDay}'),
            ),
            if (program != null && program.feedingsPerDay > 1)
              OutlinedButton(
                onPressed: () => showFeedingEventDialog(
                  context,
                  subjectType: line.subjectType, subjectId: line.subjectId, subjectName: line.name, headCount: line.headCount,
                  initialLines: linesFromTargets(line.dailyTargets),
                ),
                child: Text(context.t('recordWholeDay')),
              ),
          ]),
        ],
      ]),
    );
  }
}
