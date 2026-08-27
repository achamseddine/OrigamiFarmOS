import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/widgets/app_icon.dart';
import '../../core/widgets/status_pill.dart';
import '../../data/local/local_store.dart';
import '../../providers/access_provider.dart';
import '../../sync/sync_controller.dart';

/// Everything the tablet is still holding, and why.
///
/// Opens as a right-side sheet, same as the notification panel, so the
/// screen underneath stays visible. Nothing here is hidden: a record the
/// server rejected is shown with the server's own words and kept until a
/// person decides what to do with it.
void showSyncPanel(BuildContext context) {
  showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: context.t('syncStatus'),
    barrierColor: FarmColors.ink.withOpacity(0.25),
    transitionDuration: const Duration(milliseconds: 180),
    pageBuilder: (_, __, ___) => const _SyncPanel(),
    transitionBuilder: (context, animation, _, child) {
      final rtl = Directionality.of(context) == TextDirection.rtl;
      return SlideTransition(
        position: Tween<Offset>(begin: Offset(rtl ? -1 : 1, 0), end: Offset.zero)
            .animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
        child: child,
      );
    },
  );
}

class _SyncPanel extends StatefulWidget {
  const _SyncPanel();

  @override
  State<_SyncPanel> createState() => _SyncPanelState();
}

class _SyncPanelState extends State<_SyncPanel> {
  late Future<List<OutboxItem>> _items = context.read<SyncController>().queuedItems();

  void _reload() => setState(() => _items = context.read<SyncController>().queuedItems());

  @override
  Widget build(BuildContext context) {
    final sync = context.watch<SyncController>();

    return Align(
      alignment: AlignmentDirectional.centerEnd,
      child: Material(
        color: FarmColors.stone,
        child: SizedBox(
          width: 430,
          height: double.infinity,
          child: SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Header(sync: sync, onClose: () => Navigator.of(context).pop()),
                const Divider(height: 1, color: FarmColors.border),
                Expanded(
                  child: FutureBuilder<List<OutboxItem>>(
                    future: _items,
                    builder: (context, snapshot) {
                      if (snapshot.connectionState != ConnectionState.done) {
                        return const Center(child: CircularProgressIndicator());
                      }
                      final items = snapshot.data ?? const <OutboxItem>[];
                      if (items.isEmpty) return _EmptyQueue(sync: sync);
                      return ListView.separated(
                        padding: const EdgeInsets.all(FarmSpacing.md),
                        itemCount: items.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (context, i) => _QueuedRow(
                          item: items[i],
                          onChanged: _reload,
                        ),
                      );
                    },
                  ),
                ),
                const Divider(height: 1, color: FarmColors.border),
                Padding(
                  padding: const EdgeInsets.all(FarmSpacing.md),
                  child: Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: sync.syncing
                              ? null
                              : () async {
                                  await sync.syncNow();
                                  if (context.mounted) _reload();
                                },
                          icon: const Icon(Icons.sync, size: 18),
                          label: Text(sync.syncing ? context.t('syncing') : context.t('syncNow')),
                          style: FilledButton.styleFrom(minimumSize: const Size(0, kFarmTouchTarget)),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.sync, required this.onClose});
  final SyncController sync;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final (level, text) = switch (sync.badge) {
      SyncBadge.offline => (FarmStatusLevel.neutral, context.t('offline')),
      SyncBadge.syncing => (FarmStatusLevel.info, context.t('syncing')),
      SyncBadge.attention => (FarmStatusLevel.alert, context.t('syncNeedsAttention')),
      SyncBadge.pending => (FarmStatusLevel.watch, context.t('waitingToSync')),
      SyncBadge.synced || SyncBadge.disabled => (FarmStatusLevel.good, context.t('synced')),
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(FarmSpacing.md, FarmSpacing.md, FarmSpacing.sm, FarmSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const AppIcon(FarmIcon.cloudSync, size: 20, color: FarmColors.cedar),
              const SizedBox(width: 10),
              Expanded(child: Text(context.t('syncStatus'), style: FarmTypography.display(size: 19))),
              IconButton(onPressed: onClose, icon: const Icon(Icons.close), tooltip: context.t('close')),
            ],
          ),
          const SizedBox(height: 6),
          Row(children: [
            StatusPill(label: text, level: level, dense: true),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                sync.lastSyncAt == null
                    ? context.t('neverSynced')
                    : '${context.t('lastSynced')} ${_time(sync.lastSyncAt!)}',
                style: const TextStyle(fontSize: 11.5, color: FarmColors.muted),
              ),
            ),
          ]),
          const SizedBox(height: 8),
          Text(
            sync.online ? context.t('syncExplainerOnline') : context.t('syncExplainerOffline'),
            style: FarmTypography.textTheme.bodySmall,
          ),
          // Never let the panel imply the tablet is empty when it isn't:
          // records another sign-in left behind are held for their author,
          // not lost.
          if (sync.otherUsersPending > 0) ...[
            const SizedBox(height: 8),
            Text(
              '${sync.otherUsersPending} ${context.t('otherUserQueueNote')}',
              style: FarmTypography.textTheme.bodySmall?.copyWith(color: FarmColors.warning),
            ),
          ],
        ],
      ),
    );
  }
}

