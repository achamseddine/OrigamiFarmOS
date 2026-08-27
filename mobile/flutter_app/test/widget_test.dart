import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:farmos/app/app.dart';
import 'package:farmos/data/local/cache_effects.dart';
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

    test('a write with no safe local prediction produces no effect', () {
      // Harvest moves produce into inventory *and* advances a planting;
      // guessing it wrong would be worse than showing it as queued.
      expect(effectsFor('POST', '/harvest', {'field_id': 'f1'}, localId: 'local-5'), isEmpty);
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
