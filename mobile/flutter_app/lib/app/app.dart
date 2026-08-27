import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import '../auth/session_controller.dart';
import '../core/i18n/locale_controller.dart';
import '../core/theme/theme.dart';
import '../core/widgets/app_shell.dart';
import '../data/local/local_store.dart';
import '../domain/entities/user_profile.dart';
import '../features/auth/login_screen.dart';
import '../providers/access_provider.dart';
import '../providers/agriculture_provider.dart';
import '../providers/animals_provider.dart';
import '../providers/employees_provider.dart';
import '../providers/feed_provider.dart';
import '../providers/mouneh_provider.dart';
import '../providers/notifications_provider.dart';
import '../providers/production_provider.dart';
import '../providers/recommendations_provider.dart';
import '../providers/sales_provider.dart';
import '../providers/tasks_provider.dart';
import '../providers/visits_provider.dart';
import '../sync/sync_controller.dart';
import 'app_navigator.dart';
import 'nav_config.dart';

class FarmOSApp extends StatelessWidget {
  const FarmOSApp({super.key, this.store});

  /// The tablet's offline store. Null in widget tests, where there is no
  /// SQLite platform channel — the app then runs online-only.
  final LocalStore? store;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => LocaleController()),
        ChangeNotifierProvider(create: (_) => SessionController(store: store)..restore()),
      ],
      child: Consumer2<LocaleController, SessionController>(
        builder: (context, locale, session, _) {
          final app = MaterialApp(
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
            home: switch (session.status) {
              SessionStatus.checking => const Scaffold(body: Center(child: CircularProgressIndicator())),
              SessionStatus.loggedOut => const LoginScreen(),
              SessionStatus.loggedIn => _DataLoader(user: session.user!),
            },
          );
          if (session.status != SessionStatus.loggedIn) return app;
          // The farm providers wrap the MaterialApp, not its `home`.
          // MaterialApp owns the Navigator, and a pushed route or dialog
          // is a *sibling* of `home` — so anything provided below it is
          // invisible to the Digital Twin screen, the notification panel
          // and every form opened with showDialog. Above it, they see
          // everything.
          return _FarmScope(key: ValueKey(session.user!.id), session: session, child: app);
        },
      ),
    );
  }
}

/// Everything behind the login — one provider tree per signed-in account.
/// Keyed on the user's id so handing the tablet to a colleague rebuilds
/// the tree rather than leaving the previous account's data behind it.
class _FarmScope extends StatelessWidget {
  const _FarmScope({super.key, required this.session, required this.child});
  final SessionController session;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final api = session.apiClient;
    final user = session.user!;
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AppNavigator()),
        ChangeNotifierProvider(create: (_) => SyncController(api: api)),
        ChangeNotifierProvider(create: (_) => AccessProvider(apiClient: api)),
        ChangeNotifierProvider(create: (_) => NotificationsProvider(apiClient: api)),
        ChangeNotifierProvider(create: (_) => EmployeesProvider(apiClient: api)),
        ChangeNotifierProvider(create: (_) => AgricultureProvider(apiClient: api)),
        ChangeNotifierProvider(create: (_) => TasksProvider(apiClient: api, farmId: user.farmId, currentUserId: user.id)),
        ChangeNotifierProvider(create: (_) => AnimalsProvider(apiClient: api, farmId: user.farmId, currentUserId: user.id)),
        ChangeNotifierProvider(create: (_) => FeedProvider(apiClient: api, farmId: user.farmId)),
        ChangeNotifierProvider(create: (_) => ProductionProvider(apiClient: api, farmId: user.farmId)),
        ChangeNotifierProvider(create: (_) => RecommendationsProvider(apiClient: api, farmId: user.farmId, currentUserId: user.id)),
        ChangeNotifierProvider(create: (_) => SalesProvider(apiClient: api, farmId: user.farmId)),
        ChangeNotifierProvider(create: (_) => MounehProvider(apiClient: api)),
        ChangeNotifierProvider(create: (_) => VisitsProvider(apiClient: api)),
      ],
      child: child,
    );
  }
}

