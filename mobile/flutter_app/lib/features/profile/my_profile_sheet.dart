import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
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
import '../../sync/sync_controller.dart';

enum ProfileTab { profile, responsibilities }

/// "My Profile" and "My Responsibilities" from the profile menu — who I
/// am, and exactly which areas of the farm I am responsible for and what I
/// may do in each.
void showMyProfileSheet(BuildContext context, {ProfileTab initialTab = ProfileTab.profile}) {
  showDialog<void>(
    context: context,
    builder: (_) => _MyProfileDialog(initialTab: initialTab),
  );
}

class _MyProfileDialog extends StatefulWidget {
  const _MyProfileDialog({required this.initialTab});
  final ProfileTab initialTab;

  @override
  State<_MyProfileDialog> createState() => _MyProfileDialogState();
}

class _MyProfileDialogState extends State<_MyProfileDialog> {
  late ProfileTab _tab = widget.initialTab;

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionController>();
    final access = context.watch<AccessProvider>();
    final user = session.user;
    if (user == null) return const SizedBox.shrink();

    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620, maxHeight: 680),
        child: Padding(
          padding: const EdgeInsets.all(FarmSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(children: [
                Container(
                  width: 46,
                  height: 46,
                  decoration: const BoxDecoration(color: FarmColors.gold, shape: BoxShape.circle),
                  child: Center(
                    child: Text(
                      user.name.trim().isEmpty ? '?' : user.name.trim().substring(0, 1).toUpperCase(),
                      style: FarmTypography.textTheme.titleLarge?.copyWith(color: FarmColors.ink),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(user.name, style: FarmTypography.display(size: 20)),
                      Text(user.email ?? '—', style: FarmTypography.textTheme.bodySmall),
                    ],
                  ),
                ),
                IconButton(onPressed: () => Navigator.of(context).pop(), icon: const Icon(Icons.close)),
              ]),
              const SizedBox(height: FarmSpacing.md),
              SegmentedButton<ProfileTab>(
                segments: [
                  ButtonSegment(value: ProfileTab.profile, label: Text(context.t('myProfile'))),
                  ButtonSegment(value: ProfileTab.responsibilities, label: Text(context.t('myResponsibilities'))),
                ],
                selected: {_tab},
                onSelectionChanged: (s) => setState(() => _tab = s.first),
              ),
              const SizedBox(height: FarmSpacing.md),
              Flexible(
                child: SingleChildScrollView(
                  child: _tab == ProfileTab.profile
                      ? _ProfileDetails(user: user, access: access)
                      : _Responsibilities(access: access),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProfileDetails extends StatelessWidget {
  const _ProfileDetails({required this.user, required this.access});
  final dynamic user;
  final AccessProvider access;

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionController>();
    final sync = context.watch<SyncController>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _row(context, 'name', user.name as String),
        _row(context, 'email', (user.email as String?) ?? '—'),
        _row(context, 'phone', (user.phone as String?) ?? '—'),
        _row(context, 'role', (user.role as String).replaceAll('_', ' ')),
        if (user.department != null) _row(context, 'department', user.department as String),
        _row(context, 'language', context.watch<LocaleController>().locale.languageCode == 'ar' ? 'العربية' : 'English'),
        const Divider(height: 24, color: FarmColors.border),
        if (session.standalone)
          _row(context, 'dataSource', context.t('dataSourceThisTablet'))
        else
          _row(context, 'server', session.baseUrl),
        _row(context, 'accessLevel', access.isFullAccess ? context.t('fullFarmAccess') : context.t('moduleBasedAccess')),
        if (sync.enabled)
          _row(
            context,
            'syncStatus',
            sync.online
                ? (sync.hasPending
                    ? '${context.t('synced')} · ${sync.pendingCount} ${context.t('waitingToSync')}'
                    : context.t('synced'))
                : '${context.t('offline')} · ${sync.pendingCount} ${context.t('waitingToSync')}',
          ),
      ],
    );
  }

  Widget _row(BuildContext context, String labelKey, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 150, child: Text(context.t(labelKey), style: const TextStyle(color: FarmColors.muted))),
            Expanded(child: Text(value, style: FarmTypography.textTheme.titleSmall)),
          ],
        ),
      );
}

/// Every module the user holds, and what they may do in it. This is the
/// same data the backend enforces — an employee can see exactly why a
/// button is missing, and what to ask their manager for.
class _Responsibilities extends StatelessWidget {
  const _Responsibilities({required this.access});
  final AccessProvider access;

  static const _actionLabels = {
    PermissionAction.view: 'permView',
    PermissionAction.create: 'permCreate',
    PermissionAction.edit: 'permEdit',
    PermissionAction.delete: 'permDelete',
    PermissionAction.approve: 'permApprove',
    PermissionAction.export: 'permExport',
    PermissionAction.assign: 'permAssign',
    PermissionAction.configure: 'permConfigure',
  };

  @override
  Widget build(BuildContext context) {
    final language = Localizations.localeOf(context).languageCode;

    if (access.isFullAccess) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const AppIcon(FarmIcon.check, size: 18, color: FarmColors.success),
            const SizedBox(width: 8),
            Expanded(child: Text(context.t('fullAccessExplainer'), style: FarmTypography.textTheme.bodyMedium)),
          ]),
          const SizedBox(height: FarmSpacing.md),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final module in access.catalog)
                StatusPill(
                  label: module.label(language),
                  level: module.licensedActive ? FarmStatusLevel.good : FarmStatusLevel.neutral,
                  dense: true,
                ),
            ],
          ),
        ],
      );
    }

    final held = access.access.heldModules;
    if (held.isEmpty) {
      return Text(context.t('noResponsibilitiesYet'), style: FarmTypography.textTheme.bodyMedium);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final code in held) ...[
          Text(access.moduleLabel(code, language), style: FarmTypography.textTheme.titleSmall),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final entry in _actionLabels.entries)
                if (access.can(code, entry.key))
                  StatusPill(label: context.t(entry.value), level: FarmStatusLevel.good, dense: true),
            ],
          ),
          const Divider(height: 22, color: FarmColors.border),
        ],
      ],
    );
  }
}
