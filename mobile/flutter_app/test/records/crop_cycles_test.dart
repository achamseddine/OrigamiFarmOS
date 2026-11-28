import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:farmos/data/local/outbox_labels.dart';
import 'package:farmos/domain/entities/access.dart';
import 'package:farmos/domain/entities/crop.dart';
import 'package:farmos/features/produce/crop_cycle_sheet.dart';
import 'package:farmos/features/produce/produce_harvest_screen.dart';
import 'package:farmos/providers/agriculture_provider.dart';

import '../support/snapshot_farm.dart';

/// A crop cycle from planting to its margin (master prompt Package 7), the
/// same on the tablet and the web: the work done and the stock it used, the
/// water given, the produce sold, and what the cycle earned against what it
/// cost — unknown costs named, never counted as free.
void main() {
  const cycleId = 'cycle-cuc';
  Map<String, dynamic> planting({String? closedAt}) => {
        'id': cycleId, 'field_id': 'field-4', 'crop_id': 'crop-cucumber', 'variety': 'Beit Alpha', 'planted_area': 0.9, 'area_unit': 'dunum',
        'planted_date': '2026-10-14T08:00:00', 'expected_harvest_date': '2026-12-01T08:00:00', 'stage': closedAt == null ? 'growing' : 'closed',
        'status': closedAt == null ? 'active' : 'closed', 'cycle_code': 'CUCU-2026-001', 'production_purpose': 'sale', 'closed_at': closedAt,
        'created_at': '2026-10-14T08:00:00',
      };
  final inputs = [
    {'id': 'npk', 'name': 'NPK 20-20-20', 'category': 'fertilizer', 'unit': 'kg', 'current_qty': 50, 'unit_cost': 1.5},
    {'id': 'seed', 'name': 'Cucumber seed', 'category': 'seeds', 'unit': 'packet', 'current_qty': 5, 'unit_cost': 5},
  ];
  final margin = {
    'crop_cycle_id': cycleId, 'cycle_code': 'CUCU-2026-001', 'status': 'active',
    'harvest': {'harvested': 500, 'lost': 20, 'sellable': 480, 'sold': 400, 'unit': 'kg', 'harvests': 1, 'loss_reasons': ['split fruit']},
    'revenue': 480, 'costs': {'inputs': 40, 'labour': 40, 'irrigation_energy': 8, 'other_expenses': 0, 'total_known': 88},
    'inputs': [], 'labour_hours': 6, 'water_m3': 30, 'margin': 392, 'cost_per_unit_harvested': 0.176,
    'unknown': ['labour_not_priced', 'inputs_without_cost'], 'unpriced_inputs': ['Copper spray'],
  };

  Future<SnapshotFarm> open(WidgetTester tester, {String? closedAt, Map<String, Object?>? access, Locale locale = const Locale('en')}) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final farm = await SnapshotFarm.open();
    if (access != null) farm.api.snapshot['GET /me/access'] = access;
    final items = [...(farm.api.snapshot['GET /feed/items?farm_id=farm-origami'] as List)];
    items.add({'id': 'produce-cuc', 'name': 'Cucumbers', 'category': 'produce', 'unit': 'kg', 'current_qty': 80, 'reorder_level': 0});
    farm.api.snapshot.addAll({
      'GET /crop-plantings': [planting(closedAt: closedAt)],
      'GET /crop-inputs': inputs,
      'GET /crop-plantings/$cycleId/margin': margin,
      'GET /feed/items?farm_id=farm-origami': items,
    });
    await tester.pumpWidget(farm.app(Scaffold(body: Builder(builder: (context) {
      return const ProduceHarvestScreen();
    })), locale: locale));
    await settle(tester);
    await tester.element(find.byType(ProduceHarvestScreen)).read<AgricultureProvider>().load();
    await settle(tester);
    return farm;
  }

  Map body(SnapshotFarm farm, String path) => farm.api.writes.lastWhere((w) => w.$1 == 'POST' && w.$2 == path).$3! as Map;

  Future<void> openCycle(WidgetTester tester) async {
    await tester.ensureVisible(find.byKey(const ValueKey('cc-open-field-4')));
    await tester.tap(find.byKey(const ValueKey('cc-open-field-4')));
    await settle(tester);
  }

  Future<void> part(WidgetTester tester, String label) async {
    await tester.tap(find.descendant(of: find.byType(SegmentedButton<CropCyclePart>), matching: find.text(label)));
    await settle(tester);
  }

  group('a crop cycle opened from its field', () {
    testWidgets('the field row names its cycle and opens it', (tester) async {
      await open(tester);
      expect(find.text('Manage cycle · CUCU-2026-001'), findsOneWidget);
      await openCycle(tester);
      expect(find.text('Crop cycle CUCU-2026-001'), findsOneWidget);
      expect(find.text('Cucumbers in Field 4 — Cucumbers'), findsOneWidget);
      for (final p in ['Work', 'Water', 'Sell', 'Margin']) {
        expect(find.descendant(of: find.byType(SegmentedButton<CropCyclePart>), matching: find.text(p)), findsOneWidget, reason: p);
      }
      expect(find.text('Close cycle'), findsOneWidget);
    });

    testWidgets('work takes its input out of stock, with its labour and its time', (tester) async {
      final farm = await open(tester);
      await openCycle(tester);
      await tester.tap(find.byKey(const ValueKey('cc-work-input')));
      await settle(tester);
      await tester.tap(find.text('NPK 20-20-20').last);
      await settle(tester);
      expect(find.text('50 kg in stock'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('cc-work-hours')), '2');
      await tester.enterText(find.byKey(const ValueKey('cc-work-cost')), '10');
      await tester.enterText(find.byKey(const ValueKey('cc-work-qty')), '20');
      await tester.tap(find.text('Record work'));
      await settle(tester);
      final sent = body(farm, '/crop-plantings/$cycleId/operations');
      expect(sent['operation_type'], 'fertilize');
      expect(sent['labour_hours'], 2);
      expect(sent['labour_cost'], 10);
      expect(sent['inputs'], [
        {'inventory_item_id': 'npk', 'quantity': 20}
      ]);
      // Queued on a tablet, the work keeps the time it was done.
      expect(DateTime.parse(sent['completed_at'] as String).isUtc, isTrue);
    });

    testWidgets('an input chosen with no quantity is not sent', (tester) async {
      final farm = await open(tester);
      await openCycle(tester);
      await tester.tap(find.byKey(const ValueKey('cc-work-input')));
      await settle(tester);
      await tester.tap(find.text('Cucumber seed').last);
      await settle(tester);
      await tester.tap(find.text('Record work'));
      await settle(tester);
      expect(find.text('Enter how much was used.'), findsOneWidget);
      expect(farm.api.writes.where((w) => w.$2.endsWith('/operations')), isEmpty);
    });

    testWidgets('irrigation: the water, its source and the pumping cost', (tester) async {
      final farm = await open(tester);
      await openCycle(tester);
      await part(tester, 'Water');
      await tester.enterText(find.byKey(const ValueKey('cc-water-m3')), '12.5');
      await tester.enterText(find.byKey(const ValueKey('cc-water-energy')), '3');
      await tester.tap(find.text('Record irrigation'));
      await settle(tester);
      final sent = body(farm, '/crop-plantings/$cycleId/irrigation');
      expect(sent['water_quantity'], 12.5);
      expect(sent['unit'], 'm3');
      expect(sent['energy_cost'], 3);
      expect(sent['source_code'], 'well');
    });

    testWidgets('a sale of its produce: from stock, with a quantity and a price', (tester) async {
      final farm = await open(tester);
      await openCycle(tester);
      await part(tester, 'Sell');
      expect(find.text('80 kg of Cucumbers in stock'), findsOneWidget);
      await tester.tap(find.text('Record sale'));
      await settle(tester);
      expect(find.text('Enter the quantity and the price.'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('cc-sell-qty')), '40');
      await tester.enterText(find.byKey(const ValueKey('cc-sell-price')), '1.2');
      await tester.tap(find.text('Record sale'));
      await settle(tester);
      final sent = body(farm, '/crop-plantings/$cycleId/sales');
      expect(sent['quantity'], 40);
      expect(sent['unit_price'], 1.2);
      expect(sent['currency'], 'USD');
      expect(sent['payment_status'], 'paid');
    });

    testWidgets('the margin: what it sold for against its known costs, unknown costs named', (tester) async {
      await open(tester);
      await openCycle(tester);
      await part(tester, 'Margin');
      expect(find.text('\$480'), findsOneWidget);
      expect(find.text('\$88'), findsOneWidget);
      expect(find.text('\$392'), findsOneWidget);
      expect(find.text('\$0.176'), findsOneWidget);
      expect(find.byKey(const ValueKey('cc-margin-unknown')), findsOneWidget);
      expect(find.text('• Some labour was not priced.'), findsOneWidget);
      expect(find.text('• Some inputs have no price: Copper spray.'), findsOneWidget);
    });

    testWidgets('closing the cycle is asked first, then sent', (tester) async {
      final farm = await open(tester);
      await openCycle(tester);
      await tester.tap(find.text('Close cycle'));
      await settle(tester);
      expect(find.textContaining('Close CUCU-2026-001?'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Close cycle'));
      await settle(tester);
      expect(farm.api.writes.where((w) => w.$1 == 'POST' && w.$2 == '/crop-plantings/$cycleId/close'), hasLength(1));
    });
  });

  group('who sees which part', () {
    testWidgets('a closed cycle takes no more work, but its produce still sells', (tester) async {
      await open(tester, closedAt: '2026-11-20T10:00:00Z');
      await openCycle(tester);
      expect(find.text('Closed'), findsOneWidget);
      final segments = find.byType(SegmentedButton<CropCyclePart>);
      expect(find.descendant(of: segments, matching: find.text('Work')), findsNothing);
      expect(find.descendant(of: segments, matching: find.text('Water')), findsNothing);
      expect(find.descendant(of: segments, matching: find.text('Sell')), findsOneWidget);
      expect(find.text('Close cycle'), findsNothing);
    });

    testWidgets('a field worker records work and water, not sales or the margin', (tester) async {
      await open(tester, access: {
        'user_id': 'user-field', 'role': 'worker', 'full_access': false,
        'modules': {
          FarmModule.agriculture: {'view': true, 'create': true},
          FarmModule.produceHarvest: {'view': true, 'create': true},
        },
      });
      await openCycle(tester);
      final segments = find.byType(SegmentedButton<CropCyclePart>);
      expect(find.descendant(of: segments, matching: find.text('Work')), findsOneWidget);
      expect(find.descendant(of: segments, matching: find.text('Water')), findsOneWidget);
      expect(find.descendant(of: segments, matching: find.text('Sell')), findsNothing);
      expect(find.descendant(of: segments, matching: find.text('Margin')), findsNothing);
      // Closing needs the right to edit the crop records.
      expect(find.text('Close cycle'), findsNothing);
    });

    testWidgets('someone with no crop, sales or money role is not offered the cycle', (tester) async {
      await open(tester, access: {
        'user_id': 'user-milker', 'role': 'worker', 'full_access': false,
        'modules': {FarmModule.milkProduction: {'view': true, 'create': true}},
      });
      expect(find.byKey(const ValueKey('cc-open-field-4')), findsNothing);
    });

    testWidgets('in Arabic', (tester) async {
      await open(tester, locale: const Locale('ar'));
      await openCycle(tester);
      expect(find.text('سجّل الشغل'), findsOneWidget);
      expect(find.text('سكّر الموسم'), findsOneWidget);
    });
  });

  group('the cycle', () {
    test('the one still growing is opened, else the last one planted', () {
      CropPlanting p(String id, String planted, {String? closed}) => CropPlanting.fromJson({
            'id': id, 'field_id': 'f', 'crop_id': 'c', 'planted_date': planted, 'stage': 'growing', 'status': closed == null ? 'active' : 'closed',
            'closed_at': closed,
          });
      expect(currentCycle([p('old', '2025-03-01T00:00:00', closed: '2025-07-01T00:00:00Z'), p('now', '2026-03-01T00:00:00')])!.id, 'now');
      expect(currentCycle([p('a', '2025-03-01T00:00:00', closed: '2025-07-01T00:00:00Z'), p('b', '2026-03-01T00:00:00', closed: '2026-07-01T00:00:00Z')])!.id, 'b');
      expect(currentCycle(const []), isNull);
      expect(p('x', '2026-01-01T00:00:00', closed: '2026-02-01T00:00:00Z').closed, isTrue);
    });

    test('its writes are named in the sync panel', () {
      expect(describeWrite('/crop-plantings/$cycleId/operations').labelKey, 'outboxCropWork');
      expect(describeWrite('/crop-plantings/$cycleId/operations/op1/reverse').labelKey, 'outboxCropWork');
      expect(describeWrite('/crop-plantings/$cycleId/irrigation').labelKey, 'outboxIrrigation');
      expect(describeWrite('/crop-plantings/$cycleId/sales'), (labelKey: 'outboxSale', moduleCode: FarmModule.sales));
      expect(describeWrite('/crop-plantings/$cycleId/close').labelKey, 'outboxCropCycleClose');
      expect(describeWrite('/crop-plantings').labelKey, 'outboxPlanting');
      expect(describeWrite('/crop-plantings/$cycleId').labelKey, 'outboxPlanting');
    });
  });
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}
