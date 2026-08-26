import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/i18n/locale_controller.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/widgets/section_card.dart';
import '../../core/widgets/status_pill.dart';
import '../../data/demo/demo_data.dart';
import '../../providers/mouneh_provider.dart';
import '../../providers/visits_provider.dart';
import '../../sync/sync_queue_controller.dart';

/// Farm configuration (tech spec §6 nav table: "Users, roles, languages,
/// currency, thresholds").
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final locale = context.watch<LocaleController>();
    final sync = context.watch<SyncQueueController>();
    final mouneh = context.watch<MounehProvider>();
    final visits = context.watch<VisitsProvider>();

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(context.t('navSettings'), style: FarmTypography.display(size: 28)),
          const SizedBox(height: FarmSpacing.md),
          SectionCard(
            title: 'Farm',
            child: Column(children: [
              _Row(label: 'Name', value: DemoData.farm.name),
              _Row(label: 'Region', value: '${DemoData.farm.region}, ${DemoData.farm.country}'),
              _Row(label: 'Timezone', value: DemoData.farm.timezone),
              _Row(label: 'Default currency', value: DemoData.farm.defaultCurrency),
            ]),
          ),
          const SizedBox(height: FarmSpacing.md),
          SectionCard(
            title: 'Language',
            child: Row(children: [
              Expanded(child: Text('Interface language (EN / AR, RTL-aware)', style: FarmTypography.textTheme.bodyMedium)),
              SegmentedButton<Locale>(
                segments: const [
                  ButtonSegment(value: Locale('en'), label: Text('English')),
                  ButtonSegment(value: Locale('ar'), label: Text('العربية')),
                ],
                selected: {locale.locale},
                onSelectionChanged: (s) => locale.setLocale(s.first),
              ),
            ]),
          ),
          const SizedBox(height: FarmSpacing.md),
          SectionCard(
            title: 'Sync & offline',
            child: Column(children: [
              _Row(label: 'Status', value: sync.status.name),
              _Row(label: 'Pending items', value: '${sync.pendingCount}'),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Simulate offline (demo)'),
                value: !sync.online,
                onChanged: (v) => sync.setOnline(!v),
              ),
            ]),
          ),
          const SizedBox(height: FarmSpacing.md),
          SectionCard(
            title: 'Modules',
            subtitle: 'License-controlled add-ons — activated per farm by a super user',
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(children: [
                            Text('Mouneh & Farm Product Processing', style: FarmTypography.textTheme.titleSmall),
                            const SizedBox(width: 8),
                            StatusPill(label: mouneh.isActive ? 'Active' : 'Inactive', level: mouneh.isActive ? FarmStatusLevel.good : FarmStatusLevel.neutral, dense: true),
                          ]),
                          const SizedBox(height: 2),
                          Text(
                            'Makdous, Labneh, Kishk, Jam or any custom product — recipes, batches, finished-goods stock and profitability.',
                            style: FarmTypography.textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    Switch(value: mouneh.isActive, onChanged: (v) => mouneh.setModuleActive(v)),
                  ],
                ),
                const SizedBox(height: 6),
                Text('Toggle acts as the super-user activation control (REQ-MOU-001) — a real deployment gates this behind a super-user login.', style: FarmTypography.textTheme.bodySmall),
                const Divider(height: 24, color: FarmColors.border),
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(children: [
                            Text('Farm Visits & Agri-Tourism', style: FarmTypography.textTheme.titleSmall),
                            const SizedBox(width: 8),
                            StatusPill(label: visits.isActive ? 'Active' : 'Inactive', level: visits.isActive ? FarmStatusLevel.good : FarmStatusLevel.neutral, dense: true),
                          ]),
                          const SizedBox(height: 2),
                          Text(
                            'Bookings, activities, visitor check-in, farm-shop POS and visit profitability — only shown once licensed.',
                            style: FarmTypography.textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    Switch(value: visits.isActive, onChanged: (v) => visits.setModuleActive(v)),
                  ],
                ),
                const SizedBox(height: 6),
                Text('Toggle acts as the super-user activation control (RULE-VIS-001) — a real deployment gates this behind a super-user login.', style: FarmTypography.textTheme.bodySmall),
              ],
            ),
          ),
          const SizedBox(height: FarmSpacing.md),
          SectionCard(
            title: 'Roles',
            subtitle: 'Owner · Manager · Worker · Veterinarian · Accountant · Read-only',
            child: Text(
              'Role-based access is enforced on the backend (see backend/app/api/deps.py). '
              'Worker accounts can capture observations and production records but cannot enter a '
              'diagnosis — that is reserved for Manager, Owner and Veterinarian roles.',
              style: FarmTypography.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        Expanded(child: Text(label, style: const TextStyle(color: FarmColors.muted))),
        Text(value, style: FarmTypography.textTheme.titleSmall),
      ]),
    );
  }
}
