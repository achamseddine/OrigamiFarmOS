import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/widgets/section_card.dart';
import '../../core/widgets/status_pill.dart';
import '../../domain/entities/access.dart';
import '../../domain/entities/animal.dart';
import '../../domain/entities/feeding.dart';
import '../../providers/access_provider.dart';
import '../../providers/feeding_provider.dart';
import '../feed/feed_workspace_screen.dart' show FeedKeyValue, feedDate, feedMoney, feedNumber;
import '../feed/feeding_event_dialog.dart';

/// The feeding section of an animal's profile (generic feed architecture
/// §17): the program it is on and where that came from — its own
/// assignment or its group's — today's quantities, the supplements,
/// overrides and restrictions that apply to it alone, what it was fed
/// lately and what that cost, and the review the system is asking for
/// after a lifecycle change. A program is never swapped silently: the
/// banner says which one is recommended and why, and only someone who may
/// approve feed changes can assign it.
class AnimalFeedingSection extends StatefulWidget {
  const AnimalFeedingSection({super.key, required this.animal});
  final Animal animal;

  @override
  State<AnimalFeedingSection> createState() => _AnimalFeedingSectionState();
}

class _AnimalFeedingSectionState extends State<AnimalFeedingSection> {
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  Future<void> _load() async {
    if (!mounted) return;
    await context.read<FeedingProvider>().planFor(widget.animal.id, force: true);
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final feeding = context.watch<FeedingProvider>();
    final access = context.watch<AccessProvider>();
    final lang = Localizations.localeOf(context).languageCode;
    final plan = feeding.cachedPlan(widget.animal.id);
    final canRecord = access.canCreate(FarmModule.feedNutrition);
    final canAssign = access.can(FarmModule.feedNutrition, PermissionAction.approve);

    return SectionCard(
      title: context.t('feedingPlan'),
      trailing: canRecord ? context.t('recordFeeding') : null,
      onTrailingTap: canRecord ? () => _recordFeeding(context, plan) : null,
      child: _loading && plan == null
          ? const Padding(padding: EdgeInsets.symmetric(vertical: 16), child: Center(child: SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))))
          : plan == null
              ? Text(context.t('feedingPlanUnavailable'), style: FarmTypography.textTheme.bodySmall)
              : _PlanBody(plan: plan, animal: widget.animal, lang: lang, canAssign: canAssign),
    );
  }

  Future<void> _recordFeeding(BuildContext context, FeedingPlan? plan) async {
    final program = plan?.program;
    final targets = plan?.dailyTargets ?? const <DailyTarget>[];
    await showFeedingEventDialog(
      context,
      subjectType: 'animal',
      subjectId: widget.animal.id,
      subjectName: widget.animal.name,
      initialLines: targets.isEmpty ? null : linesFromTargets(targets, fraction: program == null || program.feedingsPerDay <= 1 ? 1 : 1 / program.feedingsPerDay),
    );
  }
}

class _PlanBody extends StatelessWidget {
  const _PlanBody({required this.plan, required this.animal, required this.lang, required this.canAssign});
  final FeedingPlan plan;
  final Animal animal;
  final String lang;
  final bool canAssign;

