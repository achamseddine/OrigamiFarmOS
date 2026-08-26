import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/widgets/app_icon.dart';
import '../../core/widgets/status_pill.dart';
import '../../domain/entities/notification.dart';
import '../../providers/access_provider.dart';
import '../../providers/notifications_provider.dart';
import '../navigation/entity_router.dart';
import '../priorities/priorities_screen.dart';

/// The notification panel behind the bell (tech spec §3).
///
/// Opens as a right-side sheet on a tablet so the farm screen stays
/// visible behind it. Every row is a link: tapping marks it read and opens
/// the record that caused it.
void showNotificationPanel(BuildContext context) {
  final provider = context.read<NotificationsProvider>();
  provider.load();
  showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: context.t('notifications'),
    barrierColor: FarmColors.ink.withOpacity(0.25),
    transitionDuration: const Duration(milliseconds: 180),
    pageBuilder: (_, __, ___) => const _NotificationPanel(),
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

class _NotificationPanel extends StatefulWidget {
  const _NotificationPanel();

  @override
  State<_NotificationPanel> createState() => _NotificationPanelState();
}

class _NotificationPanelState extends State<_NotificationPanel> {
  bool _unreadOnly = false;
  String? _moduleFilter;

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<NotificationsProvider>();
    final access = context.watch<AccessProvider>();
    final language = Localizations.localeOf(context).languageCode;

    var items = provider.notifications;
    if (_unreadOnly) items = items.where((n) => !n.isRead).toList();
    if (_moduleFilter != null) items = items.where((n) => n.moduleCode == _moduleFilter).toList();

    final modules = {for (final n in provider.notifications) n.moduleCode}.toList()..sort();

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
                Padding(
                  padding: const EdgeInsets.fromLTRB(FarmSpacing.lg, FarmSpacing.md, FarmSpacing.sm, 0),
                  child: Row(children: [
                    const AppIcon(FarmIcon.bell, size: 20, color: FarmColors.cedar),
                    const SizedBox(width: 8),
                    Expanded(child: Text(context.t('notifications'), style: FarmTypography.display(size: 22))),
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close),
                      tooltip: context.t('close'),
                    ),
                  ]),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: FarmSpacing.lg),
                  child: Row(children: [
                    Expanded(
                      child: Text(
                        provider.unreadCount > 0
                            ? '${provider.unreadCount} ${context.t('unreadNotifications')}'
                            : context.t('allCaughtUp'),
                        style: FarmTypography.textTheme.bodySmall,
                      ),
                    ),
                    if (provider.unreadCount > 0)
                      TextButton(
                        onPressed: () => provider.markAllRead(),
                        child: Text(context.t('markAllRead')),
                      ),
                  ]),
                ),
                const SizedBox(height: 4),
                SizedBox(
                  height: 40,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: FarmSpacing.lg),
                    children: [
                      FilterChip(
                        label: Text(context.t('unreadOnly')),
                        selected: _unreadOnly,
                        onSelected: (v) => setState(() => _unreadOnly = v),
                      ),
                      const SizedBox(width: 8),
                      ChoiceChip(
                        label: Text(context.t('allModules')),
                        selected: _moduleFilter == null,
                        onSelected: (_) => setState(() => _moduleFilter = null),
                      ),
                      for (final code in modules) ...[
                        const SizedBox(width: 8),
                        ChoiceChip(
                          label: Text(access.moduleLabel(code, language)),
                          selected: _moduleFilter == code,
                          onSelected: (_) => setState(() => _moduleFilter = code),
                        ),
                      ],
                    ],
                  ),
                ),
                const Divider(height: 16, color: FarmColors.border),
                Expanded(
                  child: provider.loading && provider.notifications.isEmpty
                      ? const Center(child: CircularProgressIndicator())
                      : items.isEmpty
                          ? _EmptyState(unreadOnly: _unreadOnly, error: provider.error)
                          : ListView.separated(
                              padding: const EdgeInsets.symmetric(horizontal: FarmSpacing.md),
                              itemCount: items.length,
                              separatorBuilder: (_, __) => const Divider(height: 1, color: FarmColors.border),
                              itemBuilder: (context, i) => _NotificationRow(notification: items[i]),
                            ),
                ),
                const Divider(height: 1, color: FarmColors.border),
                Padding(
                  padding: const EdgeInsets.all(FarmSpacing.sm),
                  child: SizedBox(
                    width: double.infinity,
                    child: TextButton.icon(
                      onPressed: () {
                        Navigator.of(context).pop();
                        Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => const PrioritiesScreen()),
                        );
                      },
                      icon: const Icon(Icons.open_in_full, size: 16),
                      label: Text(context.t('viewAllPriorities')),
                    ),
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

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.unreadOnly, this.error});
  final bool unreadOnly;
  final String? error;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(FarmSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppIcon(error != null ? FarmIcon.warning : FarmIcon.check,
                size: 30, color: error != null ? FarmColors.danger : FarmColors.success),
            const SizedBox(height: 10),
            Text(
              error ?? (unreadOnly ? context.t('noUnreadNotifications') : context.t('allCaughtUp')),
              textAlign: TextAlign.center,
              style: FarmTypography.textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}

class _NotificationRow extends StatelessWidget {
  const _NotificationRow({required this.notification});
  final FarmNotification notification;

  @override
  Widget build(BuildContext context) {
    final access = context.read<AccessProvider>();
    final language = Localizations.localeOf(context).languageCode;
    final level = priorityLevel(notification.priority);

    return InkWell(
      onTap: () {
        context.read<NotificationsProvider>().markRead(notification.id);
        Navigator.of(context).pop();
        EntityRouter.openEntityOrExplain(context, notification.entityType, notification.entityId);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        color: notification.isRead ? Colors.transparent : FarmColors.tint(FarmColors.cedar, 0.05),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: notification.isRead ? FarmColors.border : priorityColor(notification.priority),
                  shape: BoxShape.circle,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    notification.title,
                    style: FarmTypography.textTheme.titleSmall?.copyWith(
                      fontWeight: notification.isRead ? FontWeight.w500 : FontWeight.w700,
                    ),
                  ),
                  if (notification.description != null && notification.description!.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(notification.description!, style: FarmTypography.textTheme.bodySmall, maxLines: 2, overflow: TextOverflow.ellipsis),
                    ),
                  const SizedBox(height: 6),
                  Row(children: [
                    StatusPill(label: access.moduleLabel(notification.moduleCode, language), level: FarmStatusLevel.neutral, dense: true),
                    const SizedBox(width: 6),
                    StatusPill(label: notification.priority, level: level, dense: true),
                    const Spacer(),
                    Text(relativeTime(context, notification.createdAt),
                        style: const TextStyle(fontSize: 10.5, color: FarmColors.muted)),
                  ]),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, size: 18, color: FarmColors.muted),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- shared
FarmStatusLevel priorityLevel(String priority) => switch (priority) {
      'critical' || 'high' => FarmStatusLevel.alert,
      'medium' => FarmStatusLevel.watch,
      'low' => FarmStatusLevel.neutral,
      _ => FarmStatusLevel.info,
    };

Color priorityColor(String priority) => switch (priority) {
      'critical' || 'high' => FarmColors.danger,
      'medium' => FarmColors.warning,
      'low' => FarmColors.muted,
      _ => FarmColors.cedar,
    };

String relativeTime(BuildContext context, DateTime when) {
  final diff = DateTime.now().difference(when);
  if (diff.inMinutes < 1) return context.t('justNow');
  if (diff.inMinutes < 60) return '${diff.inMinutes}${context.t('minutesShort')}';
  if (diff.inHours < 24) return '${diff.inHours}${context.t('hoursShort')}';
  if (diff.inDays < 7) return '${diff.inDays}${context.t('daysShort')}';
  return '${when.day}/${when.month}';
}
