import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:farmos/domain/entities/animal.dart';
import 'package:farmos/domain/entities/feeding.dart';
import 'package:farmos/domain/entities/livestock.dart';
import 'package:farmos/domain/entities/production_records.dart';
import 'package:farmos/features/animals/animal_quick_entry_screen.dart';
import 'package:farmos/features/animals/animal_scan.dart';
import 'package:farmos/features/animals/quick_round.dart';
import 'package:farmos/features/scan/qr_labels.dart';
import 'package:farmos/features/scan/qr_scanner_page.dart';

import '../support/snapshot_farm.dart';

/// The scan-first worker workflow (docs/QR-ANIMAL-QUICK-ENTRY.md,
/// architecture/ADR-003): the QR grammar, rounds, the duplicate check,
/// feed rows from the program, labels — and the screen itself over the
/// bundled farm, with the camera replaced by a fake that "reads" a code.
class _FakeScanner extends QrScanSource {
  _FakeScanner(this.codes);
  final List<String?> codes;
  int calls = 0;

  @override
  Future<String?> scan(BuildContext context) async {
    // A person takes a moment to aim; the farm has loaded by then.
    await Future<void>.delayed(const Duration(milliseconds: 400));
    return calls < codes.length ? codes[calls++] : null;
  }
}

Animal _animal(String id, {String tag = '', bool lactating = false, String lifecycle = 'active'}) => Animal(
      id: id,
      name: 'Animal $id',
      species: 'cow',
      breed: '',
      sex: 'F',
      birthDate: DateTime(2022),
      status: AnimalHealthStatus.healthy,
      location: 'Barn',
      healthScore: 90,
      lactating: lactating,
      lifecycleStatus: lifecycle,
      identifiers: [if (tag.isNotEmpty) AnimalIdentifier(id: 'i-$id', type: 'EAR_TAG', value: tag, isPrimary: true, status: 'active')],
    );

MilkRecord _milk(String animal, String session, DateTime at) =>
    MilkRecord(id: '$animal-$session-$at', animalId: animal, session: session, liters: 12, destination: 'stored', recordedAt: at);

