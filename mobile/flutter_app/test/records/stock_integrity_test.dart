import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:farmos/data/local/cache_effects.dart';
import 'package:farmos/data/local/outbox_labels.dart';
import 'package:farmos/domain/entities/approvals.dart';
import 'package:farmos/domain/entities/feeding.dart';
import 'package:farmos/features/feed/feed_stock_dialogs.dart';
import 'package:farmos/features/feed/feeding_event_dialog.dart';
import 'package:farmos/features/feed/purchase_and_mix_dialogs.dart';
import 'package:farmos/features/feed/tabs/feeds_and_lots_tab.dart';
import 'package:farmos/providers/approvals_provider.dart';

import '../support/snapshot_farm.dart';

/// Feed stock integrity (v0.8.4), the same on the tablet and the web: more
/// than the stock on record is recorded only with the manager's override
/// and a reason; what was fed with no lot shows on the feed until the
/// manager reconciles it — the lot it came from, stock that was there, or
/// a count — and is not counted as available meanwhile.
void main() {
  const me = 'user-ali-demo';
  const workerAccess = {
    'user_id': me, 'role': 'worker', 'full_access': false,
    'modules': {'feed_nutrition': {'view': true, 'create': true}, 'animals': {'view': true}, 'inventory': {'view': true, 'create': true}},
  };
  const straw = 'fp-wheat-straw';

  /// Wheat straw after a 30 kg feeding the manager approved past the stock:
  /// 250 kg in its lots, 30 kg fed with no lot and open.
  void strawShort(Map<String, dynamic> s) {
    for (final p in s['GET /feed-products'] as List) {
      if ((p as Map)['id'] != straw) continue;
      final a = p['availability'] as Map;
      a
        ..['lot_on_hand'] = 250
        ..['on_hand'] = 220
        ..['untraced'] = 30
        ..['open_exceptions'] = 1
        ..['available'] = 220;
    }
    s['GET /feed-inventory/exceptions'] = [
      {
        'id': 'sx-1', 'feed_product_id': straw, 'feed_product_name': 'Wheat straw', 'kind': 'untraced_issue', 'quantity': 30,
        'resolved_quantity': 0, 'open_quantity': 30, 'unit': 'kg', 'status': 'open', 'reason': 'Bales from the truck, not entered yet',
        'requested_by_name': 'Karim', 'approved_by_name': 'Rami', 'source_entity_type': 'feeding_event', 'source_entity_id': 'fe-1',
        'lot_code': null, 'occurred_at': '2026-11-24T06:30:00Z', 'created_at': '2026-11-24T06:30:00Z', 'detail': {},
      },
    ];
  }

  Future<SnapshotFarm> open(WidgetTester tester, Widget home,
      {bool worker = false, bool scroll = false, Locale locale = const Locale('en'), void Function(Map<String, dynamic>)? data}) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final farm = await SnapshotFarm.open();
    if (worker) farm.api.snapshot['GET /me/access'] = workerAccess;
    data?.call(farm.api.snapshot);
    await tester.pumpWidget(farm.app(Scaffold(body: scroll ? SingleChildScrollView(child: home) : home), locale: locale));
    await settle(tester);
    return farm;
  }

  Widget opener(void Function(BuildContext) onTap) =>
      Builder(builder: (context) => Center(child: TextButton(onPressed: () => onTap(context), child: const Text('open'))));

  Map? last(SnapshotFarm farm, String method, String path) {
    final w = farm.api.writes.where((w) => w.$1 == method && w.$2 == path);
    return w.isEmpty ? null : w.last.$3! as Map;
  }

  group('recording past the stock', () {
    testWidgets('the override says why — no reason, nothing is sent', (tester) async {
      final farm = await open(tester, opener((c) => showFeedingEventDialog(c, subjectType: 'animal', subjectId: 'cow-744', subjectName: 'Bella')));
      await tester.tap(find.text('open'));
      await settle(tester);
      await tester.enterText(find.byType(TextField).at(2), '99999');
      await tester.pump();
      await tester.tap(find.text('Stock not entered yet — record anyway'));
      await tester.pump();
      expect(find.byKey(const ValueKey('stock-override-reason')), findsOneWidget);
      await tester.tap(find.text('Save'));
      await settle(tester);
      expect(last(farm, 'POST', '/feeding-events'), isNull);
      expect(find.text('Say why more than the stock on record is recorded.'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('stock-override-reason')), 'Truck unloaded, delivery not entered yet');
      await tester.tap(find.text('Save'));
      await settle(tester);
      final body = last(farm, 'POST', '/feeding-events')!;
      expect((body['allow_negative'], body['override_reason']), (true, 'Truck unloaded, delivery not entered yet'));
    });

    testWidgets('the reason field appears only once the override is ticked', (tester) async {
      await open(tester, opener((c) => showFeedingEventDialog(c, subjectType: 'animal', subjectId: 'cow-744', subjectName: 'Bella')));
      await tester.tap(find.text('open'));
      await settle(tester);
      await tester.enterText(find.byType(TextField).at(2), '99999');
      await tester.pump();
      expect(find.byKey(const ValueKey('stock-override-reason')), findsNothing);
    });

    testWidgets('a mix past the stock says why too', (tester) async {
      final farm = await open(tester, opener((c) => showRecordMixDialog(c, productId: 'fp-dairy-mix')));
      await tester.tap(find.text('open'));
      await settle(tester);
      await tester.enterText(find.widgetWithText(TextField, 'Quantity').first, '99999');
      await tester.pump();
      final anyway = find.text('Stock not entered yet — record anyway');
      await tester.ensureVisible(anyway);
      await tester.tap(anyway);
      await tester.pump();
      final save = find.widgetWithText(FilledButton, 'Save the mix');
      await tester.tap(save);
      await settle(tester);
      expect(last(farm, 'POST', '/feed-mixes'), isNull, reason: 'no reason, nothing sent');
      await tester.enterText(find.byKey(const ValueKey('stock-override-reason')), 'Barley bags in the truck');
      await tester.tap(save);
      await settle(tester);
      final body = last(farm, 'POST', '/feed-mixes');
      expect(body, isNotNull);
      expect((body!['allow_negative'], body['override_reason']), (true, 'Barley bags in the truck'));
    });

    test('approving a short mix anyway sends the reason with the override', () async {
      final farm = await SnapshotFarm.open();
      final approvals = ApprovalsProvider(apiClient: farm.api, currentUserId: 'user-rami');
      final r = ApprovalRequest.fromJson({'id': 'ar-1', 'kind': 'feed_mix', 'status': 'pending', 'summary': 'Heifer mix', 'module_code': 'feed_nutrition',
                                          'requested_by': 'user-worker-1', 'requested_at': '2026-11-25T08:00:00Z', 'payload': {}});
      await approvals.approve(r, allowNegative: true, overrideReason: 'Delivery note to follow');
      final sent = farm.api.writes.lastWhere((w) => w.$2 == '/approval-requests/ar-1/approve').$3! as Map;
      expect((sent['allow_negative'], sent['override_reason']), (true, 'Delivery note to follow'));
    });
  });

  group('what was fed with no lot', () {
    testWidgets('shows on the feed, is not available, and the manager reconciles it from a lot', (tester) async {
      final farm = await open(tester, const FeedsAndLotsTab(), scroll: true, data: strawShort);
      expect(find.byKey(const ValueKey('feed-untraced-pill-$straw')), findsOneWidget);
      expect(find.text('Fed with no lot 30 kg'), findsOneWidget);
      await tester.tap(find.text('Wheat straw'));
      await settle(tester);
      expect(find.text('In lots'), findsOneWidget);
      expect(find.text('− 30 kg'), findsOneWidget);
      expect(find.byKey(const ValueKey('feed-untraced-notice-$straw')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('feed-reconcile-$straw')));
      await settle(tester);
      expect(find.text('Why: Bales from the truck, not entered yet'), findsOneWidget, reason: 'why, as the manager wrote it');
      expect(find.textContaining('Recorded by Karim'), findsOneWidget);
      expect(find.textContaining('approved by Rami'), findsOneWidget);

      // No lot chosen: refused before anything is sent.
      await tester.enterText(find.byKey(const ValueKey('sx-note-sx-1')), 'Fed from the truck before it was entered');
      await tester.tap(find.byKey(const ValueKey('sx-save-sx-1')));
      await settle(tester);
      expect(find.text('Choose the lot it came from.'), findsOneWidget);
      expect(last(farm, 'POST', '/feed-inventory/exceptions/sx-1/resolve'), isNull);

      await tester.tap(find.byKey(const ValueKey('sx-lot-sx-1')));
      await settle(tester);
      await tester.tap(find.textContaining('WST-2609-04').last);
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('sx-save-sx-1')));
      await settle(tester);
      final body = last(farm, 'POST', '/feed-inventory/exceptions/sx-1/resolve')!;
      expect(body['resolution'], 'assigned_to_lot');
      expect(body['note'], 'Fed from the truck before it was entered');
      expect(body['lot_id'], isNotNull);
    });

    testWidgets('…or confirms the stock was there; a note is required', (tester) async {
      final farm = await open(tester, const FeedsAndLotsTab(), scroll: true, data: strawShort);
      await tester.tap(find.text('Wheat straw'));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('feed-reconcile-$straw')));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('sx-mode-there-sx-1')));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('sx-save-sx-1')));
      await settle(tester);
      expect(find.text('Say how it was reconciled.'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('sx-note-sx-1')), 'Old bales behind the stack were never entered');
      await tester.tap(find.byKey(const ValueKey('sx-save-sx-1')));
      await settle(tester);
      final body = last(farm, 'POST', '/feed-inventory/exceptions/sx-1/resolve')!;
      expect((body['resolution'], body.containsKey('lot_id')), ('confirmed_unrecorded_stock', false));
    });

    testWidgets('an employee sees it but does not reconcile it', (tester) async {
      await open(tester, const FeedsAndLotsTab(), scroll: true, worker: true, data: strawShort);
      expect(find.byKey(const ValueKey('feed-untraced-pill-$straw')), findsOneWidget);
      await tester.tap(find.text('Wheat straw'));
      await settle(tester);
      expect(find.byKey(const ValueKey('feed-reconcile-$straw')), findsNothing);
    });

    testWidgets('a count says it settles what was fed with no lot', (tester) async {
      await open(tester, opener((c) => showStockCountDialog(c, productId: straw)), data: strawShort);
      await tester.tap(find.text('open'));
      await settle(tester);
      expect(find.byKey(const ValueKey('count-settles')), findsOneWidget);
      expect(find.text('This count also settles the 30 kg fed with no lot.'), findsOneWidget);
      // "The records say": the stock on record, lots less what was fed with no lot.
      expect(tester.widget<Text>(find.byKey(const ValueKey('count-on-records'))).data, contains('220 kg'));
    });

    testWidgets('in Arabic', (tester) async {
      await open(tester, const FeedsAndLotsTab(), scroll: true, locale: const Locale('ar'), data: strawShort);
      expect(find.text('مطعّم بلا دفعة 30 kg'), findsOneWidget);
    });
  });

  test('the server\'s availability parts, and an older server without them', () {
    final a = FeedAvailability.fromJson({'on_hand': 50, 'lot_on_hand': 100, 'untraced': 50, 'open_exceptions': 1, 'unusable': 0, 'reserved': 0, 'available': 50, 'unit': 'kg'});
    expect((a.onHand, a.lotOnHand, a.untraced, a.openExceptions, a.available), (50.0, 100.0, 50.0, 1, 50.0));
    final older = FeedAvailability.fromJson({'on_hand': 80, 'unusable': 0, 'reserved': 0, 'available': 80, 'unit': 'kg'});
    expect((older.lotOnHand, older.untraced), (80.0, 0.0));
  });

  test('offline: a reconciliation shows at once and is named in the list', () {
    final merge = effectsFor('POST', '/feed-inventory/exceptions/sx-1/resolve', {'resolution': 'confirmed_unrecorded_stock', 'note': 'x'}, localId: 'l')
        .whereType<MergeRecord>()
        .single;
    expect((merge.collectionPath, merge.id, merge.patch['status']), ('/feed-inventory/exceptions', 'sx-1', 'resolved'));
    expect(describeWrite('/feed-inventory/exceptions/sx-1/resolve').labelKey, 'outboxStockException');
  });
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}
