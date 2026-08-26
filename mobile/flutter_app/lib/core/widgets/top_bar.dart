import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'app_icon.dart';
import '../i18n/locale_controller.dart';
import '../../auth/session_controller.dart';
import '../theme/colors.dart';
import '../theme/spacing.dart';
import '../theme/typography.dart';

/// EN/AR toggle, notification bell, and the logged-in user's avatar (with
/// a log-out action) — tech spec §7. The sync-status pill this used to
/// show is gone along with the rest of the offline-first pipeline: the
/// app is always-online now, so there's no local queue to report on.
class TopBar extends StatelessWidget implements PreferredSizeWidget {
  const TopBar({super.key, this.notificationCount = 0});

  final int notificationCount;

  @override
  Size get preferredSize => const Size.fromHeight(64);

  @override
  Widget build(BuildContext context) {
    final locale = context.watch<LocaleController>();
    final session = context.watch<SessionController>();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: FarmSpacing.lg, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          _LanguageToggle(locale: locale),
          const SizedBox(width: FarmSpacing.md),
          _NotificationBell(count: notificationCount),
          const SizedBox(width: FarmSpacing.md),
          _UserMenu(session: session),
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

class _UserMenu extends StatelessWidget {
  const _UserMenu({required this.session});
  final SessionController session;

  @override
  Widget build(BuildContext context) {
    final name = session.user?.name ?? '?';
    final initials = name.isEmpty ? '?' : name.trim().substring(0, 1).toUpperCase();
    return PopupMenuButton<String>(
      tooltip: name,
      onSelected: (value) {
        if (value == 'logout') session.logout();
      },
      itemBuilder: (context) => [
        PopupMenuItem(enabled: false, child: Text(name, style: FarmTypography.textTheme.titleSmall)),
        if (session.user?.role != null) PopupMenuItem(enabled: false, child: Text(session.user!.role, style: const TextStyle(color: FarmColors.muted, fontSize: 12))),
        const PopupMenuDivider(),
        const PopupMenuItem(value: 'logout', child: Text('Log out')),
      ],
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: kFarmTouchTarget - 4,
            height: kFarmTouchTarget - 4,
            decoration: const BoxDecoration(color: FarmColors.gold, shape: BoxShape.circle),
            child: Center(
              child: Text(initials, style: const TextStyle(color: FarmColors.ink, fontWeight: FontWeight.w700)),
            ),
          ),
          const SizedBox(width: 4),
          const Icon(Icons.expand_more, color: FarmColors.muted),
        ],
      ),
    );
  }
}
