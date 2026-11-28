import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:farmos/api/api_client.dart';
import 'package:farmos/auth/offline_credentials.dart';
import 'package:farmos/auth/session_controller.dart';
import 'package:farmos/data/local/local_store.dart';
import 'package:farmos/sync/sync_controller.dart';

/// Offline sign-in after a restart (audit I-10, ADR-007): the worker who
/// signed in with the server can open the tablet again with no network,
/// see their farm and record; nothing is sent until the server accepts a
/// sign-in again, and then it is sent once.
const _server = 'https://farm.example/api/v1';
const _karim = {'id': 'user-karim', 'farm_id': 'farm-origami', 'name': 'Karim', 'email': 'karim@farm.example', 'role': 'worker'};

class _FakeStore implements LocalStore {
  @override
  String? activeUserId;
  String? boundUser;
  final List<OutboxItem> queue = [];
  final List<int> removed = [];
  final List<int> failed = [];

  @override
  bool get available => true;

  @override
  Future<void> setActiveUser(String? userId) async {
    activeUserId = userId;
    boundUser = userId;
  }

  @override
  Future<void> clearCachedFarmData() async => activeUserId = null;

  @override
  Future<List<OutboxItem>> outbox({bool pendingOnly = false}) async => [for (final i in queue) if (!removed.contains(i.id) && !failed.contains(i.id)) i];

  @override
  Future<int> pendingCount() async => (await outbox()).length;

  @override
  Future<int> failedCount() async => failed.length;

  @override
  Future<int> otherUsersPendingCount() async => 0;

  @override
  Future<Set<String>> pendingLocalIds() async => {for (final i in await outbox()) if (i.localId != null) i.localId!};

  @override
  Future<void> removeFromOutbox(int id) async => removed.add(id);

  @override
  Future<void> markOutboxFailed(int id, String error, {required bool permanent, Map<String, dynamic>? refusal}) async => failed.add(id);

  @override
  Future<Map<String, dynamic>?> metaJson(String key) async => null;

  @override
  Future<void> setMetaJson(String key, Map<String, dynamic>? value) async {}

  @override
  Future<void> setMeta(String key, String? value) async {}

  @override
  Future<String?> meta(String key) async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}

class _FakeApi extends ApiClient {
  _FakeApi(LocalStore store) : super(baseUrl: _server, store: store);
  bool serverUp = true;
  final List<String> replayed = [];

  @override
  Future<dynamic> authenticate(String path, {Object? body}) async {
    if (!serverUp) throw ApiException(0, 'No route to the farm server');
    final b = body! as Map;
    if (b['password'] != 'secret' || b['email'] != 'karim@farm.example') throw ApiException(401, 'Invalid email or password');
    return {'access_token': 'token-karim', 'user': _karim};
  }

  @override
  Future<dynamic> send(String method, String path, {Object? body, Map<String, dynamic>? query, String? idempotencyKey}) async {
    if (!serverUp) throw ApiException(0, 'No route to the farm server');
    if ((token ?? '').isEmpty) throw ApiException(401, 'Not signed in');
    replayed.add('$method $path');
    return <String, dynamic>{'id': 'server-1'};
  }
}

