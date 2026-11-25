import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:farmos/domain/entities/feeding.dart';
import 'package:farmos/features/animals/animal_feeding_section.dart';
import 'package:farmos/features/animals/quick_round.dart';
import 'package:farmos/features/feed/tabs/daily_feeding_tab.dart';
import 'package:farmos/providers/animals_provider.dart';
import 'package:farmos/providers/feeding_provider.dart';

import '../support/snapshot_farm.dart';

/// One feeding policy (v0.8.6, audit I-4 / I-5 / I-6), the same on the
/// tablet and the web:
///   - each head is planned once: a group's line counts the heads its
///     ration feeds, and names the members fed on a line of their own;
///   - only feed that left the store is fed — a refusal or an intake
///     estimate is shown apart and is not a feeding round;
///   - "today" is the farm's day from the server's plan (Asia/Beirut), not
///     the device's or the browser's clock zone.
void main() {
  // The farm day 2026-11-25 in Beirut (UTC+2): 22:00 UTC the evening before
  // to 22:00 UTC that evening.
  final plan = DailyPlan.fromJson({
    'date': '2026-11-25', 'timezone': 'Asia/Beirut',
    'from': '2026-11-24T22:00:00+00:00', 'to': '2026-11-25T22:00:00+00:00',
    'lines': <dynamic>[], 'totals': <dynamic>[],
  });

  FeedingEvent event(String id, String at, {String type = 'offered', String status = 'recorded', String subject = 'cow-744'}) => FeedingEvent.fromJson({
        'id': id, 'subject_type': 'animal', 'subject_id': subject, 'occurred_at': at, 'event_type': type, 'status': status, 'components': <dynamic>[],
      });

  group("the farm's day", () {
    test('NEW-6: 00:30 in Beirut is that Beirut day, whatever the device zone', () {
      final now = DateTime.utc(2026, 11, 25, 18);
      expect(plan.timezone, 'Asia/Beirut');
      expect(onFarmToday(DateTime.utc(2026, 11, 24, 22, 30), plan, now: now), isTrue, reason: '00:30 Beirut = 22:30 UTC the evening before');
      expect(onFarmToday(DateTime.utc(2026, 11, 24, 21, 30), plan, now: now), isFalse, reason: '23:30 Beirut yesterday');
      expect(onFarmToday(DateTime.utc(2026, 11, 25, 21, 59), plan, now: now), isTrue);
      expect(onFarmToday(DateTime.utc(2026, 11, 25, 22), plan, now: now), isFalse, reason: 'midnight in Beirut starts the next day');
    });

    test('a tablet left on past midnight moves to the next farm day until the plan reloads', () {
      final after = DateTime.utc(2026, 11, 26, 3);
      expect(onFarmToday(DateTime.utc(2026, 11, 25, 23), plan, now: after), isTrue);
      expect(onFarmToday(DateTime.utc(2026, 11, 25, 12), plan, now: after), isFalse);
    });

    test('with no plan loaded it is the device day, as before', () {
      final now = DateTime(2026, 11, 25, 9);
      expect(onFarmToday(DateTime(2026, 11, 25, 7), DailyPlan.empty, now: now), isTrue);
      expect(onFarmToday(DateTime(2026, 11, 24, 23), DailyPlan.empty, now: now), isFalse);
    });
  });

  group('fed means it left the store', () {
    test('AF-05: a refusal or an intake estimate is not a feeding', () {
      final now = DateTime.utc(2026, 11, 25, 10);
      final events = [
        event('fed', '2026-11-25T06:00:00Z'),
        event('refused', '2026-11-25T08:00:00Z', type: 'refusal'),
        event('estimate', '2026-11-25T09:00:00Z', type: 'consumed_estimate'),
        event('reversed', '2026-11-25T07:00:00Z', status: 'reversed'),
        event('delivered', '2026-11-24T22:30:00Z', type: 'delivered'),
      ];
      expect([for (final e in events) e.countsAsFed], [true, false, false, false, true]);
      expect(feedingsToday('cow-744', events, now: now, plan: plan), 2, reason: 'the 06:00 feeding and the 00:30 delivery');
    });

    test('the subject plan keeps refused feed apart from fed', () {
      final p = FeedingPlan.fromJson({
        'subject': {'subject_type': 'group', 'subject_id': 'grp-dairy-herd'},
        'fed_7d': [{'feed_product_id': 'fp-dairy-mix', 'quantity': 33, 'unit': 'kg'}],
        'refused_7d': [{'feed_product_id': 'fp-dairy-mix', 'quantity': 2, 'unit': 'kg'}],
      });
      expect(p.fed7d.single.dailyTotal, 33);
      expect(p.refused7d.single.dailyTotal, 2);
      expect(FeedingPlan.fromJson({'subject': <String, dynamic>{}}).refused7d, isEmpty, reason: 'an older server sends none');
    });
  });

  group('one base ration per head', () {
    final line = DailyPlanLine.fromJson({
      'subject_type': 'group', 'subject_id': 'grp-dairy-herd', 'name': 'Dairy Herd', 'species': 'cow', 'head_count': 2, 'member_count': 3,
      'excluded_heads': [{'animal_id': 'cow-clover', 'name': 'Clover', 'reason': 'own_program'}],
      'daily_targets': [{'feed_product_id': 'fp-dairy-mix', 'product_name': 'Dairy Mix 24L', 'unit': 'kg', 'daily_total': 40}],
      'fed': [{'feed_product_id': 'fp-dairy-mix', 'quantity': 20}], 'warnings': <dynamic>[],
    });

    test('a group line says how many of its members its ration feeds', () {
      expect((line.headCount, line.memberCount), (2, 3));
      expect(line.excludedHeads.single.name, 'Clover');
      expect(line.excludedHeads.single.reason, 'own_program');
      expect(line.fed.single.dailyTotal, 20);
    });

    testWidgets('AF-01: the daily feeding list shows 2 of 3 head and names the cow fed on her own', (tester) async {
      tester.view.physicalSize = const Size(1200, 2600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final farm = await SnapshotFarm.open();
      final today = farm.api.snapshot['GET /feeding-plan/today'] as Map<String, dynamic>;
      final lines = [for (final l in today['lines'] as List<dynamic>) (l as Map).cast<String, dynamic>()];
      for (final l in lines) {
        if (l['subject_id'] == 'grp-dairy-herd') {
          l
            ..['head_count'] = 2
            ..['member_count'] = 3
            ..['excluded_heads'] = [{'animal_id': 'cow-clover', 'name': 'Clover', 'reason': 'own_program'}];
        }
        if (l['subject_type'] == 'animal' && l['subject_id'] == 'cow-744') l['basis'] = 'supplement_only';
      }
      lines.add({
        'subject_type': 'animal', 'subject_id': 'cow-clover', 'name': 'Clover', 'species': 'cow', 'head_count': 1, 'basis': 'own_program',
        'daily_targets': [{'feed_product_id': 'fp-dairy-mix', 'product_name': 'Dairy Mix 24L', 'unit': 'kg', 'daily_total': 16}], 'warnings': <dynamic>[],
      });
      today['lines'] = lines;
      await tester.pumpWidget(farm.app(const Scaffold(body: DailyFeedingTab())));
      await settle(tester);
      expect(find.textContaining('2 of 3 head'), findsOneWidget);
      expect(find.byKey(const ValueKey('plan-excluded-grp-dairy-herd')), findsOneWidget);
      expect(find.text('Planned on their own line, not in this count: Clover (on her own ration)'), findsOneWidget);
      expect(find.text("Added on top of her group's ration"), findsOneWidget);
      final provider = tester.element(find.byType(DailyFeedingTab)).read<FeedingProvider>();
      expect(provider.dailyPlan.lines.firstWhere((l) => l.subjectId == 'grp-dairy-herd').headCount, 2);
    });

    testWidgets('the same list in Arabic', (tester) async {
      tester.view.physicalSize = const Size(1200, 2600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final farm = await SnapshotFarm.open();
      final today = farm.api.snapshot['GET /feeding-plan/today'] as Map<String, dynamic>;
      for (final l in today['lines'] as List<dynamic>) {
        final m = l as Map<String, dynamic>;
        if (m['subject_id'] == 'grp-dairy-herd') {
          m
            ..['head_count'] = 2
            ..['member_count'] = 3
            ..['excluded_heads'] = [{'animal_id': 'cow-clover', 'name': 'Clover', 'reason': 'other_group', 'group_name': 'Pregnant cows'}];
        }
      }
      await tester.pumpWidget(farm.app(const Scaffold(body: DailyFeedingTab()), locale: const Locale('ar')));
      await settle(tester);
      expect(find.textContaining('2 من 3 رأس'), findsOneWidget);
      expect(find.textContaining('تُعلف مع Pregnant cows'), findsOneWidget);
    });
  });

  testWidgets("an animal's feeding shows refused feed apart, never as fed", (tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final farm = await SnapshotFarm.open();
    final p = farm.api.snapshot['GET /livestock-subjects/cow-744/feeding-plan'] as Map<String, dynamic>;
    p['refused_7d'] = [{'feed_product_id': 'fp-dairy-mix', 'quantity': 2, 'unit': 'kg'}];
    await tester.pumpWidget(farm.app(Scaffold(
      body: SingleChildScrollView(
        child: Builder(builder: (c) {
          final bella = c.watch<AnimalsProvider>().find('cow-744');
          return bella == null ? const SizedBox() : AnimalFeedingSection(animal: bella);
        }),
      ),
    )));
    await settle(tester);
    expect(find.byKey(const ValueKey('feeding-refused-7d')), findsOneWidget);
    expect(find.text('Refused (recorded, not fed)'), findsOneWidget);
    expect(find.text('2 kg'), findsWidgets);
  });
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}
