import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:farmos/data/local/cache_effects.dart';
import 'package:farmos/data/local/outbox_labels.dart';
import 'package:farmos/domain/entities/animal.dart';
import 'package:farmos/features/animals/animal_queue_screen.dart';
import 'package:farmos/features/animals/animal_quick_entry_screen.dart';
import 'package:farmos/features/animals/quick_round.dart';
import 'package:farmos/features/production/milk_production_screen.dart';
import 'package:farmos/features/record/record_sheet.dart' show recordMilkFlow;
import 'package:farmos/features/reports/report_docs.dart';
import 'package:farmos/features/reports/report_export.dart';
import 'package:farmos/features/reports/reports_screen.dart';

import '../support/snapshot_farm.dart';

/// Each cow's number in the milking queue (v0.8.2), the same on the tablet
/// and the web: the manager numbers the cows in the order they come in;
/// the queue and the manual milk entry follow it — after each save the
/// next number opens by herself — and a number typed in opens her cow.
/// And the milk report shows every cow's morning and afternoon.
void main() {
  const me = 'user-ali-demo';
  const workerAccess = {
    'user_id': me, 'role': 'worker', 'full_access': false,
    'modules': {'animals': {'view': true, 'create': true}, 'milk_production': {'view': true, 'create': true}, 'morning_operations': {'view': true}},
  };

  Future<SnapshotFarm> open(WidgetTester tester, Widget home,
      {Map<String, int> numbers = const {}, bool worker = false, Locale locale = const Locale('en'), Size size = const Size(1200, 2400)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final farm = await SnapshotFarm.open();
    if (worker) farm.api.snapshot['GET /me/access'] = workerAccess;
    for (final a in farm.api.snapshot['GET /animals?farm_id=farm-origami'] as List<dynamic>) {
      (a as Map)['milking_queue_number'] = numbers[a['id']];
    }
    await tester.pumpWidget(farm.app(Scaffold(body: home), locale: locale));
    await settle(tester);
    return farm;
  }

  Map body(SnapshotFarm farm, String method, String path) => farm.api.writes.lastWhere((w) => w.$1 == method && w.$2 == path).$3! as Map;

  group('the order', () {
    Animal cow(String id, String? tag, {int? n}) =>
        Animal.fromJson({'id': id, 'name': id, 'species': 'cow', 'tag': tag, 'status': 'healthy', 'milking_queue_number': n});

    test('numbered cows first, by number; the others after, by tag', () {
      final cows = [cow('a', '744'), cow('b', 'G-091', n: 2), cow('c', '214'), cow('d', '9', n: 10), cow('e', 'S-118', n: 1)]..sort(milkingQueueOrder);
      expect([for (final c in cows) c.id], ['e', 'b', 'd', 'c', 'a']);
    });

    test('a number typed in finds her cow — "4", "No. 4", "#4", in Arabic digits', () {
      final status = RoundStatus([RoundEntry(cow('a', '744', n: 4), done: false), RoundEntry(cow('b', '214', n: 12), done: false)]);
      for (final typed in ['4', ' 4 ', 'No. 4', 'no 4', '#4', '٤', 'رقم ٤']) {
        expect(byQueueNumber(status, typed)?.id, 'a', reason: typed);
      }
      expect(byQueueNumber(status, '12')?.id, 'b');
      expect(byQueueNumber(status, '5'), isNull);
      expect(byQueueNumber(status, 'G-4'), isNull, reason: 'a tag is not a number');
    });

    test('a run passes the cows already saved or skipped', () {
      final status = RoundStatus([for (final id in ['a', 'b', 'c']) RoundEntry(cow(id, null), done: false)]);
      expect(nextInQueue(status, after: 'a', passed: {'a', 'b'})?.id, 'c');
      expect(nextInQueue(status, after: 'c', passed: {'a', 'b', 'c'}), isNull);
    });

    test('offline: the numbers show on the herd at once; named in the waiting list', () {
      final fx = effectsFor('PUT', '/animals/milking-queue', {
        'numbers': [
          {'animal_id': 'cow-744', 'number': 1},
          {'animal_id': 'cow-214', 'number': null},
        ],
      }, localId: 'local-1');
      expect([for (final e in fx.whereType<MergeRecord>()) (e.collectionPath, e.id, e.patch['milking_queue_number'])],
          [('/animals', 'cow-744', 1), ('/animals', 'cow-214', null)]);
      expect(describeWrite('/animals/milking-queue').labelKey, 'outboxMilkingQueue');
    });
  });

  group('the milking queue', () {
    testWidgets('follows the numbers the manager gave', (tester) async {
      await open(tester, const AnimalQueueScreen(initial: QuickRound.milking('morning')), numbers: {'cow-744': 1, 'goat-gigi': 2, 'cow-214': 3});
      double y(String id) => tester.getTopLeft(find.byKey(ValueKey('queue-row-$id'))).dy;
      expect(y('cow-744'), lessThan(y('goat-gigi')));
      expect(y('goat-gigi'), lessThan(y('cow-214')));
      expect(y('cow-214'), lessThan(y('cow-clover')), reason: 'a cow with no number comes after the numbered ones');
      expect(find.text("By each cow's number in the milking queue"), findsOneWidget);
      expect(find.textContaining('Follow the queue · Bella'), findsOneWidget, reason: 'number 1 opens first');
    });

    testWidgets('the manager numbers the cows; a number given twice is refused', (tester) async {
      final farm = await open(tester, const AnimalQueueScreen(initial: QuickRound.milking('morning')));
      await tester.tap(find.byKey(const ValueKey('queue-set-numbers')));
      await settle(tester);
      expect(find.text("Each cow's number in the milking queue"), findsOneWidget);
      // Numbered in the order listed (by tag): Luna, Clover, Bella, Gigi, Willow.
      await tester.tap(find.byKey(const ValueKey('mq-number-in-order')));
      await settle(tester);
      String field(String id) => tester.widget<TextField>(find.byKey(ValueKey('mq-number-$id'))).controller!.text;
      expect([for (final id in ['cow-214', 'cow-clover', 'cow-744', 'goat-gigi', 'goat-willow']) field(id)], ['1', '2', '3', '4', '5']);
      // Bella comes in first.
      await tester.enterText(find.byKey(const ValueKey('mq-number-cow-744')), '1');
      await settle(tester);
      expect(find.text('Number 1 is given to more than one cow.'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('mq-save')));
      await settle(tester);
      expect(farm.api.writes.where((w) => w.$2 == '/animals/milking-queue'), isEmpty, reason: 'nothing is sent while a number is twice');
      await tester.enterText(find.byKey(const ValueKey('mq-number-cow-214')), '3');
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('mq-save')));
      await settle(tester);
      final sent = {for (final e in body(farm, 'PUT', '/animals/milking-queue')['numbers'] as List) (e as Map)['animal_id']: e['number']};
      expect(sent, {'cow-744': 1, 'cow-clover': 2, 'cow-214': 3, 'goat-gigi': 4, 'goat-willow': 5});
    });

    testWidgets('only the changed numbers are sent; a number can be taken away', (tester) async {
      final farm = await open(tester, const AnimalQueueScreen(initial: QuickRound.milking('morning')), numbers: {'cow-744': 1, 'cow-214': 2});
      await tester.tap(find.byKey(const ValueKey('queue-set-numbers')));
      await settle(tester);
      await tester.enterText(find.byKey(const ValueKey('mq-number-cow-214')), '');
      await tester.enterText(find.byKey(const ValueKey('mq-number-cow-clover')), '2');
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('mq-save')));
      await settle(tester);
      final sent = {for (final e in body(farm, 'PUT', '/animals/milking-queue')['numbers'] as List) (e as Map)['animal_id']: e['number']};
      expect(sent, {'cow-214': null, 'cow-clover': 2});
    });

    testWidgets('an employee follows the numbers but does not set them', (tester) async {
      await open(tester, const AnimalQueueScreen(initial: QuickRound.milking('morning')), worker: true, numbers: {'cow-744': 1});
      expect(find.byKey(const ValueKey('queue-set-numbers')), findsNothing);
      expect(find.byKey(const ValueKey('queue-row-cow-744')), findsOneWidget);
    });

    testWidgets('in the quick entry, a queue number typed in opens her cow; a tag still opens its own', (tester) async {
      await open(tester, const AnimalQuickEntryScreen(round: QuickRound.milking('morning')), numbers: {'cow-744': 1, 'cow-214': 2});
      expect(find.text('Scan code, enter tag or queue number'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('qr-code-field')), 'No. 2');
      await tester.testTextInput.receiveAction(TextInputAction.go);
      await settle(tester);
      expect(find.text('Luna'), findsWidgets);
      expect(find.textContaining('NO. 2'), findsWidgets, reason: 'her number is on her card');
      await tester.enterText(find.byKey(const ValueKey('qr-code-field')), '744');
      await tester.testTextInput.receiveAction(TextInputAction.go);
      await settle(tester);
      expect(find.textContaining('NO. 1'), findsWidgets, reason: 'tag 744 is Bella, number 1');
    });
  });

  group('Record milk by hand', () {
    Widget starter() => Builder(builder: (c) => Center(child: TextButton(onPressed: () => recordMilkFlow(c), child: const Text('record'))));

    testWidgets('the next cow in the queue opens by herself after each save', (tester) async {
      final farm = await open(tester, starter(), numbers: {'cow-744': 1, 'cow-214': 2, 'cow-clover': 3});
      await tester.tap(find.text('record'));
      await settle(tester);
      // The picker offers number 1 on top, and shows each cow's number.
      expect(find.byKey(const ValueKey('pick-next-in-queue')), findsOneWidget);
      expect(find.textContaining('Next: No. 1 · Bella'), findsOneWidget);
      expect(find.textContaining('No. 2 · Luna'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('pick-next-in-queue')));
      await settle(tester);
      expect(find.text('No. 1 · Cow 1 of 5 in the queue'), findsOneWidget);
      expect(find.text('Next: Luna'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('milk-dialog-liters')), '12.5');
      await tester.tap(find.byKey(const ValueKey('milk-dialog-save')));
      await settle(tester);
      final first = body(farm, 'POST', '/production/milk');
      expect((first['animal_id'], first['liters']), ('cow-744', 12.5));
      // Luna, number 2, is open: no picking.
      expect(find.text('No. 2 · Cow 2 of 5 in the queue'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('milk-dialog-liters')), '10');
      await tester.tap(find.byKey(const ValueKey('milk-dialog-save')));
      await settle(tester);
      expect(body(farm, 'POST', '/production/milk')['animal_id'], 'cow-214');
      expect(body(farm, 'POST', '/production/milk')['session'], first['session'], reason: 'the same milking');
      // Clover, number 3: skipped; then the unnumbered cows by tag.
      expect(find.text('No. 3 · Cow 3 of 5 in the queue'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('milk-dialog-skip')));
      await settle(tester);
      expect(find.text('Cow 4 of 5 in the queue'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('milk-dialog-close')));
      await settle(tester);
      expect(find.byKey(const ValueKey('milk-queue-info')), findsNothing, reason: 'Stop ends the run');
      expect(farm.api.writes.where((w) => w.$2 == '/production/milk'), hasLength(2));
    });

    testWidgets('typing her number in the picker finds her first', (tester) async {
      await open(tester, starter(), numbers: {'cow-744': 1, 'cow-214': 2, 'cow-clover': 3});
      await tester.tap(find.text('record'));
      await settle(tester);
      await tester.enterText(find.byType(TextField).first, '3');
      await settle(tester);
      expect(find.byKey(const ValueKey('pick-next-in-queue')), findsNothing);
      final tiles = find.byType(ListTile);
      expect(find.descendant(of: tiles.first, matching: find.textContaining('Clover')), findsOneWidget);
    });
  });

  group('the milk report, each cow', () {
    Map<String, Object?> report({int sheetDays = 2}) => {
          'kind': 'milk', 'start': '2026-11-23', 'end': '2026-11-24', 'days': 2, 'farm_name': 'Origami', 'currency': 'USD', 'second_milking': 'afternoon',
          'kpis': {'total_l': 45.5}, 'destinations': [], 'by_day': [],
          'by_animal': [
            {'animal_id': 'cow-744', 'tag': '744', 'name': 'Bella', 'queue_number': 1, 'morning_l': 25.5, 'midday_l': 0, 'evening_l': 20, 'total_l': 45.5,
             'days_milked': 2, 'avg_per_day_l': 22.8, 'best_day_l': 23, 'milkings': 4},
          ],
          'by_animal_day': [
            for (var i = 0; i < sheetDays; i++)
              {'date': '2026-11-${24 - i}', 'animal_id': 'cow-744', 'tag': '744', 'name': 'Bella', 'queue_number': 1, 'morning_l': 12.5, 'midday_l': 0, 'evening_l': 10, 'total_l': 22.5},
          ],
        };

    testWidgets('morning and afternoon for every cow, then day by day', (tester) async {
      late ReportDoc doc;
      await open(tester, Builder(builder: (c) {
        doc = buildReportDoc(c, 'milk', report(), speciesName: (s) => s);
        return const SizedBox();
      }));
      final perCow = doc.tables.firstWhere((t) => t.title == 'Per animal');
      expect(perCow.columns.take(4), ['Animal', 'Morning', 'Afternoon', 'Total (L)']);
      expect(perCow.rows.single.take(4), ['No. 1 · 744 · Bella', '25.5', '20', '45.5']);
      final sheet = doc.tables.firstWhere((t) => t.title == 'Each cow, day by day');
      expect(sheet.columns, ['Date', 'Animal', 'Morning', 'Afternoon', 'Total (L)']);
      expect(sheet.rows.first, ['24/11/2026', 'No. 1 · 744 · Bella', '12.5', '10', '22.5']);
      expect(doc.toCsv(), contains('Each cow, day by day'));
    });

    testWidgets('a long period has no day-by-day sheet; a long table is cut into parts', (tester) async {
      late ReportDoc doc;
      await open(tester, Builder(builder: (c) {
        doc = buildReportDoc(c, 'milk', {...report(), 'by_animal_day': null}, speciesName: (s) => s);
        return const SizedBox();
      }));
      expect(doc.tables.where((t) => t.title == 'Each cow, day by day'), isEmpty);
      final long = ReportTable(title: 'Each cow, day by day', columns: const ['a'], rows: [for (var i = 0; i < 95; i++) ['$i']]);
      final parts = tableParts([long], continued: 'continued');
      expect([for (final p in parts) p.rows.length], [40, 40, 15]);
      expect([for (final p in parts) p.title], ['Each cow, day by day', 'Each cow, day by day (continued)', 'Each cow, day by day (continued)']);
    });

    testWidgets('the Milk page opens every cow\'s milk on today', (tester) async {
      await open(tester, const MilkProductionScreen(), size: const Size(1280, 2400));
      await tester.ensureVisible(find.byKey(const ValueKey('milk-each-cow')));
      await tester.tap(find.byKey(const ValueKey('milk-each-cow')));
      await settle(tester);
      expect(find.text('Milk report'), findsOneWidget);
      final today = tester.widget<ChoiceChip>(find.byKey(const ValueKey('report-period-today')));
      expect(today.selected, isTrue);
    });

    testWidgets('in Arabic', (tester) async {
      await open(tester, const AnimalQueueScreen(initial: QuickRound.milking('morning')), locale: const Locale('ar'));
      expect(find.text('أرقام الدور'), findsOneWidget);
    });
  });
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}
