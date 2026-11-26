import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/widgets/duplicate_confirmation.dart';
import '../../domain/entities/feeding_overlap.dart';
import '../../providers/animals_provider.dart';
import '../../providers/feeding_provider.dart';

/// Installs the app's one "Fed already this round?" question (v0.8.7,
/// audit I-12, Session 01), asked in the person's language before a
/// feeding that overlaps another of the same round is recorded — the
/// feeding form, the quick entry, the cow queue and My Day all record
/// through [FeedingProvider.recordFeeding]. *Record as additional feeding*
/// needs the reason (it goes with `additional_feeding_reason`, kept on the
/// record); *Don't record* sends nothing.
void installAdditionalFeedingQuestion([GlobalKey<NavigatorState>? key]) {
  final navigator = key ?? rootNavigatorKey;
  FeedingProvider.confirmAdditionalFeeding = ({FeedingOverlap? overlap, String? serverDetail}) async {
    final context = navigator.currentContext;
    // No screen to ask over: send it unconfirmed and let the server ask.
    if (context == null || !context.mounted) return null;
    final notRecorded = context.t('faNotRecorded');
    final reason = await askAdditionalFeedingReason(context, overlap: overlap, serverDetail: serverDetail);
    return (confirmed: reason != null, reason: reason ?? '', message: notRecorded);
  };
}

/// The question itself: the reason typed when the person records it as an
/// additional feeding, null when they do not. Also used by the sync panel
/// for a queued feeding the server asked about.
Future<String?> askAdditionalFeedingReason(BuildContext context, {FeedingOverlap? overlap, String? serverDetail}) =>
    showDialog<String>(context: context, builder: (_) => _AdditionalFeedingDialog(overlap: overlap, serverDetail: serverDetail));

class _AdditionalFeedingDialog extends StatefulWidget {
  const _AdditionalFeedingDialog({this.overlap, this.serverDetail});
  final FeedingOverlap? overlap;
  final String? serverDetail;

  @override
  State<_AdditionalFeedingDialog> createState() => _AdditionalFeedingDialogState();
}

class _AdditionalFeedingDialogState extends State<_AdditionalFeedingDialog> {
  final _reason = TextEditingController();

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final overlap = widget.overlap;
    final detail = overlap != null ? additionalFeedingSentence(context, overlap) : (widget.serverDetail ?? '');
    final groupSide = overlap?.kind == FeedingOverlapKind.groupAfterAnimal;
    final canRecord = _reason.text.trim().isNotEmpty;
    return AlertDialog(
      icon: const Icon(Icons.grass, color: FarmColors.warning),
      title: Text(context.t('faTitle')),
      content: SizedBox(
        width: 460,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(detail, key: const ValueKey('additional-feeding-detail'), style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 10),
          Text(context.t(groupSide ? 'faAskGroup' : 'faAskAnimal'), style: const TextStyle(fontSize: 13, color: FarmColors.muted)),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('additional-feeding-reason'),
            controller: _reason,
            maxLength: 300,
            autofocus: true,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(labelText: context.t('faReason'), helperText: context.t('faReasonHelp')),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(context.t('faDontRecord'))),
        FilledButton(
          onPressed: canRecord ? () => Navigator.of(context).pop(_reason.text.trim()) : null,
          child: Text(context.t('faRecordExtra')),
        ),
      ],
    );
  }
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
