import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/widgets/app_icon.dart';
import '../../sync/sync_controller.dart';
import 'sync_panel.dart';

/// The one thing in the whole app that tells a worker whether what they
/// just recorded has actually left the tablet.
///
/// It sits in the top bar next to the bell and is never hidden while
/// anything is waiting: a farmhand who spent the morning entering milk in
/// a dead spot must be able to glance up and see that it is still on the
/// device. Tapping it opens the detail panel.
class SyncPill extends StatelessWidget {
  const SyncPill({super.key});

  @override
  Widget build(BuildContext context) {
    final sync = context.watch<SyncController>();
    if (sync.badge == SyncBadge.disabled) return const SizedBox.shrink();

    final look = _lookFor(context, sync);

    return Tooltip(
      message: look.tooltip,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(FarmRadii.pill),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => showSyncPanel(context),
          child: Container(
            height: kFarmTouchTarget,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: FarmColors.tint(look.color, 0.12),
              border: Border.all(color: look.color.withOpacity(0.45)),
              borderRadius: BorderRadius.circular(FarmRadii.pill),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (look.spinning)
                  SizedBox(
                    width: 15,
                    height: 15,
                    child: CircularProgressIndicator(strokeWidth: 2, color: look.color),
                  )
                else
                  Icon(look.icon, size: 17, color: look.color),
                const SizedBox(width: 7),
                Text(
                  look.label,
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: look.color),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

typedef _Look = ({String label, String tooltip, IconData icon, Color color, bool spinning});

_Look _lookFor(BuildContext context, SyncController sync) {
  final waiting = sync.pendingCount;
  switch (sync.badge) {
    case SyncBadge.syncing:
      return (
        label: context.t('syncing'),
        tooltip: context.t('syncingTooltip'),
        icon: Icons.sync,
        color: FarmColors.cedar2,
        spinning: true,
      );
    case SyncBadge.offline:
      return (
        label: waiting > 0 ? '${context.t('offline')} · $waiting' : context.t('offline'),
        tooltip: waiting > 0 ? '$waiting ${context.t('waitingToSync')}' : context.t('offlineTooltip'),
        icon: Icons.cloud_off,
        color: FarmColors.statusOffline,
        spinning: false,
      );
    case SyncBadge.attention:
      return (
        label: '${sync.failedCount}',
        tooltip: context.t('syncNeedsAttention'),
        icon: Icons.error_outline,
        color: FarmColors.danger,
        spinning: false,
      );
    case SyncBadge.pending:
      return (
        label: '$waiting',
        tooltip: '$waiting ${context.t('waitingToSync')}',
        icon: Icons.cloud_upload_outlined,
        color: FarmColors.warning,
        spinning: false,
      );
    case SyncBadge.synced:
    case SyncBadge.disabled:
      return (
        label: context.t('synced'),
        tooltip: context.t('syncedTooltip'),
        icon: Icons.cloud_done_outlined,
        color: FarmColors.success,
        spinning: false,
      );
  }
}

/// A full-width strip under the top bar, shown only while the tablet is
/// out of contact. The pill alone is easy to miss on a bright screen in a
/// field; this is not.
class OfflineBanner extends StatelessWidget {
  const OfflineBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final sync = context.watch<SyncController>();
    if (!sync.enabled || sync.online) return const SizedBox.shrink();

    return Material(
      color: FarmColors.tint(FarmColors.statusOffline, 0.18),
      child: InkWell(
        onTap: () => showSyncPanel(context),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: FarmSpacing.lg, vertical: 8),
          child: Row(
            children: [
              const AppIcon(FarmIcon.cloudSync, size: 16, color: FarmColors.statusOffline),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  sync.hasPending
                      ? '${context.t('workingOffline')} — ${sync.pendingCount} ${context.t('waitingToSync')}'
                      : context.t('workingOfflineNothingQueued'),
                  style: FarmTypography.textTheme.bodySmall?.copyWith(
                    color: FarmColors.ink,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              TextButton(
                onPressed: () => showSyncPanel(context),
                child: Text(context.t('details')),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "Not synced yet" marker for a single row in a list — the counterpart
/// to the pill at record level, so a farmer can tell which three of
/// today's twelve entries are still on the tablet.
class PendingChip extends StatelessWidget {
  const PendingChip({super.key, this.dense = true});
  final bool dense;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: dense ? 7 : 10, vertical: dense ? 2 : 4),
      decoration: BoxDecoration(
        color: FarmColors.tint(FarmColors.warning, 0.14),
        border: Border.all(color: FarmColors.warning.withOpacity(0.4)),
        borderRadius: BorderRadius.circular(FarmRadii.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cloud_upload_outlined, size: 12, color: FarmColors.warning),
          const SizedBox(width: 5),
          Text(
            context.t('notSynced'),
            style: TextStyle(fontSize: dense ? 10.5 : 12, fontWeight: FontWeight.w700, color: FarmColors.warning),
          ),
        ],
      ),
    );
  }
}
