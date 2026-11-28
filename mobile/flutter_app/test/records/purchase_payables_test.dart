import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:farmos/data/local/cache_effects.dart';
import 'package:farmos/data/local/outbox_labels.dart';
import 'package:farmos/domain/entities/finance.dart';
import 'package:farmos/features/finance/sales_finance_screen.dart';

import '../support/snapshot_farm.dart';

/// Purchases in the books (audit I-9, I-14), the same page on the tablet
/// and the web: a delivery's bill is for what was accepted; on credit it is
/// owed, not paid; a part payment leaves the rest owed.
void main() {
  Map<String, dynamic> bill(String id, {String payment = 'pending', double paid = 0, double? due}) => {
        'id': id, 'category': 'feed', 'description': 'Corn grain: 480 kg accepted', 'amount': 240, 'currency': 'USD',
        'incurred_at': DateTime.now().toUtc().subtract(const Duration(days: 2)).toIso8601String(), 'supplier_name': 'Bekaa Grain Co.',
        'payment_status': payment, 'status': 'recorded', 'reference': 'INV-1001', 'amount_paid': paid,
        'balance_due': due ?? (240 - paid), 'stock_purchase': true, 'lot_type': 'feed_lot', 'lot_id': 'lot-corn-1',
      };

  test('a bill paid in part owes its balance, not its amount', () {
    final e = FinanceExpense.fromJson(bill('b1', payment: 'partial', paid: 100));
    expect([e.toPay, e.partlyPaid, e.owed, e.amountPaid, e.stockPurchase, e.lotId], [true, true, 140, 100, true, 'lot-corn-1']);
    expect(FinanceExpense.fromJson(bill('b2', payment: 'paid', paid: 240, due: 0)).toPay, isFalse);
  });

  test('a payment made offline shows the bill paid in part until the server has it', () {
    final merge = effectsFor('POST', '/finance/expenses/b1/payments', {'amount': 100}, localId: 'x').whereType<MergeRecord>().single;
    expect([merge.collectionPath, merge.id, merge.patch['payment_status']], ['/finance/expenses', 'b1', 'partial']);
    expect(describeWrite('/finance/expenses/b1/payments').labelKey, 'outboxExpense');
  });

  testWidgets('a bill is paid in part: the dialog offers what is still owed and sends the part', (tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final farm = await SnapshotFarm.open();
    farm.api.snapshot['GET /finance/expenses?days=365'] = [bill('b1', payment: 'partial', paid: 100)];
    await tester.pumpWidget(farm.app(const Scaffold(body: SalesFinanceScreen(initialTab: FinanceTab.expenses))));
    await settle(tester);

    expect(find.textContaining('Still owed'), findsWidgets);
    expect(find.textContaining('Stock bought'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('finance-expense-pay-b1')));
    await settle(tester);
    final field = tester.widget<TextField>(find.byKey(const ValueKey('pay-bill-amount')));
    expect(field.controller!.text, '140.00', reason: 'what is still owed');
    await tester.enterText(find.byKey(const ValueKey('pay-bill-amount')), '40');
    await tester.tap(find.byKey(const ValueKey('pay-bill-save')));
    await settle(tester);
    final sent = farm.api.writes.lastWhere((w) => w.$1 == 'POST' && w.$2 == '/finance/expenses/b1/payments').$3! as Map;
    expect([sent['amount'], sent['currency']], [40, 'USD']);
  });

  testWidgets('in Arabic too', (tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final farm = await SnapshotFarm.open();
    farm.api.snapshot['GET /finance/expenses?days=365'] = [bill('b1', payment: 'partial', paid: 100)];
    await tester.pumpWidget(farm.app(const Scaffold(body: SalesFinanceScreen(initialTab: FinanceTab.expenses)), locale: const Locale('ar')));
    await settle(tester);
    expect(find.textContaining('بيضل دين'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}
