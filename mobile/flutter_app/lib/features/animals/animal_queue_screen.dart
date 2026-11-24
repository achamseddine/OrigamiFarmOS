import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/widgets/section_card.dart';
import '../../core/widgets/status_pill.dart';
import '../../core/widgets/ux_blocks.dart';
import '../../domain/entities/access.dart';
import '../../domain/entities/livestock.dart';
import '../../providers/access_provider.dart';
import '../../providers/animals_provider.dart';
import '../../providers/feeding_provider.dart';
import '../../providers/livestock_provider.dart';
import '../../providers/production_provider.dart';
import 'animal_quick_entry_screen.dart';
import 'animal_scan.dart' show milkSessionForHour;
import 'quick_round.dart';
import '../production/milk_sessions.dart';

/// The cow queue: today's milking or feeding round as an ordered list —
/// by tag number — with who is done and who is still to do.
///
/// A worker either **follows the queue** (the next cow opens, and after
/// each save the one after it) or **scans QR codes** in whatever order the
/// animals come; both record into the same round, so the list is the same
/// either way. Tapping a cow opens her entry; the queue goes on from there.
class AnimalQueueScreen extends StatefulWidget {
  const AnimalQueueScreen({super.key, this.initial});

  /// The round to open on; else the milking of this time of day (or the
  /// feeding round for someone who records feeding but not milk).
  final QuickRound? initial;

  @override
  State<AnimalQueueScreen> createState() => _AnimalQueueScreenState();
}

class _AnimalQueueScreenState extends State<AnimalQueueScreen> {
  late QuickRound _round = widget.initial ?? _defaultRound();

  QuickRound _defaultRound() {
    final access = context.read<AccessProvider>();
    if (!access.canCreate(FarmModule.milkProduction) && access.canCreate(FarmModule.feedNutrition)) return const QuickRound.feeding();
    return QuickRound.milking(milkSessionForHour(DateTime.now().hour));
  }

  bool _same(QuickRound a, QuickRound b) => a.kind == b.kind && a.session == b.session;

