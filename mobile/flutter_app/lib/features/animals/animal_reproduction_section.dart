import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/widgets/section_card.dart';
import '../../core/widgets/app_icon.dart';
import '../../core/widgets/status_pill.dart';
import '../../core/widgets/ux_blocks.dart';
import '../../domain/entities/access.dart';
import '../../domain/entities/animal.dart';
import '../../domain/entities/reproduction.dart';
import '../../providers/access_provider.dart';
import '../../providers/herd_records_provider.dart';
import '../feed/feed_workspace_screen.dart' show feedDate, feedNumber;
import 'reproduction_forms.dart';

/// Reproduction & milking on the animal's profile (REPRODUCTION-SCHEMA,
/// PRODUCTION-SCHEMA §8, generic animal model §5, §8).
///
/// Everything here comes from the server's summary on the Digital Twin:
/// whether the animal is pregnant and when she is due, the last service
/// and check, the lactation in progress — and which actions apply at all.
/// A hen is never offered a pregnancy check and a bull never a birth,
/// because the resolved capabilities say so, not because this widget knows
/// what a hen is. The species' own word names the birth ("Calving").
class AnimalReproductionSection extends StatelessWidget {
  const AnimalReproductionSection({super.key, required this.animal, required this.twin, required this.loading, this.onChanged});

  final Animal animal;
  final Map<String, dynamic>? twin;
  final bool loading;

  /// Called after a record was saved, so the profile can refetch the twin.
  final VoidCallback? onChanged;

