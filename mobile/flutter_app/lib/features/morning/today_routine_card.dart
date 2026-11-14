import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../app/app_navigator.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/widgets/app_icon.dart';
import '../../core/widgets/section_card.dart';
import '../../core/widgets/ux_blocks.dart';
import '../../domain/entities/access.dart';
import '../../domain/entities/animal.dart';
import '../../domain/entities/feeding.dart';
import '../../domain/entities/livestock.dart';
import '../../domain/entities/production_records.dart';
import '../../providers/access_provider.dart';
import '../../providers/animals_provider.dart';
import '../../providers/feeding_provider.dart';
import '../../providers/livestock_provider.dart';
import '../../providers/production_provider.dart';
import '../animals/animal_quick_entry_screen.dart';
import '../animals/quick_round.dart';
import '../feed/feeding_event_dialog.dart';

/// The husbandry routine of the day (V3 prototype, "My Day"): the
/// milkings, the feeding rounds and the egg collection, each ticked off
/// from what has actually been recorded today — never by hand, so the
/// checklist cannot say a round was done when nobody recorded it.
///
/// Where the prototype printed fixed clock times (06:00, 11:30, 18:00),
/// this uses what the farm's own data says: the milking sessions the
/// tablet records, and each feeding program's feedings per day.
enum RoutineKind { milking, feeding, eggs }

class RoutineCheck {
  const RoutineCheck({required this.kind, required this.key, required this.name, required this.done, required this.total, this.line});
  final RoutineKind kind;

  /// The milking session ("morning"/"evening"), or the subject's id.
  final String key;

  /// The group or flock it is for (empty for a milking session).
  final String name;
  final int done;
  final int total;

  /// The plan line a feeding round comes from — what the record form is
  /// prefilled with.
  final DailyPlanLine? line;

  bool get complete => total > 0 && done >= total;
  bool get started => done > 0;
}

/// The key of the one routine line that stands for every animal fed on a
/// program of its own.
const kIndividualFeeding = 'individual-animals';

bool _isToday(DateTime t, DateTime now) {
  final l = t.toLocal();
  return l.year == now.year && l.month == now.month && l.day == now.day;
}

/// Today's routine from today's records. [milked] says whether an animal
/// is milked at all (its resolved capabilities), so a lactating ewe on a
/// meat farm is not counted as a milking that was missed.
List<RoutineCheck> computeRoutine({
  required List<Animal> animals,
  required bool Function(Animal) milked,
  required List<MilkRecord> milk,
  required DailyPlan plan,
  required List<FeedingEvent> Function(String subjectId) fedToday,
  required List<EggRecord> eggs,
  required String Function(String flockId) flockName,
  DateTime? now,
}) {
  final today = now ?? DateTime.now();
  final inMilk = {for (final a in animals) if (a.onFarm && a.lactating && milked(a)) a.id};
  final checks = <RoutineCheck>[];
  if (inMilk.isNotEmpty) {
    for (final session in const ['morning', 'evening']) {
      final done = {for (final r in milk) if (r.session == session && _isToday(r.recordedAt, today) && inMilk.contains(r.animalId)) r.animalId};
      checks.add(RoutineCheck(kind: RoutineKind.milking, key: session, name: '', done: done.length, total: inMilk.length));
    }
  }
  // Herds and flocks are a round each; animals on a program of their own
  // are one line together, so a farm with forty individually fed horses
  // still reads its morning at a glance.
  var soloCount = 0, soloDone = 0, soloTotal = 0;
  for (final line in plan.lines) {
    final program = line.program;
    if (program == null) continue;
    final rounds = program.feedingsPerDay < 1 ? 1 : program.feedingsPerDay;
    final fed = fedToday(line.subjectId).length;
    final done = fed > rounds ? rounds : fed;
    if (line.subjectType == 'animal') {
      soloCount++;
      soloDone += done;
      soloTotal += rounds;
      continue;
    }
    checks.add(RoutineCheck(kind: RoutineKind.feeding, key: line.subjectId, name: line.name, done: done, total: rounds, line: line));
  }
  if (soloCount > 0) {
    checks.add(RoutineCheck(kind: RoutineKind.feeding, key: kIndividualFeeding, name: '$soloCount', done: soloDone, total: soloTotal));
  }
  // A flock whose eggs were collected this week is a flock to collect
  // from today.
  final weekAgo = today.subtract(const Duration(days: 7));
  final flocks = <String>{for (final e in eggs) if (e.recordedAt.isAfter(weekAgo)) e.flockId};
  for (final flock in flocks) {
    final done = eggs.any((e) => e.flockId == flock && _isToday(e.recordedAt, today));
    checks.add(RoutineCheck(kind: RoutineKind.eggs, key: flock, name: flockName(flock), done: done ? 1 : 0, total: 1));
  }
  return checks;
}

class TodayRoutineCard extends StatelessWidget {
  const TodayRoutineCard({super.key});

