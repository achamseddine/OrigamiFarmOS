import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import '../core/i18n/locale_controller.dart';
import '../core/theme/theme.dart';
import '../core/widgets/app_shell.dart';
import '../data/local/demo_seed.dart';
import '../data/local/farm_write_service.dart';
import '../data/remote/api_client.dart';
import '../data/remote/farmos_api.dart';
import '../data/remote/session_manager.dart';
import '../data/repositories/bootstrap_repository.dart';
import '../data/sync/sync_engine.dart';
import '../features/animals/animal_status_screen.dart';
import '../features/feed/feed_inventory_screen.dart';
import '../features/finance/sales_finance_screen.dart';
import '../features/health/health_intelligence_screen.dart';
import '../features/morning/morning_briefing_screen.dart';
import '../features/production/egg_production_screen.dart';
import '../features/production/milk_production_screen.dart';
import '../features/produce/produce_harvest_screen.dart';
import '../features/tasks/tasks_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/welcome/welcome_screen.dart';
import '../providers/animals_provider.dart';
import '../providers/feed_provider.dart';
import '../providers/finance_provider.dart';
import '../providers/recommendations_provider.dart';
import '../providers/tasks_provider.dart';
import '../sync/sync_queue_controller.dart';

class FarmOSApp extends StatelessWidget {
  const FarmOSApp({super.key});

  @override
  Widget build(BuildContext context) {
    final session = SessionManager();
    final apiClient = ApiClient(session);
    final api = FarmosApi(apiClient);
    final syncEngine = SyncEngine(session: session, api: api);
    final bootstrapRepository = BootstrapRepository(session: session, api: api);
    final writeService = FarmWriteService(session: session);

    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => LocaleController()),
        ChangeNotifierProvider.value(value: session),
        Provider<FarmosApi>.value(value: api),
        Provider<BootstrapRepository>.value(value: bootstrapRepository),
        ChangeNotifierProvider(create: (_) => SyncQueueController(engine: syncEngine)),
        Provider<FarmWriteService>.value(value: writeService),
        ChangeNotifierProxyProvider<SyncQueueController, TasksProvider>(
          create: (context) => TasksProvider(
            writeService: writeService,
            syncQueue: context.read<SyncQueueController>(),
          ),
          update: (context, sync, previous) => previous!,
        ),
        ChangeNotifierProxyProvider<SyncQueueController, AnimalsProvider>(
          create: (context) => AnimalsProvider(
            writeService: writeService,
            syncQueue: context.read<SyncQueueController>(),
          ),
          update: (context, sync, previous) => previous!,
        ),
        ChangeNotifierProxyProvider<SyncQueueController, FeedProvider>(
          create: (context) => FeedProvider(
            writeService: writeService,
            syncQueue: context.read<SyncQueueController>(),
          ),
          update: (context, sync, previous) => previous!,
        ),
        ChangeNotifierProvider(create: (_) => FinanceProvider(session: session, api: api)),
        ChangeNotifierProvider(create: (_) => RecommendationsProvider(session: session, api: api)),
      ],
      child: Consumer<LocaleController>(
        builder: (context, locale, _) {
          return MaterialApp(
            title: 'Origami FarmOS',
            debugShowCheckedModeBanner: false,
            theme: FarmTheme.light,
            locale: locale.locale,
            supportedLocales: const [Locale('en'), Locale('ar')],
            localizationsDelegates: const [
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            home: const _RootRouter(),
          );
        },
      ),
    );
  }
}

class _RootRouter extends StatefulWidget {
  const _RootRouter();

  @override
  State<_RootRouter> createState() => _RootRouterState();
}

class _RootRouterState extends State<_RootRouter> {
  bool _started = false;
  bool _seeding = false;

  Future<void> _start() async {
    // Captured up front — never read `context` again after an `await` in
    // this method (a `mounted` check doesn't make a later `context.read`
    // safe, only a `State` field reference does).
    final session = context.read<SessionManager>();
    final bootstrapRepository = context.read<BootstrapRepository>();
    final animalsProvider = context.read<AnimalsProvider>();
    final feedProvider = context.read<FeedProvider>();
    final tasksProvider = context.read<TasksProvider>();
    final financeProvider = context.read<FinanceProvider>();
    final recommendationsProvider = context.read<RecommendationsProvider>();

    setState(() => _seeding = true);
    try {
      await DemoSeed.ensureSeeded();
    } catch (_) {
      // Local persistence is a progressive enhancement in this build —
      // screens still render from the in-memory demo dataset if the
      // platform's SQLite plugin is unavailable (e.g. certain CI/desktop
      // test targets), matching the mock-data-first milestone (M3).
    }

    await session.load();
    // A farm that has signed in before (Settings → Server connection) gets
    // its real data pulled down and cached over the demo seed; a farm that
    // hasn't stays in demo mode with exactly today's behavior. The two
    // read-only providers (finance, recommendations) already tried once in
    // their own constructor, before `session.load()` above resolved — this
    // is the real attempt.
    if (session.isLoggedIn) {
      final result = await bootstrapRepository.run();
      if (result.success) {
        await Future.wait([animalsProvider.reload(), feedProvider.reload(), tasksProvider.reload()]);
      }
      await Future.wait([financeProvider.refresh(), recommendationsProvider.refresh()]);
    }
    if (!mounted) return;
    setState(() {
      _seeding = false;
      _started = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_started) {
      return const AppShell(
        screens: [
          MorningBriefingScreen(),
          AnimalStatusScreen(),
          FeedInventoryScreen(),
          MilkProductionScreen(),
          EggProductionScreen(),
          HealthIntelligenceScreen(),
          ProduceHarvestScreen(),
          SalesFinanceScreen(),
          TasksScreen(),
          SettingsScreen(),
        ],
      );
    }
    if (_seeding) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return WelcomeScreen(onStart: _start);
  }
}