  @override
  Widget build(BuildContext context) {
    final raw = twin?['reproduction'];
    final summary = raw is Map ? ReproSummary.fromJson(raw.cast<String, dynamic>()) : null;
    if (!loading && (summary == null || !summary.applies.any)) return const SizedBox.shrink();
    final access = context.watch<AccessProvider>();
    final canRecord = animal.onFarm && (access.canCreate(FarmModule.animals) || access.canCreate(FarmModule.animalHealth));
    final canMilking = animal.onFarm && (access.canCreate(FarmModule.animals) || access.canCreate(FarmModule.milkProduction));
    final arabic = Localizations.localeOf(context).languageCode == 'ar';

    Future<void> run(Future<bool> Function() action) async {
      if (await action()) onChanged?.call();
    }

    return SectionCard(
      title: context.t('reproTitle'),
      subtitle: context.t('reproSubtitle'),
      trailing: summary != null ? context.t('reproActTimeline') : null,
      onTrailingTap: summary != null ? () => showReproTimelineSheet(context, animal) : null,
      child: loading || summary == null
          ? const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Center(child: SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))),
            )
          : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _status(context, summary),
              const SizedBox(height: FarmSpacing.sm),
              if (summary.lastBreeding != null)
                _line(context, context.t('reproLastService'),
                    '${context.t('breed_${summary.lastBreeding!.eventType}')} · ${_date(summary.lastBreeding!.occurredAt)}${summary.lastBreeding!.sire != null ? ' · ${summary.lastBreeding!.sire}' : ''}'),
              if (summary.lastCheck != null)
                _line(context, context.t('reproLastCheck'),
                    '${context.t('result_${summary.lastCheck!.resultCode}')} · ${context.t('check_${summary.lastCheck!.assessmentType}')} · ${_date(summary.lastCheck!.assessedAt)}'),
              if (summary.lastBirthAt != null)
                _line(context, '${context.t('reproLastBirth')} (${summary.birthTerm(arabic)})',
                    '${_date(summary.lastBirthAt)}${summary.lastBirthLive != null ? ' · ${summary.lastBirthLive} ${context.t('nb_LIVE')}' : ''}'),
              if (summary.applies.lactation) _lactationLine(context, summary),
              ..._calendarLines(context, summary),
              if (summary.lastBreeding == null && summary.lastCheck == null && summary.lastBirthAt == null && summary.lactation == null && !summary.pregnant)
                Text(context.t('reproNone'), style: FarmTypography.textTheme.bodySmall?.copyWith(color: FarmColors.muted)),
              if (canRecord || canMilking) ...[
                const SizedBox(height: FarmSpacing.sm),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  if (canRecord && summary.applies.breeding && !summary.pregnant)
                    _action(context, Icons.favorite_border, context.t('reproActBreeding'), () => run(() => showBreedingForm(context, animal))),
                  if (canRecord && summary.applies.pregnancy)
                    _action(context, Icons.fact_check_outlined, context.t('reproActCheck'), () => run(() => showPregnancyCheckForm(context, animal))),
                  if (canRecord && summary.applies.liveBirth)
                    _action(context, Icons.child_friendly_outlined, summary.birthTerm(arabic), () => run(() => showBirthForm(context, animal, summary))),
                  if (canRecord && summary.pregnant)
                    _action(context, Icons.heart_broken_outlined, context.t('reproActLoss'), () => run(() => showPregnancyLossForm(context, animal))),
                  if (canMilking && summary.applies.lactation && summary.lactation == null)
                    _action(context, Icons.water_drop_outlined, context.t('reproActStartMilking'), () => run(() => confirmLactationChange(context, animal, start: true))),
                  if (canMilking && summary.lactation != null)
                    _action(context, Icons.do_not_disturb_on_outlined, context.t('reproActDryOff'), () => run(() => confirmLactationChange(context, animal, start: false))),
                ]),
              ],
            ]),
    );
  }

  Widget _status(BuildContext context, ReproSummary s) {
    final p = s.pregnancy;
    if (s.pregnant && p != null) {
      final due = p.expectedDueDate != null ? ' · ${context.t('reproDue')} ${feedDate(p.expectedDueDate!)}' : '';
      final days = p.daysPregnant != null ? ' ${p.daysPregnant}' : '';
      return StatusPill(
        label: '${context.t('reproPregnantDay')}$days$due${p.overdue ? ' · ${context.t('reproOverdue')}' : ''}',
        level: p.overdue ? FarmStatusLevel.alert : FarmStatusLevel.good,
      );
    }
    if (s.awaitingCheck) return StatusPill(label: context.t('reproAwaitingCheck'), level: FarmStatusLevel.watch);
    if (s.inseminatedUnconfirmed) return StatusPill(label: context.t('stPreg_inseminated'), level: FarmStatusLevel.info);
    if (s.applies.pregnancy) return StatusPill(label: context.t('reproOpen'), level: FarmStatusLevel.neutral);
    return const SizedBox.shrink();
  }

  /// The calendar after the last calving, from the farm's settings: when
  /// to watch her milk peak, from when to inseminate, when to watch for a
  /// return to heat after a service.
  List<Widget> _calendarLines(BuildContext context, ReproSummary s) => [
        if (s.calvingAt != null)
          _line(context, context.t('calvingDate'),
              '${feedDate(s.calvingAt!)}${s.daysInMilk != null ? ' · ${context.t('reproDaysInMilk')} ${s.daysInMilk}' : ''}'),
        if (s.milkPeakFrom != null && s.lactation != null)
          _line(context, context.t('stMilkPeak'),
              '${feedDate(s.milkPeakFrom!)} – ${feedDate(s.milkPeakTo!)}${s.inMilkPeak ? ' · ${context.t('stNow')}' : ''}'),
        if (s.breedingFrom != null && !s.pregnant)
          _line(context, context.t('stInseminateFrom'),
              '${feedDate(s.breedingFrom!)}${s.readyForBreeding ? ' · ${context.t('stReadyToInseminate')}' : ''}'),
        if (s.heatWatchFrom != null)
          _line(context, context.t('stHeatWatch'),
              '${feedDate(s.heatWatchFrom!)} – ${feedDate(s.heatWatchTo!)}${s.heatWatchNow ? ' · ${context.t('stNow')}' : ''}'),
      ];

  Widget _lactationLine(BuildContext context, ReproSummary s) {
    final l = s.lactation;
    if (l == null) return _line(context, context.t('reproLactations'), context.t('reproDry'));
    final line = _line(context, context.t('reproLactations'),
        '${context.t('reproInMilk')} ${l.number ?? s.lactationNumber ?? '–'}${l.daysInMilk != null ? ' · ${l.daysInMilk} ${context.t('reproDaysInMilk')}' : ''}');
    final dryFrom = s.dryOffFrom;
    if (dryFrom == null) return line;
    // Pregnant and in milk: when milking stops, from the farm's setting.
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      line,
      _line(context, context.t('stDryOffDueOn'),
          '${feedDate(dryFrom)} (${s.dryOffDays} ${context.t('stDaysBefore')})${s.dryOffDue ? ' · ${context.t('stDryOffDue')}' : ''}'),
    ]);
  }
}