  @override
  Widget build(BuildContext context) {
    final program = plan.program;
    final feeding = context.read<FeedingProvider>();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // Which program, and whose decision it was.
      if (program == null)
        Text(context.t('noProgramAssigned'), style: FarmTypography.textTheme.bodySmall)
      else ...[
        Row(children: [
          Expanded(child: Text(program.label(lang), style: FarmTypography.textTheme.titleSmall)),
          StatusPill(
            label: program.isInherited ? '${context.t('inherited')} · ${program.inheritedFromGroupName ?? animal.groupName ?? ''}'.trim() : context.t('assignedDirectly'),
            level: program.isInherited ? FarmStatusLevel.info : FarmStatusLevel.good,
            dense: true,
          ),
        ]),
        Text(
          'v${program.version} · ${program.feedingsPerDay} ${context.t('feedingsPerDay').toLowerCase()}${program.since != null ? ' · ${context.t('since')} ${feedDate(program.since!)}' : ''}',
          style: FarmTypography.textTheme.bodySmall,
        ),
      ],
      // The review banner: never a silent reassignment.
      if (plan.reviewRequired) ...[
        const SizedBox(height: 10),
        _ReviewBanner(plan: plan, lang: lang, canAssign: canAssign, animalId: animal.id),
      ],
      for (final w in plan.warnings) Padding(padding: const EdgeInsets.only(top: 4), child: Text(w, style: const TextStyle(fontSize: 12, color: FarmColors.warningInk))),
      // Today's targets.
      if (plan.dailyTargets.isNotEmpty) ...[
        const SizedBox(height: 10),
        _Label(context.t('dailyTargets')),
        for (final t in plan.dailyTargets) FeedKeyValue(t.productName ?? feeding.productName(t.feedProductId, lang), '${feedNumber(t.dailyTotal)} ${t.unit}/${context.t('day')}'),
      ],
      // Exceptions that are this animal's alone.
      if (plan.supplements.isNotEmpty || plan.overrides.isNotEmpty || plan.restrictions.isNotEmpty) ...[
        const SizedBox(height: 10),
        _Label(context.t('individualExceptions')),
        for (final s in plan.supplements)
          _ExceptionRow(
            kind: 'supplement',
            text: '+${feedNumber(s.dailyPerHead)} ${s.unit} ${s.productName ?? feeding.productName(s.feedProductId, lang)}${s.reason != null ? ' · ${s.reason}' : ''}${s.validTo != null ? ' · ${context.t('until')} ${feedDate(s.validTo!)}' : ''}',
            onEnd: canAssign ? () => _end(context, s.assignmentId) : null,
          ),
        for (final o in plan.overrides)
          _ExceptionRow(
            kind: 'override',
            text: '${feedNumber((o['quantity_per_head'] as num?)?.toDouble() ?? 0)} ${o['unit'] ?? 'kg'} ${o['product_name'] ?? feeding.productName(o['feed_product_id'] as String? ?? '', lang)}${o['reason'] != null ? ' · ${o['reason']}' : ''}',
            onEnd: canAssign && o['assignment_id'] != null ? () => _end(context, o['assignment_id'] as String) : null,
          ),
        for (final r in plan.restrictions)
          _ExceptionRow(
            kind: 'restriction',
            text: '${r['product_name'] ?? feeding.productName(r['feed_product_id'] as String? ?? '', lang)}${r['reason'] != null ? ' · ${r['reason']}' : ''}',
            onEnd: canAssign && r['assignment_id'] != null ? () => _end(context, r['assignment_id'] as String) : null,
          ),
      ],
      // What actually happened lately.
      const SizedBox(height: 10),
      _Label(context.t('lastSevenDays')),
      if (plan.fed7d.isEmpty)
        Text(context.t('noFeedingsYet'), style: FarmTypography.textTheme.bodySmall)
      else
        for (final f in plan.fed7d) FeedKeyValue(f.productName ?? feeding.productName(f.feedProductId, lang), '${feedNumber(f.dailyTotal)} ${f.unit}'),
      if (plan.feedCost7d > 0) FeedKeyValue(context.t('feedingCost'), feedMoney(plan.feedCost7d), bold: true),
      if (plan.recentEvents.isNotEmpty) ...[
        const SizedBox(height: 6),
        for (final e in plan.recentEvents.take(3))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Text(
              '${feedDate(e.occurredAt)} · ${context.t('event_${e.eventType}')} · ${feedNumber(e.totalQuantity)} kg${e.status == 'reversed' ? ' · ${context.t('reversed')}' : ''}',
              style: FarmTypography.textTheme.bodySmall?.copyWith(decoration: e.status == 'reversed' ? TextDecoration.lineThrough : null),
            ),
          ),
      ],
    ]);
  }

  Future<void> _end(BuildContext context, String assignmentId) async {
    final result = await context.read<FeedingProvider>().endAssignment(animal.id, assignmentId);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(result.success ? context.t('saved') : (result.error ?? context.t('couldNotSave')))));
  }
}

class _ReviewBanner extends StatefulWidget {
  const _ReviewBanner({required this.plan, required this.lang, required this.canAssign, required this.animalId});
  final FeedingPlan plan;
  final String lang;
  final bool canAssign;
  final String animalId;

  @override
  State<_ReviewBanner> createState() => _ReviewBannerState();
}

class _ReviewBannerState extends State<_ReviewBanner> {
  bool _saving = false;

  Future<void> _assign(ProgramMatch recommended) async {
    setState(() => _saving = true);
    final result = await context.read<FeedingProvider>().assign(widget.animalId, {
      'assignment_type': 'explicit',
      'program_id': recommended.programId,
      'program_version_id': recommended.versionId,
      'reason': 'feeding_review',
    });
    if (!mounted) return;
    setState(() => _saving = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(result.success ? context.t('programAssigned') : (result.error ?? context.t('couldNotSave')))));
  }

  @override
  Widget build(BuildContext context) {
    final recommended = widget.plan.recommended;
    return Container(
      padding: const EdgeInsets.all(FarmSpacing.md),
      decoration: BoxDecoration(color: FarmColors.tint(FarmColors.warning, 0.12), borderRadius: BorderRadius.circular(FarmRadii.md)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.rule, size: 16, color: FarmColors.warningInk),
          const SizedBox(width: 6),
          Expanded(child: Text(context.t('feedingReviewRequired'), style: FarmTypography.textTheme.titleSmall?.copyWith(color: FarmColors.warningInk))),
        ]),
        const SizedBox(height: 4),
        Text(
          recommended == null ? context.t('noProgramMatches') : '${context.t('recommendedProgram')}: ${recommended.label(widget.lang)}',
          style: FarmTypography.textTheme.bodyMedium,
        ),
        if (recommended != null)
          for (final reason in recommended.reasons) Text('• $reason', style: FarmTypography.textTheme.bodySmall),
        if (widget.canAssign && recommended != null) ...[
          const SizedBox(height: 8),
          FilledButton(
            onPressed: _saving ? null : () => _assign(recommended),
            child: Text('${context.t('assignProgram')} · ${recommended.label(widget.lang)}'),
          ),
        ],
      ]),
    );
  }
}

class _ExceptionRow extends StatelessWidget {
  const _ExceptionRow({required this.kind, required this.text, this.onEnd});
  final String kind;
  final String text;
  final VoidCallback? onEnd;

  @override
  Widget build(BuildContext context) {
    final level = switch (kind) { 'restriction' => FarmStatusLevel.alert, 'override' => FarmStatusLevel.watch, _ => FarmStatusLevel.info };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        StatusPill(label: context.t('assignment_$kind'), level: level, dense: true),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: FarmTypography.textTheme.bodySmall)),
        if (onEnd != null) TextButton(onPressed: onEnd, style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8), minimumSize: const Size(0, 28)), child: Text(context.t('end'))),
      ]),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: Text(text.toUpperCase(), style: const TextStyle(fontSize: 11, color: FarmColors.muted, fontWeight: FontWeight.w700, letterSpacing: 0.4)),
      );
}
