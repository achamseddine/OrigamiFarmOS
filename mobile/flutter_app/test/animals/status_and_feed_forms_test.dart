import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:farmos/core/i18n/locale_controller.dart';
import 'package:farmos/domain/entities/reproduction.dart';
import 'package:farmos/features/animals/add_animal_form.dart';
import 'package:farmos/features/feed/feeding_event_dialog.dart';
import 'package:farmos/features/settings/settings_screen.dart';
import 'package:farmos/providers/animals_provider.dart';

import '../support/snapshot_farm.dart';

/// The corrections from on-farm testing: the feeding form's three default
/// rows, pregnancy and milk answered on the animal form (new and existing
/// animals), registering with nothing to scan, and the farm's dry-off
/// setting — each driven over the bundled demo farm, checking what the
/// tablet actually sends.
void main() {
  Future<SnapshotFarm> open(WidgetTester tester, Widget home) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final farm = await SnapshotFarm.open();
    await tester.pumpWidget(farm.app(home));
    await settle(tester);
    return farm;
  }

  Widget opener(void Function(BuildContext) onTap) => Scaffold(
        body: Builder(builder: (context) => Center(child: TextButton(onPressed: () => onTap(context), child: const Text('open')))),
      );

  Map writeTo(SnapshotFarm farm, String method, String path) => farm.api.writes.lastWhere((w) => w.$1 == method && w.$2 == path).$3! as Map;

  group('the animal feeding form', () {
    testWidgets('opens with concentrate, corn silage and wheat straw; a blank row records nothing', (tester) async {
      final farm = await open(tester, opener((c) => showFeedingEventDialog(c, subjectType: 'animal', subjectId: 'goat-g032', subjectName: 'Mira')));
      await tester.tap(find.text('open'));
      await settle(tester);
      for (final label in ['Concentrate', 'Corn silage']) {
        expect(find.text(label), findsOneWidget, reason: 'a default row for $label');
      }
      // Each row already points at the farm's own feed for it.
      expect(find.text('Dairy Concentrate 18'), findsOneWidget);
      expect(find.text('Corn Silage'), findsOneWidget);
      expect(find.text('Wheat straw'), findsNWidgets(2), reason: 'the row label and the product picked for it');

      await tester.enterText(find.byType(TextField).at(1), '20');
      await tester.tap(find.text('Save'));
      await settle(tester);
      final body = writeTo(farm, 'POST', '/feeding-events');
      expect(body['event_type'], 'offered');
      expect(body.containsKey('allow_negative'), isFalse);
      final components = (body['components'] as List).cast<Map>();
      expect(components, hasLength(1));
      expect(components.single['feed_product_id'], 'fp-corn-silage');
      expect(components.single['quantity_offered'], 20);
    });

    testWidgets('more than the entered stock is said, and recorded only when the worker says so', (tester) async {
      final farm = await open(tester, opener((c) => showFeedingEventDialog(c, subjectType: 'animal', subjectId: 'goat-g032', subjectName: 'Mira')));
      await tester.tap(find.text('open'));
      await settle(tester);
      await tester.enterText(find.byType(TextField).at(2), '99999');
      await tester.pump();
      expect(find.text('Not enough stock recorded'), findsOneWidget);
      await tester.tap(find.text('Save'));
      await settle(tester);
      expect(farm.api.writes.where((w) => w.$2 == '/feeding-events'), isEmpty, reason: 'not without the explicit override');
      await tester.tap(find.text('Stock not entered yet — record anyway'));
      await tester.pump();
      await tester.tap(find.text('Save'));
      await settle(tester);
      expect(writeTo(farm, 'POST', '/feeding-events')['allow_negative'], isTrue);
    });
  });

  group('the animal form', () {
    testWidgets('a new cow: nothing to scan, pregnant from an insemination date, in milk', (tester) async {
      final farm = await open(tester, opener((c) => showAnimalForm(c)));
      await tester.tap(find.text('open'));
      await settle(tester);
      expect(find.textContaining('Nothing to scan'), findsOneWidget);
      await tester.enterText(find.widgetWithText(TextField, 'Name').first, 'Noor');
      await tester.ensureVisible(find.text('Pregnant'));
      await tester.tap(find.text('Pregnant'));
      await tester.pump();
      await tester.ensureVisible(find.text('Insemination date…'));
      await tester.pump();
      await tester.tap(find.text('Insemination date…'));
      await settle(tester);
      await tester.tap(find.text('OK'));
      await settle(tester);
      expect(find.textContaining('Expected birth'), findsOneWidget);
      await tester.ensureVisible(find.text('Producing milk — being milked'));
      await tester.tap(find.text('Producing milk — being milked'));
      await tester.pump();
      final add = find.widgetWithText(FilledButton, 'Add Animal');
      await tester.ensureVisible(add);
      await tester.tap(add);
      await settle(tester);
      final body = writeTo(farm, 'POST', '/animals');
      expect(body['name'], 'Noor');
      expect(body['identifiers'], isEmpty, reason: 'no ear tag needed to register');
      expect(body['pregnant'], isTrue);
      expect(body['lactating'], isTrue);
      expect(body['service_type'], 'ARTIFICIAL_INSEMINATION');
      expect(body['service_date'], isNotNull);
    });

    testWidgets("Daisy's insemination is shown, and confirming it records a pregnancy check", (tester) async {
      final farm = await open(tester, const SizedBox());
      final daisy = tester.element(find.byType(SizedBox)).read<AnimalsProvider>().find('sheep-s045')!;
      await tester.pumpWidget(farm.app(opener((c) => showAnimalForm(c, animal: daisy))));
      await settle(tester);
      await tester.tap(find.text('open'));
      await settle(tester);
      final inseminated = tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Inseminated — not confirmed yet'));
      expect(inseminated.selected, isTrue, reason: 'served 35 days ago, no check yet');
      await tester.ensureVisible(find.widgetWithText(ChoiceChip, 'Pregnant'));
      await tester.tap(find.widgetWithText(ChoiceChip, 'Pregnant'));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Save changes'));
      await settle(tester);
      final paths = [for (final w in farm.api.writes) '${w.$1} ${w.$2}'];
      expect(paths, containsAllInOrder(['PUT /animals/sheep-s045', 'POST /animals/sheep-s045/pregnancy-checks']));
      expect(paths, isNot(contains('POST /animals/sheep-s045/breedings')), reason: 'the insemination is already on record');
      expect(writeTo(farm, 'POST', '/animals/sheep-s045/pregnancy-checks')['result_code'], 'POSITIVE');
      // The pregnancy line stays a record, never a flag on the edit.
      expect(writeTo(farm, 'PUT', '/animals/sheep-s045').containsKey('pregnant'), isFalse);
    });

    testWidgets('saying Mira is milked makes her dairy, starts the lactation and opens the milk record', (tester) async {
      final farm = await open(tester, const SizedBox());
      final mira = tester.element(find.byType(SizedBox)).read<AnimalsProvider>().find('goat-g032')!;
      await tester.pumpWidget(farm.app(opener((c) => showAnimalForm(c, animal: mira))));
      await settle(tester);
      await tester.tap(find.text('open'));
      await settle(tester);
      await tester.ensureVisible(find.text('Producing milk — being milked'));
      await tester.tap(find.text('Producing milk — being milked'));
      await tester.pump();
      expect(find.textContaining('Changed so this can be recorded'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Save changes'));
      await settle(tester);
      expect(writeTo(farm, 'PUT', '/animals/goat-g032')['management_profile'], 'dairy');
      expect(farm.api.writes.any((w) => w.$2 == '/animals/goat-g032/lactations'), isTrue);
      expect(find.textContaining('Mira #'), findsOneWidget, reason: 'the milk record opened by itself');
    });
  });

  testWidgets('the manager sets the dry-off days in Settings', (tester) async {
    final farm = await open(tester, ChangeNotifierProvider(create: (_) => LocaleController(), child: const Scaffold(body: SettingsScreen())));
    await tester.ensureVisible(find.byKey(const ValueKey('dry-off-days')));
    expect(find.text('60'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('dry-off-days')), '45');
    await tester.tap(find.descendant(of: find.ancestor(of: find.byKey(const ValueKey('dry-off-days')), matching: find.byType(Row)), matching: find.text('Save')));
    await settle(tester);
    expect(writeTo(farm, 'PATCH', '/farms/me'), {'dry_off_days_before_birth': 45});
  });

  test('the dry-off date is the expected birth less the farm setting', () {
    expect(dryOffFrom(DateTime(2027, 5, 21), 60), DateTime(2027, 3, 22));
    expect(dryOffFrom(null, 60), isNull);
  });
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}
