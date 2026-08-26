import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'app_icon.dart';
import '../i18n/locale_controller.dart';
import '../i18n/strings.dart';
import '../theme/colors.dart';
import '../theme/spacing.dart';
import '../theme/typography.dart';
import '../../sync/sync_queue_controller.dart';

/// Sync pill, EN/AR toggle, notification bell, manager avatar.
/// Tech spec §7 (Welcome), §2 ("sync status visible in top bar").
class TopBar extends StatelessWidget implements PreferredSizeWidget {
  const TopBar({super.key, this.notificationCount = 3, this.managerName = 'Rami'});

  final int notificationCount;
  final String managerName;

  @override
  Size get preferredSize => const Size.fromHeight(64);

  @override
  Widget build(BuildContext context) {
    final sync = context.watch<SyncQueueController>();
    final locale = context.watch<LocaleController>();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: FarmSpacing.lg, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          _SyncPill(sync: sync),
          const SizedBox(width: FarmSpacing.md),
          _LanguageToggle(locale: locale),
          const SizedBox(width: FarmSpacing.md),
          _NotificationBell(count: notificationCount),
          const SizedBox(width: FarmSpacing.md),
          _ManagerAvatar(name: managerName),
        ],
      ),
    );
  }
}

class _SyncPill extends StatelessWidget {
  const _SyncPill({required this.sync});
  final SyncQueueController sync;

  @override
  Widget build(BuildContext context) {
    final (label, color, icon) = switch (sync.status) {
      SyncStatus.synced => (context.t('synced'), FarmColors.success, Icons.cloud_done_outlined),
      SyncStatus.syncing => (context.t('syncing'), FarmColors.warning, Icons.cloud_sync_outlined),
      SyncStatus.offline => (context.t('offline'), FarmColors.muted, Icons.cloud_off_outlined),
      SyncStatus.error => (context.t('syncError'), FarmColors.danger, Icons.error_outline),
    };
    return InkWell(
      borderRadius: BorderRadius.circular(FarmRadii.pill),
      onTap: () => _showSyncSheet(context, sync),
      child: Container(
        constraints: const BoxConstraints(minHeight: kFarmTouchTarget),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: FarmColors.card,
          border: Border.all(color: FarmColors.border),
          borderRadius: BorderRadius.circular(FarmRadii.pill),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(label, style: FarmTypography.textTheme.titleSmall),
                Text(
                  sync.pendingCount > 0
                      ? '${sync.pendingCount} ${context.t('pendingSync')}'
                      : context.t('justNow'),
                  style: const TextStyle(fontSize: 10.5, color: FarmColors.muted),
                ),
              ],
            ),
            const SizedBox(width: 6),
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
          ],
        ),
      ),
    );
  }

  void _showSyncSheet(BuildContext context, SyncQueueController sync) {
    showModalBottomSheet(
      context: context,
      backgroundColor: FarmColors.stone,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(FarmRadii.xl)),
      ),
      builder: (sheetContext) {
        return Consumer<SyncQueueController>(
          builder: (sheetContext, s, _) => Padding(
            padding: const EdgeInsets.all(FarmSpacing.lg),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Sync status', style: FarmTypography.textTheme.titleLarge),
                const SizedBox(height: 8),
                Text(
                  s.pendingCount > 0
                      ? '${s.pendingCount} record(s) queued locally. They are safe on this '
                          'tablet and will upload automatically once the connection is back.'
                      : 'Everything is synced.'
                          '${s.lastSyncedAt != null ? ' Last synced ${TimeOfDay.fromDateTime(s.lastSyncedAt!).format(sheetContext)}.' : ''}',
                  style: FarmTypography.textTheme.bodyMedium,
                ),
                const SizedBox(height: FarmSpacing.md),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Work offline'),
                  subtitle: const Text('Core workflows keep working with no connection.'),
                  value: !s.online,
                  onChanged: (offline) => s.setOnline(!offline),
                ),
                const SizedBox(height: FarmSpacing.sm),
                if (s.online)
                  FilledButton(
                    onPressed: s.pendingCount == 0 ? null : s.syncNow,
                    child: const Text('Sync now'),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _LanguageToggle extends StatelessWidget {
  const _LanguageToggle({required this.locale});
  final LocaleController locale;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: kFarmTouchTarget,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        color: FarmColors.card,
        border: Border.all(color: FarmColors.border),
        borderRadius: BorderRadius.circular(FarmRadii.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _langButton(context, 'EN', const Locale('en')),
          Container(width: 1, height: 20, color: FarmColors.border),
          _langButton(context, 'AR', const Locale('ar')),
        ],
      ),
    );
  }

  Widget _langButton(BuildContext context, String label, Locale value) {
    final selected = locale.locale == value;
    return InkWell(
      onTap: () => locale.setLocale(value),
      borderRadius: BorderRadius.circular(FarmRadii.pill),
      child: Container(
        width: 48,
        height: kFarmTouchTarget - 8,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? FarmColors.cedar : Colors.transparent,
          borderRadius: BorderRadius.circular(FarmRadii.pill),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 12.5,
            color: selected ? FarmColors.white : FarmColors.muted,
          ),
        ),
      ),
    );
  }
}

class _NotificationBell extends StatelessWidget {
  const _NotificationBell({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          width: kFarmTouchTarget,
          height: kFarmTouchTarget,
          decoration: BoxDecoration(
            color: FarmColors.card,
            border: Border.all(color: FarmColors.border),
            shape: BoxShape.circle,
          ),
          child: Center(child: AppIcon(FarmIcon.bell, size: 18, color: FarmColors.ink)),
        ),
        if (count > 0)
          Positioned(
            top: -2,
            right: -2,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: const BoxDecoration(color: FarmColors.danger, shape: BoxShape.circle),
              constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
              child: Text(
                '$count',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 10.5, fontWeight: FontWeight.w700),
              ),
            ),
          ),
      ],
    );
  }
}

class _ManagerAvatar extends StatelessWidget {
  const _ManagerAvatar({required this.name});
  final String name;

  @override
  Widget build(BuildContext context) {
    final initials = name.isEmpty ? '?' : name.trim().substring(0, 1).toUpperCase();
    return Row(
      children: [
        Container(
          width: kFarmTouchTarget - 4,
          height: kFarmTouchTarget - 4,
          decoration: const BoxDecoration(color: FarmColors.gold, shape: BoxShape.circle),
          child: Center(
            child: Text(
              initials,
              style: const TextStyle(color: FarmColors.ink, fontWeight: FontWeight.w700),
            ),
          ),
        ),
        const SizedBox(width: 4),
        const Icon(Icons.expand_more, color: FarmColors.muted),
      ],
    );
  }
}