/// Loads the farm data once up front so screens can read it synchronously.
///
/// Permissions come first and alone: the navigation itself depends on
/// them, and a module the user does not hold should not be fetched at all.
/// The rest load together, and a module the user cannot see is skipped
/// rather than fetched and discarded.
class _DataLoader extends StatefulWidget {
  const _DataLoader({required this.user});
  final UserProfile user;

  @override
  State<_DataLoader> createState() => _DataLoaderState();
}

class _DataLoaderState extends State<_DataLoader> with WidgetsBindingObserver {
  late final Future<void> _boot = _startup();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Picking the tablet back up is the most likely moment for it to be
  /// back in range — check there and then rather than waiting out the
  /// backoff timer.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || !mounted) return;
    final sync = context.read<SyncController>();
    if (!sync.enabled) return;
    if (sync.online) {
      sync.syncNow();
    } else {
      context.read<SessionController>().apiClient.monitor.checkNow();
    }
  }

  Future<void> _startup() async {
    final sync = context.read<SyncController>();
    // Once the queue drains, throw away the local predictions and take the
    // server's version: real IDs, server-computed totals, fresh signals.
    sync.onSynced = _refreshAll;
    await _refreshAll();
    if (!mounted) return;
    await sync.start();
  }

  Future<void> _refreshAll() async {
    final access = context.read<AccessProvider>();
    try {
      await access.load();
    } catch (_) {
      // Offline with nothing cached yet: the shell renders its empty
      // state rather than a crash, and the sync pill explains why.
    }
    if (!mounted) return;

    // A failed module load must not take the whole app down with it — a
    // farm with no Visits data should still get its animals.
    Future<void> ifAllowed(String module, Future<void> Function() load) async {
      if (!access.isModuleAvailable(module)) return;
      try {
        await load();
      } catch (_) {
        // Screens render their own empty/error state.
      }
    }

    await Future.wait([
      ifAllowed(FarmModuleShortcuts.tasks, () => context.read<TasksProvider>().load(includeRoster: access.isFullAccess)),
      ifAllowed(FarmModuleShortcuts.animals, () => context.read<AnimalsProvider>().load()),
      ifAllowed(FarmModuleShortcuts.feed, () => context.read<FeedProvider>().load()),
      ifAllowed(FarmModuleShortcuts.produce, () => context.read<ProductionProvider>().load()),
      ifAllowed(FarmModuleShortcuts.agriculture, () => context.read<AgricultureProvider>().load()),
      ifAllowed(FarmModuleShortcuts.ai, () => context.read<RecommendationsProvider>().load()),
      ifAllowed(FarmModuleShortcuts.finance, () => context.read<SalesProvider>().load()),
      ifAllowed(FarmModuleShortcuts.mouneh, () => context.read<MounehProvider>().load()),
      ifAllowed(FarmModuleShortcuts.visits, () => context.read<VisitsProvider>().load()),
      // The bell is for everyone: the backend already scopes its contents
      // to the modules this user holds.
      context.read<NotificationsProvider>().load(),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _boot,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        final access = context.watch<AccessProvider>();
        final plan = buildNavForAccess(access);
        // Registered every build so the tab map follows a permission change
        // (a manager granting themselves a module mid-session, say).
        context.read<AppNavigator>().registerTabs(plan.moduleIndex);
        return AppShell(entries: plan.entries, screens: plan.screens);
      },
    );
  }
}

/// The module codes `_DataLoader` gates each fetch on, named for the
/// provider they belong to so the wiring above reads as a list of
/// "load this if they can see it".
class FarmModuleShortcuts {
  static const tasks = 'tasks';
  static const animals = 'animals';
  static const feed = 'feed_nutrition';
  static const produce = 'produce_harvest';
  static const agriculture = 'agriculture';
  static const ai = 'ai_intelligence';
  static const finance = 'finance';
  static const mouneh = 'mouneh_production';
  static const visits = 'farm_visits';
}
