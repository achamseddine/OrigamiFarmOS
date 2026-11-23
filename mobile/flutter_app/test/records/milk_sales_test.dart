import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:farmos/data/local/cache_effects.dart';
import 'package:farmos/data/local/outbox_labels.dart';
import 'package:farmos/features/finance/sales_finance_screen.dart';
import 'package:farmos/features/production/milk_production_screen.dart';
import 'package:farmos/features/production/milk_sales_ui.dart';

import '../support/snapshot_farm.dart';

/// Milk was stored but could not be sold (v0.7.9): the Milk page and
/// Sales & Finance now sell it from the tank — litres, price, buyer, paid
/// or to be paid — and the tank is never typed in, only counted. The same
/// screens on the tablet and the web.
void main() {
  const me = 'user-ali-demo';
  const workerAccess = {
    'user_id': me,
    'role': 'worker',
    'full_access': false,
    'modules': {
      'animals': {'view': true, 'create': true, 'edit': true},
      'milk_production': {'view': true, 'create': true, 'edit': true},
      'morning_operations': {'view': true, 'create': true, 'edit': true},
    },
  };

  Map<String, dynamic> sale(String id, {String payment = 'pending', String status = 'recorded', double liters = 80, double price = 0.6, String? buyer = 'Laiterie Bekaa'}) => {
        'id': id, 'sold_at': DateTime.now().toUtc().toIso8601String(), 'liters': liters, 'price_per_liter': price,
        'amount': double.parse((liters * price).toStringAsFixed(2)), 'currency': 'USD', 'buyer_name': buyer,
        'payment_status': payment, 'status': status, 'cancel_reason': null,
      };

  Future<SnapshotFarm> open(WidgetTester tester, Widget home, {bool worker = false, Map<String, Object?> extra = const {}}) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final farm = await SnapshotFarm.open();
    if (worker) farm.api.snapshot['GET /me/access'] = workerAccess;
    farm.api.snapshot.addAll(extra);
    await tester.pumpWidget(farm.app(Scaffold(body: home)));
    await settle(tester);
    return farm;
  }

  Map body(SnapshotFarm farm, String path) => farm.api.writes.lastWhere((w) => w.$1 == 'POST' && w.$2 == path).$3! as Map;

  group('selling milk', () {
    testWidgets('the Milk page shows the tank worked out from the records', (tester) async {
      await open(tester, const MilkProductionScreen());
      expect(find.byKey(const ValueKey('milk-tank-card')), findsOneWidget);
      expect(find.text('Milk tank and sales'), findsOneWidget);
      // The demo farm: 617.3 L stored, nothing sold yet.
      expect(find.text('617.3 L'), findsOneWidget);
      expect(find.text('No milk sold yet.'), findsOneWidget);
      expect(find.byKey(const ValueKey('sell-milk')), findsOneWidget);
      expect(find.byKey(const ValueKey('count-tank')), findsOneWidget);
    });

    testWidgets('a sale: litres, price, buyer and to be paid, the total as it is typed', (tester) async {
      final farm = await open(tester, const MilkProductionScreen());
      await tester.tap(find.byKey(const ValueKey('sell-milk')));
      await settle(tester);
      expect(find.text('In the tank: 617.3 L'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('sell-liters')), '120');
      await tester.enterText(find.byKey(const ValueKey('sell-price')), '0.55');
      await settle(tester);
      expect(find.text('Total: \$66.00'), findsOneWidget);
      await tester.enterText(find.widgetWithText(TextField, 'Buyer'), 'Laiterie Bekaa');
      await tester.tap(find.byKey(const ValueKey('sell-pending')));
      await settle(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Save sale'));
      await settle(tester);

      final sent = body(farm, '/production/milk-sales');
      expect(sent['liters'], 120);
      expect(sent['price_per_liter'], 0.55);
      expect(sent['buyer_name'], 'Laiterie Bekaa');
      expect(sent['payment_status'], 'pending');
      expect(sent.containsKey('allow_negative'), isFalse);
      expect(DateTime.parse(sent['sold_at'] as String).isUtc, isTrue);
      expect(find.textContaining('Sold 120 L'), findsOneWidget);
    });

    testWidgets('no litres or no price is said, not sent', (tester) async {
      final farm = await open(tester, const MilkProductionScreen());
      await tester.tap(find.byKey(const ValueKey('sell-milk')));
      await settle(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Save sale'));
      await settle(tester);
      expect(find.text('Enter how many litres.'), findsOneWidget);
      expect(farm.api.writes.where((w) => w.$2 == '/production/milk-sales'), isEmpty);
    });

    testWidgets('more than the tank holds: the manager records it only when ticked', (tester) async {
      final farm = await open(tester, const MilkProductionScreen());
      await tester.tap(find.byKey(const ValueKey('sell-milk')));
      await settle(tester);
      await tester.enterText(find.byKey(const ValueKey('sell-liters')), '700');
      await tester.enterText(find.byKey(const ValueKey('sell-price')), '0.5');
      await settle(tester);
      expect(find.text('More than the tank holds'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Save sale'));
      await settle(tester);
      expect(farm.api.writes.where((w) => w.$2 == '/production/milk-sales'), isEmpty);
      await tester.tap(find.text('Record anyway — the milk was there'));
      await settle(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Save sale'));
      await settle(tester);
      expect(body(farm, '/production/milk-sales')['allow_negative'], isTrue);
    });

    testWidgets('a sale to be paid is marked paid; a mistaken one is cancelled with a reason', (tester) async {
      final farm = await open(tester, const MilkProductionScreen(), extra: {
        'GET /production/milk-sales?days=90': [sale('ms-1'), sale('ms-2', payment: 'paid')],
      });
      expect(find.byKey(const ValueKey('milk-sale-ms-1')), findsOneWidget);
      expect(find.text('To be paid'), findsOneWidget);
      expect(find.byKey(const ValueKey('mark-paid-ms-2')), findsNothing, reason: 'already paid');

      await tester.tap(find.byKey(const ValueKey('mark-paid-ms-1')));
      await settle(tester);
      expect(farm.api.writes.any((w) => w.$1 == 'POST' && w.$2 == '/production/milk-sales/ms-1/paid'), isTrue);

      await tester.tap(find.byKey(const ValueKey('cancel-sale-ms-2')));
      await settle(tester);
      await tester.enterText(find.widgetWithText(TextField, 'Why is this sale cancelled?'), 'typed twice');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await settle(tester);
      expect(body(farm, '/production/milk-sales/ms-2/cancel')['reason'], 'typed twice');
    });

    testWidgets('the manager counts the tank or takes milk out with a reason', (tester) async {
      final farm = await open(tester, const MilkProductionScreen());
      await tester.tap(find.byKey(const ValueKey('count-tank')));
      await settle(tester);
      await tester.enterText(find.byKey(const ValueKey('tank-liters')), '600');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await settle(tester);
      final count = body(farm, '/production/milk-tank/adjustments');
      expect(count['reason'], 'count');
      expect(count['counted_level'], 600);
      expect(count.containsKey('liters'), isFalse);

      await tester.tap(find.byKey(const ValueKey('count-tank')));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('tank-spoiled')));
      await settle(tester);
      await tester.enterText(find.byKey(const ValueKey('tank-liters')), '15');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await settle(tester);
      final spoiled = body(farm, '/production/milk-tank/adjustments');
      expect(spoiled['reason'], 'spoiled');
      expect(spoiled['liters'], 15);
    });

    testWidgets('an employee who records milk sees the tank but does not sell or count it', (tester) async {
      await open(tester, const MilkProductionScreen(), worker: true, extra: {
        'GET /production/milk-sales?days=90': [sale('ms-1')],
      });
      expect(find.byKey(const ValueKey('milk-tank-card')), findsOneWidget);
      expect(find.byKey(const ValueKey('milk-sale-ms-1')), findsOneWidget, reason: 'the sales are seen');
      expect(find.byKey(const ValueKey('sell-milk')), findsNothing);
      expect(find.text('Sell milk'), findsNothing, reason: 'nor on the band');
      expect(find.byKey(const ValueKey('count-tank')), findsNothing);
      expect(find.byKey(const ValueKey('mark-paid-ms-1')), findsNothing);
      expect(find.byKey(const ValueKey('cancel-sale-ms-1')), findsNothing);
    });

    testWidgets('Sales & Finance sells milk too and opens the Finance report', (tester) async {
      await open(tester, const SalesFinanceScreen());
      expect(find.byKey(const ValueKey('finance-sell-milk')), findsOneWidget);
      expect(find.byKey(const ValueKey('milk-tank-card')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('finance-sell-milk')));
      await settle(tester);
      expect(find.byKey(const ValueKey('sell-liters')), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('finance-report')));
      await settle(tester);
      expect(find.text('Finance report'), findsWidgets);
    });

    testWidgets('in Arabic', (tester) async {
      tester.view.physicalSize = const Size(1200, 2600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final farm = await SnapshotFarm.open();
      await tester.pumpWidget(farm.app(const Scaffold(body: MilkProductionScreen()), locale: const Locale('ar')));
      await settle(tester);
      expect(find.text('خزان الحليب والمبيع'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('sell-milk')));
      await settle(tester);
      expect(find.text('احفظ البيعة'), findsOneWidget);
    });
  });

  test('offline: a sale is shown at once and named in the waiting list', () {
    final sale = effectsFor('POST', '/production/milk-sales', {'liters': 40, 'price_per_liter': 0.5, 'payment_status': 'pending'}, localId: 'local-1');
    final row = sale.whereType<AppendRecord>().single;
    expect(row.collectionPath, '/production/milk-sales');
    expect(row.record['amount'], 20);
    expect(row.record['status'], 'recorded');
    final paid = effectsFor('POST', '/production/milk-sales/ms-1/paid', null, localId: 'local-2').whereType<MergeRecord>().single;
    expect((paid.id, paid.patch['payment_status']), ('ms-1', 'paid'));
    final cancelled = effectsFor('POST', '/production/milk-sales/ms-1/cancel', {'reason': 'typed twice'}, localId: 'local-3').whereType<MergeRecord>().single;
    expect(cancelled.patch, containsPair('status', 'cancelled'));
    expect(describeWrite('/production/milk-sales').labelKey, 'outboxMilkSale');
    expect(describeWrite('/production/milk-sales/ms-1/cancel').labelKey, 'outboxMilkSale');
    expect(describeWrite('/production/milk-tank/adjustments').labelKey, 'outboxMilkTank');
    expect(describeWrite('/production/milk').labelKey, 'outboxMilkRecord', reason: 'a milk record is still a milk record');
  });

  test('money and litres as the farm writes them', () {
    expect(money(66, 'USD'), '\$66.00');
    expect(money(1250, 'USD'), '\$1250');
    expect(money(12.5, 'LBP'), '12.50 LBP');
    expect(litres(617.3), '617.3');
    expect(litres(120), '120');
  });
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}
