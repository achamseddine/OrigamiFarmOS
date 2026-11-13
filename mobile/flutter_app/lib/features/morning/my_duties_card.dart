import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/widgets/section_card.dart';
import '../../core/widgets/status_pill.dart';
import '../../domain/entities/responsibility.dart';
import '../../providers/employees_provider.dart';
import '../../providers/feeding_provider.dart';
import '../../providers/production_provider.dart';
import '../animals/animal_digital_twin_screen.dart';
import '../animals/animal_quick_entry_screen.dart';
import '../feed/feeding_event_dialog.dart';

/// My Day for whoever looks after animals: the groups and animals they are
/// responsible for, their duties there, and what is already recorded today
/// — milked, fed — counted from today's records, never ticked by hand.
class MyDutiesCard extends StatefulWidget {
  const MyDutiesCard({super.key});

  @override
  State<MyDutiesCard> createState() => _MyDutiesCardState();
}

class _MyDutiesCardState extends State<MyDutiesCard> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<EmployeesProvider>().loadMine();
    });
  }

  @override
  Widget build(BuildContext context) {
    final mine = context.watch<EmployeesProvider>().mine.where((r) => r.active).toList();
    if (mine.isEmpty) return const SizedBox.shrink();
    final production = context.watch<ProductionProvider>();
    final feeding = context.watch<FeedingProvider>();
    final now = DateTime.now();
    bool today(DateTime d) {
      final l = d.toLocal();
      return l.year == now.year && l.month == now.month && l.day == now.day;
    }

    final milkedToday = {for (final m in production.milkRecords) if (today(m.recordedAt)) m.animalId};
    return Padding(
      padding: const EdgeInsets.only(bottom: FarmSpacing.md),
      child: SectionCard(
        title: context.t('mdTitle'),
        subtitle: context.t('mdSubtitle'),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (final r in mine) _row(context, r, milkedToday, feeding),
        ]),
      ),
    );
  }

  Widget _row(BuildContext context, WorkResponsibility r, Set<String> milkedToday, FeedingProvider feeding) {
    final milking = r.duties.contains('milking');
    final feedingDuty = r.duties.contains('feeding');
    final inMilk = [for (final a in r.animals) if (a.lactating) a];
    final milked = inMilk.where((a) => milkedToday.contains(a.id)).length;
    final groupFed = r.scopeType == 'group' && feeding.fedToday(r.scopeId).isNotEmpty;
    final fed = r.animals.where((a) => feeding.fedToday(a.id).isNotEmpty).length;
    return Container(
      margin: const EdgeInsets.only(bottom: FarmSpacing.sm),
      padding: const EdgeInsets.all(FarmSpacing.sm),
      decoration: BoxDecoration(color: FarmColors.surfaceSoft, borderRadius: BorderRadius.circular(FarmRadii.sm)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(r.scopeName, style: FarmTypography.textTheme.titleSmall)),
          Text('${r.animals.length} ${context.t('mdAnimals')}', style: FarmTypography.textTheme.bodySmall),
        ]),
        const SizedBox(height: 6),
        Wrap(spacing: 6, runSpacing: 6, children: [
          if (milking)
            StatusPill(
              label: '${context.t('wrDuty_milking')} · $milked/${inMilk.length}',
              level: inMilk.isNotEmpty && milked >= inMilk.length ? FarmStatusLevel.good : FarmStatusLevel.watch,
              dense: true,
            ),
          if (feedingDuty)
            StatusPill(
              label: '${context.t('wrDuty_feeding')} · ${groupFed ? context.t('mdGroupFed') : '$fed/${r.animals.length}'}',
              level: groupFed || (r.animals.isNotEmpty && fed >= r.animals.length) ? FarmStatusLevel.good : FarmStatusLevel.watch,
              dense: true,
            ),
          for (final d in r.duties)
            if (d != 'milking' && d != 'feeding') StatusPill(label: context.t('wrDuty_$d'), level: FarmStatusLevel.info, dense: true),
        ]),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 6, children: [
          if (r.scopeType != 'field')
            FilledButton.tonalIcon(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AnimalQuickEntryScreen(startWithCamera: true))),
              icon: const Icon(Icons.qr_code_scanner, size: 16),
              label: Text(context.t('mdScanRecord')),
            ),
          if (feedingDuty && r.scopeType == 'group')
            OutlinedButton.icon(
              onPressed: () => showFeedingEventDialog(context, subjectType: 'group', subjectId: r.scopeId, subjectName: r.scopeName, headCount: r.animals.length),
              icon: const Icon(Icons.grass, size: 16),
              label: Text(context.t('mdFeedGroup')),
            ),
        ]),
        if (r.animals.isNotEmpty) ...[
          const SizedBox(height: 6),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final a in r.animals.take(24))
              ActionChip(
                avatar: Icon(milkedToday.contains(a.id) ? Icons.check_circle : Icons.circle_outlined, size: 16,
                    color: milkedToday.contains(a.id) ? FarmColors.success : FarmColors.muted),
                label: Text(a.name),
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => AnimalDigitalTwinScreen(animalId: a.id))),
              ),
          ]),
        ],
      ]),
    );
  }
}
