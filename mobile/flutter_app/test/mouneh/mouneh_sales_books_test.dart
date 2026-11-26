import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:farmos/data/local/cache_effects.dart';
import 'package:farmos/data/local/outbox_labels.dart';
import 'package:farmos/domain/entities/finance.dart';
import 'package:farmos/domain/entities/mouneh.dart';
import 'package:farmos/features/mouneh/sales_profitability_tab.dart';
import 'package:farmos/providers/mouneh_provider.dart';

import '../support/snapshot_farm.dart';

/// Mouneh sales in the farm's books (audit I-8), the same on the tablet and
/// the web: a sale is paid now, owed by a named buyer, or paid in part; it
/// is sent with the moment it was made (so one that waited offline keeps its
/// day); a manager cancels it and its jars go back on the shelf.
void main() {
  Map<String, dynamic> line(String id,
          {String payment = 'paid', String status = 'recorded', double paid = 7, double due = 0, bool farmShop = false}) =>
      {
        'id': id, 'farm_id': 'farm-origami', 'product_id': 'prod-makdous', 'batch_id': 'batch-makdous-001',
        'finished_goods_stock_id': 'stock-makdous-001', 'quantity': 1, 'unit_price': 7, 'discount': 0, 'channel': 'retail',
        'cost_per_unit': 3.69, 'revenue': 7, 'margin': 3.31, 'cost_of_goods': 3.69, 'sold_at': DateTime.now().toUtc().toIso8601String(),
        'status': status, 'sale_id': 'sale-$id', 'farm_shop': farmShop, 'payment_status': payment, 'amount_paid': paid,
        'balance_due': due, if (payment != 'paid') 'buyer_name': 'Um Ali', 'currency': 'USD',
      };

  Map lastPost(SnapshotApi api, String path) => api.writes.lastWhere((w) => w.$1 == 'POST' && w.$2 == path).$3! as Map;

  group('recording a Mouneh sale', () {
    test('a sale paid now is sent with the moment it was made, in UTC', () async {
      final api = SnapshotApi(loadSnapshot());
      final mouneh = MounehProvider(apiClient: api);
      final made = DateTime(2026, 11, 24, 18, 30);
      final result = await mouneh.recordSale(productId: 'prod-makdous', quantity: 1, unitPrice: 7, soldAt: made);
      expect(result.success, isTrue);
      final body = lastPost(api, '/mouneh/sales');
      expect(body['payment_status'], 'paid');
      expect(body['sold_at'], made.toUtc().toIso8601String(), reason: 'kept when it waits offline and is sent later');
      expect(body.containsKey('amount_paid'), isFalse);
    });

    test('owed and part paid need the buyer; a part is more than nothing and less than the sale', () async {
      final api = SnapshotApi(loadSnapshot());
      final mouneh = MounehProvider(apiClient: api);
      expect((await mouneh.recordSale(productId: 'prod-makdous', quantity: 1, unitPrice: 7, paymentStatus: 'pending')).error, 'mnSaleNeedsBuyer');
      expect((await mouneh.recordSale(productId: 'prod-makdous', quantity: 1, unitPrice: 7, paymentStatus: 'partial', buyerName: 'Um Ali')).error,
          'mnSalePartInvalid');
      expect(
          (await mouneh.recordSale(productId: 'prod-makdous', quantity: 1, unitPrice: 7, paymentStatus: 'partial', amountPaid: 7, buyerName: 'Um Ali'))
              .error,
          'mnSalePartInvalid');
      expect((await mouneh.recordSale(productId: 'prod-makdous', quantity: 1, unitPrice: 5, discount: 5)).error, 'mnSaleForNothing');
      expect(api.writes.where((w) => w.$2 == '/mouneh/sales'), isEmpty, reason: 'nothing sent that the server would refuse');

      final ok = await mouneh.recordSale(
          productId: 'prod-makdous', quantity: 1, unitPrice: 7, paymentStatus: 'partial', amountPaid: 4, buyerName: ' Um Ali ');
      expect(ok.success, isTrue);
      final body = lastPost(api, '/mouneh/sales');
      expect([body['payment_status'], body['amount_paid'], body['buyer_name']], ['partial', 4, 'Um Ali']);
    });

    test('a cancellation says why, and goes to the Mouneh sale', () async {
      final api = SnapshotApi(loadSnapshot());
      final mouneh = MounehProvider(apiClient: api);
      expect((await mouneh.cancelSale('line-1', '  ')).error, 'mnCancelWhyRequired');
      expect((await mouneh.cancelSale('line-1', 'Brought back')).success, isTrue);
      expect(lastPost(api, '/mouneh/sales/line-1/cancel'), {'reason': 'Brought back'});
      expect(describeWrite('/mouneh/sales/line-1/cancel').labelKey, 'outboxSale');
    });
  });

  group('what the books say', () {
    test('a cancelled sale sold nothing: out of revenue, profit and what is owed', () async {
      final api = SnapshotApi(loadSnapshot());
      api.snapshot['GET /mouneh/sales'] = [
        line('a'),
        line('b', payment: 'partial', paid: 4, due: 3),
        line('c', status: 'cancelled', paid: 0),
      ];
      final mouneh = MounehProvider(apiClient: api);
      await mouneh.load();
      expect(mouneh.totalRevenue, 14);
      expect(mouneh.totalOwed, 3);
      expect(mouneh.profitabilityFor('prod-makdous').totalRevenue, 14);
      expect(mouneh.sales.where((s) => s.cancelled).single.id, 'c');
    });

    test('a sale waiting to be sent reads from what was typed', () {
      final sale = MounehSale.fromJson({
        'id': 'local-1', 'product_id': 'prod-makdous', 'quantity': 2, 'unit_price': 6.5, 'discount': 1, 'channel': 'retail',
        'sold_at': '2026-11-24T16:30:00.000Z', 'payment_status': 'partial', 'amount_paid': 5, '_pending': true,
      });
      expect([sale.revenue, sale.amountPaid, sale.balanceDue, sale.pending], [12, 5, 7, true]);
      expect(sale.soldAt, DateTime.utc(2026, 11, 24, 16, 30));
    });

    test('offline, a cancelled sale shows cancelled and nothing owed until the server has it', () {
      final effects = effectsFor('POST', '/mouneh/sales/line-1/cancel', {'reason': 'Brought back'}, localId: 'x');
      final merge = effects.whereType<MergeRecord>().single;
      expect([merge.collectionPath, merge.id], ['/mouneh/sales', 'line-1']);
      expect(merge.patch, containsPair('status', 'cancelled'));
      expect(merge.patch, containsPair('balance_due', 0));
    });

    test('Sales & Finance owes the balance of a sale paid in part, not the whole sale', () {
      final s = FinanceSale.fromJson({
        'id': 's1', 'product_type': 'mouneh', 'amount': 7, 'payment_status': 'partial', 'sold_at': '2026-11-24T16:30:00Z',
        'status': 'recorded', 'amount_paid': 4, 'balance_due': 3, 'mouneh_sale_id': 'line-1',
      });
      expect([s.owed, s.due, s.amountPaid, s.partlyPaid, s.mounehSaleId], [true, 3, 4, true, 'line-1']);
      final cancelled = FinanceSale.fromJson({'id': 's2', 'product_type': 'mouneh', 'amount': 7, 'payment_status': 'pending', 'status': 'cancelled'});
      expect(cancelled.owed, isFalse);
    });
  });

  group('the Mouneh sales tab', () {
    testWidgets('payment choice, the buyer, and a manager can cancel a sale (not a farm-shop jar)', (tester) async {
      tester.view.physicalSize = const Size(1400, 2600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final farm = await SnapshotFarm.open();
      farm.api.snapshot['GET /mouneh/sales'] = [line('a'), line('b', payment: 'partial', paid: 4, due: 3), line('shop', farmShop: true)];
      await tester.pumpWidget(farm.app(const Scaffold(body: SingleChildScrollView(child: SalesProfitabilityTab()))));
      await settle(tester);

      expect(find.byKey(const ValueKey('mouneh-sale-payment')), findsOneWidget);
      expect(find.byKey(const ValueKey('mouneh-sale-buyer')), findsOneWidget);
      expect(find.byKey(const ValueKey('mouneh-sale-amount-paid')), findsNothing, reason: 'asked only for a part payment');
      expect(find.text('Part paid'), findsWidgets);
      expect(find.textContaining('Owed \$3.00'), findsOneWidget);
      expect(find.byKey(const ValueKey('mouneh-sale-cancel-a')), findsOneWidget);
      expect(find.byKey(const ValueKey('mouneh-sale-cancel-shop')), findsNothing, reason: 'a farm-shop jar is cancelled in Farm visits');

      await tester.tap(find.byKey(const ValueKey('mouneh-sale-payment')));
      await settle(tester);
      await tester.tap(find.text('Part paid').last);
      await settle(tester);
      expect(find.byKey(const ValueKey('mouneh-sale-amount-paid')), findsOneWidget);
    });

    testWidgets('in Arabic too', (tester) async {
      tester.view.physicalSize = const Size(1400, 2600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final farm = await SnapshotFarm.open();
      farm.api.snapshot['GET /mouneh/sales'] = [line('b', payment: 'partial', paid: 4, due: 3)];
      await tester.pumpWidget(farm.app(const Scaffold(body: SingleChildScrollView(child: SalesProfitabilityTab())), locale: const Locale('ar')));
      await settle(tester);
      expect(find.text('مدفوع قسم منها'), findsWidgets);
      expect(find.textContaining('دين'), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  });
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}
