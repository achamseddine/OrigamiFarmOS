import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:farmos/api/api_client.dart';
import 'package:farmos/core/util/farm_clock.dart';
import 'package:farmos/core/util/record_dates.dart';
import 'package:farmos/data/local/cache_effects.dart';
import 'package:farmos/data/local/local_store.dart';
import 'package:farmos/domain/entities/production_records.dart';
import 'package:farmos/features/production/milk_awaiting_check_card.dart';
import 'package:farmos/providers/animals_provider.dart';
import 'package:farmos/providers/production_provider.dart';
import 'package:farmos/sync/sync_controller.dart';

/// Milk recorded offline waits for the server's safety check, and the
/// morning and afternoon milkings are the farm's (audit I-11, I-16;
/// ADR-008). The server's side — tablet A's 10 L under the withdrawal
/// tablet B recorded, kept but held — is backend/tests/test_offline_milk_clearance.py.

// Asia/Beirut as the server gives it: UTC+2 until the clocks go forward on
// 2027-03-28 at 00:00 (22:00 UTC the day before), UTC+3 after.
final _beirut = FarmClock.fromJson({
  'timezone': 'Asia/Beirut',
  'offsets': [
    {'from': '2026-11-24T00:00:00+00:00', 'offset_minutes': 120},
    {'from': '2027-03-27T22:00:00+00:00', 'offset_minutes': 180},
  ],
});

OutboxItem _milkItem(int id, {OutboxStatus status = OutboxStatus.pending, String? error, String localId = 'local-milk-1'}) => OutboxItem(
      id: id, method: 'POST', path: '/production/milk', query: null,
      body: {'animal_id': 'cow-744', 'session': 'morning', 'liters': 10, 'destination': 'stored', 'recorded_at': '2026-11-26T05:00:00.000Z'},
      idempotencyKey: 'key-$id', localId: localId, label: 'outboxMilk', moduleCode: 'milk_production',
      createdAt: DateTime.utc(2026, 11, 26, 5, 1), attempts: 1, lastError: error, status: status);

