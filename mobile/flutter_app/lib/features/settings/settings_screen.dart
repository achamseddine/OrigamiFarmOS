import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/i18n/locale_controller.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/widgets/section_card.dart';
import '../../data/demo/demo_data.dart';
import '../../data/local/local_repository.dart';
import '../../data/remote/api_exception.dart';
import '../../data/remote/farmos_api.dart';
import '../../data/remote/session_manager.dart';
import '../../data/repositories/bootstrap_repository.dart';
import '../../providers/animals_provider.dart';
import '../../providers/feed_provider.dart';
import '../../providers/finance_provider.dart';
import '../../providers/recommendations_provider.dart';
import '../../providers/tasks_provider.dart';
import '../../sync/sync_queue_controller.dart';

/// Farm configuration (tech spec §6 nav table: "Users, roles, languages,
/// currency, thresholds") plus the server connection this app now has:
/// signing in here is what switches a farm from demo mode (local
/// `DemoData`/seeded SQLite only) to real mode (server-backed, cached to
/// SQLite for offline use) — see `data/repositories/bootstrap_repository.dart`.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _baseUrlController;
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _signingIn = false;
  String? _statusMessage;

  @override
  void initState() {
    super.initState();
    final session = context.read<SessionManager>();
    _baseUrlController = TextEditingController(text: session.baseUrl);
  }

  @override
  void dispose() {
    _baseUrlController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    // Captured up front — a `mounted` check doesn't make a later
    // `context.read` safe after an `await`, only a local reference does.
    final session = context.read<SessionManager>();
    final api = context.read<FarmosApi>();
    final bootstrapRepository = context.read<BootstrapRepository>();
    final localRepository = context.read<LocalRepository>();
    final animalsProvider = context.read<AnimalsProvider>();
    final feedProvider = context.read<FeedProvider>();
    final tasksProvider = context.read<TasksProvider>();
    final financeProvider = context.read<FinanceProvider>();
    final recommendationsProvider = context.read<RecommendationsProvider>();
    // Whoever was signed in before this attempt, if anyone — used below to
    // clear their data off the tablet if a *different* farm signs in.
    final previousFarmId = session.farmId;

    setState(() {
      _signingIn = true;
      _statusMessage = null;
    });
    try {
      await session.setBaseUrl(_baseUrlController.text);
      final token = await api.login(
        email: _emailController.text.trim(),
        password: _passwordController.text,
      );
      // Stash the token first so the GET /auth/me call below carries it.
      await session.saveSession(token: token, farmId: '', userId: '', displayName: '', role: '');
      final me = await api.me();
      final newFarmId = me['farm_id'] as String? ?? '';
      await session.saveSession(
        token: token,
        farmId: newFarmId,
        userId: me['id'] as String? ?? '',
        displayName: me['name'] as String? ?? '',
        role: me['role'] as String? ?? '',
      );

      // A different farm is taking over this tablet — clear the previous
      // one's cached rows and unsent queue rather than letting two farms'
      // data sit side by side in one database.
      if (previousFarmId != null && previousFarmId.isNotEmpty && previousFarmId != newFarmId) {
        await localRepository.purgeFarmData(previousFarmId);
      }

      final result = await bootstrapRepository.run();
      if (!mounted) return;
      if (result.success) {
        await Future.wait([animalsProvider.reload(), feedProvider.reload(), tasksProvider.reload()]);
        await Future.wait([financeProvider.refresh(), recommendationsProvider.refresh()]);
        setState(() => _statusMessage = 'Signed in as ${session.displayName} — data synced.');
      } else {
        setState(() => _statusMessage = 'Signed in, but the initial sync failed'
            '${result.error != null ? ': ${result.error}' : ' (offline).'}');
      }
      _passwordController.clear();
    } on ApiException catch (e) {
      setState(() => _statusMessage = e.detail);
    } on ApiOfflineException catch (e) {
      setState(() => _statusMessage = e.message);
    } finally {
      if (mounted) setState(() => _signingIn = false);
    }
  }

  Future<void> _signOut() async {
    final session = context.read<SessionManager>();
    final localRepository = context.read<LocalRepository>();
    final animalsProvider = context.read<AnimalsProvider>();
    final feedProvider = context.read<FeedProvider>();
    final tasksProvider = context.read<TasksProvider>();

    // Purge before clearing the session — purgeFarmData needs to know
    // which farm's rows to remove, and after signOut() that's gone.
    // Anything still queued for this farm goes with it: it can't be
    // uploaded without this farmer's token, and leaving it on a shared
    // tablet is exactly what we don't want.
    final farmId = session.farmId;
    if (farmId != null) await localRepository.purgeFarmData(farmId);
    await session.signOut();

    // Re-read so the screens fall back to the demo farm immediately
    // rather than showing the signed-out farm's rows until next launch.
    await Future.wait([animalsProvider.reload(), feedProvider.reload(), tasksProvider.reload()]);
    if (!mounted) return;
    setState(() => _statusMessage = 'Signed out — this farm\'s data has been removed from '
        'this tablet, and it is back in demo mode.');
  }

  @override
  Widget build(BuildContext context) {
    final locale = context.watch<LocaleController>();
    final sync = context.watch<SyncQueueController>();
    final session = context.watch<SessionManager>();

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
            title: 'Server connection',
            subtitle: session.isLoggedIn
                ? 'Signed in as ${session.displayName} (${session.role}) — real data, cached '
                    'locally for offline use.'
                : 'Not signed in — this tablet is running in demo mode on local sample data.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: _baseUrlController,
                  enabled: !session.isLoggedIn,
                  decoration: const InputDecoration(labelText: 'Server URL'),
                ),
                const SizedBox(height: FarmSpacing.sm),
                if (!session.isLoggedIn) ...[
                  TextField(
                    controller: _emailController,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(labelText: 'Email'),
                  ),
                  const SizedBox(height: FarmSpacing.sm),
                  TextField(
                    controller: _passwordController,
                    obscureText: true,
                    decoration: const InputDecoration(labelText: 'Password'),
                    onSubmitted: (_) => _signingIn ? null : _signIn(),
                  ),
                  const SizedBox(height: FarmSpacing.sm),
                  FilledButton(
                    onPressed: _signingIn ? null : _signIn,
                    child: _signingIn
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Sign in & sync'),
                  ),
                ] else
                  OutlinedButton(onPressed: _signOut, child: const Text('Sign out (back to demo mode)')),
                if (_statusMessage != null) ...[
                  const SizedBox(height: FarmSpacing.sm),
                  Text(_statusMessage!, style: FarmTypography.textTheme.bodySmall),
                ],
              ],
            ),
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
            title: 'Roles',
            subtitle: 'Owner · Manager · Worker · Veterinarian · Accountant · Read-only',
            child: Text(
              'Role-based access is enforced on the backend (see OrigamiFarmServer '
              'app/farmos/deps.py and app/farmos/permissions.py). Worker accounts can capture '
              'observations and production records but cannot enter a diagnosis — that is '
              'reserved for Manager, Owner and Veterinarian roles.',
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
