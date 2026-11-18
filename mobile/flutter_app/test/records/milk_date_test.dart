import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:farmos/core/util/record_dates.dart';
import 'package:farmos/domain/entities/production_records.dart';
import 'package:farmos/features/animals/animal_quick_actions.dart';
import 'package:farmos/features/animals/quick_round.dart';
import 'package:farmos/providers/animals_provider.dart';

import '../support/snapshot_farm.dart';

/// Milk noted on paper and entered later: the milk record takes the day it
/// was milked (tablet and web, one form). Today stays the default.
void main() {
  group('the time a milking is recorded at', () {
    test('today is now; an earlier day is that session\'s usual hour', () {
      final now = DateTime.now();
      expect(milkingInstant(now, 'morning').difference(now).inSeconds.abs(), lessThan(5));
      final earlier = DateTime(now.year, now.month, now.day).subtract(const Duration(days: 3));
      expect(milkingInstant(earlier, 'morning'), DateTime(earlier.year, earlier.month, earlier.day, 7));
      expect(milkingInstant(earlier, 'midday'), DateTime(earlier.year, earlier.month, earlier.day, 12));
      expect(milkingInstant(earlier, 'evening'), DateTime(earlier.year, earlier.month, earlier.day, 18));
    });

    test('the same session is looked for on the chosen day, not only today', () {
      final now = DateTime.now();
      final yesterday = now.subtract(const Duration(days: 1));
      final records = [
        MilkRecord(id: 'm1', animalId: 'cow-744', session: 'morning', liters: 12, destination: 'stored',
            recordedAt: DateTime(yesterday.year, yesterday.month, yesterday.day, 7)),
      ];
      expect(sameSessionOn('cow-744', 'morning', yesterday, records), isNotNull);
      expect(sameSessionOn('cow-744', 'evening', yesterday, records), isNull);
      expect(sameSessionToday('cow-744', 'morning', records), isNull, reason: 'yesterday\'s morning is not today\'s');
    });
  });

  group('the milk form', () {
    Future<SnapshotFarm> open(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1200, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final farm = await SnapshotFarm.open();
      await tester.pumpWidget(farm.app(Scaffold(
        body: Builder(
          builder: (c) => Center(child: TextButton(onPressed: () => showMilkDialog(c, c.read<AnimalsProvider>().find('cow-744')!), child: const Text('open'))),
        ),
      )));
      await settle(tester);
      await tester.tap(find.text('open'));
      await settle(tester);
      return farm;
    }

    Map sent(SnapshotFarm farm) => farm.api.writes.lastWhere((w) => w.$1 == 'POST' && w.$2 == '/production/milk').$3! as Map;

    testWidgets('opens on today and records today', (tester) async {
      final farm = await open(tester);
      expect(find.textContaining('Milked on: ${dayLabel(DateTime.now())}'), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, '11');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await settle(tester);
      final at = DateTime.parse(sent(farm)['recorded_at'] as String).toLocal();
      expect(isToday(at), isTrue);
    });

    testWidgets('an earlier day is recorded for that day, and is not "milk today"', (tester) async {
      final farm = await open(tester);
      final animals = tester.element(find.text('open')).read<AnimalsProvider>();
      final before = animals.find('cow-744')!.milkTodayL ?? 0;
      final now = DateTime.now();
      final day = DateTime(now.year, now.month, now.day).subtract(const Duration(days: 3));

      await tester.tap(find.byKey(const ValueKey('milk-day')));
      await settle(tester);
      // The calendar's keyboard entry: type the date rather than page months.
      await tester.tap(find.byIcon(Icons.edit_outlined));
      await settle(tester);
      await tester.enterText(find.byType(TextField).last, '${day.month}/${day.day}/${day.year}');
      await tester.tap(find.text('OK'));
      await settle(tester);
      expect(find.text('Recording for ${dayLabel(day)}, not today.'), findsOneWidget);

      await tester.enterText(find.byType(TextField).first, '9.5');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await settle(tester);
      final at = DateTime.parse(sent(farm)['recorded_at'] as String).toLocal();
      expect(at, DateTime(day.year, day.month, day.day, 7), reason: 'the morning milking of that day');
      expect(animals.find('cow-744')!.milkTodayL ?? 0, before, reason: 'an earlier day does not add to today');
    });
  });
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}
