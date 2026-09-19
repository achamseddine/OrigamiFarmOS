import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'app_icon.dart';
import '../i18n/strings.dart';
import '../../auth/session_controller.dart';
import '../../features/notifications/notification_panel.dart';
import '../../features/profile/profile_menu.dart';
import '../../features/sync/sync_pill.dart';
import '../../providers/notifications_provider.dart';
import '../theme/colors.dart';
import '../theme/spacing.dart';

/// Sync state, the notification bell, and the signed-in user's menu.
///
/// The EN/AR toggle used to sit here too. A row of utility controls
/// pinned to the top-right corner is a *website* header, and it was a
/// large part of why this tablet read as one — so the strip now carries
/// only what changes on its own and is worth a glance from across a
/// barn. Language is a preference, it changes about once, and it lives
/// with the other preferences on Settings, which is a destination like
/// any other.
class TopBar extends StatelessWidget implements PreferredSizeWidget {
  const TopBar({super.key});

  @override
  Size get preferredSize => const Size.fromHeight(60);

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionController>();
    final unread = context.watch<NotificationsProvider>().unreadCount;

    return Padding(
      padding: const EdgeInsets.fromLTRB(FarmSpacing.lg, 6, FarmSpacing.lg, 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          const SyncPill(),
          const SizedBox(width: FarmSpacing.md),
          _NotificationBell(count: unread),
          const SizedBox(width: FarmSpacing.md),
          UserMenuButton(session: session),
        ],
      ),
    );
  }
}

/// The bell. Tapping it — anywhere on it, badge included — opens the
/// notification panel.
class _NotificationBell extends StatelessWidget {
  const _NotificationBell({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: count > 0 ? '$count ${context.t('unreadNotifications')}' : context.t('notifications'),
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => showNotificationPanel(context),
          customBorder: const CircleBorder(),
          child: Stack(
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
                child: const Center(child: AppIcon(FarmIcon.bell, size: 18, color: FarmColors.ink)),
              ),
              if (count > 0)
                Positioned(
                  top: -2,
                  right: -2,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      color: FarmColors.danger,
                      shape: count > 9 ? BoxShape.rectangle : BoxShape.circle,
                      borderRadius: count > 9 ? BorderRadius.circular(9) : null,
                    ),
                    constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
                    child: Text(
                      count > 99 ? '99+' : '$count',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white, fontSize: 10.5, fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
