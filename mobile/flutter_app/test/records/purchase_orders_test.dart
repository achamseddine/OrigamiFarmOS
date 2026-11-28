import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:farmos/data/local/cache_effects.dart';
import 'package:farmos/data/local/outbox_labels.dart';
import 'package:farmos/domain/entities/purchase_orders.dart';
import 'package:farmos/features/feed/tabs/buying_tab.dart';

import '../support/snapshot_farm.dart';

/// Buying feed (master prompt Package 2), the same page on the tablet and
/// the web: suppliers' prices cheapest first, an order placed, a delivery
/// received against it with a rejection, and the order's match.
void main() {
  Map<String, dynamic> order({String status = 'approved', double received = 0, double rejected = 0}) => {
        'id': 'po-1', 'po_no': 'PO-000001', 'supplier_id': 'sup-zahle', 'supplier_name': 'Zahle Feeds', 'status': status, 'currency': 'USD',
        'payment_terms': 'credit', 'total_amount': 460.0, 'order_date': '2026-11-26T06:00:00+00:00',
        'lines': [
          {'id': 'pol-1', 'line_no': 1, 'feed_product_id': 'fp-barley', 'name': 'Barley', 'ordered_quantity': 1000, 'unit': 'kg', 'unit_price': 0.46,
           'line_total': 460.0, 'received_quantity': received, 'accepted_quantity': received - rejected, 'rejected_quantity': rejected,
           'remaining_quantity': 1000 - received, 'status': received > 0 ? 'partially_received' : 'open'},
        ],
      };
  final quotes = [
    {'id': 'q2', 'supplier_id': 'sup-zahle', 'supplier_name': 'Zahle Feeds', 'unit_price': 0.46, 'currency': 'USD', 'purchase_uom': 'kg', 'unit_price_usd': 0.46},
    {'id': 'q1', 'supplier_id': 'sup-bekaa', 'supplier_name': 'Bekaa Grain Co.', 'unit_price': 0.5, 'currency': 'USD', 'purchase_uom': 'kg', 'unit_price_usd': 0.5},
  ];

  test('an order reads what came, what was rejected and what is still to come', () {
    final o = PurchaseOrder.fromJson(order(status: 'partially_received', received: 600, rejected: 20));
    expect([o.isOpen, o.isDraft, o.anythingReceived], [true, false, true]);
    final l = o.lines.single;
    expect([l.receivedQuantity, l.acceptedQuantity, l.rejectedQuantity, l.remainingQuantity, l.unitPrice], [600, 580, 20, 400, 0.46]);
    final m = OrderMatch.fromJson({'state': 'delivered_awaiting_payment', 'currency': 'USD', 'lines': [], 'problems': [],
      'totals': {'ordered_value': 460, 'accepted_value': 450.8, 'billed': 450.8, 'paid': 0, 'owed': 450.8}});
    expect([m.state, m.totals['owed']], ['delivered_awaiting_payment', 450.8]);
  });

  test('an order made offline shows at once; deliveries wait for the server', () {
    final add = effectsFor('POST', '/procurement/purchase-orders', {
      'supplier_id': 'sup-zahle', 'approve': true, 'lines': [{'feed_product_id': 'fp-barley', 'quantity': 1000, 'unit_price': 0.46}],
    }, localId: 'local-po').whereType<AppendRecord>().single;
    expect([add.collectionPath, add.record['status'], add.record['total_amount']], ['/procurement/purchase-orders', 'approved', 460.0]);
    expect(effectsFor('POST', '/procurement/purchase-orders/po-1/receive', const {}, localId: 'x'), isEmpty);
    expect(describeWrite('/procurement/purchase-orders/po-1/receive').labelKey, 'outboxPurchaseOrder');
  });

  testWidgets('a delivery received against the order, 20 kg rejected as wet, sends what came and why', (tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final farm = await SnapshotFarm.open();
    farm.api.snapshot['GET /procurement/purchase-orders'] = [order()];
    farm.api.snapshot['GET /procurement/supplier-items'] = quotes;
    await tester.pumpWidget(farm.app(const Scaffold(body: BuyingTab())));
    await settle(tester);

    expect(find.text('PO-000001 · Zahle Feeds'), findsOneWidget);
    expect(find.textContaining('1000 kg to come'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('po-receive-po-1')));
    await settle(tester);
    await tester.enterText(find.byKey(const ValueKey('po-received-pol-1')), '600');
    await tester.enterText(find.byKey(const ValueKey('po-rejected-pol-1')), '20');
    await tester.tap(find.byKey(const ValueKey('po-receive-save')));
    await settle(tester);
    expect(find.text('Say why the rejected quantity was rejected.'), findsOneWidget, reason: 'a rejection says why');
    await tester.enterText(find.byKey(const ValueKey('po-reason-pol-1')), 'wet bags');
    await tester.enterText(find.byKey(const ValueKey('po-delivery-note')), 'DN-1');
    await tester.tap(find.byKey(const ValueKey('po-receive-save')));
    await settle(tester);
    final sent = farm.api.writes.lastWhere((w) => w.$1 == 'POST' && w.$2 == '/procurement/purchase-orders/po-1/receive').$3! as Map;
    final line = (sent['lines'] as List).single as Map;
    expect([line['received_quantity'], line['rejected_quantity'], line['rejection_reason'], line['quality_grade'], sent['delivery_note_no']],
        [600, 20, 'wet bags', 'good', 'DN-1']);
  });

  testWidgets('the match says what is still owed, and the suppliers\' prices are cheapest first', (tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final farm = await SnapshotFarm.open();
    farm.api.snapshot['GET /procurement/purchase-orders'] = [order(status: 'received', received: 1000, rejected: 20)];
    farm.api.snapshot['GET /procurement/purchase-orders/po-1/match'] = {
      'state': 'delivered_awaiting_payment', 'currency': 'USD', 'problems': [],
      'lines': [{'name': 'Barley', 'unit': 'kg', 'ordered': 1000, 'received': 1000, 'accepted': 980, 'rejected': 20}],
      'totals': {'ordered_value': 460.0, 'accepted_value': 450.8, 'billed': 450.8, 'paid': 366.8, 'owed': 84.0},
    };
    farm.api.snapshot['GET /procurement/supplier-items'] = quotes;
    await tester.pumpWidget(farm.app(const Scaffold(body: BuyingTab())));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('po-match-po-1')));
    await settle(tester);
    expect(find.text('Delivered — still owed'), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('po-match-owed')), matching: find.text('\$84.00')), findsOneWidget);
    await tester.tap(find.text('Close'));
    await settle(tester);

    await tester.tap(find.byKey(const ValueKey('quotes-feed')));
    await settle(tester);
    await tester.tap(find.text('Barley').last);
    await settle(tester);
    expect(find.byKey(const ValueKey('quote-row-sup-zahle')), findsOneWidget);
    final zahle = tester.getTopLeft(find.byKey(const ValueKey('quote-row-sup-zahle'))).dy;
    final bekaa = tester.getTopLeft(find.byKey(const ValueKey('quote-row-sup-bekaa'))).dy;
    expect(zahle < bekaa, isTrue, reason: 'cheapest first, as the server orders them');
    expect(find.text('Cheapest'), findsOneWidget);
  });
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}