String _date(DateTime? d) => d == null ? '—' : feedDate(d);

Widget _line(BuildContext context, String label, String value) => Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 120, child: Text(label, style: const TextStyle(fontSize: 12, color: FarmColors.muted, fontWeight: FontWeight.w600))),
        Expanded(child: Text(value, style: const TextStyle(fontSize: 12.5, color: FarmColors.ink))),
      ]),
    );

Widget _action(BuildContext context, IconData icon, String label, VoidCallback onTap) =>
    OutlinedButton.icon(onPressed: onTap, icon: Icon(icon, size: 18), label: Text(label));

/// The animal's whole reproductive life, read from `/animals/{id}/reproduction`.
Future<void> showReproTimelineSheet(BuildContext context, Animal animal) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => FractionallySizedBox(heightFactor: 0.85, child: ReproTimelineView(animal: animal)),
    );

/// The reproductive record as a list: in its own sheet, or [embedded] in
/// the Reproduction tab of the animal's profile, where the page scrolls.
class ReproTimelineView extends StatefulWidget {
  const ReproTimelineView({super.key, required this.animal, this.embedded = false});
  final Animal animal;
  final bool embedded;

  @override
  State<ReproTimelineView> createState() => _ReproTimelineViewState();
}

class _ReproTimelineViewState extends State<ReproTimelineView> {
  late Future<ReproTimeline> _future = context.read<HerdRecordsProvider>().timeline(widget.animal.id);

  void _reload() => setState(() => _future = context.read<HerdRecordsProvider>().timeline(widget.animal.id));

