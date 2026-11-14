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
/// (the same cow's morning milk, a delivery note typed in twice) with
/// "Possible duplicate: …" (backend app/core/duplicates.py). The person
/// answers here: *No* leaves nothing recorded twice and the form shows the
/// server's sentence; *Yes* resends that one request confirmed, and the
/// server logs it as a confirmed repeat. Offline entries refused this way
/// get the same choice in the sync panel.
void installDuplicateConfirmation([GlobalKey<NavigatorState>? key]) {
  final navigator = key ?? rootNavigatorKey;
  ApiClient.confirmPossibleDuplicate = (detail) async {
    final context = navigator.currentContext;
    if (context == null || !context.mounted) return false;
    final answer = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        icon: const Icon(Icons.content_copy_outlined, color: FarmColors.warning),
        title: Text(dialog.t('dupTitle')),
        content: SizedBox(
          width: 460,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(detail, style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 10),
            Text(dialog.t('dupExplainer'), style: const TextStyle(fontSize: 13, color: FarmColors.muted)),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialog).pop(false), child: Text(dialog.t('dupDontRecord'))),
          FilledButton(onPressed: () => Navigator.of(dialog).pop(true), child: Text(dialog.t('dupRecordAnyway'))),
        ],
      ),
    );
    return answer == true;
  };
}
