import 'dart:convert';

import 'package:farmos/data/local/database.dart';
import 'package:farmos/data/local/local_repository.dart';
import 'package:farmos/data/remote/session_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Proves the tablet's own half of "each farmer sees only their own data".
///
/// The server enforces this with Postgres RLS + `check_farm_id` (see
/// OrigamiFarmServer `TENANCY.md` and its `tests/test_tenant_isolation.py`),
/// but a tablet caches rows locally for offline use and can be handed
/// between farms — so the same rule has to hold on-device, especially
/// offline where there's no server round trip to correct a stale list.
///
/// These run against the real SQLite engine in memory (sqflite_common_ffi),
/// not a mock, so they exercise the actual queries.
void main() {
  sqfliteFfiInit();

  late Database db;
  late SessionManager session;
  late LocalRepository repository;

  const farmA = 'farm-aaa';
  const farmB = 'farm-bbb';

  Future<void> insertAnimal(String id, String farmId, String name) => db.insert('animals', {
        'id': id,
        'farm_id': farmId,
        'tag': id,
        'name': name,
        'species': 'cow',
        'status': 'healthy',
        'health_score': 90,
      });

  Future<void> insertTask(String id, String farmId, String title) => db.insert('tasks', {
        'id': id,
        'farm_id': farmId,
        'title': title,
        'priority': 'medium',
        'status': 'open',
      });

  Future<void> insertFeedItem(String id, String farmId, String name) => db.insert('inventory_items', {
        'id': id,
        'farm_id': farmId,
        'name': name,
        'unit': 'kg',
        'current_qty': 100,
        'reorder_level': 10,
      });

  /// One unsynced write, exactly as `FarmWriteService` records it: an
  /// `events` row (which carries farm_id) plus a `sync_queue` row pointing
  /// at it (which does not).
  Future<void> insertQueuedWrite(String id, String farmId) async {
    await db.insert('events', {
      'id': 'event-$id',
      'farm_id': farmId,
      'entity_type': 'animal',
      'entity_id': 'animal-$id',
      'event_type': 'observation_recorded',
      'payload_json': jsonEncode({'farm_id': farmId}),
      'created_by': 'user-1',
      'created_at': DateTime.now().toIso8601String(),
    });
    await db.insert('sync_queue', {
      'id': 'queue-$id',
      'local_event_id': 'event-$id',
      'operation': 'create',
      'entity_type': 'animal',
      'entity_id': 'animal-$id',
      'payload_json': jsonEncode({'farm_id': farmId}),
      'status': 'pending',
      'retry_count': 0,
      'created_at': DateTime.now().toIso8601String(),
    });
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await FarmDatabase.createSchema(db);
    session = SessionManager();
    repository = LocalRepository(session: session, db: FarmDatabase.forTesting(db));
  });

  tearDown(() async => db.close());

  Future<void> signInAs(String farmId) => session.saveSession(
        token: 'token-for-$farmId',
        farmId: farmId,
        userId: 'user-$farmId',
        displayName: 'Owner $farmId',
        role: 'owner',
      );

  group('local reads are scoped to the signed-in farm', () {
    test('animals from another farm are never returned', () async {
      await insertAnimal('a1', farmA, 'Bella');
      await insertAnimal('b1', farmB, 'Luna');

      await signInAs(farmA);
      final forA = await repository.loadAnimals();
      expect(forA.map((a) => a.name), ['Bella']);

      await signInAs(farmB);
      final forB = await repository.loadAnimals();
      expect(forB.map((a) => a.name), ['Luna']);
    });

    test('tasks and feed items are scoped the same way', () async {
      await insertTask('t-a', farmA, 'Inspect Bella');
      await insertTask('t-b', farmB, 'Inspect Luna');
      await insertFeedItem('i-a', farmA, 'Dairy Mix');
      await insertFeedItem('i-b', farmB, 'Layer Feed');

      await signInAs(farmA);
      expect((await repository.loadTasks()).map((t) => t.title), ['Inspect Bella']);
      expect((await repository.loadFeedItems()).map((i) => i.name), ['Dairy Mix']);
    });

    test('signed out, only the demo farm is visible — not a real farm left on the device', () async {
      await insertAnimal('a1', farmA, 'Bella');
      await insertAnimal('demo1', SessionManager.demoFarmId, 'Demo Cow');

      // No saveSession call: this is a freshly-wiped / signed-out tablet.
      final loaded = await repository.loadAnimals();
      expect(loaded.map((a) => a.name), ['Demo Cow']);
    });
  });

  group('purgeFarmData', () {
    test('removes only the named farm, including its unsent queue', () async {
      await insertAnimal('a1', farmA, 'Bella');
      await insertAnimal('b1', farmB, 'Luna');
      await insertQueuedWrite('a', farmA);
      await insertQueuedWrite('b', farmB);

      await repository.purgeFarmData(farmA);

      await signInAs(farmA);
      expect(await repository.loadAnimals(), isEmpty);
      await signInAs(farmB);
      expect((await repository.loadAnimals()).map((a) => a.name), ['Luna']);

      // Farm A's queued write is gone; farm B's is untouched.
      final remaining = await db.query('sync_queue');
      expect(remaining.map((r) => r['id']), ['queue-b']);
      final events = await db.query('events');
      expect(events.map((r) => r['farm_id']), [farmB]);
    });

    test('never deletes the shipped demo dataset', () async {
      await insertAnimal('demo1', SessionManager.demoFarmId, 'Demo Cow');
      await repository.purgeFarmData(SessionManager.demoFarmId);
      expect(await db.query('animals'), hasLength(1));
    });
  });
}