OutboxItem _feeding(int id) => OutboxItem(
      id: id, method: 'POST', path: '/feeding-events', query: null,
      body: {'subject_type': 'animal', 'subject_id': 'cow-1', 'event_type': 'offered'},
      idempotencyKey: 'key-$id', localId: 'local-$id', label: 'outboxFeeding', moduleCode: 'feed_nutrition',
      createdAt: DateTime.utc(2026, 11, 26, 6), attempts: 0, lastError: null, status: OutboxStatus.pending);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('the offline check kept on the tablet', () {
    test('PBKDF2-HMAC-SHA256 matches the published test vectors', () {
      String hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
      expect(hex(OfflineCredentials.pbkdf2(utf8.encode('password'), utf8.encode('salt'), 1)),
          '120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b');
      expect(hex(OfflineCredentials.pbkdf2(utf8.encode('password'), utf8.encode('salt'), 2)),
          'ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43');
    });

    test('opens for the same server, email and password only, never stores the password', () async {
      final creds = OfflineCredentials(iterations: 500);
      await creds.remember(server: _server, email: 'karim@farm.example', password: 'secret', profile: _karim);
      final raw = (await SharedPreferences.getInstance()).getString('offline_credentials_v1')!;
      expect(raw.contains('secret'), isFalse);
      expect(raw.contains('token'), isFalse);
      expect((await creds.unlock(server: _server, email: 'KARIM@farm.example ', password: 'secret')).result, OfflineUnlockResult.ok);
      expect((await creds.unlock(server: _server, email: 'karim@farm.example', password: 'wrong')).result, OfflineUnlockResult.wrongPassword);
      expect((await creds.unlock(server: 'https://other.example/api/v1', email: 'karim@farm.example', password: 'secret')).result,
          OfflineUnlockResult.unknown);
      expect((await creds.unlock(server: _server, email: 'nour@farm.example', password: 'secret')).result, OfflineUnlockResult.unknown);
    });

    test('expires a week after the server last accepted the sign-in; signing out forgets it', () async {
      var now = DateTime.utc(2026, 11, 26, 6);
      final creds = OfflineCredentials(iterations: 500, clock: () => now);
      await creds.remember(server: _server, email: 'karim@farm.example', password: 'secret', profile: _karim);
      now = now.add(const Duration(days: 6));
      expect((await creds.unlock(server: _server, email: 'karim@farm.example', password: 'secret')).result, OfflineUnlockResult.ok);
      now = now.add(const Duration(days: 2));
      expect((await creds.unlock(server: _server, email: 'karim@farm.example', password: 'secret')).result, OfflineUnlockResult.expired);
      await creds.forgetUser('user-karim');
      expect((await creds.unlock(server: _server, email: 'karim@farm.example', password: 'secret')).result, OfflineUnlockResult.unknown);
    });
  });

  group('signing in after a restart with no network', () {
    Future<(_FakeStore, OfflineCredentials)> signedInOnceOnline() async {
      final store = _FakeStore();
      final creds = OfflineCredentials(iterations: 500);
      final first = SessionController(store: store, client: _FakeApi(store), offline: creds, allowOffline: true);
      expect(await first.login(email: 'karim@farm.example', password: 'secret'), isTrue);
      await pumpEventQueue(times: 50);
      return (store, creds);
    }

    test('the same worker opens their farm offline and holds no server token', () async {
      final (store, creds) = await signedInOnceOnline();
      final api = _FakeApi(store)..serverUp = false;
      final restarted = SessionController(store: store, client: api, offline: creds, allowOffline: true);
      expect(restarted.status, SessionStatus.loggedOut, reason: 'the sign-in form shows on every launch');
      expect(await restarted.login(email: 'karim@farm.example', password: 'secret'), isTrue);
      expect([restarted.status, restarted.offlineSession, restarted.user!.id, api.token], [SessionStatus.loggedIn, true, 'user-karim', null]);
      expect(store.boundUser, 'user-karim', reason: 'the cache stays this worker\'s');
    });

    test('a wrong password, another worker, an expired check or a browser stay out', () async {
      final (store, creds) = await signedInOnceOnline();
      final offline = _FakeApi(store)..serverUp = false;
      final s = SessionController(store: store, client: offline, offline: creds, allowOffline: true);
      expect(await s.login(email: 'karim@farm.example', password: 'guess'), isFalse);
      expect(s.error, startsWith('OFFLINE SIGN-IN'));
      expect(await s.login(email: 'nour@farm.example', password: 'secret'), isFalse);
      expect(s.needsFirstOnlineLogin, isTrue, reason: 'never signed in with the server on this tablet');
      final web = SessionController(store: store, client: offline, offline: creds, allowOffline: false);
      expect(await web.login(email: 'karim@farm.example', password: 'secret'), isFalse, reason: 'a browser always asks the server');

      final later = OfflineCredentials(iterations: 500, clock: () => DateTime.now().add(const Duration(days: 8)));
      final expired = SessionController(store: store, client: offline, offline: later, allowOffline: true);
      expect(await expired.login(email: 'karim@farm.example', password: 'secret'), isFalse);
      expect(expired.error, startsWith('OFFLINE SIGN-IN EXPIRED'));
    });

    test('the server refusing the password forgets the offline check', () async {
      final (store, creds) = await signedInOnceOnline();
      // The password was changed on the server: the tablet tries the old one online.
      final api = _FakeApi(store);
      final s = SessionController(store: store, client: api, offline: creds, allowOffline: true);
      expect(await s.login(email: 'karim@farm.example', password: 'stale'), isFalse);
      final offline = SessionController(store: store, client: _FakeApi(store)..serverUp = false, offline: creds, allowOffline: true);
      expect(await offline.login(email: 'karim@farm.example', password: 'secret'), isFalse);
    });

    test('signing out closes offline access', () async {
      final (store, creds) = await signedInOnceOnline();
      final s = SessionController(store: store, client: _FakeApi(store)..serverUp = false, offline: creds, allowOffline: true);
      expect(await s.login(email: 'karim@farm.example', password: 'secret'), isTrue);
      await s.logout();
      expect(await s.login(email: 'karim@farm.example', password: 'secret'), isFalse);
    });
  });

  group('records made in an offline session', () {
    test('wait untouched without a server token, then are sent once after the server accepts a sign-in', () async {
      final store = _FakeStore()..queue.add(_feeding(1));
      final api = _FakeApi(store)..serverUp = true;
      final sync = SyncController(api: api);
      expect(await sync.syncNow(), SyncOutcome.needsSignIn);
      expect([store.removed, store.failed, api.replayed, sync.waitingForSignIn], [<int>[], <int>[], <String>[], true]);

      final session = SessionController(store: store, client: api, offline: OfflineCredentials(iterations: 500), allowOffline: true);
      expect(await session.login(email: 'karim@farm.example', password: 'secret'), isTrue);
      expect(await sync.syncNow(), SyncOutcome.sent);
      expect(await sync.syncNow(), SyncOutcome.nothingToDo);
      expect([store.removed, api.replayed, sync.waitingForSignIn], [
        [1],
        ['POST /feeding-events'],
        false
      ], reason: 'sent exactly once');
    });

    test('a token the server no longer accepts keeps the queue, not fails it', () async {
      final store = _FakeStore()..queue.add(_feeding(2));
      // The server answers 401 for an expired token.
      final sync = SyncController(api: _ExpiredTokenApi(store));
      expect(await sync.syncNow(), SyncOutcome.needsSignIn);
      expect([store.failed, store.removed, sync.waitingForSignIn], [<int>[], <int>[], true]);
    });
  });
}

class _ExpiredTokenApi extends _FakeApi {
  _ExpiredTokenApi(super.store) {
    token = 'expired';
  }

  @override
  Future<dynamic> send(String method, String path, {Object? body, Map<String, dynamic>? query, String? idempotencyKey}) async =>
      throw ApiException(401, 'Token expired');
}