class _EmptyQueue extends StatelessWidget {
  const _EmptyQueue({required this.sync});
  final SyncController sync;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(FarmSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(sync.online ? Icons.cloud_done_outlined : Icons.cloud_off, size: 44, color: FarmColors.muted),
            const SizedBox(height: 12),
            Text(context.t('nothingWaiting'), style: FarmTypography.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              sync.online ? context.t('everythingUpToDate') : context.t('nothingWaitingOffline'),
              textAlign: TextAlign.center,
              style: FarmTypography.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _QueuedRow extends StatelessWidget {
  const _QueuedRow({required this.item, required this.onChanged});
  final OutboxItem item;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final sync = context.read<SyncController>();
    final access = context.watch<AccessProvider>();
    final language = Localizations.localeOf(context).languageCode;
    final failed = item.status == OutboxStatus.failed;

    return Container(
      padding: const EdgeInsets.all(FarmSpacing.sm),
      decoration: BoxDecoration(
        color: FarmColors.card,
        border: Border.all(color: failed ? FarmColors.danger.withOpacity(0.4) : FarmColors.border),
        borderRadius: BorderRadius.circular(FarmRadii.sm),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(_iconFor(item.method), size: 16, color: failed ? FarmColors.danger : FarmColors.cedar2),
            const SizedBox(width: 8),
            Expanded(
              child: Text(context.t(item.label), style: FarmTypography.textTheme.titleSmall),
            ),
            Text(_time(item.createdAt), style: const TextStyle(fontSize: 11, color: FarmColors.muted)),
          ]),
          if (item.moduleCode != null) ...[
            const SizedBox(height: 4),
            Text(
              access.moduleLabel(item.moduleCode!, language),
              style: const TextStyle(fontSize: 11.5, color: FarmColors.muted),
            ),
          ],
          if (failed) ...[
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: FarmColors.tint(FarmColors.danger, 0.08),
                borderRadius: BorderRadius.circular(FarmRadii.sm),
              ),
              child: Text(
                item.lastError ?? context.t('serverRejected'),
                style: const TextStyle(fontSize: 11.5, color: FarmColors.danger, fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(height: 8),
            Row(children: [
              OutlinedButton(
                onPressed: () async {
                  await sync.retry(item.id);
                  onChanged();
                },
                child: Text(context.t('retry')),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: () => _confirmDiscard(context, sync),
                style: TextButton.styleFrom(foregroundColor: FarmColors.danger),
                child: Text(context.t('discard')),
              ),
            ]),
          ],
        ],
      ),
    );
  }

  /// Discarding destroys a record a worker actually made, so it asks
  /// first and says plainly that it cannot be undone.
  Future<void> _confirmDiscard(BuildContext context, SyncController sync) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(dialogContext.t('discardRecord')),
        content: Text(dialogContext.t('discardRecordExplainer')),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: Text(dialogContext.t('cancel'))),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: FarmColors.danger),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(dialogContext.t('discard')),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await sync.discard(item.id);
    onChanged();
  }

  IconData _iconFor(String method) => switch (method) {
        'POST' => Icons.add_circle_outline,
        'PATCH' || 'PUT' => Icons.edit_outlined,
        'DELETE' => Icons.delete_outline,
        _ => Icons.circle_outlined,
      };
}

String _time(DateTime value) {
  final local = value.toLocal();
  return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
}
