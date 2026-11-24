import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:farmos/data/local/cache_effects.dart';
import 'package:farmos/data/local/outbox_labels.dart';
import 'package:farmos/features/production/milk_production_screen.dart';

import '../support/snapshot_farm.dart';

/// The farm's milking routine (v0.8.1), the same on the tablet and the web:
/// two milkings a day (morning and afternoon); after each, the calves get
/// their milk and the collector takes the rest at the agreed price; he pays
/// once a week for all of it.
void main() {
  const me = 'user-ali-demo';
  String iso(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  final today = iso(DateTime.now());
  final yesterday = iso(DateTime.now().subtract(const Duration(days: 1)));

  Map<String, Object?> handovers({String second = 'afternoon', bool collector = true, bool morningDone = false}) => {
        'second_milking': second,
        'collector_name': collector ? 'Abu Ali' : null,
        'collector_price': collector ? 0.5 : null,
        'collector_currency': 'USD',
        'today': today,
        'tank_l': 617.3,
        'milkings': [
          {'day': today, 'session': 'morning', 'milked_l': 74.1, 'calves_l': morningDone ? 6 : 0, 'collected_l': morningDone ? 68 : 0,
           'left_l': morningDone ? 0.1 : 74.1, 'handed_over': morningDone, 'amount': morningDone ? 34 : 0, 'paid': false, 'sale_ids': []},
          {'day': today, 'session': 'evening', 'milked_l': 0, 'calves_l': 0, 'collected_l': 0, 'left_l': 0, 'handed_over': false, 'amount': 0,
           'paid': false, 'sale_ids': []},
          {'day': yesterday, 'session': 'evening', 'milked_l': 70, 'calves_l': 5, 'collected_l': 65, 'left_l': 0, 'handed_over': true, 'amount': 32.5,
           'paid': false, 'sale_ids': ['m-y-e']},
        ],
      };
  Map<String, Object?> milkSale(String id, double liters, {int daysAgo = 1}) => {
        'id': id, 'sold_at': DateTime.now().toUtc().subtract(Duration(days: daysAgo)).toIso8601String(), 'liters': liters, 'price_per_liter': 0.5,
        'amount': liters * 0.5, 'currency': 'USD', 'buyer_name': 'Abu Ali', 'payment_status': 'pending', 'status': 'recorded',
      };
  Map<String, Object?> sale(String id, double liters, {int daysAgo = 1}) => {
        'id': id, 'product_type': 'milk', 'product_label': 'Raw milk', 'quantity': liters, 'unit': 'L', 'unit_price': 0.5, 'amount': liters * 0.5,
        'currency': 'USD', 'payment_status': 'pending', 'sold_at': DateTime.now().toUtc().subtract(Duration(days: daysAgo)).toIso8601String(),
        'buyer_name': 'Abu Ali', 'status': 'recorded',
      };
  const workerAccess = {
    'user_id': me, 'role': 'worker', 'full_access': false,
    'modules': {'animals': {'view': true, 'create': true}, 'milk_production': {'view': true, 'create': true}, 'morning_operations': {'view': true}},
  };

  Future<SnapshotFarm> open(WidgetTester tester, {Map<String, Object?> extra = const {}, bool worker = false, Locale locale = const Locale('en')}) async {
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final farm = await SnapshotFarm.open();
    if (worker) farm.api.snapshot['GET /me/access'] = workerAccess;
    farm.api.snapshot.addAll({'GET /production/milk-handovers?days=14': handovers(), ...extra});
    await tester.pumpWidget(farm.app(const Scaffold(body: MilkProductionScreen()), locale: locale));
    await settle(tester);
    return farm;
  }

  Map body(SnapshotFarm farm, String method, String path) => farm.api.writes.lastWhere((w) => w.$1 == method && w.$2 == path).$3! as Map;

  testWidgets('each milking of today and yesterday, the second one called the afternoon', (tester) async {
    await open(tester);
    expect(find.byKey(const ValueKey('milk-handover-card')), findsOneWidget);
    expect(find.text('Collector: Abu Ali · \$0.50/L'), findsOneWidget);
    expect(find.text('Today · Morning'), findsOneWidget);
    expect(find.text('Today · Afternoon'), findsNothing, reason: 'not milked yet: nothing to hand over');
    expect(find.text('Yesterday · Afternoon'), findsOneWidget);
    expect(find.byKey(ValueKey('handover-$today-morning')), findsOneWidget, reason: 'not handed over yet');
    expect(find.byKey(ValueKey('handover-$yesterday-evening')), findsNothing, reason: 'already handed over');
  });

  testWidgets('after the morning milking: the calves, then the collector takes the rest', (tester) async {
    final farm = await open(tester);
    await tester.tap(find.byKey(ValueKey('handover-$today-morning')));
    await settle(tester);
    expect(find.text('Milked into the tank at this milking: 74.1 L'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('handover-calves')), '6');
    await settle(tester);
    expect(tester.widget<TextField>(find.byKey(const ValueKey('handover-collector'))).controller!.text, '68.1', reason: 'the rest goes to the collector');
    await tester.tap(find.byKey(const ValueKey('handover-save')));
    await settle(tester);
    final sent = body(farm, 'POST', '/production/milk-handovers');
    expect((sent['day'], sent['session'], sent['calves_l'], sent['collected_l']), (today, 'morning', 6, 68.1));
    expect(sent.containsKey('price_per_liter'), isFalse, reason: 'the price is the farm\'s setting, not typed');
  });

  testWidgets('an employee hands over the milk but does not set the collector or take payments', (tester) async {
    await open(tester, worker: true, extra: {'GET /production/milk-sales?days=90': [milkSale('m1', 65)]});
    expect(find.byKey(ValueKey('handover-$today-morning')), findsOneWidget);
    expect(find.byKey(const ValueKey('milk-routine')), findsNothing);
    expect(find.byKey(const ValueKey('collector-paid')), findsNothing);
  });

  testWidgets('the manager sets the collector, his price and the afternoon milking', (tester) async {
    final farm = await open(tester, extra: {'GET /production/milk-handovers?days=14': handovers(second: 'evening', collector: false)});
    expect(find.text('Today · Morning'), findsOneWidget);
    expect(find.text('Yesterday · Evening'), findsOneWidget, reason: 'the second milking is called the evening until the manager says otherwise');
    expect(find.text('No milk collector set yet — the farm manager sets him and his price.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('milk-routine')));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('routine-afternoon')));
    await tester.enterText(find.byKey(const ValueKey('routine-name')), 'Abu Ali');
    await tester.enterText(find.byKey(const ValueKey('routine-price')), '0.5');
    await tester.tap(find.byKey(const ValueKey('routine-save')));
    await settle(tester);
    final sent = body(farm, 'PUT', '/production/milk-routine');
    expect((sent['collector_name'], sent['collector_price'], sent['collector_currency'], sent['second_milking']), ('Abu Ali', 0.5, 'USD', 'afternoon'));
  });

  testWidgets('the collector pays for the week: every collection at once, a difference kept', (tester) async {
    final farm = await open(tester, extra: {
      'GET /production/milk-sales?days=90': [milkSale('m1', 65), milkSale('m2', 68, daysAgo: 2), milkSale('m3', 70, daysAgo: 3)],
      'GET /finance/sales?days=365': [sale('s1', 65), sale('s2', 68, daysAgo: 2), sale('s3', 70, daysAgo: 3)],
    });
    expect(find.byKey(const ValueKey('collector-owes')), findsOneWidget);
    expect(find.text('Abu Ali owes \$101.50 · 203 L · 3 collections'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('collector-paid')));
    await settle(tester);
    expect(find.text('Due: \$101.50 · 3 sales · 203 L'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('pay-amount')), '100');
    await settle(tester);
    expect(find.text('Less than due: \$1.50 — kept on record with the payment'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('pay-save')));
    await tester.tap(find.byKey(const ValueKey('pay-save')));
    await settle(tester);
    final sent = body(farm, 'POST', '/finance/payments');
    expect((sent['sale_ids'] as List).toSet(), {'s1', 's2', 's3'});
    expect((sent['amount_received'], sent['currency']), (100, 'USD'));
  });

  testWidgets('in Arabic', (tester) async {
    await open(tester, locale: const Locale('ar'));
    expect(find.text('بعد كل حلبة'), findsOneWidget);
    expect(find.textContaining('بعد الضهر'), findsWidgets);
  });

  test('offline: a payment shows its sales paid; handovers and payments are named in the waiting list', () {
    final fx = effectsFor('POST', '/finance/payments', {'sale_ids': ['s1', 's2'], 'amount_received': 60}, localId: 'local-1');
    expect([for (final e in fx.whereType<MergeRecord>()) (e.id, e.patch['payment_status'])], [('s1', 'paid'), ('s2', 'paid')]);
    expect(describeWrite('/finance/payments').labelKey, 'outboxPayment');
    expect(describeWrite('/production/milk-handovers').labelKey, 'outboxMilkHandover');
    expect(describeWrite('/production/milk-routine').labelKey, 'outboxMilkRoutine');
    expect(describeWrite('/production/milk').labelKey, 'outboxMilkRecord');
  });
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}
