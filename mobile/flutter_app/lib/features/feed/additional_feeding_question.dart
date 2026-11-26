import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/widgets/duplicate_confirmation.dart';
import '../../domain/entities/feeding_overlap.dart';
import '../../providers/animals_provider.dart';
import '../../providers/feeding_provider.dart';

/// Installs the app's one "Fed already this round?" question (v0.8.7,
/// audit I-12), asked in the person's language before a feeding that
/// overlaps another of the same round is sent — the feeding form, the
/// quick entry, the cow queue and My Day all record through
/// [FeedingProvider.recordFeeding]. *Record as additional feeding* sends it
/// with `confirm_additional_feeding: true` (the server audits who said
/// so); *Don't record* sends nothing.
void installAdditionalFeedingQuestion([GlobalKey<NavigatorState>? key]) {
  final navigator = key ?? rootNavigatorKey;
  FeedingProvider.confirmAdditionalFeeding = (overlap) async {
    final context = navigator.currentContext;
    // No screen to ask over: send it unconfirmed and let the server ask.
    if (context == null || !context.mounted) return null;
    final notRecorded = context.t('faNotRecorded');
    final answer = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        icon: const Icon(Icons.grass, color: FarmColors.warning),
        title: Text(dialog.t('faTitle')),
        content: SizedBox(
          width: 460,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(additionalFeedingSentence(dialog, overlap), key: const ValueKey('additional-feeding-detail'),
                style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 10),
            Text(dialog.t(overlap.kind == FeedingOverlapKind.animalAfterGroup ? 'faAskAnimal' : 'faAskGroup'),
                style: const TextStyle(fontSize: 13, color: FarmColors.muted)),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialog).pop(false), child: Text(dialog.t('faDontRecord'))),
          FilledButton(onPressed: () => Navigator.of(dialog).pop(true), child: Text(dialog.t('faRecordExtra'))),
        ],
      ),
    );
    return (confirmed: answer == true, message: notRecorded);
  };
}

/// "Bella is fed with Dairy Herd's ration, and Dairy Herd was given Dairy
/// Mix 24L at 06:00." — or the group's side of it.
String additionalFeedingSentence(BuildContext context, FeedingOverlap overlap) {
  final animals = context.read<AnimalsProvider>();
  final feeding = context.read<FeedingProvider>();
  final names = [for (final id in overlap.animalIds) animals.find(id)?.name ?? id].join(', ');
  final feeds = [for (final id in overlap.productIds) feeding.productById(id)?.name ?? id].join(', ');
  final t = overlap.other.occurredAt.toLocal();
  final time = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  final key = overlap.kind == FeedingOverlapKind.animalAfterGroup ? 'faAnimalAfterGroup' : 'faGroupAfterAnimal';
  return context
      .t(key)
      .replaceAll('{animal}', names)
      .replaceAll('{animals}', names)
      .replaceAll('{group}', overlap.groupName)
      .replaceAll('{feeds}', feeds)
      .replaceAll('{time}', time)
      .replaceAll('{heads}', '${overlap.heads}');
}
