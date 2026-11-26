import 'package:flutter/material.dart';
import '../../api/api_client.dart';
import '../i18n/strings.dart';
import '../theme/colors.dart';

/// The navigator every farm screen lives under — the duplicate question is
/// asked over whichever form sent the write.
final rootNavigatorKey = GlobalKey<NavigatorState>();

/// Installs the one "Already recorded?" question for the whole app.
///
/// The server refuses a record that says what an existing one already says
/// (the same cow's morning milk, a delivery note typed in twice; a cow fed
/// with her group and on her own in one round) with "Possible duplicate:
/// …" (backend app/core/duplicates.py), naming the field that confirms it
/// and, when it wants to know why, the reason field. The person answers
/// here: *No* leaves nothing recorded twice and the form shows the server's
/// sentence; *Yes* resends that one request confirmed (with the reason),
/// and the server logs it as a confirmed repeat. Offline entries refused
/// this way get the same choice in the sync panel.
void installDuplicateConfirmation([GlobalKey<NavigatorState>? key]) {
  final navigator = key ?? rootNavigatorKey;
  ApiClient.confirmPossibleDuplicate = (refusal) async {
    final context = navigator.currentContext;
    if (context == null || !context.mounted) return null;
    final reason = await askConfirmation(context,
        detail: refusal.duplicateDetail, words: ConfirmationWords.forCode(refusal.code), needsReason: refusal.reasonField != null);
    return reason == null ? null : refusal.confirmation(reason);
  };
}

/// The words of a confirmation question, as string keys.
class ConfirmationWords {
  const ConfirmationWords({required this.title, required this.explainer, required this.record, required this.dontRecord, this.icon = Icons.content_copy_outlined});

  final String title;
  final String explainer;
  final String record;
  final String dontRecord;
  final IconData icon;

  /// The same record twice.
  static const duplicate = ConfirmationWords(title: 'dupTitle', explainer: 'dupExplainer', record: 'dupRecordAnyway', dontRecord: 'dupDontRecord');

  /// A head fed with her group and on her own in one round (`feeding_overlap`).
  static const feedingOverlap =
      ConfirmationWords(title: 'faTitle', explainer: 'faAskAnimal', record: 'faRecordExtra', dontRecord: 'faDontRecord', icon: Icons.grass);

  /// The same, asked of the group's feeding.
  static const feedingOverlapGroup =
      ConfirmationWords(title: 'faTitle', explainer: 'faAskGroup', record: 'faRecordExtra', dontRecord: 'faDontRecord', icon: Icons.grass);

  static ConfirmationWords forCode(String? code) => code == 'feeding_overlap' ? feedingOverlap : duplicate;
}

/// Asks [detail] in [words]. With [needsReason], recording waits for the
/// person to say why. The reason given ('' when none was asked), or null
/// when it is not to be recorded.
Future<String?> askConfirmation(BuildContext context, {required String detail, ConfirmationWords words = ConfirmationWords.duplicate, bool needsReason = false}) =>
    showDialog<String>(context: context, builder: (_) => _ConfirmationDialog(detail: detail, words: words, needsReason: needsReason));

class _ConfirmationDialog extends StatefulWidget {
  const _ConfirmationDialog({required this.detail, required this.words, required this.needsReason});
  final String detail;
  final ConfirmationWords words;
  final bool needsReason;

  @override
  State<_ConfirmationDialog> createState() => _ConfirmationDialogState();
}

class _ConfirmationDialogState extends State<_ConfirmationDialog> {
  final _reason = TextEditingController();

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final words = widget.words;
    final reason = _reason.text.trim();
    return AlertDialog(
      icon: Icon(words.icon, color: FarmColors.warning),
      title: Text(context.t(words.title)),
      content: SizedBox(
        width: 460,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(widget.detail, key: const ValueKey('confirmation-detail'), style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 10),
          Text(context.t(words.explainer), style: const TextStyle(fontSize: 13, color: FarmColors.muted)),
          if (widget.needsReason) ...[
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('confirmation-reason'),
              controller: _reason,
              maxLength: 300,
              autofocus: true,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(labelText: context.t('faReason'), helperText: context.t('faReasonHelp')),
            ),
          ],
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(context.t(words.dontRecord))),
        FilledButton(
          onPressed: widget.needsReason && reason.isEmpty ? null : () => Navigator.of(context).pop(reason),
          child: Text(context.t(words.record)),
        ),
      ],
    );
  }
}