void main() {
  group('the farm\'s clock (I-16)', () {
    test('the milking is the farm\'s hour, whatever zone the tablet is in', () {
      // 11:30 UTC is 13:30 in Beirut: the afternoon milking there, even on
      // a tablet set to UTC (or to London) that says 11:30.
      expect(_beirut.milkSessionAt(DateTime.utc(2026, 11, 26, 11, 30)), 'evening');
      expect(_beirut.milkSessionAt(DateTime.utc(2026, 11, 26, 10, 30)), 'morning');
      expect(_beirut.hourAt(DateTime.utc(2026, 11, 26, 4, 0)), 6);
    });

    test('across the daylight-saving change, the offset of the day applies', () {
      expect(_beirut.offsetAt(DateTime.utc(2027, 3, 27, 21, 59)), const Duration(hours: 2));
      expect(_beirut.offsetAt(DateTime.utc(2027, 3, 27, 22, 0)), const Duration(hours: 3));
      expect(_beirut.milkSessionAt(DateTime.utc(2027, 3, 27, 10, 30)), 'morning', reason: '12:30 at UTC+2');
      expect(_beirut.milkSessionAt(DateTime.utc(2027, 3, 28, 10, 30)), 'evening', reason: '13:30 at UTC+3');
      expect(_beirut.instantOf(DateTime(2027, 3, 28), 7), DateTime.utc(2027, 3, 28, 4));
      expect(_beirut.instantOf(DateTime(2026, 11, 25), 18), DateTime.utc(2026, 11, 25, 16));
    });

    test('the farm\'s day starts at the farm\'s midnight', () {
      expect(_beirut.farmDay(DateTime.utc(2026, 11, 25, 22, 30)), DateTime(2026, 11, 26));
      expect(_beirut.isFarmToday(DateTime(2026, 11, 26), now: DateTime.utc(2026, 11, 25, 22, 30)), isTrue);
    });

    test('milk entered for an earlier day is dated at that milking\'s farm hour', () {
      final now = DateTime.utc(2026, 11, 26, 9);
      expect(milkingInstant(DateTime(2026, 11, 24), 'morning', clock: _beirut, now: now), DateTime.utc(2026, 11, 24, 5));
      expect(milkingInstant(DateTime(2026, 11, 24), 'evening', clock: _beirut, now: now), DateTime.utc(2026, 11, 24, 16));
      expect(milkingInstant(DateTime(2026, 11, 26), 'morning', clock: _beirut, now: now), now, reason: 'today is now');
    });

    test('until the farm\'s clock is known, the device\'s own is used', () {
      final unknown = FarmClock();
      final t = DateTime.utc(2026, 11, 26, 11, 30);
      expect(unknown.known, isFalse);
      expect(unknown.hourAt(t), t.toLocal().hour);
    });

    test('the clock comes from the farm server and replaces the device\'s', () async {
      final before = FarmClock.current;
      addTearDown(() => FarmClock.current = before);
      final api = _ClockApi({'id': 'farm-origami', 'timezone': 'Asia/Beirut', 'clock': {
        'timezone': 'Asia/Beirut', 'offsets': [{'from': '2026-11-24T00:00:00+00:00', 'offset_minutes': 120}]}});
      await FarmClock.load(api);
      expect(FarmClock.current.timezone, 'Asia/Beirut');
      expect(FarmClock.current.milkSessionAt(DateTime.utc(2026, 11, 26, 11, 30)), 'evening');
      // A server that does not say keeps the clock there was.
      await FarmClock.load(_ClockApi({'id': 'farm-origami'}));
      expect(FarmClock.current.timezone, 'Asia/Beirut');
    });
  });

  group('milk recorded offline (I-11)', () {
    test('waits for the server\'s check: it is not stored or sellable milk on the tablet', () {
      final effects = effectsFor('POST', '/production/milk',
          {'animal_id': 'cow-744', 'session': 'morning', 'liters': 10, 'destination': 'stored', 'recorded_at': '2026-11-26T05:00:00.000Z'},
          localId: 'local-milk-1');
      final record = MilkRecord.fromJson((effects.single as AppendRecord).record);
      expect([record.awaitingCheck, record.saleable, record.destination, record.liters], [true, false, 'stored', 10]);
      expect(record.recordedAt, DateTime.utc(2026, 11, 26, 5), reason: 'the milking keeps its own time');
      // The demo farm (no server) has nothing to wait for.
      final local = effectsFor('POST', '/production/milk', {'animal_id': 'cow-744', 'session': 'morning', 'liters': 10, 'destination': 'stored'},
          localId: 'local-2', queued: false);
      expect(MilkRecord.fromJson((local.single as AppendRecord).record).awaitingCheck, isFalse);
    });

    test('a queued write tells the server when it was recorded offline; a live one does not', () async {
      final seen = <String, String?>{};
      final api = ApiClient(baseUrl: 'https://farm.example/api/v1', token: 't', httpClient: MockClient((request) async {
        seen[request.url.path] = request.headers[kOfflineRecordedAtHeader];
        return http.Response(jsonEncode({'id': 'server-1', 'release_status': 'held'}), 201);
      }));
      await api.replay(_milkItem(1));
      expect(seen['/api/v1/production/milk'], '2026-11-26T05:01:00.000Z');
      seen.clear();
      await api.post('/production/milk', body: {'animal_id': 'cow-744'});
      expect(seen.containsKey('/api/v1/production/milk'), isTrue);
      expect(seen['/api/v1/production/milk'], isNull);
    });

    testWidgets('the Milk page lists it as waiting, and what the server refused stays in view', (tester) async {
      final store = _Store([
        _milkItem(1, localId: 'local-milk-1'),
        _milkItem(2, status: OutboxStatus.failed, localId: 'local-milk-2',
            error: 'Luna was dried off on 2026-11-25; milk after the dry-off is refused.'),
      ]);
      final api = _MilkApi(store, [
        {'id': 'local-milk-1', 'animal_id': 'cow-744', 'session': 'morning', 'liters': 10, 'destination': 'stored',
         'recorded_at': '2026-11-26T05:00:00.000Z', 'release_status': 'awaiting_check', kPendingFlag: true},
        {'id': 'local-milk-2', 'animal_id': 'cow-214', 'session': 'morning', 'liters': 9, 'destination': 'stored',
         'recorded_at': '2026-11-26T05:10:00.000Z', 'release_status': 'awaiting_check', kPendingFlag: true},
        {'id': 'server-7', 'animal_id': 'cow-clover', 'session': 'morning', 'liters': 12, 'destination': 'stored',
         'recorded_at': '2026-11-26T05:20:00.000Z', 'release_status': 'saleable'},
      ]);
      final production = ProductionProvider(apiClient: api, farmId: 'farm-origami');
      final animals = AnimalsProvider(apiClient: api, farmId: 'farm-origami', currentUserId: 'user-worker-1');
      final sync = SyncController(api: api);
      await production.load();
      await sync.refreshCounts();
      await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: production),
          ChangeNotifierProvider.value(value: animals),
          ChangeNotifierProvider.value(value: sync),
        ],
        child: const MaterialApp(home: Scaffold(body: SingleChildScrollView(child: MilkAwaitingCheckCard()))),
      ));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('milk-awaiting-check-card')), findsOneWidget);
      expect(find.byKey(const ValueKey('mac-waiting-local-milk-1')), findsOneWidget, reason: 'still waiting for the server');
      expect(find.byKey(const ValueKey('mac-waiting-server-7')), findsNothing, reason: 'the server has checked it');
      expect(find.byKey(const ValueKey('mac-waiting-local-milk-2')), findsNothing, reason: 'refused, shown as refused');
      expect(find.byKey(const ValueKey('mac-refused-2')), findsOneWidget);
      expect(find.textContaining('dried off on 2026-11-25'), findsOneWidget);
      expect(find.textContaining('10 L recorded on this tablet'), findsOneWidget);

      // Discard asks first, and only then drops it.
      await tester.tap(find.byKey(const ValueKey('mac-discard-2')));
      await tester.pumpAndSettle();
      expect(store.discarded, isEmpty);
      await tester.tap(find.byKey(const ValueKey('mac-discard-confirm')));
      await tester.pumpAndSettle();
      expect(store.discarded, [2]);
      expect(find.byKey(const ValueKey('mac-refused-2')), findsNothing);
      expect(production.milkRecords.map((r) => r.id), isNot(contains('local-milk-2')), reason: 'gone from the tablet\'s list too');
      expect(find.byKey(const ValueKey('mac-waiting-local-milk-2')), findsNothing);
    });

    test('the milk list keeps what the server judged', () {
      final held = MilkRecord.fromJson({'id': 'm', 'animal_id': 'cow-744', 'session': 'morning', 'liters': 10, 'destination': 'stored',
          'recorded_at': '2026-11-26T05:00:00Z', 'release_status': 'held', 'withdrawal_check': 'withdrawal'});
      expect([held.awaitingCheck, held.isHeld, held.saleable], [false, true, false]);
      final released = MilkRecord.fromJson({'id': 'n', 'animal_id': 'cow-744', 'session': 'morning', 'liters': 10, 'destination': 'stored',
          'recorded_at': '2026-11-26T05:00:00Z', 'release_status': 'released'});
      expect(released.saleable, isTrue);
    });
  });
}

