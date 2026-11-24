import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/widgets/section_card.dart';
import '../build_info.dart';
import 'app_update_provider.dart';

String _d(DateTime d) {
  final l = d.toLocal();
  return '${l.day}/${l.month}/${l.year} ${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
}

Future<void> installUpdate(BuildContext context) async {
  final updates = context.read<AppUpdateProvider>();
  final ok = await updates.install();
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    duration: const Duration(seconds: 8),
    content: Text(context.t(ok ? (updates.isWeb ? 'updReloading' : 'updDownloading') : 'updCouldNotOpen')),
  ));
}

/// Settings → App updates: this version, the newest one, Check and Update.
class AppUpdateCard extends StatelessWidget {
  const AppUpdateCard({super.key});

  @override
  Widget build(BuildContext context) {
    final u = context.watch<AppUpdateProvider>();
    final latest = u.latest;
    final String status;
    if (u.checking) {
      status = context.t('updChecking');
    } else if (u.error != null) {
      status = context.t('updCheckFailed');
    } else if (u.isDevBuild) {
      status = context.t('updDevBuild');
    } else if (u.updateAvailable) {
      status = '${context.t('updAvailable')}: ${latest!.label}';
    } else if (u.checkedAt != null) {
      status = context.t('updUpToDate');
    } else {
      status = context.t('updNotChecked');
    }
    return SectionCard(
      key: const ValueKey('app-update-card'),
      title: context.t('updTitle'),
      subtitle: context.t(u.isWeb ? 'updWebHow' : 'updTabletHow'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Icon(u.updateAvailable ? Icons.system_update : Icons.verified_outlined, color: u.updateAvailable ? FarmColors.warning : FarmColors.success),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${context.t('updThisVersion')}: $kAppStamp', style: FarmTypography.textTheme.titleSmall),
              Text(status, key: const ValueKey('app-update-status'), style: FarmTypography.textTheme.bodySmall),
              if (u.checkedAt != null)
                Text('${context.t('updLastChecked')}: ${_d(u.checkedAt!)}', style: FarmTypography.textTheme.bodySmall?.copyWith(color: FarmColors.muted)),
            ]),
          ),
        ]),
        const SizedBox(height: FarmSpacing.md),
        Wrap(spacing: 8, runSpacing: 8, children: [
          if (u.updateAvailable)
            FilledButton.icon(
              key: const ValueKey('app-update-install'),
              onPressed: () => installUpdate(context),
              icon: const Icon(Icons.download, size: 18),
              label: Text('${context.t(u.isWeb ? 'updReload' : 'updUpdateTo')} ${latest!.label}'),
            ),
          OutlinedButton.icon(
            key: const ValueKey('app-update-check'),
            onPressed: u.checking ? null : () => context.read<AppUpdateProvider>().check(),
            icon: const Icon(Icons.refresh, size: 18),
            label: Text(context.t('updCheckNow')),
          ),
        ]),
      ]),
    );
  }
}

/// The strip under the top bar while a newer version waits.
class AppUpdateBanner extends StatelessWidget {
  const AppUpdateBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final u = context.watch<AppUpdateProvider>();
    if (!u.showNotice) return const SizedBox.shrink();
    return Material(
      key: const ValueKey('app-update-banner'),
      color: FarmColors.tint(FarmColors.gold, 0.22),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: FarmSpacing.lg, vertical: 6),
        child: Row(children: [
          const Icon(Icons.system_update, size: 18, color: FarmColors.ink),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '${context.t(u.isWeb ? 'updWebReady' : 'updReady')} ${u.latest!.label}',
              style: FarmTypography.textTheme.bodySmall?.copyWith(color: FarmColors.ink, fontWeight: FontWeight.w600),
            ),
          ),
          TextButton(onPressed: () => context.read<AppUpdateProvider>().dismiss(), child: Text(context.t('updLater'))),
          FilledButton(
            key: const ValueKey('app-update-banner-install'),
            onPressed: () => installUpdate(context),
            child: Text(context.t(u.isWeb ? 'updReload' : 'updUpdate')),
          ),
        ]),
      ),
    );
  }
}

/// The first line of the notifications while a newer version waits.
class AppUpdateNotice extends StatelessWidget {
  const AppUpdateNotice({super.key});

  @override
  Widget build(BuildContext context) {
    final u = context.watch<AppUpdateProvider>();
    if (!u.updateAvailable) return const SizedBox.shrink();
    return Container(
      key: const ValueKey('app-update-notice'),
      margin: const EdgeInsets.fromLTRB(FarmSpacing.lg, FarmSpacing.sm, FarmSpacing.lg, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: FarmColors.tint(FarmColors.gold, 0.18), borderRadius: BorderRadius.circular(10)),
      child: Row(children: [
        const Icon(Icons.system_update, color: FarmColors.ink),
        const SizedBox(width: 10),
        Expanded(child: Text('${context.t(u.isWeb ? 'updWebReady' : 'updReady')} ${u.latest!.label}', style: FarmTypography.textTheme.titleSmall)),
        TextButton(onPressed: () => installUpdate(context), child: Text(context.t(u.isWeb ? 'updReload' : 'updUpdate'))),
      ]),
    );
  }
}
