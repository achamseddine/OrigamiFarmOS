import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:farmos/domain/entities/animal.dart';
import 'package:farmos/features/animals/animal_queue_screen.dart';
import 'package:farmos/features/animals/quick_round.dart';
import 'package:farmos/features/approvals/approvals_card.dart';
import 'package:farmos/features/approvals/ask_to_buy_dialog.dart';
import 'package:farmos/features/approvals/correction_dialogs.dart';
import 'package:farmos/features/feed/purchase_and_mix_dialogs.dart';
import 'package:farmos/features/production/milk_production_screen.dart';
import 'package:farmos/providers/feeding_provider.dart';
import 'package:farmos/providers/production_provider.dart';

import '../support/snapshot_farm.dart';

/// Employees enter the day's milk and feedings; buying feed, a numbered
/// mix and correcting a record are the farm manager's (v0.7.8). The same
/// screens on the tablet and the web: an employee sends those as requests,
/// the manager decides them on the approvals card. And the cow queue:
/// follow the milking cow by cow, or scan labels in any order.
void main() {
  const me = 'user-ali-demo';
  const workerAccess = {
    'user_id': me,
    'role': 'worker',
    'full_access': false,
    'modules': {
      'animals': {'view': true, 'create': true, 'edit': true},
      'feed_nutrition': {'view': true, 'create': true, 'edit': true},
      'inventory': {'view': true, 'create': true, 'edit': true},
      'milk_production': {'view': true, 'create': true, 'edit': true},
      'morning_operations': {'view': true, 'create': true, 'edit': true},
    },
  };

  Future<SnapshotFarm> open(WidgetTester tester, Widget Function() home,
      {bool worker = false, Map<String, Object?> extra = const {}, Size size = const Size(1200, 2400)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final farm = await SnapshotFarm.open();
    if (worker) farm.api.snapshot['GET /me/access'] = workerAccess;
    farm.api.snapshot.addAll(extra);
    await tester.pumpWidget(farm.app(Scaffold(body: home())));
    await settle(tester);
    return farm;
  }

  Widget opener(void Function(BuildContext) open) => Builder(builder: (c) => Center(child: TextButton(onPressed: () => open(c), child: const Text('open'))));

  Map body(SnapshotFarm farm, String path) => farm.api.writes.lastWhere((w) => w.$1 == 'POST' && w.$2 == path).$3! as Map;

  Map<String, dynamic> request(String id, {String kind = 'feed_mix', String status = 'pending', String by = 'user-worker-1', String? note, String? target}) => {
        'id': id, 'kind': kind, 'module_code': kind == 'milk_correction' ? 'milk_production' : 'feed_nutrition', 'status': status,
        'summary': 'Mix of Dairy Mix 24L: 40 kg from Barley', 'requested_by': by, 'requested_by_name': 'Karim Youssef',
        'requested_at': DateTime.now().toUtc().toIso8601String(), 'reason': 'weighed twice', 'payload': <String, dynamic>{},
        'decision_note': note, 'decided_by_name': status == 'pending' ? null : 'Ali', 'target_id': target,
        'decided_at': status == 'pending' ? null : DateTime.now().toUtc().toIso8601String(),
      };

  group('buying feed', () {
    testWidgets('an employee asks the manager; nothing is bought', (tester) async {
      final farm = await open(tester, () => opener((c) => showRecordPurchaseDialog(c, productId: 'fp-barley')), worker: true);
      await tester.tap(find.text('open'));
      await settle(tester);
      expect(find.text('Ask to buy feed'), findsOneWidget);
      expect(find.text("Buying feed is the farm manager's decision"), findsOneWidget);
      await tester.enterText(find.widgetWithText(TextField, 'How much'), '500');
      await tester.tap(find.widgetWithText(FilledButton, 'Send to the manager'));
      await settle(tester);
      final sent = body(farm, '/procurement/requisitions');
      expect(sent['submit'], isTrue);
      expect((sent['lines'] as List).single['feed_product_id'], 'fp-barley');
      expect((sent['lines'] as List).single['requested_quantity'], 500);
      expect(farm.api.writes.where((w) => w.$2 == '/feed-lots/receive'), isEmpty);
    });

    testWidgets('an approved request is received against it', (tester) async {
      final farm = await open(tester, () => opener((c) => showAskToBuyDialog(c)), worker: true, extra: {
        'GET /procurement/requisitions': [
          {
            'id': 'pr-1', 'requisition_no': 'PR-000007', 'status': 'approved', 'requested_by': me, 'requested_at': '2026-11-19T08:00:00Z',
            'lines': [
              {'inventory_item_id': 'feed-barley', 'item_name': 'Barley', 'requested_quantity': 500, 'uom_code': 'kg', 'status': 'approved'},
            ],
            'approvals': [
              {'decision': 'approved', 'comments': 'Order from Bekaa'},
            ],
          },
        ],
      });
      await tester.tap(find.text('open'));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('deliver-pr-1')));
      await settle(tester);
      expect(find.byKey(const ValueKey('delivery-of-request')), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await settle(tester);
      final lot = body(farm, '/feed-lots/receive');
      expect(lot['requisition_id'], 'pr-1');
      expect(lot['feed_product_id'], 'fp-barley');
      expect(lot['quantity'], 500, reason: 'the approved quantity, to correct if less arrived');
    });

    testWidgets('the manager records a purchase directly', (tester) async {
      await open(tester, () => opener((c) => showRecordPurchaseDialog(c)));
      await tester.tap(find.text('open'));
      await settle(tester);
      expect(find.text('Ask to buy feed'), findsNothing);
      expect(find.text('Record purchase'), findsWidgets);
    });
  });

  group('the approvals card', () {
    testWidgets('the manager approves or rejects with a reason', (tester) async {
      final farm = await open(
        tester,
        () => const SingleChildScrollView(child: ApprovalsCard()),
        extra: {
          'GET /approval-requests': [request('ar-1'), request('ar-2')],
        },
      );
      expect(find.text('Waiting for your approval · 2'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('approve-ar-1')));
      await settle(tester);
      expect(farm.api.writes.any((w) => w.$1 == 'POST' && w.$2 == '/approval-requests/ar-1/approve'), isTrue);

      await tester.tap(find.byKey(const ValueKey('reject-ar-2')));
      await settle(tester);
      await tester.enterText(find.byType(TextField).last, 'Weigh it again');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await settle(tester);
      expect(body(farm, '/approval-requests/ar-2/reject')['note'], 'Weigh it again');
    });

    testWidgets('an employee sees what became of their requests and withdraws one waiting', (tester) async {
      final farm = await open(
        tester,
        () => const SingleChildScrollView(child: ApprovalsCard()),
        worker: true,
        extra: {
          'GET /approval-requests': [request('ar-3', by: me, status: 'rejected', note: 'Barley was wet'), request('ar-4', by: me)],
        },
      );
      expect(find.text('Your requests'), findsOneWidget);
      expect(find.text('Not approved'), findsOneWidget);
      expect(find.textContaining('Barley was wet'), findsOneWidget);
      expect(find.byKey(const ValueKey('approve-ar-4')), findsNothing, reason: 'an employee does not approve');
      await tester.tap(find.byKey(const ValueKey('withdraw-ar-4')));
      await settle(tester);
      expect(farm.api.writes.any((w) => w.$2 == '/approval-requests/ar-4/cancel'), isTrue);
    });
  });

  group('corrections', () {
    testWidgets('an employee asks for a milk correction', (tester) async {
      late SnapshotFarm farm;
      farm = await open(tester, () => opener((c) {
            final record = c.read<ProductionProvider>().milkRecords.firstWhere((r) => r.animalId == 'cow-744');
            showCorrectMilkDialog(c, record);
          }), worker: true);
      await tester.tap(find.text('open'));
      await settle(tester);
      expect(find.byKey(const ValueKey('correction-goes-to-manager')), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, '16.1');
      await tester.tap(find.widgetWithText(FilledButton, 'Send to the manager'));
      await settle(tester);
      expect(find.text('Say why it is corrected.'), findsOneWidget, reason: 'a correction says why');
      await tester.enterText(find.byType(TextField).last, 'Typed 18.6 for 16.1');
      await tester.tap(find.widgetWithText(FilledButton, 'Send to the manager'));
      await settle(tester);
      final sent = body(farm, '/approval-requests');
      expect(sent['kind'], 'milk_correction');
      expect(sent['target_id'], isNotNull);
      expect((sent['payload'] as Map)['liters'], 16.1);
      expect(farm.api.writes.where((w) => (w.$2).endsWith('/correct')), isEmpty);
    });

    testWidgets('the manager corrects milk directly', (tester) async {
      final farm = await open(tester, () => opener((c) {
            final record = c.read<ProductionProvider>().milkRecords.firstWhere((r) => r.animalId == 'cow-744');
            showCorrectMilkDialog(c, record);
          }));
      await tester.tap(find.text('open'));
      await settle(tester);
      await tester.enterText(find.byType(TextField).first, '17');
      await tester.enterText(find.byType(TextField).last, 'misread the jar');
      await tester.tap(find.widgetWithText(FilledButton, 'Save the correction'));
      await settle(tester);
      final write = farm.api.writes.lastWhere((w) => w.$2.startsWith('/production/milk/') && w.$2.endsWith('/correct'));
      expect((write.$3! as Map)['liters'], 17);
      expect((write.$3! as Map)['reason'], 'misread the jar');
    });

    testWidgets('a feeding is undone (the manager)', (tester) async {
      final farm = await open(tester, () => opener((c) {
            final event = c.read<FeedingProvider>().recentEvents.firstWhere((e) => e.status == 'recorded');
            showCorrectFeedingDialog(c, event);
          }));
      await tester.tap(find.text('open'));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('undo-all')));
      await tester.pump();
      await tester.enterText(find.byType(TextField).last, 'Recorded on the wrong pen');
      await tester.tap(find.widgetWithText(FilledButton, 'Save the correction'));
      await settle(tester);
      final write = farm.api.writes.lastWhere((w) => w.$2.startsWith('/feeding-events/') && w.$2.endsWith('/correct'));
      expect((write.$3! as Map)['components'], isEmpty);
    });
  });

  group('the cow queue', () {
    Animal cow(String id, String? tag) => Animal.fromJson({'id': id, 'name': id, 'species': 'cattle', 'tag': tag, 'status': 'active'});

    test('natural tag order: plain numbers, then prefixed tags, numbers as numbers', () {
      final cows = [cow('a', '744'), cow('b', 'G-091'), cow('c', '214'), cow('d', '9'), cow('e', 'S-118'), cow('f', null)]..sort(queueOrder);
      expect([for (final c in cows) c.tag], ['9', '214', '744', 'G-091', 'S-118', null]);
    });

    test('the next cow skips those done and goes round to the start', () {
      final status = RoundStatus([
        RoundEntry(cow('a', '1'), done: true),
        RoundEntry(cow('b', '2'), done: false),
        RoundEntry(cow('c', '3'), done: true),
        RoundEntry(cow('d', '4'), done: false),
      ]);
      expect(nextInQueue(status)?.id, 'b');
      expect(nextInQueue(status, after: 'b')?.id, 'd');
      expect(nextInQueue(status, after: 'd')?.id, 'b', reason: 'round to the start');
      expect(nextInQueue(RoundStatus([RoundEntry(cow('a', '1'), done: true)])), isNull);
    });

    testWidgets('follow the queue: the first cow opens, Skip moves to the next', (tester) async {
      await open(tester, () => const SizedBox(), size: const Size(1280, 800));
      final context = tester.element(find.byType(Scaffold).first);
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const AnimalQueueScreen(initial: QuickRound.milking('morning'))));
      await settle(tester);
      expect(find.text('Cow queue'), findsOneWidget);
      // Cows by tag (214, 381, 744), then the goats (G-091, S-118).
      final rows = find.byWidgetPredicate((w) => w.key is ValueKey && '${(w.key! as ValueKey).value}'.startsWith('queue-row-'));
      expect(rows, findsNWidgets(5));
      final first = tester.getTopLeft(find.byKey(const ValueKey('queue-row-cow-214'))).dy;
      expect(first, lessThan(tester.getTopLeft(find.byKey(const ValueKey('queue-row-cow-744'))).dy));
      expect(tester.getTopLeft(find.byKey(const ValueKey('queue-row-cow-744'))).dy, lessThan(tester.getTopLeft(find.byKey(const ValueKey('queue-row-goat-gigi'))).dy));
      expect(find.byKey(const ValueKey('queue-scan')), findsOneWidget, reason: 'or scan labels in any order');

      await tester.tap(find.byKey(const ValueKey('queue-follow')));
      await settle(tester);
      expect(find.byKey(const ValueKey('queue-bar')), findsOneWidget);
      expect(find.text('Cow 1 of 5 in the queue'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('queue-skip')));
      await settle(tester);
      expect(find.text('Cow 2 of 5 in the queue'), findsOneWidget);
    });

    testWidgets('the Milk page records milk and opens the milking queue', (tester) async {
      await open(tester, () => const MilkProductionScreen(), size: const Size(1280, 1600));
      expect(find.text('Record milk'), findsOneWidget);
      expect(find.text('Milking queue'), findsOneWidget);
    });
  });
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}
