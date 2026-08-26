import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import '../auth/session_controller.dart';
import '../core/i18n/locale_controller.dart';
import '../core/theme/theme.dart';
import '../core/widgets/app_shell.dart';
import '../domain/entities/user_profile.dart';
import '../features/auth/login_screen.dart';
import '../providers/animals_provider.dart';
import '../providers/feed_provider.dart';
import '../providers/mouneh_provider.dart';
import '../providers/production_provider.dart';
import '../providers/recommendations_provider.dart';
import '../providers/sales_provider.dart';
import '../providers/tasks_provider.dart';
import '../providers/visits_provider.dart';
import 'nav_config.dart';

class FarmOSApp extends StatelessWidget {
  const FarmOSApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => LocaleController()),
        ChangeNotifierProvider(create: (_) => SessionController()..restore()),
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

/// No demo mode, no offline cache, and — per the "one-time login" design —
/// no Welcome screen: [SessionController.restore] runs once at startup and
/// this just reflects whatever it found (a still-valid saved token, or
/// nothing, in which case [LoginScreen] is the entire landing page).
class _RootRouter extends StatelessWidget {
  const _RootRouter();

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionController>();
    switch (session.status) {
      case SessionStatus.checking:
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      case SessionStatus.loggedOut:
        return const LoginScreen();
      case SessionStatus.loggedIn:
        return _AuthenticatedApp(key: ValueKey(session.user!.id), session: session);
    }
  }
}

/// Everything behind the login — one farm-data provider tree per signed-in
/// account. Keyed on the user's id so logging out and back in as a
/// different account (e.g. handing the tablet to another employee) always
/// rebuilds a fresh provider tree rather than reusing one that may still
/// hold the previous account's data.
class _AuthenticatedApp extends StatelessWidget {
  const _AuthenticatedApp({super.key, required this.session});
  final SessionController session;

  @override
  Widget build(BuildContext context) {
    final api = session.apiClient;
    final user = session.user!;
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => TasksProvider(apiClient: api, farmId: user.farmId, currentUserId: user.id)),
        ChangeNotifierProvider(create: (_) => AnimalsProvider(apiClient: api, farmId: user.farmId, currentUserId: user.id)),
        ChangeNotifierProvider(create: (_) => FeedProvider(apiClient: api, farmId: user.farmId)),
        ChangeNotifierProvider(create: (_) => ProductionProvider(apiClient: api, farmId: user.farmId)),
        ChangeNotifierProvider(create: (_) => RecommendationsProvider(apiClient: api, farmId: user.farmId, currentUserId: user.id)),
        ChangeNotifierProvider(create: (_) => SalesProvider(apiClient: api, farmId: user.farmId)),
        ChangeNotifierProvider(create: (_) => MounehProvider(apiClient: api)),
        ChangeNotifierProvider(create: (_) => VisitsProvider(apiClient: api)),
      ],
      child: _DataLoader(user: user),
    );
  }
}

/// Loads every farm-data provider once up front so the shell's screens can
/// read from them synchronously (no per-screen loading spinners) — the
/// same one-shot-then-cached shape [MounehProvider]/[VisitsProvider] have
/// always used, just fanned out across the whole app now that there's no
/// local database to seed instead.
class _DataLoader extends StatefulWidget {
  const _DataLoader({required this.user});
  final UserProfile user;

  @override
  State<_DataLoader> createState() => _DataLoaderState();
}

class _DataLoaderState extends State<_DataLoader> {
  late final Future<void> _loadAll;

  @override
  void initState() {
    super.initState();
    _loadAll = Future.wait([
      context.read<TasksProvider>().load(includeRoster: widget.user.isManager),
      context.read<AnimalsProvider>().load(),
      context.read<FeedProvider>().load(),
      context.read<ProductionProvider>().load(),
      context.read<RecommendationsProvider>().load(),
      context.read<SalesProvider>().load(),
      context.read<MounehProvider>().load(),
      context.read<VisitsProvider>().load(),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _loadAll,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        final nav = buildNavForUser(widget.user);
        return AppShell(entries: nav.entries, screens: nav.screens);
      },
    );
  }
}
