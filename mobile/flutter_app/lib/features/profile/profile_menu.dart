import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../app/app_navigator.dart';
import '../../auth/session_controller.dart';
import '../../core/i18n/locale_controller.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/widgets/app_icon.dart';
import '../../core/widgets/status_pill.dart';
import '../../domain/entities/access.dart';
import '../../providers/access_provider.dart';
import 'my_profile_sheet.dart';

/// The avatar in the top bar and the menu behind it (tech spec §2).
///
/// The whole control is one tap target — avatar, initial and chevron alike
/// — because the previous build had a chevron that looked tappable and was
/// not. Tapping outside or pressing Escape closes it (both come free with
/// [PopupMenuButton]; the Escape binding matters on a keyboard-attached
/// tablet).
class UserMenuButton extends StatelessWidget {
  const UserMenuButton({super.key, required this.session});
  final SessionController session;

  @override
  Widget build(BuildContext context) {
    final user = session.user;
    final access = context.watch<AccessProvider>();
    final navigator = context.read<AppNavigator>();
    final name = user?.name ?? '?';
    final initials = name.trim().isEmpty ? '?' : name.trim().characters.first.toUpperCase();
    final isManager = access.isFullAccess || (user?.isManager ?? false);

    return PopupMenuButton<String>(
      tooltip: name,
      offset: const Offset(0, kFarmTouchTarget),
      position: PopupMenuPosition.under,
      constraints: const BoxConstraints(minWidth: 268, maxWidth: 320),
      onSelected: (value) => _handle(context, value, navigator),
      itemBuilder: (context) => [
        PopupMenuItem<String>(
          enabled: false,
          height: 76,
          child: _SignedInHeader(name: name, user: user, access: access),
        ),
        const PopupMenuDivider(),
        _item(context, 'profile', FarmIcon.eye, 'myProfile'),
        _item(context, 'responsibilities', FarmIcon.check, 'myResponsibilities'),
        _item(context, 'language', FarmIcon.language, 'language'),
        if (isManager) ...[
          const PopupMenuDivider(),
          _item(context, 'employees', FarmIcon.people, 'manageEmployees'),
          _item(context, 'permissions', FarmIcon.settings, 'rolesAndPermissions'),
          _item(context, 'modules', FarmIcon.inventory, 'moduleManagement'),
          _item(context, 'farmSettings', FarmIcon.barn, 'farmSettings'),
        ],
        const PopupMenuDivider(),
        _item(context, 'settings', FarmIcon.settings, 'navSettings'),
        PopupMenuItem<String>(
          value: 'logout',
          child: Row(children: [
            const Icon(Icons.logout, size: 17, color: FarmColors.danger),
            const SizedBox(width: 12),
            Text(context.t('logOut'), style: const TextStyle(color: FarmColors.danger, fontWeight: FontWeight.w600)),
          ]),
        ),
      ],
      child: Semantics(
        button: true,
        label: '$name — ${context.t('openProfileMenu')}',
        child: Container(
          height: kFarmTouchTarget,
          padding: const EdgeInsets.only(left: 2, right: 4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(FarmRadii.pill),
            border: Border.all(color: FarmColors.border),
            color: FarmColors.card,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: kFarmTouchTarget - 8,
                height: kFarmTouchTarget - 8,
                decoration: const BoxDecoration(color: FarmColors.gold, shape: BoxShape.circle),
                child: Center(
                  child: Text(initials, style: const TextStyle(color: FarmColors.ink, fontWeight: FontWeight.w700)),
                ),
              ),
              const SizedBox(width: 2),
              const Icon(Icons.expand_more, color: FarmColors.muted, size: 20),
            ],
          ),
        ),
      ),
    );
  }

  PopupMenuItem<String> _item(BuildContext context, String value, FarmIcon icon, String labelKey) {
    return PopupMenuItem<String>(
      value: value,
      child: Row(children: [
        AppIcon(icon, size: 17, color: FarmColors.cedar),
        const SizedBox(width: 12),
        Text(context.t(labelKey)),
      ]),
    );
  }

  void _handle(BuildContext context, String value, AppNavigator navigator) {
    switch (value) {
      case 'logout':
        context.read<SessionController>().logout();
      case 'profile':
        showMyProfileSheet(context);
      case 'responsibilities':
        showMyProfileSheet(context, initialTab: ProfileTab.responsibilities);
      case 'language':
        _showLanguageDialog(context);
      // Every manager destination lives on the Employees or Settings tab —
      // the menu is a shortcut into them, not a second place to do the work.
      case 'employees':
      case 'permissions':
        if (!navigator.goToModule(FarmModule.employees)) {
          navigator.goToModule(FarmModule.settings);
        }
      case 'modules':
      case 'farmSettings':
      case 'settings':
        navigator.goToModule(FarmModule.settings);
    }
  }

  void _showLanguageDialog(BuildContext context) {
    final locale = context.read<LocaleController>();
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(dialogContext.t('language')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final option in const [(Locale('en'), 'English'), (Locale('ar'), 'العربية')])
              RadioListTile<Locale>(
                value: option.$1,
                groupValue: locale.locale,
                title: Text(option.$2),
                onChanged: (picked) {
                  if (picked != null) locale.setLocale(picked);
                  Navigator.of(dialogContext).pop();
                },
              ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: Text(dialogContext.t('close'))),
        ],
      ),
    );
  }
}

/// Who is signed in, their role, and how many areas they look after —
/// tech spec §2 asks the menu to make all three obvious.
class _SignedInHeader extends StatelessWidget {
  const _SignedInHeader({required this.name, required this.user, required this.access});
  final String name;
  final dynamic user;
  final AccessProvider access;

  @override
  Widget build(BuildContext context) {
    final role = (user?.role as String?) ?? '';
    final moduleCount = access.isFullAccess ? access.catalog.length : access.access.heldModules.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(name, style: FarmTypography.textTheme.titleSmall),
        if (user?.email != null)
          Text(user.email as String, style: const TextStyle(fontSize: 11, color: FarmColors.muted)),
        const SizedBox(height: 6),
        Row(children: [
          StatusPill(label: role.replaceAll('_', ' '), level: FarmStatusLevel.info, dense: true),
          const SizedBox(width: 6),
          Text(
            access.isFullAccess
                ? context.t('allModules')
                : '$moduleCount ${context.t(moduleCount == 1 ? 'moduleSingular' : 'modulePlural')}',
            style: const TextStyle(fontSize: 11, color: FarmColors.muted),
          ),
        ]),
      ],
    );
  }
}

/// Escape closes any open menu or sheet on a keyboard-attached tablet.
class DismissOnEscape extends StatelessWidget {
  const DismissOnEscape({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (Navigator.of(context).canPop()) Navigator.of(context).pop();
        },
      },
      child: Focus(autofocus: true, child: child),
    );
  }
}
