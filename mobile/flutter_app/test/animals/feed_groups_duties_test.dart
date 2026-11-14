import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:farmos/features/animals/add_animal_form.dart';
import 'package:farmos/features/animals/group_form.dart';
import 'package:farmos/features/employees/responsibilities_dialog.dart';
import 'package:farmos/features/feed/purchase_and_mix_dialogs.dart';
import 'package:farmos/providers/animals_provider.dart';
import 'package:farmos/providers/employees_provider.dart';

import '../support/snapshot_farm.dart';

/// The feed room's purchase and one-step mix, groups that follow the
/// records, worker responsibilities, and leaving the farm from the
/// profile — each over the bundled farm, checking what the tablet sends.
void main() {
  Future<SnapshotFarm> open(WidgetTester tester, Widget home) async {
    tester.view.physicalSize = const Size(1200, 2600);
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

  Map lastWrite(SnapshotFarm farm, String method, String path) => farm.api.writes.lastWhere((w) => w.$1 == method && w.$2 == path).$3! as Map;

  testWidgets('a grain purchase records the new feed, then its delivery with supplier and quality', (tester) async {
    final farm = await open(tester, opener((c) => showRecordPurchaseDialog(c)));
    await tester.tap(find.text('open'));
    await settle(tester);
    await tester.tap(find.text('What arrived'));
    await settle(tester);
    await tester.tap(find.textContaining('New feed').last);
    await settle(tester);
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Corn grain');
    await tester.enterText(find.widgetWithText(TextField, 'Received'), '1000');
    await tester.enterText(find.widgetWithText(TextField, 'Supplier'), 'Bekaa Grain Co.');
    await tester.tap(find.text('Good'));
    await tester.enterText(find.widgetWithText(TextField, 'Moisture'), '13.5');
    await tester.tap(find.text('Save'));
    await settle(tester);
    final product = lastWrite(farm, 'POST', '/feed-products');
    expect(product['name'], 'Corn grain');
    expect(product['is_ingredient'], isTrue);
    final lot = lastWrite(farm, 'POST', '/feed-lots/receive');
    expect(lot['quantity'], 1000);
    expect(lot['supplier_label'], 'Bekaa Grain Co.');
    expect(lot['quality_grade'], 'good');
    expect(lot['moisture_pct'], 13.5);
    expect(lot['received_at'], isNotNull);
  });

  testWidgets('a mix starts from the recipe and is saved in one step', (tester) async {
    final farm = await open(tester, opener((c) => showRecordMixDialog(c)));
    await tester.tap(find.text('open'));
    await settle(tester);
    expect(find.text('Dairy Mix 24L'), findsOneWidget, reason: 'the farm-made feed this mix makes');
    expect(find.text('Corn Silage'), findsWidgets, reason: 'rows from its recipe');
    await tester.tap(find.text('Save the mix'));
    await settle(tester);
    final body = lastWrite(farm, 'POST', '/feed-mixes');
    expect(body['feed_product_id'], 'fp-dairy-mix');
    expect((body['components'] as List), isNotEmpty);
    expect(body['produced_at'], isNotNull);
  });

  testWidgets('pregnant / not-pregnant groups are created as rule groups', (tester) async {
    final farm = await open(tester, opener((c) => showNewGroupForm(c, species: 'cow')));
    await tester.tap(find.text('open'));
    await settle(tester);
    await tester.enterText(find.widgetWithText(TextField, 'Group name'), 'Cows in milk');
    await tester.tap(find.text('In milk'));
    await tester.pump();
    await tester.tap(find.text('Create group'));
    await settle(tester);
    final body = lastWrite(farm, 'POST', '/animal-groups');
    expect(body['membership_rule'], 'IN_MILK');
    expect(body['group_type'], 'cohort');
    expect(body['species'], 'cow');
  });

  testWidgets('a worker is made responsible for the dairy herd with duties', (tester) async {
    final farm = await open(tester, const SizedBox());
    final emp = tester.element(find.byType(SizedBox)).read<EmployeesProvider>();
    await emp.load();
    final vet = emp.employees.firstWhere((e) => e.name.startsWith('Dr.'));
    await tester.pumpWidget(farm.app(opener((c) => showResponsibilitiesDialog(c, vet))));
    await settle(tester);
    await tester.tap(find.text('open'));
    await settle(tester);
    await tester.tap(find.byType(DropdownButtonFormField<String>).first);
    await settle(tester);
    await tester.tap(find.text('Dairy Herd').last);
    await settle(tester);
    await tester.tap(find.text('Add'));
    await settle(tester);
    final body = lastWrite(farm, 'POST', '/employees/${vet.id}/responsibilities');
    expect(body['scope_type'], 'group');
    expect(body['scope_id'], 'grp-dairy-herd');
    expect(body['duties'], containsAll(['milking', 'feeding', 'observation']));
  });

  testWidgets('Rasha marked sold on her profile records the exit, with its date', (tester) async {
    final farm = await open(tester, const SizedBox());
    final rasha = tester.element(find.byType(SizedBox)).read<AnimalsProvider>().find('goat-189')!;
    await tester.pumpWidget(farm.app(opener((c) => showAnimalForm(c, animal: rasha))));
    await settle(tester);
    await tester.tap(find.text('open'));
    await settle(tester);
    final sold = find.widgetWithText(ChoiceChip, 'Sold');
    await tester.ensureVisible(sold);
    await tester.tap(sold);
    await tester.pump();
    await tester.enterText(find.widgetWithText(TextField, 'Reason'), 'sold at market');
    await tester.tap(find.widgetWithText(FilledButton, 'Save changes'));
    await settle(tester);
    final paths = [for (final w in farm.api.writes) '${w.$1} ${w.$2}'];
    expect(paths, containsAllInOrder(['PUT /animals/goat-189', 'POST /animals/goat-189/exit']));
    final exit = lastWrite(farm, 'POST', '/animals/goat-189/exit');
    expect(exit['exit_type'], 'sold');
    expect(exit['reason'], 'sold at market');
    expect(exit['occurred_at'], isNotNull);
  });
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}
