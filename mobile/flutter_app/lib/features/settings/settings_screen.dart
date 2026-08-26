import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../auth/session_controller.dart';
import '../../core/i18n/locale_controller.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/widgets/section_card.dart';
import '../../core/widgets/status_pill.dart';
import '../../providers/mouneh_provider.dart';
import '../../providers/tasks_provider.dart';
import '../../providers/visits_provider.dart';

/// Farm configuration (tech spec §6 nav table: "Users, roles, languages,
/// currency, thresholds"). Farm-wide sections (Modules, Roster) are
/// manager-only — an employee sees their own account and the language
/// toggle only.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  Map<String, dynamic>? _farm;
  String? _farmError;

  @override
  void initState() {
    super.initState();
    _loadFarm();
  }

  Future<void> _loadFarm() async {
    try {
      final json = await context.read<SessionController>().apiClient.get('/farms/me') as Map<String, dynamic>;
      if (!mounted) return;
      setState(() => _farm = json);
    } catch (_) {
      if (!mounted) return;
      setState(() => _farmError = 'Could not load farm details.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final locale = context.watch<LocaleController>();
    final session = context.watch<SessionController>();
    final user = session.user!;

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(context.t('navSettings'), style: FarmTypography.display(size: 28)),
          const SizedBox(height: FarmSpacing.md),
          SectionCard(
            title: 'My account',
            child: Column(children: [
              _Row(label: 'Name', value: user.name),
              _Row(label: 'Email', value: user.email ?? '—'),
              _Row(label: 'Role', value: user.role.replaceAll('_', ' ')),
              if (user.department != null) _Row(label: 'Department', value: user.department!),
            ]),
          ),
          const SizedBox(height: FarmSpacing.md),
          if (user.isManager) ...[
            SectionCard(
              title: 'Farm',
              child: _farm != null
                  ? Column(children: [
                      _Row(label: 'Name', value: _farm!['name'] as String? ?? '—'),
                      _Row(label: 'Region', value: '${_farm!['region'] ?? '—'}, ${_farm!['country'] ?? '—'}'),
                      _Row(label: 'Timezone', value: _farm!['timezone'] as String? ?? '—'),
                      _Row(label: 'Default currency', value: _farm!['default_currency'] as String? ?? '—'),
                    ])
                  : Text(_farmError ?? 'Loading…', style: FarmTypography.textTheme.bodySmall),
            ),
            const SizedBox(height: FarmSpacing.md),
          ],
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
          if (user.isManager) ...[
            const SizedBox(height: FarmSpacing.md),
            _RosterCard(),
            const SizedBox(height: FarmSpacing.md),
            _ModulesCard(),
          ],
          const SizedBox(height: FarmSpacing.md),
          SectionCard(
            title: 'Account',
            child: Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: () => session.logout(),
                icon: const Icon(Icons.logout, size: 18),
                label: const Text('Log out'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RosterCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final roster = context.watch<TasksProvider>().roster;
    return SectionCard(
      title: 'Team',
      subtitle: 'Every account on this farm — created by the platform, not from this screen.',
      child: roster.isEmpty
          ? Text('No other accounts loaded yet.', style: FarmTypography.textTheme.bodySmall)
          : Column(children: [
              for (final u in roster)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(u.name, style: FarmTypography.textTheme.titleSmall),
                          Text(u.email ?? '—', style: FarmTypography.textTheme.bodySmall),
                        ],
                      ),
                    ),
                    StatusPill(label: u.department ?? u.role.replaceAll('_', ' '), level: FarmStatusLevel.neutral, dense: true),
                  ]),
                ),
            ]),
    );
  }
}

class _ModulesCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final mouneh = context.watch<MounehProvider>();
    final visits = context.watch<VisitsProvider>();
    return SectionCard(
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
          Text('REQ-MOU-001: module activation is a super-user action — this toggle only succeeds when your account is one.', style: FarmTypography.textTheme.bodySmall),
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
          Text('RULE-VIS-001: module activation is a super-user action — this toggle only succeeds when your account is one.', style: FarmTypography.textTheme.bodySmall),
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