  @override
  Widget build(BuildContext context) {
    final animals = context.watch<AnimalsProvider>().animals;
    final livestock = context.watch<LivestockProvider>();
    final production = context.watch<ProductionProvider>();
    final feeding = context.watch<FeedingProvider>();
    final access = context.watch<AccessProvider>();
    final checks = computeRoutine(
      animals: animals,
      milked: (a) => livestock.resolve(species: a.species, sex: a.sex, lifeStage: a.lifeStage, managementProfile: a.managementProfile).has(Cap.milkProduction),
      milk: production.milkRecords,
      plan: feeding.dailyPlan,
      fedToday: feeding.fedToday,
      eggs: production.eggRecords,
      flockName: (id) {
        for (final g in livestock.groups) {
          if (g.id == id) return g.name;
        }
        return id;
      },
    );
    final complete = checks.where((c) => c.complete).length;

    return SectionCard(
      title: context.t('routineTitle'),
      subtitle: context.t('routineSubtitle'),
      child: checks.isEmpty
          ? EmptyState(message: context.t('routineEmpty'), icon: FarmIcon.check, compact: true)
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(children: [
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(FarmRadii.pill),
                      child: LinearProgressIndicator(
                        value: checks.isEmpty ? 0 : complete / checks.length,
                        minHeight: 8,
                        backgroundColor: FarmColors.sand,
                        color: FarmColors.cedar,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text('$complete ${context.t('regOf')} ${checks.length} ${context.t('routineDone')}', style: FarmTypography.textTheme.labelMedium),
                ]),
                const SizedBox(height: FarmSpacing.sm),
                for (final c in checks) _RoutineRow(check: c, onRecord: _actionFor(context, c, access)),
              ],
            ),
    );
  }

  VoidCallback? _actionFor(BuildContext context, RoutineCheck c, AccessProvider access) {
    if (c.complete) return null;
    switch (c.kind) {
      case RoutineKind.milking:
        if (!access.canCreate(FarmModule.milkProduction)) return null;
        // The round, scan by scan, with who is left on screen.
        return () => Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => AnimalQuickEntryScreen(round: QuickRound.milking(c.key), startWithCamera: true),
            ));
      case RoutineKind.eggs:
        if (!access.canCreate(FarmModule.eggProduction)) return null;
        return () => context.read<AppNavigator>().goToModule(FarmModule.eggProduction);
      case RoutineKind.feeding:
        if (!access.canCreate(FarmModule.feedNutrition)) return null;
        final line = c.line;
        if (line == null) {
          return () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => const AnimalQuickEntryScreen(round: QuickRound.feeding(), startWithCamera: true),
              ));
        }
        final rounds = line.program?.feedingsPerDay ?? 1;
        return () => showFeedingEventDialog(
              context,
              subjectType: line.subjectType,
              subjectId: line.subjectId,
              subjectName: line.name,
              initialLines: line.dailyTargets.isEmpty ? null : linesFromTargets(line.dailyTargets, fraction: rounds <= 1 ? 1 : 1 / rounds),
            );
    }
  }
}

class _RoutineRow extends StatelessWidget {
  const _RoutineRow({required this.check, this.onRecord});
  final RoutineCheck check;
  final VoidCallback? onRecord;

  @override
  Widget build(BuildContext context) {
    final (icon, title) = switch (check.kind) {
      RoutineKind.milking => (FarmIcon.milkBottle, check.key == 'morning' ? context.t('routineMilkMorning') : context.t('routineMilkEvening')),
      RoutineKind.feeding => (
          FarmIcon.feedBag,
          check.key == kIndividualFeeding ? '${context.t('routineFeeding')} · ${context.t('routineIndividual')} (${check.name})' : '${context.t('routineFeeding')} · ${check.name}'
        ),
      RoutineKind.eggs => (FarmIcon.egg, '${context.t('routineEggs')} · ${check.name}'),
    };
    final detail = switch (check.kind) {
      RoutineKind.milking => '${check.done} ${context.t('regOf')} ${check.total} ${context.t('routineAnimalsRecorded')}',
      RoutineKind.feeding => '${check.done} ${context.t('regOf')} ${check.total} ${context.t('routineRounds')}',
      RoutineKind.eggs => check.complete ? context.t('routineCollected') : context.t('routineNotYet'),
    };
    final mark = check.complete
        ? const Icon(Icons.check_circle, color: FarmColors.success, size: 22)
        : check.started
            ? const Icon(Icons.timelapse, color: FarmColors.warning, size: 22)
            : const Icon(Icons.radio_button_unchecked, color: FarmColors.muted, size: 22);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: FarmColors.border))),
      child: Row(children: [
        mark,
        const SizedBox(width: 10),
        AppIcon(icon, size: 18, color: FarmColors.cedar),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: FarmTypography.textTheme.titleSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
            Text(detail, style: FarmTypography.textTheme.bodySmall),
          ]),
        ),
        if (onRecord != null) FilledButton.tonal(onPressed: onRecord, child: Text(context.t('twRecord'))),
      ]),
    );
  }
}
