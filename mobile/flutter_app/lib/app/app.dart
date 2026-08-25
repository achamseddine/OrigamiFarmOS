import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import '../core/i18n/locale_controller.dart';
import '../core/theme/theme.dart';
import '../core/widgets/app_shell.dart';
import '../data/local/demo_seed.dart';
import '../data/local/farm_write_service.dart';
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
import '../providers/tasks_provider.dart';
import '../sync/sync_queue_controller.dart';

class FarmOSApp extends StatelessWidget {
  const FarmOSApp({super.key});

  @override
  Widget build(BuildContext context) {
    final writeService = FarmWriteService();

    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => LocaleController()),
        ChangeNotifierProvider(create: (_) => SyncQueueController()),
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
    setState(() => _seeding = true);
    try {
      await DemoSeed.ensureSeeded();
    } catch (_) {
      // Local persistence is a progressive enhancement in this build —
      // screens still render from the in-memory demo dataset if the
      // platform's SQLite plugin is unavailable (e.g. certain CI/desktop
      // test targets), matching the mock-data-first milestone (M3).
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
