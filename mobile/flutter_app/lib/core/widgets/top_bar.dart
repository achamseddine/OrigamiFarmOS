import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'app_icon.dart';
import '../i18n/locale_controller.dart';
import '../i18n/strings.dart';
import '../../auth/session_controller.dart';
import '../../features/notifications/notification_panel.dart';
import '../../features/profile/profile_menu.dart';
import '../../features/sync/sync_pill.dart';
import '../../providers/notifications_provider.dart';
import '../theme/colors.dart';
import '../theme/spacing.dart';

/// EN/AR toggle, the notification bell, and the signed-in user's menu
/// (tech spec §7). Both the bell and the avatar open real panels — the
/// dead ornaments they used to be are gone.
class TopBar extends StatelessWidget implements PreferredSizeWidget {
  const TopBar({super.key});

  @override
  Size get preferredSize => const Size.fromHeight(64);

  @override
  Widget build(BuildContext context) {
    final locale = context.watch<LocaleController>();
    final session = context.watch<SessionController>();
    final unread = context.watch<NotificationsProvider>().unreadCount;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: FarmSpacing.lg, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          const SyncPill(),
          const SizedBox(width: FarmSpacing.md),
          _LanguageToggle(locale: locale),
          const SizedBox(width: FarmSpacing.md),
          _NotificationBell(count: unread),
          const SizedBox(width: FarmSpacing.md),
          UserMenuButton(session: session),
        ],
      ),
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
