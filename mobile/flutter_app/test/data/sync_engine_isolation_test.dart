import 'dart:convert';

import 'package:farmos/data/local/database.dart';
import 'package:farmos/data/remote/api_client.dart';
import 'package:farmos/data/remote/farmos_api.dart';
import 'package:farmos/data/remote/session_manager.dart';
import 'package:farmos/data/sync/sync_engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The sync queue is the one place a tablet turns *stored* data into a
/// *write against someone's farm*, so it's where a tenant-isolation
/// mistake does the most damage: a push carries whichever bearer token is
/// in the session now, and the server files the write into that token's
/// farm. Flushing a queue row left behind by a different farm — a farmer
/// who worked offline, never synced, and handed the tablet on — would
/// silently write their observations and stock movements into the current
/// farmer's records.
///
/// These tests capture the actual outgoing HTTP requests to prove that
/// can't happen.
void main() {
  sqfliteFfiInit();

  late Database db;
  late SessionManager session;
  late List<http.Request> sentRequests;
  late SyncEngine engine;

  const farmA = 'farm-aaa';
  const farmB = 'farm-bbb';

  Future<void> queueObservation(String id, String farmId) async {
    await db.insert('events', {
      'id': 'event-$id',
      'farm_id': farmId,
      'entity_type': 'animal',
      'entity_id': 'animal-$id',
      'event_type': 'observation_recorded',
      'payload_json': jsonEncode({'farm_id': farmId, 'observation_type': 'limping'}),
      'created_by': 'user-1',
      'created_at': DateTime.now().toIso8601String(),
    });
    await db.insert('sync_queue', {
      'id': 'queue-$id',
      'local_event_id': 'event-$id',
      'operation': 'create',
      'entity_type': 'animal',
      'entity_id': 'animal-$id',
      'payload_json': jsonEncode({'farm_id': farmId, 'observation_type': 'limping'}),
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

    sentRequests = [];
    final mockClient = MockClient((request) async {
      sentRequests.add(request);
      return http.Response(jsonEncode({'id': 'server-assigned-id'}), 201);
    });
    engine = SyncEngine(
      session: session,
      api: FarmosApi(ApiClient(session, client: mockClient)),
      db: FarmDatabase.forTesting(db),
    );
  });

  tearDown(() async => db.close());

  Future<void> signInAs(String farmId) => session.saveSession(
        token: 'token-for-$farmId',
        farmId: farmId,
        userId: 'user-$farmId',
        displayName: 'Owner $farmId',
        role: 'owner',
      );

  test('another farm\'s queued write is never pushed under this farm\'s token', () async {
    await queueObservation('a', farmA);
    await queueObservation('b', farmB);

    await signInAs(farmB);
    final result = await engine.flushPending();

    // Exactly one request, carrying farm B's token and farm B's payload.
    expect(sentRequests, hasLength(1));
    expect(sentRequests.single.headers['authorization'], 'Bearer token-for-$farmB');
    expect(jsonDecode(sentRequests.single.body)['farm_id'], farmB);
    expect(result.pushed, 1);

    // Farm A's row is still queued — not pushed, and not silently dropped.
    final rows = await db.query('sync_queue', where: 'status = ?', whereArgs: ['pending']);
    expect(rows.map((r) => r['id']), ['queue-a']);
  });

  test('pending count reflects only the signed-in farm', () async {
    await queueObservation('a', farmA);
    await queueObservation('b1', farmB);
    await queueObservation('b2', farmB);

    await signInAs(farmB);
    expect(await engine.countPending(), 2);

    await signInAs(farmA);
    expect(await engine.countPending(), 1);
  });

  test('signing out does not discard a real farm\'s unsynced work', () async {
    await queueObservation('a', farmA);
    await queueObservation('demo', SessionManager.demoFarmId);

    // Signed out: demo rows resolve locally (no server), farm A's stay put.
    final result = await engine.flushPending();
    expect(sentRequests, isEmpty, reason: 'demo mode must not call the server');
    expect(result.pushed, 1);

    final stillPending = await db.query('sync_queue', where: 'status = ?', whereArgs: ['pending']);
    expect(stillPending.map((r) => r['id']), ['queue-a']);
  });
}