class _ClockApi extends ApiClient {
  _ClockApi(this.farm) : super(baseUrl: 'https://farm.example/api/v1');
  final Map<String, dynamic> farm;

  @override
  Future<dynamic> get(String path, {Map<String, dynamic>? query}) async => path == '/farms/me' ? farm : const <dynamic>[];
}

class _MilkApi extends ApiClient {
  _MilkApi(LocalStore store, this.milk) : super(baseUrl: 'https://farm.example/api/v1', store: store);
  final List<Map<String, dynamic>> milk;

  @override
  Future<dynamic> get(String path, {Map<String, dynamic>? query}) async => path == '/production/milk' ? milk : const <dynamic>[];
}

class _Store implements LocalStore {
  _Store(this.items);
  final List<OutboxItem> items;
  final List<int> discarded = [];

  @override
  bool get available => true;

  @override
  Future<List<OutboxItem>> outbox({bool pendingOnly = false}) async =>
      [for (final i in items) if (!discarded.contains(i.id) && (!pendingOnly || i.status == OutboxStatus.pending)) i];

  @override
  Future<int> pendingCount() async => (await outbox(pendingOnly: true)).length;

  @override
  Future<int> failedCount() async => [for (final i in await outbox()) if (i.status == OutboxStatus.failed) i].length;

  @override
  Future<int> otherUsersPendingCount() async => 0;

  @override
  Future<Set<String>> pendingLocalIds() async => {for (final i in await outbox(pendingOnly: true)) if (i.localId != null) i.localId!};

  @override
  Future<Map<String, dynamic>?> metaJson(String key) async => null;

  @override
  Future<List<String>> cacheKeysForPath(String path) async => const [];

  @override
  Future<String?> meta(String key) async => null;

  @override
  Future<void> discardOutboxItem(int id) async => discarded.add(id);

  @override
  Future<void> removeFromOutbox(int id) async => discarded.add(id);

  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}