  @override
  Widget build(BuildContext context) {
    final access = context.watch<AccessProvider>();
    final canRegister = access.canCreate(FarmModule.animals) || access.canCreate(FarmModule.animalHealth);
    return FutureBuilder<ReproTimeline>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Padding(padding: EdgeInsets.all(FarmSpacing.md), child: Center(child: CircularProgressIndicator()));
        }
        if (snap.hasError || snap.data == null) return Center(child: Text(context.t('twinLoadFailed')));
        final t = snap.data!;
        final arabic = Localizations.localeOf(context).languageCode == 'ar';
        final children = <Widget>[
          if (!widget.embedded) ...[
            Text('${context.t('reproTimelineTitle')} — ${widget.animal.name}', style: FarmTypography.textTheme.titleMedium),
            const SizedBox(height: FarmSpacing.sm),
          ],
          if (t.isEmpty) EmptyState(message: context.t('reproNone'), icon: FarmIcon.pregnancy, compact: true),
          if (t.births.isNotEmpty) ...[
            _heading('${context.t('reproBirths')} (${t.summary.birthTerm(arabic)})'),
            for (final b in t.births)
              _entry(
                '${_date(b.occurredAt)} · ${b.liveCount}/${b.offspringCount} ${context.t('nb_LIVE')} · ${context.t('assist_${b.assistanceCode}')}${b.sire != null ? ' · ${b.sire}' : ''}',
                children: [
                  for (final n in b.offspring)
                    Row(children: [
                      Expanded(
                        child: Text(
                          '#${n.sequenceNo} ${context.t('nb_${n.outcomeCode}')}'
                          '${n.sex != null ? ' · ${n.sex == 'F' ? context.t('female') : context.t('male')}' : ''}'
                          '${n.birthWeightKg != null ? ' · ${feedNumber(n.birthWeightKg!)} kg' : ''}'
                          '${n.animalName != null ? ' · ${n.animalName} #${n.animalTag ?? ''}' : n.groupName != null ? ' → ${n.groupName}' : n.registrable ? ' · ${context.t('reproNotRegistered')}' : ''}',
                          style: const TextStyle(fontSize: 12.5),
                        ),
                      ),
                      if (n.registrable && canRegister)
                        TextButton(
                          onPressed: () async {
                            if (await showRegisterNewbornForm(context, dam: widget.animal, birthId: b.id, newborn: n)) _reload();
                          },
                          child: Text(context.t('reproRegister')),
                        ),
                    ]),
                ],
              ),
          ],
          if (t.pregnancies.isNotEmpty) ...[
            _heading(context.t('reproPregnancies')),
            for (final p in t.pregnancies)
              _entry(p.active
                  ? '${context.t('reproPregnantDay')} ${p.daysPregnant ?? '–'}${p.expectedDueDate != null ? ' · ${context.t('reproDue')} ${feedDate(p.expectedDueDate!)}' : ''}'
                  : '${_date(p.conceivedAt)} → ${_date(p.endedAt)} · ${context.t('preg_${p.outcomeCode ?? 'BIRTH'}')}'),
          ],
          if (t.checks.isNotEmpty) ...[
            _heading(context.t('reproChecks')),
            for (final c in t.checks)
              _entry('${_date(c.assessedAt)} · ${context.t('result_${c.resultCode}')} · ${context.t('check_${c.assessmentType}')}${c.gestationDays != null ? ' · ${c.gestationDays}d' : ''}'),
          ],
          if (t.breedings.isNotEmpty) ...[
            _heading(context.t('reproBreedings')),
            for (final b in t.breedings)
              _entry(
                '${_date(b.occurredAt)} · ${context.t('breed_${b.eventType}')}${b.sire != null ? ' · ${b.sire}' : ''}${b.voided ? ' · ${context.t('reproVoided')}' : ''}',
                muted: b.voided,
              ),
          ],
          if (t.lactations.isNotEmpty) ...[
            _heading(context.t('reproLactations')),
            for (final l in t.lactations)
              _entry('#${l.number ?? '–'} · ${_date(l.startedAt)} → ${l.active ? '…' : _date(l.endedAt)} · ${l.daysInMilk ?? '–'} ${context.t('reproDaysInMilk')}'),
          ],
        ];
        if (widget.embedded) return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
        return ListView(padding: const EdgeInsets.fromLTRB(FarmSpacing.lg, 0, FarmSpacing.lg, FarmSpacing.lg), children: children);
      },
    );
  }

  Widget _heading(String text) => Padding(
        padding: const EdgeInsets.only(top: FarmSpacing.md, bottom: 4),
        child: Text(text, style: const TextStyle(fontWeight: FontWeight.w700, color: FarmColors.ink)),
      );

  Widget _entry(String text, {List<Widget> children = const [], bool muted = false}) => Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.all(FarmSpacing.sm),
        decoration: BoxDecoration(color: FarmColors.surfaceSoft, borderRadius: BorderRadius.circular(FarmRadii.sm)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(text, style: TextStyle(fontSize: 12.5, color: muted ? FarmColors.muted : FarmColors.ink, decoration: muted ? TextDecoration.lineThrough : null)),
          ...children,
        ]),
      );
}