  void _open({String? animalId, bool camera = false}) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => AnimalQuickEntryScreen(
        initialAnimalId: animalId,
        round: _round,
        startWithCamera: camera,
        followQueue: !camera,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final access = context.watch<AccessProvider>();
    final animals = context.watch<AnimalsProvider>().animals;
    final livestock = context.watch<LivestockProvider>();
    final production = context.watch<ProductionProvider>();
    final feeding = context.watch<FeedingProvider>();
    final canMilk = access.canCreate(FarmModule.milkProduction);
    final canFeed = access.canCreate(FarmModule.feedNutrition);
    final status = roundStatus(
      _round,
      animals: animals,
      milked: (a) => livestock.resolve(species: a.species, sex: a.sex, lifeStage: a.lifeStage, managementProfile: a.managementProfile).has(Cap.milkProduction),
      milk: production.milkRecords,
      plan: feeding.dailyPlan,
      fedToday: feeding.fedToday,
    );
    final next = nextInQueue(status);
    final rounds = <(QuickRound, String)>[
      if (canMilk) (const QuickRound.milking('morning'), 'routineMilkMorning'),
      if (canMilk) (const QuickRound.milking('evening'), 'routineMilkEvening'),
      if (canFeed) (const QuickRound.feeding(), 'queueFeedingRound'),
    ];

    return Scaffold(
      backgroundColor: FarmColors.stone,
      appBar: AppBar(backgroundColor: FarmColors.stone, title: Text(context.t('queueTitle'))),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 820),
            child: ListView(
              padding: const EdgeInsets.all(FarmSpacing.md),
              children: [
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final (r, label) in rounds)
                    ChoiceChip(
                      key: ValueKey('queue-round-$label'),
                      label: Text(label == 'routineMilkEvening' ? milkingRoundLabel(context, 'evening') : context.t(label)),
                      selected: _same(r, _round),
                      onSelected: (_) => setState(() => _round = r),
                    ),
                ]),
                const SizedBox(height: FarmSpacing.md),
                SectionCard(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Row(children: [
                      Expanded(
                        child: Text(
                          status.total == 0
                              ? context.t('queueEmpty')
                              : '${status.done} ${context.t('regOf')} ${status.total} ${context.t('routineDone')}',
                          style: FarmTypography.textTheme.titleMedium,
                        ),
                      ),
                      if (status.complete) StatusPill(label: context.t('queueAllDone'), level: FarmStatusLevel.good),
                    ]),
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: LinearProgressIndicator(
                        value: status.total == 0 ? 0 : status.done / status.total,
                        minHeight: 10,
                        backgroundColor: FarmColors.sand,
                        color: FarmColors.cedar,
                      ),
                    ),
                    const SizedBox(height: FarmSpacing.md),
                    Text(context.t('queueHowTo'), style: FarmTypography.textTheme.bodySmall),
                    const SizedBox(height: FarmSpacing.sm),
                    LayoutBuilder(builder: (context, c) {
                      final follow = FilledButton.icon(
                        key: const ValueKey('queue-follow'),
                        style: FilledButton.styleFrom(minimumSize: const Size(0, kFarmPrimaryTarget), backgroundColor: FarmColors.cedarDark),
                        onPressed: next == null ? null : () => _open(animalId: next.id),
                        icon: const Icon(Icons.format_list_numbered),
                        label: Text(next == null ? context.t('queueFollow') : '${context.t('queueFollow')} · ${next.name}'),
                      );
                      final scan = OutlinedButton.icon(
                        key: const ValueKey('queue-scan'),
                        style: OutlinedButton.styleFrom(minimumSize: const Size(0, kFarmPrimaryTarget)),
                        onPressed: status.total == 0 ? null : () => _open(camera: true),
                        icon: const Icon(Icons.qr_code_scanner),
                        label: Text(context.t('queueScan')),
                      );
                      if (c.maxWidth < 560) {
                        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [follow, const SizedBox(height: 8), scan]);
                      }
                      return Row(children: [Expanded(child: follow), const SizedBox(width: 12), Expanded(child: scan)]);
                    }),
                  ]),
                ),
                const SizedBox(height: FarmSpacing.md),
                if (status.total == 0)
                  SectionCard(
                    child: EmptyState(
                      message: context.t('queueEmpty'),
                      detail: context.t(_round.kind == RoundKind.milking ? 'queueEmptyMilking' : 'queueEmptyFeeding'),
                    ),
                  )
                else
                  SectionCard(
                    title: context.t('queueInOrder'),
                    child: Column(children: [
                      for (var i = 0; i < status.entries.length; i++)
                        _QueueRow(
                          number: i + 1,
                          entry: status.entries[i],
                          next: status.entries[i].animal.id == next?.id,
                          onTap: () => _open(animalId: status.entries[i].animal.id),
                        ),
                    ]),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _QueueRow extends StatelessWidget {
  const _QueueRow({required this.number, required this.entry, required this.next, required this.onTap});
  final int number;
  final RoundEntry entry;
  final bool next;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final a = entry.animal;
    return InkWell(
      key: ValueKey('queue-row-${a.id}'),
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        constraints: const BoxConstraints(minHeight: kFarmTouchTarget),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        decoration: next ? BoxDecoration(color: FarmColors.tint(FarmColors.cedar, 0.08), borderRadius: BorderRadius.circular(10)) : null,
        child: Row(children: [
          SizedBox(
            width: 32,
            child: Text('$number', style: FarmTypography.textTheme.labelMedium?.copyWith(color: FarmColors.muted)),
          ),
          Expanded(
            child: Text(
              [if (a.tag != null && a.tag!.isNotEmpty) a.tag!, a.name].join(' · '),
              style: FarmTypography.textTheme.titleSmall?.copyWith(decoration: entry.done ? TextDecoration.lineThrough : null),
            ),
          ),
          if (next) ...[
            StatusPill(label: context.t('queueNext'), level: FarmStatusLevel.info, dense: true),
            const SizedBox(width: 6),
          ],
          StatusPill(
            label: context.t(entry.done ? 'queueDone' : 'queueToDo'),
            level: entry.done ? FarmStatusLevel.good : FarmStatusLevel.watch,
            dense: true,
          ),
        ]),
      ),
    );
  }
}
