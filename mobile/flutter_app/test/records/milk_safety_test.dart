import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:farmos/data/local/cache_effects.dart';
import 'package:farmos/data/local/outbox_labels.dart';
import 'package:farmos/domain/entities/production_records.dart';
import 'package:farmos/features/animals/animal_quick_actions.dart';
import 'package:farmos/features/production/held_milk_card.dart';
import 'package:farmos/providers/animals_provider.dart';

import '../support/snapshot_farm.dart';

/// Milk safety at the milking time (v0.8.5), the same on the tablet and the
/// web: the milk form asks the server about the day and milking chosen —
/// a withdrawal then means the milk is withheld; records that cannot vouch
/// for it mean it will be held for review — and the Milk page shows held
/// milk, which only a vet or the manager releases or withholds, saying why.
void main() {
  const me = 'user-ali-demo';
  const workerAccess = {
    'user_id': me, 'role': 'worker', 'full_access': false,
    'modules': {'milk_production': {'view': true, 'create': true}, 'animals': {'view': true}},
  };

  Future<SnapshotFarm> openDialog(WidgetTester tester, String animalId, {Map<String, dynamic>? safety}) async {
    tester.view.physicalSize = const Size(1200, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final farm = await SnapshotFarm.open();
    if (safety != null) farm.api.snapshot['GET /production/milk-safety'] = safety;
    await tester.pumpWidget(farm.app(Scaffold(
      body: Builder(
        builder: (c) => Center(child: TextButton(onPressed: () => showMilkDialog(c, c.read<AnimalsProvider>().find(animalId)!), child: const Text('open'))),
      ),
    )));
    await settle(tester);
    await tester.tap(find.text('open'));
    await settle(tester);
    return farm;
  }

  Map sent(SnapshotFarm farm) => farm.api.writes.lastWhere((w) => w.$1 == 'POST' && w.$2 == '/production/milk').$3! as Map;

  group('the milk form asks about the milking\'s own time', () {
    testWidgets('a withdrawal then: the milk is withheld, whatever her record says today', (tester) async {
      final farm = await openDialog(tester, 'cow-214', safety: {
        'withdrawal_check': 'withdrawal', 'until': '2026-11-24T08:00:00Z', 'note': 'Luna was under withdrawal when milked', 'windows': [],
      });
      expect(find.byKey(const ValueKey('milk-safety-withdrawal')), findsOneWidget);
      expect(find.textContaining('Under withdrawal at this milking'), findsOneWidget);
      expect(find.text('Destination'), findsNothing, reason: 'no destination to choose: it is withheld');
      await tester.enterText(find.byKey(const ValueKey('milk-dialog-liters')), '12');
      await tester.tap(find.byKey(const ValueKey('milk-dialog-save')));
      await settle(tester);
      expect(sent(farm)['destination'], 'withheld');
    });

    testWidgets('records that cannot vouch for it: said before saving, the destination kept', (tester) async {
      final farm = await openDialog(tester, 'cow-214', safety: {'withdrawal_check': 'uncertain', 'windows': []});
      expect(find.byKey(const ValueKey('milk-safety-uncertain')), findsOneWidget);
      expect(find.textContaining('held for review'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('milk-dialog-liters')), '12');
      await tester.tap(find.byKey(const ValueKey('milk-dialog-save')));
      await settle(tester);
      expect(sent(farm)['destination'], 'stored', reason: 'the server holds it; the form does not pretend it was withheld');
    });

    testWidgets('a lactation that did not cover the milking is said before saving', (tester) async {
      await openDialog(tester, 'cow-214', safety: {'withdrawal_check': 'clear', 'windows': [], 'lactation_problem': 'Luna was dried off on 2026-11-24.'});
      expect(find.byKey(const ValueKey('milk-safety-lactation')), findsOneWidget);
      expect(find.text('Luna was dried off on 2026-11-24.'), findsOneWidget);
    });

    testWidgets('clear then: nothing is said and the destination is chosen as usual', (tester) async {
      final farm = await openDialog(tester, 'cow-214', safety: {'withdrawal_check': 'clear', 'windows': []});
      expect(find.byKey(const ValueKey('milk-safety-withdrawal')), findsNothing);
      expect(find.byKey(const ValueKey('milk-safety-uncertain')), findsNothing);
      await tester.enterText(find.byKey(const ValueKey('milk-dialog-liters')), '12');
      await tester.tap(find.byKey(const ValueKey('milk-dialog-save')));
      await settle(tester);
      expect(sent(farm)['destination'], 'stored');
    });
  });

  group('milk held for review on the Milk page', () {
    const held = {
      'id': 'mr-held-1', 'animal_id': 'cow-clover', 'animal_name': 'Clover', 'session': 'morning', 'liters': 14.0, 'destination': 'stored',
      'recorded_at': '2026-11-23T05:00:00Z', 'quality_status': 'normal', 'withdrawal_check': 'uncertain', 'release_status': 'held',
      'safety_note': "Clover's withdrawal at this milking cannot be confirmed from her records.",
    };

    Future<SnapshotFarm> openCard(WidgetTester tester, {bool worker = false}) async {
      tester.view.physicalSize = const Size(1200, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final farm = await SnapshotFarm.open();
      farm.api.snapshot['GET /production/milk-held'] = [held];
      if (worker) farm.api.snapshot['GET /me/access'] = workerAccess;
      await tester.pumpWidget(farm.app(const Scaffold(body: SingleChildScrollView(child: HeldMilkCard()))));
      await settle(tester);
      return farm;
    }

    testWidgets('the manager releases it, saying why', (tester) async {
      final farm = await openCard(tester);
      expect(find.byKey(const ValueKey('held-milk-card')), findsOneWidget);
      expect(find.textContaining('Milk held for review — 14 L'), findsOneWidget);
      expect(find.textContaining('cannot be confirmed'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('hm-release-mr-held-1')));
      await settle(tester);
      await tester.enterText(find.byType(TextField).last, 'Vet: the treatment began after this milking');
      await tester.tap(find.text('Save'));
      await settle(tester);
      final body = farm.api.writes.lastWhere((w) => w.$2 == '/production/milk/mr-held-1/review').$3! as Map;
      expect(body, {'decision': 'release', 'note': 'Vet: the treatment began after this milking'});
      expect(find.byKey(const ValueKey('held-milk-card')), findsNothing, reason: 'nothing left to review');
    });

    testWidgets('…or withholds it', (tester) async {
      final farm = await openCard(tester);
      await tester.tap(find.byKey(const ValueKey('hm-withhold-mr-held-1')));
      await settle(tester);
      await tester.enterText(find.byType(TextField).last, 'Not worth the risk');
      await tester.tap(find.text('Save'));
      await settle(tester);
      final body = farm.api.writes.lastWhere((w) => w.$2 == '/production/milk/mr-held-1/review').$3! as Map;
      expect(body['decision'], 'withhold');
    });

    testWidgets('an employee sees what is held but does not decide it', (tester) async {
      await openCard(tester, worker: true);
      expect(find.byKey(const ValueKey('held-milk-card')), findsOneWidget);
      expect(find.byKey(const ValueKey('hm-release-mr-held-1')), findsNothing);
      expect(find.byKey(const ValueKey('hm-withhold-mr-held-1')), findsNothing);
    });

    testWidgets('in Arabic', (tester) async {
      tester.view.physicalSize = const Size(1200, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final farm = await SnapshotFarm.open();
      farm.api.snapshot['GET /production/milk-held'] = [held];
      await tester.pumpWidget(farm.app(const Scaffold(body: SingleChildScrollView(child: HeldMilkCard())), locale: const Locale('ar')));
      await settle(tester);
      expect(find.textContaining('حليب موقوف للمراجعة'), findsOneWidget);
    });
  });

  test('the server\'s answers are read; older records are unchecked and saleable', () {
    final r = MilkRecord.fromJson({'id': 'x', 'animal_id': 'a', 'session': 'morning', 'liters': 3, 'destination': 'stored', 'recorded_at': '2026-11-23T05:00:00Z',
                                   'withdrawal_check': 'uncertain', 'release_status': 'held'});
    expect((r.isHeld, r.withdrawalCheck), (true, 'uncertain'));
    final older = MilkRecord.fromJson({'id': 'y', 'animal_id': 'a', 'session': 'morning', 'liters': 3, 'destination': 'stored', 'recorded_at': '2026-11-23T05:00:00Z'});
    expect((older.isHeld, older.withdrawalCheck, older.releaseStatus), (false, 'unchecked', 'saleable'));
    expect(MilkSafety.fromJson({'withdrawal_check': 'withdrawal', 'until': '2026-11-24T08:00:00Z'}).isWithdrawal, isTrue);
  });

  test('offline: a review shows at once and is named in the list', () {
    final merge = effectsFor('POST', '/production/milk/mr-1/review', {'decision': 'withhold', 'note': 'x'}, localId: 'l').whereType<MergeRecord>().single;
    expect((merge.collectionPath, merge.patch['release_status'], merge.patch['destination']), ('/production/milk', 'not_for_sale', 'withheld'));
    expect(describeWrite('/production/milk/mr-1/review').labelKey, 'outboxMilkRecord');
  });
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}
