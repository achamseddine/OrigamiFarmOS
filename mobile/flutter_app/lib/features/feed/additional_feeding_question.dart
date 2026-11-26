import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/i18n/strings.dart';
import '../../core/widgets/duplicate_confirmation.dart';
import '../../domain/entities/feeding_overlap.dart';
import '../../providers/animals_provider.dart';
import '../../providers/feeding_provider.dart';

/// Installs "Fed already this round?" for a feeding this device sees
/// overlapping another of the same round (v0.8.7, audit I-12): asked in the
/// person's language before it is sent, also offline, with the reason it is
/// extra required ([FeedingProvider.askAdditionalFeeding]). An overlap only
/// the server can see comes back as its 409 and is asked by the same dialog
/// (core/widgets/duplicate_confirmation.dart).
void installAdditionalFeedingQuestion([GlobalKey<NavigatorState>? key]) {
  final navigator = key ?? rootNavigatorKey;
  FeedingProvider.askAdditionalFeeding = (overlap) async {
    final context = navigator.currentContext;
    // No screen to ask over: send it unconfirmed and let the server ask.
    if (context == null || !context.mounted) return null;
    final notRecorded = context.t('faNotRecorded');
    final reason = await askConfirmation(
      context,
      detail: additionalFeedingSentence(context, overlap),
      words: overlap.kind == FeedingOverlapKind.groupAfterAnimal ? ConfirmationWords.feedingOverlapGroup : ConfirmationWords.feedingOverlap,
      needsReason: true,
    );
    return (reason: reason, message: notRecorded);
  };
}

/// "Bella is fed with Dairy Herd's ration, and Dairy Herd was given Dairy
/// Mix 24L at 06:00." — or the group's side of it.
String additionalFeedingSentence(BuildContext context, FeedingOverlap overlap) {
  final lang = Localizations.localeOf(context).languageCode;
  final animals = context.read<AnimalsProvider>();
  final feeding = context.read<FeedingProvider>();
  final names = [for (final id in overlap.animalIds) animals.find(id)?.name ?? id].join(', ');
  final feeds = [for (final id in overlap.productIds) feeding.productName(id, lang)].join(', ');
  final key = overlap.kind == FeedingOverlapKind.animalAfterGroup ? 'faAnimalAfterGroup' : 'faGroupAfterAnimal';
  return context
      .t(key)
      .replaceAll('{animal}', names)
      .replaceAll('{animals}', names)
      .replaceAll('{group}', overlap.groupName)
      .replaceAll('{feeds}', feeds)
      .replaceAll('{time}', TimeOfDay.fromDateTime(overlap.other.occurredAt.toLocal()).format(context))
      .replaceAll('{heads}', '${overlap.heads}');
}
