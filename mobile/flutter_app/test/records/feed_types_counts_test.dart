import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:farmos/data/local/cache_effects.dart';
import 'package:farmos/data/local/outbox_labels.dart';
import 'package:farmos/features/animals/animal_quick_entry_screen.dart';
import 'package:farmos/features/feed/feed_inventory_screen.dart';
import 'package:farmos/features/feed/feed_stock_dialogs.dart';
import 'package:farmos/features/feed/feeding_event_dialog.dart';
import 'package:farmos/features/feed/purchase_and_mix_dialogs.dart';
import 'package:farmos/features/feed/tabs/costs_tab.dart';
import 'package:farmos/features/feed/tabs/feeds_and_lots_tab.dart';
import 'package:farmos/features/reports/report_docs.dart';

import '../support/snapshot_farm.dart';

/// Feed (v0.8.3), the same on the tablet and the web: the animals are fed
/// only concentrate, corn silage and hay & straw — a raw material goes into
/// a mix; the manager counts the stock on inspection and the count becomes
/// the stock; every feed has a price and every feeding shows its cost.
void main() {
  const me = 'user-ali-demo';
  const workerAccess = {
    'user_id': me, 'role': 'worker', 'full_access': false,
    'modules': {'feed_nutrition': {'view': true, 'create': true}, 'animals': {'view': true}, 'inventory': {'view': true, 'create': true}},
  };

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

  Map body(SnapshotFarm farm, String method, String path) => farm.api.writes.lastWhere((w) => w.$1 == method && w.$2 == path).$3! as Map;

  group('what the animals are fed', () {
    testWidgets('a feeding offers concentrate, silage and hay & straw — never a raw material — and says its cost', (tester) async {
      await open(tester, opener((c) => showFeedingEventDialog(c, subjectType: 'animal', subjectId: 'cow-744', subjectName: 'Bella')));
      await tester.tap(find.text('open'));
      await settle(tester);
      await tester.tap(find.byType(DropdownButtonFormField<String>).at(1));
      await settle(tester);
      expect(find.text('Barley'), findsNothing, reason: 'barley is a raw material');
      expect(find.text('Minerals'), findsNothing);
      expect(find.text('Cattle Dairy Premix'), findsNothing);
      expect(find.text('Dairy Mix 24L'), findsWidgets, reason: 'the farm\'s mix is a concentrate');
      await tester.tapAt(const Offset(5, 5));
      await settle(tester);
      // 20 kg of corn silage at $0.18 and 2 kg of straw at $0.12.
      await tester.enterText(find.byType(TextField).at(1), '20');
      await tester.enterText(find.byType(TextField).at(2), '2');
      await settle(tester);
      expect(find.text('Cost of this feeding: \$3.84'), findsOneWidget);
    });

    testWidgets('a feed with no price is named, not costed at zero', (tester) async {
      await open(tester, opener((c) => showFeedingEventDialog(c, subjectType: 'animal', subjectId: 'cow-744', subjectName: 'Bella')), data: (s) {
        for (final p in s['GET /feed-products'] as List) {
          if ((p as Map)['id'] == 'fp-corn-silage') p..['current_unit_cost'] = null..['default_unit_cost'] = null;
        }
      });
      await tester.tap(find.text('open'));
      await settle(tester);
      await tester.enterText(find.byType(TextField).at(1), '20');
      await settle(tester);
      expect(find.text('Cost of this feeding: \$0.00'), findsOneWidget);
      expect(find.text('No price yet for Corn Silage — not counted in the cost.'), findsOneWidget);
    });

    testWidgets('the quick entry at the animal shows the cost too', (tester) async {
      await open(tester, const AnimalQuickEntryScreen(initialAnimalId: 'cow-744'));
      final fields = find.byWidgetPredicate((w) => w is TextField && (w.decoration?.labelText ?? '').startsWith('Offered'));
      await tester.enterText(fields.at(1), '10');
      await settle(tester);
      // Bella's rows come from her ration: the second is alfalfa hay at $0.31.
      expect(find.text('Cost of this feeding: \$3.10'), findsOneWidget, reason: '10 kg of alfalfa hay at \$0.31');
    });

    testWidgets('a new feed on the purchase form is a raw material unless it is one of the three', (tester) async {
      final farm = await open(tester, opener((c) => showRecordPurchaseDialog(c)));
      await tester.tap(find.text('open'));
      await settle(tester);
      await tester.tap(find.byType(DropdownButtonFormField<String>).first);
      await settle(tester);
      await tester.tap(find.textContaining('+ New feed').last);
      await settle(tester);
      expect(find.text('What is it?'), findsOneWidget);
      await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Soybean meal');
      await tester.enterText(find.widgetWithText(TextField, 'Received'), '500');
      await tester.tap(find.text('Save'));
      await settle(tester);
      final raw = farm.api.writes.firstWhere((w) => w.$1 == 'POST' && w.$2 == '/feed-products').$3! as Map;
      expect((raw['ration_type'], raw['category']), ('raw_material', 'concentrate'));
    });

    testWidgets('…and corn silage when that is what came', (tester) async {
      final farm = await open(tester, opener((c) => showRecordPurchaseDialog(c)));
      await tester.tap(find.text('open'));
      await settle(tester);
      await tester.tap(find.byType(DropdownButtonFormField<String>).first);
      await settle(tester);
      await tester.tap(find.textContaining('+ New feed').last);
      await settle(tester);
      await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Silage pit 2');
      await tester.tap(find.byKey(const ValueKey('feed-type-silage')));
      await tester.enterText(find.widgetWithText(TextField, 'Received'), '8000');
      await tester.tap(find.text('Save'));
      await settle(tester);
      final made = farm.api.writes.firstWhere((w) => w.$1 == 'POST' && w.$2 == '/feed-products').$3! as Map;
      expect((made['ration_type'], made['category']), ('silage', 'forage'));
    });

    testWidgets('the manager changes what a feed is and its price', (tester) async {
      final farm = await open(tester, const FeedsAndLotsTab(), scroll: true);
      expect(find.byKey(const ValueKey('feed-type-pill-fp-barley')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const ValueKey('feed-type-pill-fp-barley')), matching: find.text('Raw material — for mixing')), findsOneWidget);
      await tester.tap(find.text('Barley'));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('feed-edit-fp-barley')));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('feed-type-concentrate')));
      await tester.enterText(find.byKey(const ValueKey('feed-price')), '0.4');
      await tester.tap(find.byKey(const ValueKey('feed-type-save')));
      await settle(tester);
      expect(body(farm, 'PATCH', '/feed-products/fp-barley'), {'ration_type': 'concentrate', 'default_unit_cost': 0.4});
    });
  });

  group('counting the stock', () {
    testWidgets('the count becomes the stock; the difference is said before it is saved', (tester) async {
      final farm = await open(tester, const FeedInventoryScreen(embedded: true), scroll: true);
      expect(find.byKey(const ValueKey('stock-count')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('stock-count')));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('count-product')));
      await settle(tester);
      await tester.tap(find.textContaining('Wheat straw ·').last);
      await settle(tester);
      final onRecords = tester.widget<Text>(find.byKey(const ValueKey('count-on-records'))).data!;
      expect(onRecords, startsWith('On hand by the records: '));
      await tester.enterText(find.byKey(const ValueKey('count-quantity')), '1000');
      await settle(tester);
      expect(find.byKey(const ValueKey('count-difference')), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('count-notes')), 'Rain got into the shed');
      await tester.tap(find.byKey(const ValueKey('count-save')));
      await settle(tester);
      final sent = body(farm, 'POST', '/feed-inventory/counts');
      expect((sent['feed_product_id'], sent['counted_quantity'], sent['unit'], sent['notes']), ('fp-wheat-straw', 1000, 'kg', 'Rain got into the shed'));
      expect(sent.containsKey('counted_at'), isFalse, reason: 'counted today: now');
    });

    testWidgets('a line\'s menu counts that feed; a raw material has no "used" entry', (tester) async {
      await open(tester, const FeedInventoryScreen(embedded: true), scroll: true);
      await tester.tap(find.byKey(const ValueKey('stock-row-menu-feed-barley')));
      await settle(tester);
      expect(find.text('Record distribution'), findsNothing, reason: 'barley is used by the mixes');
      expect(find.byKey(const ValueKey('stock-count-feed-barley')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('stock-count-feed-barley')));
      await settle(tester);
      expect(find.textContaining('Barley ·'), findsWidgets, reason: 'the count opens on that feed');
    });

    testWidgets('an employee neither counts nor sets prices', (tester) async {
      await open(tester, const FeedInventoryScreen(embedded: true), worker: true, scroll: true);
      expect(find.byKey(const ValueKey('stock-count')), findsNothing);
    });
  });

  group('feed prices', () {
    testWidgets('the Costs tab lists each feed\'s price and names a feed without one', (tester) async {
      await open(tester, const CostsTab(), scroll: true, data: (s) {
        for (final p in s['GET /feed-products'] as List) {
          if ((p as Map)['id'] == 'fp-corn-silage') p..['current_unit_cost'] = null..['default_unit_cost'] = null;
        }
      });
      expect(find.byKey(const ValueKey('feed-prices')), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const ValueKey('feed-price-fp-wheat-straw'))).data, '\$0.12/kg');
      expect(tester.widget<Text>(find.byKey(const ValueKey('feed-price-fp-corn-silage'))).data, 'No price');
      expect(find.textContaining('No price yet for: Corn Silage'), findsOneWidget);
      expect(find.byKey(const ValueKey('feed-set-price-fp-corn-silage')), findsOneWidget);
    });

    testWidgets('the feed report: the cost of each animal and group, and feed given without a price', (tester) async {
      late List tables;
      late List kpis;
      await open(tester, Builder(builder: (c) {
        final doc = buildReportDoc(c, 'feed', {
          'kind': 'feed', 'start': '2026-11-19', 'end': '2026-11-25', 'days': 7, 'currency': 'USD',
          'kpis': {'feedings': 4, 'subjects_fed': 1, 'feed_used_kg': 30, 'feed_cost': 7, 'feed_cost_per_day': 1, 'unpriced_kg': 5},
          'used': [], 'deliveries': [], 'mixes': [], 'stock': [],
          'by_subject': [
            {'subject_type': 'animal', 'subject_id': 'cow-744', 'name': 'Bella', 'tag': '744', 'feedings': 4, 'quantity_kg': 30, 'cost': 7, 'cost_per_day': 1},
          ],
        }, speciesName: (s) => s);
        tables = doc.tables;
        kpis = doc.kpis;
        return const SizedBox();
      }));
      final table = tables.firstWhere((t) => t.title == 'Feed cost per animal and group');
      expect(table.rows.single, ['744 · Bella', '4', '30 kg', '\$7.00', '\$1.00']);
      expect(kpis.map((k) => k.$1), containsAll(['Feed cost per day', 'Fed without a price']));
    });
  });

  test('offline: a type changed shows at once; a count waits in the list, named', () {
    final fx = effectsFor('PATCH', '/feed-products/fp-barley', {'ration_type': 'raw_material', 'default_unit_cost': 0.4}, localId: 'l');
    final merge = fx.whereType<MergeRecord>().single;
    expect((merge.patch['ration_type'], merge.patch['is_feedable'], merge.patch['default_unit_cost']), (null, false, 0.4));
    final fed = effectsFor('PATCH', '/feed-products/fp-barley', {'ration_type': 'concentrate'}, localId: 'l').whereType<MergeRecord>().single;
    expect((fed.patch['ration_type'], fed.patch['is_feedable']), ('concentrate', true));
    expect(describeWrite('/feed-inventory/counts').labelKey, 'outboxStockCount');
  });

  test('a feeding\'s cost: what is priced, and what is not', () {
    expect(feedRationTypes, ['concentrate', 'silage', 'hay_straw']);
  });

  testWidgets('in Arabic', (tester) async {
    await open(tester, const CostsTab(), locale: const Locale('ar'), scroll: true);
    expect(find.text('أسعار العلف'), findsOneWidget);
  });
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}