void main() {
  final now = DateTime(2026, 11, 13, 9);

  group('the QR grammar', () {
    test('animal and group labels, typed tags, and nothing else', () {
      expect(parseScan('origami://animal/cow-1')?.kind, ScanKind.animal);
      expect(parseScan('origami://group/pen-3')?.kind, ScanKind.group);
      expect(parseScan(' 744 ')?.value, '744');
      for (final bad in ['https://evil.example/animal/1', 'origami://pen/3', 'origami://animal/1?x=1', 'origami://animal/1#f', 'origami://u@animal/1', 'origami://animal:80/1', 'origami://animal/a/b', '']) {
        expect(parseScan(bad), isNull, reason: bad);
      }
      expect(animalQrPayload('cow-1'), 'origami://animal/cow-1');
      expect(groupQrPayload('pen-3'), 'origami://group/pen-3');
    });

    test('a scan opens one current animal or group on this farm, or nothing', () {
      final bella = _animal('cow-744', tag: '744');
      final twinA = _animal('a', tag: 'X1');
      final twinB = _animal('b', tag: 'X1');
      final sold = _animal('sold-1', tag: 'S9', lifecycle: 'sold');
      final pen = AnimalGroup.fromJson({'id': 'pen-3', 'name': 'Pen 3', 'species': 'cow'});
      ScanTarget scan(String raw) => resolveScan(raw, animals: [bella, twinA, twinB, sold], groups: [pen]);
      expect((scan('origami://animal/cow-744') as AnimalScanTarget).animal.id, 'cow-744');
      expect((scan('744') as AnimalScanTarget).animal.id, 'cow-744');
      expect((scan('origami://group/pen-3') as GroupScanTarget).group.name, 'Pen 3');
      expect((scan('X1') as NoScanTarget).reason, ScanMiss.ambiguous);
      expect((scan('origami://animal/sold-1') as NoScanTarget).reason, ScanMiss.unknown, reason: 'an animal that left opens nothing');
      expect((scan('origami://group/other-farm') as NoScanTarget).reason, ScanMiss.unknown);
      expect((scan('https://evil.example/x') as NoScanTarget).reason, ScanMiss.notOurs);
    });
  });

  group('rounds and the duplicate check', () {
    final a = _animal('a', lactating: true);
    final b = _animal('b', lactating: true);
    final dry = _animal('dry');
    test('a milking round is the animals in milk; done means recorded in that session today', () {
      final status = roundStatus(
        const QuickRound.milking('morning'),
        animals: [a, b, dry],
        milked: (_) => true,
        milk: [_milk('a', 'morning', DateTime(2026, 11, 13, 6)), _milk('b', 'morning', DateTime(2026, 11, 12, 6)), _milk('b', 'evening', DateTime(2026, 11, 13, 7))],
        plan: DailyPlan.empty,
        fedToday: (_) => const [],
        now: now,
      );
      expect((status.done, status.total), (1, 2));
      expect(status.pending.single.id, 'b', reason: "yesterday's morning and today's evening do not count");
      expect(status.contains('dry'), isFalse);
    });

    test('a feeding round is the animals on a program of their own', () {
      DailyPlanLine line(String type, String id, int perDay) => DailyPlanLine.fromJson({
            'subject_type': type, 'subject_id': id, 'name': id, 'species': 'cow', 'head_count': 1,
            'program': {'program_id': 'p', 'feedings_per_day': perDay}, 'daily_targets': <dynamic>[], 'warnings': <dynamic>[],
          });
      FeedingEvent fed(String id) => FeedingEvent.fromJson({'id': 'e-$id', 'subject_type': 'animal', 'subject_id': id, 'occurred_at': now.toIso8601String(), 'event_type': 'offered', 'status': 'recorded', 'components': <dynamic>[]});
      final status = roundStatus(
        const QuickRound.feeding(),
        animals: [a, b],
        milked: (_) => true,
        milk: const [],
        plan: DailyPlan(date: '', lines: [line('animal', 'a', 1), line('animal', 'b', 2), line('group', 'herd', 2)], totals: const []),
        fedToday: (id) => [if (id == 'a' || id == 'b') fed(id)],
        now: now,
      );
      expect([for (final e in status.entries) (e.animal.id, e.done)], [('a', true), ('b', false)]);
    });

    test('a second milking in the same session is found; another session is not', () {
      final milk = [_milk('a', 'morning', DateTime(2026, 11, 13, 6, 10))];
      expect(sameSessionToday('a', 'morning', milk, now: now), isNotNull);
      expect(sameSessionToday('a', 'evening', milk, now: now), isNull);
      expect(sameSessionToday('a', 'morning', milk, now: DateTime(2026, 11, 14, 6)), isNull);
      expect(milkToday('a', milk, now: now).single.liters, 12);
    });

    test('feed rows come from the program, with the amount per feeding as a hint', () {
      final plan = FeedingPlan.fromJson({
        'subject': {'subject_type': 'animal', 'subject_id': 'a'},
        'program': {'program_id': 'p', 'feedings_per_day': 2},
        'daily_targets': [
          {'feed_product_id': 'mix', 'product_name': 'Dairy Mix', 'unit': 'kg', 'daily_total': 20},
          {'feed_product_id': 'hay', 'product_name': 'Hay', 'unit': 'kg', 'daily_total': 0},
        ],
      });
      final rows = feedRowsFromPlan(plan);
      expect([for (final r in rows) (r.productName, r.plannedPerFeeding)], [('Dairy Mix', 10.0), ('Hay', null)]);
      expect(feedRowsFromPlan(null), isEmpty);
    });

    test('reversed feedings are not counted', () {
      FeedingEvent e(String status) => FeedingEvent.fromJson({'id': status, 'subject_type': 'animal', 'subject_id': 'a', 'occurred_at': now.toIso8601String(), 'event_type': 'offered', 'status': status, 'components': <dynamic>[]});
      expect(feedingsToday('a', [e('recorded'), e('reversed'), e('reversal')], now: now), 1);
    });
  });

  test('a label sheet is a PDF', () async {
    final pdf = await buildQrLabelPdf(const []);
    expect(String.fromCharCodes(pdf.take(4)), '%PDF');
  });

  testWidgets('a label shows the code, the name and the tag to type', (tester) async {
    final label = QrLabel.forAnimal(_animal('cow-744', tag: '744'), speciesName: 'Cattle');
    expect(label.payload, 'origami://animal/cow-744');
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Center(child: QrLabelCard(label: label)))));
    expect(find.text('Animal cow-744'), findsOneWidget);
    expect(find.text('744'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  group('the worker screen over the bundled farm', () {
    late QrScanSource previous;
    setUp(() => previous = QrScan.source);
    tearDown(() => QrScan.source = previous);

    Future<SnapshotFarm> open(WidgetTester tester, Widget home) async {
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final farm = await SnapshotFarm.open();
      await tester.pumpWidget(farm.app(home));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      return farm;
    }

    testWidgets("scan Bella, fill her program's amounts, save milk and feed", (tester) async {
      QrScan.source = _FakeScanner(['origami://animal/cow-744']);
      final farm = await open(tester, const AnimalQuickEntryScreen(startWithCamera: true));
      expect(find.text('Bella'), findsOneWidget);
      expect(find.text('Already recorded today'), findsOneWidget);
      expect(find.text('Dairy Mix 24L'), findsOneWidget, reason: 'the feed rows are her program, not empty slots');
      await tester.tap(find.text('Fill planned amounts'));
      await tester.pump();
      // The demo farm's milkings are all in the morning; the evening
      // session keeps this test free of the duplicate check's date.
      await tester.tap(find.text('Evening').first);
      await tester.pump();
      await tester.enterText(find.byKey(const ValueKey('qr-milk-field')), '١٢٫٥');
      await tester.ensureVisible(find.byKey(const ValueKey('qr-save')));
      await tester.tap(find.byKey(const ValueKey('qr-save')));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      final milk = farm.api.writes.firstWhere((w) => w.$2 == '/production/milk');
      expect((milk.$3 as Map)['liters'], 12.5, reason: 'Arabic digits and decimal separator');
      expect((milk.$3 as Map)['destination'], 'stored');
      final feed = farm.api.writes.firstWhere((w) => w.$2 == '/feeding-events');
      final components = ((feed.$3 as Map)['components'] as List).cast<Map>();
      expect(components.map((c) => c['feed_product_id']), containsAll(['fp-dairy-mix']));
      expect(components.every((c) => !c.containsKey('quantity_consumed')), isTrue, reason: 'nothing consumed unless a refusal was weighed');
      expect(find.text('Scan the animal’s label to start.'), findsOneWidget, reason: 'ready for the next animal');
    });

    testWidgets("Willow's milk is withheld during her withdrawal", (tester) async {
      QrScan.source = _FakeScanner(const []);
      final farm = await open(tester, const AnimalQuickEntryScreen());
      await tester.enterText(find.byKey(const ValueKey('qr-code-field')), 'S-118');
      await tester.testTextInput.receiveAction(TextInputAction.go);
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(find.text('Willow'), findsOneWidget);
      expect(find.textContaining('WITHHELD'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('qr-milk-field')), '3');
      await tester.ensureVisible(find.byKey(const ValueKey('qr-save')));
      await tester.tap(find.byKey(const ValueKey('qr-save')));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect((farm.api.writes.firstWhere((w) => w.$2 == '/production/milk').$3 as Map)['destination'], 'withheld');
    });

    testWidgets('a pen label opens the pen and lets the worker choose the animal', (tester) async {
      QrScan.source = _FakeScanner(['origami://group/grp-dairy-herd']);
      await open(tester, const AnimalQuickEntryScreen(startWithCamera: true));
      expect(find.text('Dairy Herd'), findsWidgets);
      expect(find.text('Feeding round'), findsOneWidget);
      expect(find.textContaining('Bella'), findsWidgets);
      expect(find.text('Milk'), findsNothing, reason: 'a pen label never picks an animal by itself');
    });

    testWidgets('a foreign code opens nothing and says why', (tester) async {
      QrScan.source = _FakeScanner(['https://evil.example/animal/cow-744']);
      final farm = await open(tester, const AnimalQuickEntryScreen(startWithCamera: true));
      expect(find.textContaining('not an Origami label'), findsOneWidget);
      expect(find.text('Bella'), findsNothing);
      expect(farm.api.writes, isEmpty);
    });

    testWidgets('a milking round lists who is left', (tester) async {
      QrScan.source = _FakeScanner(const []);
      await open(tester, const AnimalQuickEntryScreen(round: QuickRound.milking('evening')));
      expect(find.text('Evening milking'), findsOneWidget);
      expect(find.textContaining('Bella'), findsWidgets);
      expect(find.textContaining('Luna'), findsWidgets);
    });
  });
}
