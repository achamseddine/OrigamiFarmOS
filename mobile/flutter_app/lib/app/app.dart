import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import '../core/i18n/locale_controller.dart';
import '../core/theme/theme.dart';
import '../core/widgets/app_shell.dart';
import '../data/local/farm_read_service.dart';
import '../data/local/farm_write_service.dart';
import '../features/live_data_screen.dart';
import '../features/tasks/tasks_screen.dart';
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
    final readService = FarmReadService();

    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => LocaleController()),
        ChangeNotifierProvider(create: (_) => SyncQueueController()),
        Provider<FarmWriteService>.value(value: writeService),
        Provider<FarmReadService>.value(value: readService),
        ChangeNotifierProxyProvider<SyncQueueController, TasksProvider>(
          create: (context) => TasksProvider(
            writeService: writeService,
            readService: readService,
            syncQueue: context.read<SyncQueueController>(),
          ),
          update: (context, sync, previous) => previous!,
        ),
        ChangeNotifierProxyProvider<SyncQueueController, AnimalsProvider>(
          create: (context) => AnimalsProvider(
            writeService: writeService,
            readService: readService,
            syncQueue: context.read<SyncQueueController>(),
          ),
          update: (context, sync, previous) => previous!,
        ),
        ChangeNotifierProxyProvider<SyncQueueController, FeedProvider>(
          create: (context) => FeedProvider(
            writeService: writeService,
            readService: readService,
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
  bool _loading = false;

  Future<void> _start() async {
    setState(() => _loading = true);
    try {
      await Future.wait([
        context.read<AnimalsProvider>().load(),
        context.read<FeedProvider>().load(),
        context.read<TasksProvider>().load(),
      ]);
    } catch (_) {
      // The shell still opens with explicit empty states when SQLite is not
      // available (for example in widget tests without platform channels).
    }
    if (!mounted) return;
    setState(() {
      _loading = false;
      _started = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_started) {
      return const AppShell(
        screens: [
          LiveDataScreen(section: LiveDataSection.overview),
          LiveDataScreen(section: LiveDataSection.animals),
          LiveDataScreen(section: LiveDataSection.inventory),
          LiveDataScreen(section: LiveDataSection.milk),
          LiveDataScreen(section: LiveDataSection.eggs),
          LiveDataScreen(section: LiveDataSection.health),
          LiveDataScreen(section: LiveDataSection.produce),
          LiveDataScreen(section: LiveDataSection.finance),
          TasksScreen(),
          LiveDataScreen(section: LiveDataSection.settings),
        ],
      );
    }
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return WelcomeScreen(onStart: _start);
  }
}
