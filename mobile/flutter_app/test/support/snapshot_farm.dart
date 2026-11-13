import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'package:farmos/api/api_client.dart';
import 'package:farmos/app/app_navigator.dart';
import 'package:farmos/auth/session_controller.dart';
import 'package:farmos/core/theme/theme.dart';
import 'package:farmos/domain/entities/user_profile.dart';
import 'package:farmos/providers/access_provider.dart';
import 'package:farmos/providers/agriculture_provider.dart';
import 'package:farmos/providers/animals_provider.dart';
import 'package:farmos/providers/emergency_provider.dart';
import 'package:farmos/providers/employees_provider.dart';
import 'package:farmos/providers/feed_provider.dart';
import 'package:farmos/providers/feeding_provider.dart';
import 'package:farmos/providers/herd_records_provider.dart';
import 'package:farmos/providers/livestock_provider.dart';
import 'package:farmos/providers/mouneh_provider.dart';
import 'package:farmos/providers/notifications_provider.dart';
import 'package:farmos/providers/pharmacy_provider.dart';
import 'package:farmos/providers/production_provider.dart';
import 'package:farmos/providers/recommendations_provider.dart';
import 'package:farmos/providers/sales_provider.dart';
import 'package:farmos/providers/tasks_provider.dart';
import 'package:farmos/providers/visits_provider.dart';
import 'package:farmos/sync/sync_controller.dart';

/// The bundled demo farm (`assets/demo/snapshot.json`, the API's own
/// output from `backend/app/export_demo_snapshot.py`) served as the API,
/// so a widget test can draw a real screen over real server shapes.
Map<String, dynamic> loadSnapshot() => jsonDecode(File('assets/demo/snapshot.json').readAsStringSync()) as Map<String, dynamic>;

/// Answers every GET from the snapshot; records every write and answers
/// it with the body it was sent, the way a queued offline write is
/// answered.
class SnapshotApi extends ApiClient {
  SnapshotApi(this.snapshot) : super(baseUrl: 'http://snapshot.invalid');
  final Map<String, dynamic> snapshot;
  final List<(String, String, Object?)> writes = [];

  @override
  Future<dynamic> get(String path, {Map<String, dynamic>? query}) async {
    final q = query == null || query.isEmpty ? '' : '?${Uri(queryParameters: {for (final e in query.entries) e.key: '${e.value}'}).query}';
    for (final key in ['GET $path$q', 'GET $path']) {
      if (snapshot.containsKey(key)) return _copy(snapshot[key]);
    }
    for (final key in snapshot.keys) {
      if (key.startsWith('GET $path?')) return _copy(snapshot[key]);
    }
    return const <dynamic>[];
  }

  dynamic _copy(Object? body) => jsonDecode(jsonEncode(body));

  Future<dynamic> _record(String method, String path, Object? body) async {
    writes.add((method, path, body));
    return <String, dynamic>{'id': 'local-${writes.length}', if (body is Map) ...body.cast<String, dynamic>()};
  }

  @override
  Future<dynamic> post(String path, {Object? body, Map<String, dynamic>? query}) => _record('POST', path, body);
  @override
  Future<dynamic> patch(String path, {Object? body}) => _record('PATCH', path, body);
  @override
  Future<dynamic> put(String path, {Object? body}) => _record('PUT', path, body);
  @override
  Future<dynamic> delete(String path) => _record('DELETE', path, null);
}

/// The demo farm's manager, signed in.
class SnapshotFarm {
  SnapshotFarm._(this.api, this.session);
  final SnapshotApi api;
  final SessionController session;

  static Future<SnapshotFarm> open() async {
    final api = SnapshotApi(loadSnapshot());
    final me = (api.snapshot['GET /auth/me'] as Map).cast<String, dynamic>();
    final session = _SnapshotSession(api)
      ..user = UserProfile.fromJson(me)
      ..status = SessionStatus.loggedIn;
    return SnapshotFarm._(api, session);
  }

  /// [home] inside the same provider tree the app builds, every provider
  /// loaded from the snapshot.
  Widget app(Widget home, {Locale locale = const Locale('en')}) {
    final user = session.user!;
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<SessionController>.value(value: session),
        ChangeNotifierProvider(create: (_) => AppNavigator()),
        ChangeNotifierProvider(create: (_) => SyncController(api: api)),
        ChangeNotifierProvider(create: (_) => AccessProvider(apiClient: api)..load()),
        ChangeNotifierProvider(create: (_) => NotificationsProvider(apiClient: api)..load()),
        ChangeNotifierProvider(create: (_) => EmployeesProvider(apiClient: api)),
        ChangeNotifierProvider(create: (_) => AgricultureProvider(apiClient: api)),
        ChangeNotifierProvider(create: (_) => TasksProvider(apiClient: api, farmId: user.farmId, currentUserId: user.id)..load()),
        ChangeNotifierProvider(create: (_) => AnimalsProvider(apiClient: api, farmId: user.farmId, currentUserId: user.id)..load()),
        ChangeNotifierProvider(create: (_) => LivestockProvider(apiClient: api)..load()),
        ChangeNotifierProvider(create: (_) => HerdRecordsProvider(apiClient: api)..loadOverview()),
        ChangeNotifierProvider(create: (_) => FeedProvider(apiClient: api, farmId: user.farmId)..load()),
        ChangeNotifierProvider(create: (_) => FeedingProvider(apiClient: api)..load()),
        ChangeNotifierProvider(create: (_) => PharmacyProvider(apiClient: api)),
        ChangeNotifierProvider(create: (_) => EmergencyProvider(apiClient: api)),
        ChangeNotifierProvider(create: (_) => ProductionProvider(apiClient: api, farmId: user.farmId)..load()),
        ChangeNotifierProvider(create: (_) => RecommendationsProvider(apiClient: api, farmId: user.farmId, currentUserId: user.id)..load()),
        ChangeNotifierProvider(create: (_) => SalesProvider(apiClient: api, farmId: user.farmId)),
        ChangeNotifierProvider(create: (_) => MounehProvider(apiClient: api)),
        ChangeNotifierProvider(create: (_) => VisitsProvider(apiClient: api)),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: FarmTheme.light,
        locale: locale,
        supportedLocales: const [Locale('en'), Locale('ar')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: home,
      ),
    );
  }
}

/// A signed-in session whose API is the snapshot — screens that fetch
/// through `session.apiClient` (the Morning briefing) read it too.
class _SnapshotSession extends SessionController {
  _SnapshotSession(this._api);
  final SnapshotApi _api;

  @override
  ApiClient get apiClient => _api;
}