/// The herd's reproduction day on the Animals screen (Vision: "Which cows,
/// goats or sheep are ready for breeding?"): who is pregnant and due soon,
/// who is waiting for a pregnancy check, how many are in milk, what is in
/// the incubator. Each name opens the animal.
class ReproOverviewCard extends StatelessWidget {
  const ReproOverviewCard({super.key, required this.onOpenAnimal});

  final void Function(String animalId) onOpenAnimal;

  @override
  Widget build(BuildContext context) {
    final o = context.watch<HerdRecordsProvider>().overview;
    if (o.isEmpty) return const SizedBox.shrink();
    final dueSoon = [for (final p in o.pregnant) if (p['due_soon'] == true) p];
    final dryOff = [for (final p in o.pregnant) if (p['dry_off_due'] == true) p];
    // The breeding and milk calendar: who to inseminate, who to watch for
    // heat, who is at her peak.
    String name(Map<String, dynamic> r) => r['name'] as String? ?? '';
    String stat(int n, String key) => '$n ${context.t(key)}';
    return SectionCard(
      title: context.t('reproOverviewTitle'),
      subtitle: [
        stat(o.pregnant.length, 'reproPregnantCount'),
        stat(o.dueSoon, 'reproDueSoon'),
        stat(o.awaitingCheck.length, 'reproAwaiting'),
        stat(o.inMilk, 'reproInMilkCount'),
        if (o.incubations.isNotEmpty) stat(o.incubations.length, 'reproIncubating'),
      ].join(' · '),
      child: Wrap(spacing: 6, runSpacing: 6, children: [
        for (final r in o.readyForBreeding)
          ActionChip(
            avatar: const Icon(Icons.favorite_border, size: 16, color: FarmColors.cedar),
            label: Text('${name(r)} · ${context.t('stReadyToInseminate')}'),
            onPressed: () => onOpenAnimal(r['animal_id'] as String),
          ),
        for (final r in o.heatWatch)
          ActionChip(
            avatar: const Icon(Icons.visibility_outlined, size: 16, color: FarmColors.warningInk),
            label: Text('${name(r)} · ${context.t('stHeatWatch')}'),
            onPressed: () => onOpenAnimal(r['animal_id'] as String),
          ),
        for (final r in o.inMilkPeak)
          ActionChip(
            avatar: const Icon(Icons.trending_up, size: 16, color: FarmColors.milkBlue),
            label: Text('${name(r)} · ${context.t('stMilkPeak')} · ${context.t('reproDaysInMilk')} ${r['days_in_milk'] ?? '–'}'),
            onPressed: () => onOpenAnimal(r['animal_id'] as String),
          ),
        for (final p in dryOff)
          ActionChip(
            avatar: const Icon(Icons.do_not_disturb_on_outlined, size: 16, color: FarmColors.warningInk),
            label: Text('${p['name']} · ${context.t('stDryOffDue')}'),
            onPressed: () => onOpenAnimal(p['animal_id'] as String),
          ),
        for (final p in dueSoon)
          ActionChip(
            avatar: const Icon(Icons.child_friendly_outlined, size: 16),
            label: Text('${p['name']} · ${(p['days_to_due'] as num?)?.toInt() ?? '–'}d'),
            onPressed: () => onOpenAnimal(p['animal_id'] as String),
          ),
        for (final a in o.awaitingCheck)
          ActionChip(
            avatar: const Icon(Icons.fact_check_outlined, size: 16),
            label: Text('${a['name']} · ${context.t('reproAwaiting')}'),
            onPressed: () => onOpenAnimal(a['animal_id'] as String),
          ),
        for (final b in o.incubations)
          Chip(avatar: const Icon(Icons.egg_outlined, size: 16), label: Text('${b.code} · ${context.t('incubHatchIn')} ${b.daysToHatch ?? '–'} ${context.t('incubDays')}')),
      ]),
    );
  }
}
