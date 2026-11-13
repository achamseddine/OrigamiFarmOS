import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:farmos/data/local/cache_effects.dart';
import 'package:farmos/domain/entities/animal.dart';
import 'package:farmos/domain/entities/feeding.dart';
import 'package:farmos/domain/entities/production_records.dart';
import 'package:farmos/features/animals/animal_status_screen.dart';
import 'package:farmos/features/feed/feed_workspace_screen.dart';
import 'package:farmos/features/morning/today_routine_card.dart';

import '../support/snapshot_farm.dart';

/// The rules behind the screens taken from the V3 prototype: the day's
/// routine, the registry's filters, finished mix on hand, and what an
/// offline weighing does before the server answers.
void main() {
  final now = DateTime(2026, 11, 13, 14);
  final snapshot = loadSnapshot();
  final animalRows = snapshot.entries.firstWhere((e) => e.key == 'GET /animals' || e.key.startsWith('GET /animals?')).value as List<dynamic>;
  final animals = [for (final a in animalRows) Animal.fromJson(a as Map<String, dynamic>)];

  Animal byId(String id) => animals.firstWhere((a) => a.id == id);

  MilkRecord milk(String animal, String session, DateTime at) =>
      MilkRecord(id: '$animal-$session-$at', animalId: animal, session: session, liters: 10, destination: 'stored', recordedAt: at);

  DailyPlanLine line(String subjectType, String id, String name, int perDay) => DailyPlanLine.fromJson({
        'subject_type': subjectType,
        'subject_id': id,
        'name': name,
        'species': 'cow',
        'head_count': 1,
        'program': {'program_id': 'p', 'feedings_per_day': perDay},
        'daily_targets': <dynamic>[],
        'warnings': <dynamic>[],
      });

  FeedingEvent fed(String subject, DateTime at, {String status = 'recorded'}) => FeedingEvent.fromJson({
        'id': '$subject-$at-$status',
        'subject_type': 'group',
        'subject_id': subject,
        'occurred_at': at.toIso8601String(),
        'event_type': 'delivered',
        'status': status,
        'components': <dynamic>[],
      });

  group("today's routine is ticked off from today's records only", () {
    final inMilk = [for (final a in animals) if (a.lactating) a];

    List<RoutineCheck> routine({List<MilkRecord> milk = const [], List<DailyPlanLine> lines = const [], List<FeedingEvent> events = const [], List<EggRecord> eggs = const []}) =>
        computeRoutine(
          animals: animals,
          milked: (a) => a.species != 'chicken',
          milk: milk,
          plan: DailyPlan(date: '2026-11-13', lines: lines, totals: const []),
          fedToday: (id) => [
            for (final e in events)
              if (e.subjectId == id && e.status == 'recorded' && e.occurredAt.day == now.day) e,
          ],
          eggs: eggs,
          flockName: (id) => 'Flock $id',
          now: now,
        );

    test('a milking session counts the animals in milk recorded in it today', () {
      final checks = routine(milk: [
        milk(inMilk[0].id, 'morning', DateTime(2026, 11, 13, 6)),
        milk(inMilk[1].id, 'morning', DateTime(2026, 11, 13, 6, 30)),
        milk(inMilk[1].id, 'morning', DateTime(2026, 11, 13, 7)), // twice is still one animal
        milk(inMilk[2].id, 'morning', DateTime(2026, 11, 12, 6)), // yesterday does not count
      ]);
      final morning = checks.firstWhere((c) => c.kind == RoutineKind.milking && c.key == 'morning');
      expect((morning.done, morning.total), (2, inMilk.length));
      expect(morning.complete, isFalse);
      final evening = checks.firstWhere((c) => c.key == 'evening');
      expect(evening.started, isFalse);
    });

    test("a group's feeding rounds come from its program; reversed feedings do not count", () {
      final checks = routine(lines: [line('group', 'herd', 'Dairy Herd', 2)], events: [
        fed('herd', DateTime(2026, 11, 13, 6)),
        fed('herd', DateTime(2026, 11, 13, 7), status: 'reversed'),
        fed('herd', DateTime(2026, 11, 12, 17)),
      ]);
      final herd = checks.singleWhere((c) => c.kind == RoutineKind.feeding);
      expect((herd.name, herd.done, herd.total), ('Dairy Herd', 1, 2));
    });

    test('animals on their own program share one line', () {
      final checks = routine(
        lines: [line('animal', 'a', 'A', 2), line('animal', 'b', 'B', 1), line('group', 'g', 'G', 1)],
        events: [fed('a', DateTime(2026, 11, 13, 6)), fed('a', DateTime(2026, 11, 13, 9)), fed('a', DateTime(2026, 11, 13, 12))],
      );
      final feeding = checks.where((c) => c.kind == RoutineKind.feeding).toList();
      expect(feeding.length, 2);
      final solo = feeding.singleWhere((c) => c.key == kIndividualFeeding);
      expect((solo.name, solo.done, solo.total), ('2', 2, 3), reason: 'a third feeding of A does not cover B');
    });

    test("a flock collected this week is expected today", () {
      final checks = routine(eggs: [
        EggRecord(id: '1', flockId: 'layers', totalEggs: 10, sellableEggs: 10, brokenEggs: 0, recordedAt: DateTime(2026, 11, 12, 9)),
        EggRecord(id: '2', flockId: 'ducks', totalEggs: 4, sellableEggs: 4, brokenEggs: 0, recordedAt: DateTime(2026, 11, 13, 9)),
        EggRecord(id: '3', flockId: 'old', totalEggs: 4, sellableEggs: 4, brokenEggs: 0, recordedAt: DateTime(2026, 10, 1, 9)),
      ]);
      final eggs = {for (final c in checks) if (c.kind == RoutineKind.eggs) c.key: c.complete};
      expect(eggs, {'layers': false, 'ducks': true});
    });

    test('a farm with nothing to track has an empty routine', () {
      expect(computeRoutine(animals: const [], milked: (_) => true, milk: const [], plan: DailyPlan.empty, fedToday: (_) => const [], eggs: const [], flockName: (id) => id), isEmpty);
    });
  });

  group('registry filters', () {
    test('status filters read the animal, not its species', () {
      final bella = byId('cow-744');
      expect(registryFilterMatches(RegistryFilter.pregnant, bella), isTrue);
      expect(registryFilterMatches(RegistryFilter.attention, bella), isTrue);
      expect(registryFilterMatches(RegistryFilter.exited, bella), isFalse);
      expect(registryFilterMatches(RegistryFilter.inMilk, byId('cow-214')), isTrue);
      expect(registryFilterMatches(RegistryFilter.healthy, bella), isFalse);
    });

    test('search finds name, tag, any identifier, breed and group', () {
      final bella = byId('cow-744');
      expect(registrySearchMatches(bella, 'bel'), isTrue);
      expect(registrySearchMatches(bella, '744'), isTrue);
      expect(registrySearchMatches(bella, 'holstein'), isTrue);
      expect(registrySearchMatches(bella, 'dairy herd'), isTrue);
      expect(registrySearchMatches(bella, 'thunder'), isFalse);
      expect(registrySearchMatches(bella, '   '), isTrue);
    });
  });

  test('finished mix on hand adds output lots per unit and nothing else', () {
    FeedLot lot(String id, {String? batch, double qty = 10, String unit = 'kg', String status = 'active'}) => FeedLot.fromJson({
          'id': id, 'feed_product_id': 'p', 'lot_code': id, 'feed_batch_id': batch, 'quantity_on_hand': qty, 'unit': unit, 'status': status,
        });
    final onHand = finishedMixOnHand([
      lot('m1', batch: 'b1', qty: 40),
      lot('m2', batch: 'b2', qty: 12.5),
      lot('m3', batch: 'b3', qty: 3, unit: 'bag'),
      lot('m4', batch: 'b4', qty: 9, status: 'quarantined'),
      lot('m5', batch: 'b5', qty: 0),
      lot('bought', qty: 500),
    ]);
    expect(onHand, {'kg': 52.5, 'bag': 3});
  });

  test('an offline weighing heads the weight list and becomes the figure on the herd row', () {
    final effects = effectsFor('POST', '/animals/cow-9/weights', {'weight_kg': 512.5, 'method': 'tape'}, localId: 'local-w');
    final appended = effects.whereType<AppendRecord>().single;
    expect(appended.collectionPath, '/animals/cow-9/weights');
    expect(appended.record['method'], 'tape');
    expect(effects.whereType<MergeRecord>().single.patch, {'weight_kg': 512.5});
    expect(effects.whereType<PatchDocument>().single.patch['weight_kg'], 512.5);
    final weight = WeightRecord.fromJson(appended.record);
    expect((weight.weightKg, weight.pending), (512.5, true));
  });

  testWidgets('the feed page opens on mix production with ledger-derived figures', (tester) async {
    tester.view.physicalSize = const Size(1280, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final farm = await SnapshotFarm.open();
    await tester.pumpWidget(farm.app(const Scaffold(body: FeedWorkspaceScreen())));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(find.text('Numbered mixes'), findsOneWidget);
    expect(find.text('Finished mix on hand'), findsOneWidget);
    expect(find.text('Make feed mix'), findsOneWidget);
    expect(find.textContaining('it is never typed in'), findsOneWidget, reason: 'the mix tab is the first tab');
    await tester.tap(find.text('Feed intake'));
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(find.textContaining('today', findRichText: true), findsWidgets, reason: 'each plan line counts its rounds today');
  });
}
