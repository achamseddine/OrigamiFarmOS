import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../app/build_info.dart';
import '../../auth/session_controller.dart';
import '../../core/i18n/locale_controller.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/widgets/app_icon.dart';
import '../../core/widgets/brand_logo.dart';
import '../../core/widgets/hero_band.dart';
import '../../core/widgets/section_card.dart';
import '../../core/util/number_input.dart';
import '../../core/widgets/status_pill.dart';
import '../../providers/herd_records_provider.dart';
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
          HeroBand(
            eyebrow: context.t('ebSettings'),
            title: context.t('navSettings'),
            subtitle: context.t('settingsSubtitle'),
            icon: FarmIcon.settings,
            scenery: false,
          ),
          const SizedBox(height: FarmSpacing.md),
          // About: the full logo and the build stamp, so "which version is
          // on this tablet" is answerable from inside the app as well as
          // from the sign-in screen.
          SectionCard(
            title: context.t('aboutApp'),
            child: Row(children: [
              const BrandLogo(height: 44),
              const SizedBox(width: FarmSpacing.lg),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(kAppStamp, style: FarmTypography.textTheme.titleSmall),
                    Text(context.t('aboutAppBody'), style: FarmTypography.textTheme.bodySmall),
                  ],
                ),
              ),
            ]),
          ),
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
            if (_farm != null) ...[
              _DryOffCard(
                days: (_farm!['dry_off_days_before_birth'] as num?)?.toInt() ?? 60,
                onSaved: (farm) => setState(() => _farm = farm),
              ),
              const SizedBox(height: FarmSpacing.md),
            ],
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

/// The farm's dry-off setting: how many days before an expected birth a
/// milking animal stops being milked. Changes the "dry off from" date on
/// every pregnant animal in milk; the dry-off itself is still recorded on
/// the animal when it happens.
class _DryOffCard extends StatefulWidget {
  const _DryOffCard({required this.days, required this.onSaved});
  final int days;
  final ValueChanged<Map<String, dynamic>> onSaved;

  @override
  State<_DryOffCard> createState() => _DryOffCardState();
}

class _DryOffCardState extends State<_DryOffCard> {
  late final _days = TextEditingController(text: '${widget.days}');
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _days.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final days = parseLocalizedInt(_days.text);
    if (days == null || days < 0 || days > 200) {
      setState(() => _error = context.t('fsDryOffInvalid'));
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final api = context.read<SessionController>().apiClient;
    final herd = context.read<HerdRecordsProvider>();
    final messenger = ScaffoldMessenger.of(context);
    final saved = context.t('fsSaved');
    final result = await api.write(() => api.patch('/farms/me', body: {'dry_off_days_before_birth': days}));
    if (!mounted) return;
    setState(() {
      _saving = false;
      _error = result.error;
    });
    if (!result.success) return;
    if (result.data is Map<String, dynamic> && !result.queued) widget.onSaved(result.data! as Map<String, dynamic>);
    await herd.loadOverview();
    messenger.showSnackBar(SnackBar(content: Text(saved)));
  }

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: context.t('fsDryOffTitle'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(context.t('fsDryOffBody'), style: FarmTypography.textTheme.bodySmall),
        const SizedBox(height: FarmSpacing.sm),
        Row(children: [
          SizedBox(
            width: 140,
            child: TextField(
              key: const ValueKey('dry-off-days'),
              controller: _days,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: context.t('fsDryOffTitle'), suffixText: context.t('fsDays'), isDense: true),
            ),
          ),
          const SizedBox(width: FarmSpacing.md),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: _saving ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2)) : Text(context.t('save')),
          ),
        ]),
        if (_error != null) ...[
          const SizedBox(height: 6),
          Text(_error!, style: const TextStyle(color: FarmColors.danger, fontSize: 12.5)),
        ],
      ]),
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
