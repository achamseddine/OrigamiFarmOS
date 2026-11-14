import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:farmos/features/animals/animal_digital_twin_screen.dart';
import 'package:farmos/features/animals/animal_status_screen.dart';

import '../support/snapshot_farm.dart';

/// The Digital Twin and the registry drawn over the bundled demo farm —
/// the server's own responses — as the farm's manager sees them.
void main() {
  Future<SnapshotFarm> open(WidgetTester tester, Widget home) async {
    tester.view.physicalSize = const Size(1280, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final farm = await SnapshotFarm.open();
    await tester.pumpWidget(farm.app(home));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    return farm;
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  testWidgets("Bella: header, figures, and the tabs a pregnant dairy cow has", (tester) async {
    await open(tester, const AnimalDigitalTwinScreen(animalId: 'cow-744'));
    expect(find.text('Bella'), findsOneWidget);
    expect(find.text('CATTLE · #744 · DAIRY'), findsOneWidget, reason: 'species · tag · purpose, from the catalog');
    expect(find.text('Pregnant · day 120'), findsWidgets);
    expect(find.text('Milk · last 7 days'), findsOneWidget);
    expect(find.textContaining('Day 1', findRichText: true), findsOneWidget, reason: 'the pregnancy figure');
    for (final tab in ['Overview', 'Milk', 'Feed', 'Weight', 'Reproduction', 'Health & medicines', 'Timeline']) {
      expect(find.text(tab), findsWidgets, reason: tab);
    }
    expect(find.text('Identity & lifecycle'), findsOneWidget);
    expect(find.textContaining('Decision support only'), findsOneWidget, reason: 'the AI card says what it is not');
  });

  testWidgets('a hen has no Milk and no Reproduction tab', (tester) async {
    await open(tester, const AnimalDigitalTwinScreen(animalId: 'hen-247'));
    expect(find.text('Overview'), findsOneWidget);
    expect(find.text('Milk'), findsNothing);
    expect(find.text('Reproduction'), findsNothing);
    expect(find.text('Health Score'), findsWidgets, reason: 'an animal that is not milked shows its health score first');
  });

  testWidgets("Thunder's Weight tab lists his dated weighing", (tester) async {
    await open(tester, const AnimalDigitalTwinScreen(animalId: 'horse-h07'));
    expect(find.text('Milk'), findsNothing, reason: 'a stallion is not milked');
    await tester.tap(find.text('Weight').first);
    await settle(tester);
    expect(find.text('Body weight'), findsOneWidget);
    expect(find.text('480 kg'), findsOneWidget);
    expect(find.text('Needs two weighings'), findsOneWidget);
  });

  testWidgets('the Milk tab adds up recorded milkings and says only that', (tester) async {
    await open(tester, const AnimalDigitalTwinScreen(animalId: 'cow-744'));
    await tester.tap(find.text('Milk').first);
    await settle(tester);
    expect(find.text('Milk record'), findsOneWidget);
    expect(find.text('Recent milkings'), findsOneWidget);
    expect(find.textContaining('A missed recording reads as less milk'), findsOneWidget);
  });

  testWidgets('Record opens every action this animal and person have, grouped', (tester) async {
    await open(tester, const AnimalDigitalTwinScreen(animalId: 'cow-744'));
    await tester.tap(find.text('Record').first);
    await settle(tester);
    expect(find.text('Record for Bella'), findsOneWidget);
    expect(find.text('Record weight'), findsWidgets);
    expect(find.text('Pregnancy check'), findsWidgets);
    expect(find.text('Breeding'), findsWidgets, reason: 'the group heading');
    expect(find.text('Record exit'), findsOneWidget);
  });

  testWidgets('an id that is not on the farm says so instead of showing another animal', (tester) async {
    await open(tester, const AnimalDigitalTwinScreen(animalId: 'no-such-animal'));
    expect(find.text("This animal is not on the farm’s list."), findsOneWidget);
  });

  testWidgets('the registry finds an animal by tag and filters by status', (tester) async {
    await open(tester, const Scaffold(body: AnimalStatusScreen()));
    expect(find.text('Animal registry'), findsOneWidget);
    expect(find.text('Bella'), findsOneWidget);
    expect(find.text('Thunder'), findsOneWidget);

    await tester.enterText(find.byKey(const ValueKey('registry-search')), '744');
    await settle(tester);
    expect(find.text('Bella'), findsOneWidget);
    expect(find.text('Thunder'), findsNothing);

    await tester.enterText(find.byKey(const ValueKey('registry-search')), '');
    await tester.tap(find.text('Pregnant').last);
    await settle(tester);
    expect(find.text('Bella'), findsOneWidget);
    expect(find.text('Luna'), findsNothing);
  });
}
