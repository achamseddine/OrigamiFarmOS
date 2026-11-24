import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:farmos/data/local/cache_effects.dart';
import 'package:farmos/data/local/outbox_labels.dart';
import 'package:farmos/features/finance/finance_forms.dart';
import 'package:farmos/features/finance/sales_finance_screen.dart';
import 'package:farmos/providers/finance_provider.dart';

import '../support/snapshot_farm.dart';

/// Origami's financials (v0.8.0), the same page on the tablet and the web:
/// any sale and any expense or bill in USD or LBP at the farm's rate (or
/// the rate used), mark paid, cancel with a reason, who owes what, profit
/// and loss.
void main() {
  const me = 'user-ali-demo';
  const rates = {
    'base': 'USD',
    'currencies': ['USD', 'LBP'],
    'current': {'LBP': {'id': 'r1', 'currency': 'LBP', 'rate_per_usd': 89500, 'effective_date': '2026-11-01'}},
    'history': [{'id': 'r1', 'currency': 'LBP', 'rate_per_usd': 89500, 'effective_date': '2026-11-01'}],
  };
  Map<String, dynamic> sale(String id, {String payment = 'pending', String status = 'recorded', double amount = 60, String? buyer = 'Abu Karim shop'}) => {
        'id': id, 'product_type': 'eggs', 'product_label': 'Eggs', 'quantity': 10, 'unit': 'tray', 'unit_price': 6, 'amount': amount,
        'currency': 'USD', 'payment_status': payment, 'sold_at': DateTime.now().toUtc().toIso8601String(), 'buyer_name': buyer, 'status': status,
      };
  Map<String, dynamic> expense(String id, {String payment = 'pending', int dueInDays = -3}) => {
        'id': id, 'category': 'veterinary', 'description': 'Dr. Haddad visit', 'amount': 150, 'currency': 'USD',
        'incurred_at': DateTime.now().toUtc().subtract(const Duration(days: 10)).toIso8601String(), 'supplier_name': 'Dr. Haddad',
        'payment_status': payment, 'due_date': DateTime.now().toUtc().add(Duration(days: dueInDays)).toIso8601String(), 'status': 'recorded',
      };

  Future<SnapshotFarm> open(WidgetTester tester, Widget home, {Map<String, Object?> extra = const {}, Map<String, Object?>? access}) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final farm = await SnapshotFarm.open();
    if (access != null) farm.api.snapshot['GET /me/access'] = access;
    farm.api.snapshot.addAll({'GET /finance/exchange-rates': rates, ...extra});
    await tester.pumpWidget(farm.app(Scaffold(body: home)));
    await settle(tester);
    return farm;
  }

  Map body(SnapshotFarm farm, String path) => farm.api.writes.lastWhere((w) => w.$1 == 'POST' && w.$2 == path).$3! as Map;

  Future<void> tab(WidgetTester tester, String label) async {
    await tester.tap(find.widgetWithText(InkWell, label).first);
    await settle(tester);
  }

  group('the Sales & Finance page', () {
    testWidgets('one page with its tabs, the rate on the band', (tester) async {
      await open(tester, const SalesFinanceScreen());
      for (final t in ['Today', 'Sales', 'Expenses & bills', 'Who owes what', 'Profit & loss']) {
        expect(find.text(t), findsWidgets, reason: t);
      }
      expect(find.byKey(const ValueKey('finance-hero-sale')), findsOneWidget);
      expect(find.byKey(const ValueKey('finance-hero-expense')), findsOneWidget);
      expect(find.byKey(const ValueKey('finance-sell-milk')), findsOneWidget);
      expect(find.text('1 USD = 89,500 LBP'), findsOneWidget);
    });

    testWidgets('an employee without money sees today only, records nothing', (tester) async {
      await open(tester, const SalesFinanceScreen(), access: {
        'user_id': me, 'role': 'worker', 'full_access': false,
        'modules': {'milk_production': {'view': true, 'create': true}, 'morning_operations': {'view': true}},
      });
      expect(find.text('Who owes what'), findsNothing);
      expect(find.byKey(const ValueKey('finance-hero-sale')), findsNothing);
      expect(find.byKey(const ValueKey('finance-hero-expense')), findsNothing);
    });

    testWidgets('a sale to be paid is marked paid; another is cancelled with a reason', (tester) async {
      final farm = await open(tester, const SalesFinanceScreen(initialTab: FinanceTab.sales), extra: {
        'GET /finance/sales?days=365': [sale('s1'), sale('s2', payment: 'paid')],
      });
      expect(find.byKey(const ValueKey('finance-sale-s1')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('finance-sale-paid-s1')));
      await settle(tester);
      expect(farm.api.writes.any((w) => w.$2 == '/finance/sales/s1/paid'), isTrue);
      await tester.tap(find.byKey(const ValueKey('finance-sale-cancel-s2')));
      await settle(tester);
      await tester.enterText(find.widgetWithText(TextField, 'Why is this sale cancelled?'), 'typed twice');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await settle(tester);
      expect(body(farm, '/finance/sales/s2/cancel')['reason'], 'typed twice');
    });

    testWidgets('who owes what: customers and bills, overdue first', (tester) async {
      await open(tester, const SalesFinanceScreen(initialTab: FinanceTab.owed), extra: {
        'GET /finance/sales?days=365': [sale('s1'), sale('s3', amount: 40, buyer: 'Hotel Massabki')],
        'GET /finance/expenses?days=365': [expense('e1')],
      });
      expect(find.text(r'$100.00'), findsWidgets, reason: 'customers owe 60 + 40');
      expect(find.text(r'$150.00'), findsWidgets, reason: 'the farm owes the vet');
      expect(find.byKey(const ValueKey('finance-expense-paid-e1')), findsOneWidget);
      expect(find.text('Overdue'), findsWidgets);
    });

    testWidgets('profit and loss from the server', (tester) async {
      await open(tester, const SalesFinanceScreen(initialTab: FinanceTab.profitLoss));
      expect(find.byKey(const ValueKey('pl-profit')), findsOneWidget);
      expect(find.text('Month by month'), findsOneWidget);
      expect(find.text('Where the money went'), findsOneWidget);
    });
  });

  group('recording money', () {
    Widget opener(void Function(BuildContext) open) => Builder(builder: (c) => Center(child: TextButton(onPressed: () => open(c), child: const Text('open'))));

    testWidgets('eggs sold in USD, to be paid', (tester) async {
      final farm = await open(tester, opener((c) => showRecordSaleDialog(c)));
      final finance = tester.element(find.text('open')).read<FinanceProvider>();
      await finance.load();
      await tester.tap(find.text('open'));
      await settle(tester);
      await tester.enterText(find.byKey(const ValueKey('sale-quantity')), '10');
      await tester.enterText(find.byKey(const ValueKey('sale-price')), '6');
      await settle(tester);
      expect(find.text(r'Total: $60.00'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('sale-buyer')), 'Abu Karim shop');
      await tester.tap(find.byKey(const ValueKey('sale-pending')));
      await tester.ensureVisible(find.byKey(const ValueKey('sale-save')));
      await tester.tap(find.byKey(const ValueKey('sale-save')));
      await settle(tester);
      final sent = body(farm, '/finance/sales');
      expect((sent['product_type'], sent['product_label'], sent['quantity'], sent['unit'], sent['unit_price']), ('eggs', 'Eggs', 10, 'tray', 6));
      expect((sent['currency'], sent['payment_status'], sent['buyer_name']), ('USD', 'pending', 'Abu Karim shop'));
      expect(sent.containsKey('exchange_rate'), isFalse);
    });

    testWidgets('a sale in LBP at the farm\'s rate shows its USD', (tester) async {
      final farm = await open(tester, opener((c) => showRecordSaleDialog(c, type: 'produce')));
      await tester.element(find.text('open')).read<FinanceProvider>().load();
      await tester.tap(find.text('open'));
      await settle(tester);
      await tester.enterText(find.byKey(const ValueKey('sale-quantity')), '2');
      await tester.enterText(find.byKey(const ValueKey('sale-price')), '268500');
      await tester.tap(find.byKey(const ValueKey('currency-LBP')));
      await settle(tester);
      expect(find.text('In USD: \$6.00'), findsOneWidget, reason: '537,000 LBP at 89,500');
      await tester.ensureVisible(find.byKey(const ValueKey('sale-save')));
      await tester.tap(find.byKey(const ValueKey('sale-save')));
      await settle(tester);
      final sent = body(farm, '/finance/sales');
      expect((sent['product_type'], sent['currency'], sent['exchange_rate'], sent['unit_price']), ('produce', 'LBP', 89500, 268500));
    });

    testWidgets('a bill to pay by its due date; feed shows it is already counted', (tester) async {
      final farm = await open(tester, opener((c) => showRecordExpenseDialog(c)));
      await tester.tap(find.text('open'));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('expense-cat-feed')));
      await settle(tester);
      expect(find.byKey(const ValueKey('expense-stock-notice')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('expense-cat-veterinary')));
      await settle(tester);
      await tester.enterText(find.byKey(const ValueKey('expense-description')), 'Dr. Haddad visit');
      await tester.enterText(find.byKey(const ValueKey('expense-amount')), '150');
      await tester.enterText(find.byKey(const ValueKey('expense-supplier')), 'Dr. Haddad');
      await tester.ensureVisible(find.byKey(const ValueKey('expense-pending')));
      await tester.tap(find.byKey(const ValueKey('expense-pending')));
      await settle(tester);
      expect(find.byKey(const ValueKey('expense-due')), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('expense-save')));
      await tester.tap(find.byKey(const ValueKey('expense-save')));
      await settle(tester);
      final sent = body(farm, '/finance/expenses');
      expect((sent['category'], sent['amount'], sent['supplier_name'], sent['payment_status']), ('veterinary', 150, 'Dr. Haddad', 'pending'));
      expect(sent['due_date'], isNotNull);
    });

    testWidgets('the manager sets the LBP rate', (tester) async {
      final farm = await open(tester, opener((c) => showExchangeRateDialog(c)));
      await tester.element(find.text('open')).read<FinanceProvider>().load();
      await tester.tap(find.text('open'));
      await settle(tester);
      expect(find.text("Farm's rate: 1 USD = 89,500 LBP · since 1/11/2026"), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('exchange-rate-field')), '90000');
      await tester.tap(find.byKey(const ValueKey('exchange-rate-save')));
      await settle(tester);
      final sent = body(farm, '/finance/exchange-rates');
      expect((sent['currency'], sent['rate_per_usd']), ('LBP', 90000));
      expect(sent['effective_date'], isNotNull);
    });

    testWidgets('in Arabic', (tester) async {
      tester.view.physicalSize = const Size(1200, 2600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final farm = await SnapshotFarm.open();
      await tester.pumpWidget(farm.app(const Scaffold(body: SalesFinanceScreen()), locale: const Locale('ar')));
      await settle(tester);
      expect(find.text('سجّل بيعة'), findsWidgets);
      expect(find.text('الربح والخسارة'), findsWidgets);
    });
  });

  test('offline: an LBP sale shows in USD until the server answers; named in the waiting list', () {
    final fx = effectsFor('POST', '/finance/sales', {'product_type': 'eggs', 'quantity': 1, 'unit_price': 537000, 'currency': 'LBP', 'exchange_rate': 89500},
        localId: 'local-1');
    final row = fx.whereType<AppendRecord>().single.record;
    expect((row['amount'], row['original_amount'], row['original_currency'], row['status']), (6.0, 537000, 'LBP', 'recorded'));
    final bill = effectsFor('POST', '/finance/expenses', {'category': 'fuel', 'amount': 120, 'currency': 'USD'}, localId: 'local-2');
    expect(bill.whereType<AppendRecord>().single.record['amount'], 120);
    expect(effectsFor('POST', '/finance/expenses/e1/paid', null, localId: 'x').whereType<MergeRecord>().single.patch['payment_status'], 'paid');
    expect(describeWrite('/finance/sales').labelKey, 'outboxSale');
    expect(describeWrite('/finance/expenses/e1/cancel').labelKey, 'outboxExpense');
    expect(describeWrite('/finance/exchange-rates').labelKey, 'outboxExchangeRate');
  });

  test('LBP is written with thousands separators', () {
    expect(grouped(537000), '537,000');
    expect(grouped(89500), '89,500');
    expect(moneyWithOriginal(6, 537000, 'LBP'), r'$6.00 (537,000 LBP)');
    expect(moneyWithOriginal(60, null, null), r'$60.00');
  });
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}
