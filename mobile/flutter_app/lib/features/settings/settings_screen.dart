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
import '../../providers/tasks_provider.dart';

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

/// What this farm's subscription includes.
///
/// This card used to be two switches. Mouneh and Farm Visits were sold
/// separately, and a super user turned them on per farm; everything else
/// in the app was simply there. Origami is one subscription covering the
/// whole product now, so there is nothing to switch — and a toggle for a
/// decision nobody can make reads as a decision somebody made.
class _ModulesCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: 'Modules',
      subtitle: 'Every module is included in your subscription',
      child: Column(
        children: [
          _IncludedModule(
            title: 'Mouneh & Farm Product Processing',
            detail:
                'Makdous, Labneh, Kishk, Jam or any custom product — recipes, batches, '
                'finished-goods stock and profitability.',
          ),
          const Divider(height: 24, color: FarmColors.border),
          _IncludedModule(
            title: 'Farm Visits & Agri-Tourism',
            detail:
                'Bookings, activities, visitor check-in, farm-shop POS and visit '
                'profitability.',
          ),
          const SizedBox(height: 6),
          Text(
            'What each person on your farm can open is set on the Employees screen, not here.',
            style: FarmTypography.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _IncludedModule extends StatelessWidget {
  _IncludedModule({required this.title, required this.detail});
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Expanded(child: Text(title, style: FarmTypography.textTheme.titleSmall)),
                const SizedBox(width: 8),
                const StatusPill(label: 'Included', level: FarmStatusLevel.good, dense: true),
              ]),
              const SizedBox(height: 2),
              Text(detail, style: FarmTypography.textTheme.bodySmall),
            ],
          ),
        ),
      ],
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
