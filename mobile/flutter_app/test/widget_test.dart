import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:farmos/app/app.dart';
import 'package:farmos/data/local/cache_effects.dart';
import 'package:farmos/data/local/demo_mode.dart';
import 'package:farmos/data/local/local_store.dart';
import 'package:farmos/data/local/outbox_labels.dart';

/// The widget test runs without a device: there is no SQLite, so
/// `LocalStore.open()` is never called and `FarmOSApp` is built with a
/// null store — the app then behaves as an online-only client. What it
/// can still prove is that the app boots to the sign-in screen rather
/// than into the farm, which is the rule the offline design rests on:
/// **the first sign-in needs the farm network.**
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the app opens on the sign-in screen, not the farm', (WidgetTester tester) async {
    // No stored token, and a working preferences channel so the session
    // restore actually finishes instead of sitting on the splash.
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(const FarmOSApp());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Start My Day'), findsWidgets);
    expect(find.text("Today's Priorities"), findsNothing);
  });

  group('cache keys', () {
    test('query parameters are part of the key, in a stable order', () {
      expect(LocalStore.cacheKey('/animals', null), 'GET /animals');
      expect(
        LocalStore.cacheKey('/priorities', {'module': 'animals', 'assignment': 'mine'}),
        LocalStore.cacheKey('/priorities', {'assignment': 'mine', 'module': 'animals'}),
      );
      expect(LocalStore.cacheKey('/priorities', {'module': 'animals'}), 'GET /priorities?module=animals');
    });

    test('null values are dropped so an unset filter matches the plain key', () {
      expect(LocalStore.cacheKey('/priorities', {'module': null}), 'GET /priorities');
    });
  });

  group('offline cache effects', () {
    test('a queued animal appears in the cached list, flagged unsynced', () {
      final effects = effectsFor('POST', '/animals', {'tag': '744', 'name': 'Bella'}, localId: 'local-1');
      expect(effects, hasLength(1));
      final effect = effects.single as AppendRecord;
      expect(effect.collectionPath, '/animals');
      expect(effect.record['id'], 'local-1');
      expect(effect.record[kPendingFlag], true);
    });

    test('fields are written at /fields but read back at /production/fields', () {
      final effect = effectsFor('POST', '/fields', {'name': 'North Plot'}, localId: 'local-2').single;
      expect(effect.collectionPath, '/production/fields');
    });

    test('a feed movement adjusts the stock figure rather than adding a row', () {
      final effect = effectsFor(
        'POST',
        '/feed/transactions',
        {'item_id': 'item-1', 'direction': 'out', 'quantity': 40.0},
        localId: 'local-3',
      ).single as AdjustNumber;
      expect(effect.collectionPath, '/feed/items');
      expect(effect.id, 'item-1');
      expect(effect.delta, -40.0);
    });

    test('marking a notification read patches inside the envelope', () {
      final effect = effectsFor('POST', '/notifications/abc/read', null, localId: 'local-4').single as MergeRecord;
      expect(effect.id, 'abc');
      expect(effect.listKey, 'notifications');
    });

    test('an unrecognised write produces no effect rather than guessing', () {
      // Offline it still reaches the outbox and syncs; it just has no
      // local prediction. Guessing wrong is worse than showing nothing.
      expect(effectsFor('POST', '/some-future-endpoint', {'a': 1}, localId: 'local-5'), isEmpty);
      // Same for an action the transition table doesn't know.
      expect(effectsFor('POST', '/visit-bookings/b1/teleport', null, localId: 'local-6'), isEmpty);
    });
  });

  group('the bundled standalone farm', () {
    late Map<String, dynamic> snapshot;

    setUpAll(() async {
      snapshot = jsonDecode(await File('assets/demo/snapshot.json').readAsString()) as Map<String, dynamic>;
    });

    test('signs in as the demo account', () {
      final account = snapshot['__demo_account__'] as Map<String, dynamic>;
      expect(account['username'], DemoMode.username);
      expect(account['password'], DemoMode.password);
      // Owner, so the demo shows the whole farm and every Add button.
      expect((account['user'] as Map<String, dynamic>)['role'], 'owner');
    });

    test('every section the app reads has data behind it', () {
      // A section that opens empty reads as a broken build, not a demo.
      // The generator asserts the endpoints return 200; this asserts they
      // returned something worth showing.
      const mustNotBeEmpty = [
        'GET /animals?farm_id=farm-origami',
        'GET /tasks?farm_id=farm-origami',
        'GET /feed/items?farm_id=farm-origami',
        'GET /production/fields?farm_id=farm-origami',
        'GET /production/milk?days=30&farm_id=farm-origami',
        'GET /production/eggs?days=30&farm_id=farm-origami',
        'GET /production/harvest?days=90&farm_id=farm-origami',
        'GET /crops',
        'GET /crop-plantings',
        'GET /sales?farm_id=farm-origami',
        'GET /expenses?farm_id=farm-origami',
        'GET /employees?include_inactive=false',
        'GET /audit?limit=100',
        'GET /recommendations?farm_id=farm-origami&refresh=true',
        'GET /mouneh/products',
        'GET /mouneh/batches',
        'GET /visit-bookings',
        'GET /visit-sessions',
        'GET /visitors',
      ];
      for (final key in mustNotBeEmpty) {
        expect(snapshot[key], isA<List>().having((l) => l.length, '$key length', greaterThan(0)));
      }
    });

    test('the keys are the cache keys the tablet will look up', () {
      // The generator mirrors LocalStore.cacheKey; if the two ever drift,
      // every screen silently falls back to an empty list.
      expect(snapshot.containsKey(LocalStore.cacheKey('/animals', {'farm_id': 'farm-origami'})), isTrue);
      expect(
        snapshot.containsKey(LocalStore.cacheKey('/production/milk', {'farm_id': 'farm-origami', 'days': 30})),
        isTrue,
      );
      expect(snapshot.containsKey(LocalStore.cacheKey('/employees', {'include_inactive': false})), isTrue);
    });
  });

  group('standalone write effects', () {
    test('a booking transition stamps the status the server would', () {
      final effect = effectsFor('POST', '/visit-bookings/b1/check-in', null, localId: 'x').single as MergeRecord;
      expect(effect.collectionPath, '/visit-bookings');
      expect(effect.id, 'b1');
      expect(effect.patch['status'], 'checked_in');
      expect(effect.patch['checked_in_at'], isNotNull);
    });

    test('an observation lands on the animal it is about', () {
      final effect = effectsFor(
        'POST',
        '/observations',
        {'entity_type': 'animal', 'entity_id': 'cow-744', 'observation_type': 'lameness'},
        localId: 'obs-1',
      ).single as AppendRecord;
      expect(effect.collectionPath, '/animals/cow-744');
      expect(effect.listKey, 'recent_observations');
    });

    test('a module licence is matched by module_code, not id', () {
      final effect = effectsFor('POST', '/modules/mouneh/deactivate', null, localId: 'x').single as MergeRecord;
      expect(effect.idField, 'module_code');
      expect(effect.id, 'mouneh');
      expect(effect.patch['status'], 'inactive');
    });

    test('read-all clears the badge as well as the rows', () {
      final effects = effectsFor('POST', '/notifications/read-all', null, localId: 'x');
      expect(effects.whereType<PatchAll>().single.listKey, 'notifications');
      expect(effects.whereType<PatchDocument>().single.patch['unread_count'], 0);
    });

    test('recording a harvest shows up in the harvest list', () {
      final effect = effectsFor(
        'POST',
        '/harvest',
        {'field_id': 'f1', 'product_name': 'Tomatoes', 'total_quantity': 40, 'waste_quantity': 3},
        localId: 'h1',
      ).single as AppendRecord;
      expect(effect.collectionPath, '/production/harvest');
      expect(effect.record['quantity'], 40.0);
      expect(effect.record['waste_qty'], 3.0);
    });
  });

  group('outbox labels', () {
    test('the longest matching path wins', () {
      expect(describeWrite('/mouneh/batches/b1/complete').labelKey, 'outboxMounehBatch');
      expect(describeWrite('/production/milk').labelKey, 'outboxMilkRecord');
      expect(describeWrite('/tasks/t1').labelKey, 'outboxTask');
    });

    test('an unknown path still gets a readable label', () {
      expect(describeWrite('/something-new').labelKey, 'outboxChange');
    });
  });
}
