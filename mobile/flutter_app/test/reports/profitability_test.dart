import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:farmos/features/reports/report_docs.dart';
import 'package:farmos/features/reports/reports_screen.dart';

import '../support/snapshot_farm.dart';

/// Cow profitability (master prompt Package 3), the same page on the tablet
/// and the web: each cow's milk (AM, PM, saleable), its value, her feed and
/// its cost per litre, vet and medicine, labour and power, the margin — a
/// figure the records cannot give shown as unavailable, never as 0.
void main() {
  testWidgets('the demo farm\'s cows, one by one, with how costs are shared', (tester) async {
    tester.view.physicalSize = const Size(1400, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final farm = await SnapshotFarm.open();
    await tester.pumpWidget(farm.app(const Scaffold(body: ReportsScreen(initialKind: 'profitability'))));
    await settle(tester);
    expect(find.text('Cow profitability'), findsWidgets);
    expect(find.text('Each cow'), findsOneWidget);
    expect(find.text('Adds up to the records'), findsOneWidget);
    expect(find.text('How costs are shared'), findsOneWidget);
    expect(find.textContaining('Bella'), findsWidgets);
  });

  testWidgets('no milk price: the value and the margin say unavailable, not 0', (tester) async {
    late Map<String, dynamic> built;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) {
      final doc = buildReportDoc(context, 'profitability', {
        'start': '2026-11-01', 'end': '2026-11-07', 'days': 7, 'currency': 'USD',
        'milk_price': {'price_per_liter': null, 'basis': 'unavailable'},
        'totals': {'total_l': 60.0, 'saleable_l': 54.0, 'milk_value': null, 'feed_cost': 16.0, 'known_costs': 43.0, 'margin': null},
        'unallocated': {'labour': 0.0, 'power': 10.0},
        'animals': [
          {'tag': 'P31', 'name': 'Rosa', 'am_l': 30.0, 'pm_l': 30.0, 'saleable_l': 54.0, 'milk_value': null, 'feed_cost': 16.0,
           'feed_cost_per_liter': 0.267, 'medicine_cost': 0.0, 'vet_expenses': 12.0, 'labour_cost': 15.0, 'power_cost': 0.0, 'margin': null,
           'unknown': ['milk_price']},
        ],
        'reconciliation': {'milk_l': {'canonical': 60.0, 'attributed': 60.0}},
        'rules': {'milk_value': 'x'},
      }, speciesName: (c) => c);
      built = {'kpis': doc.kpis, 'row': doc.tables.first.rows.single};
      return const SizedBox();
    })));
    final kpis = {for (final (label, value) in built['kpis'] as List<(String, String)>) label: value};
    expect(kpis['Milk value'], 'unavailable (no milk price)');
    expect(kpis['Margin'], 'unavailable (no milk price)');
    final row = built['row'] as List<String>;
    expect(row[4], '—', reason: 'her milk value is unknown, not 0');
    expect(row[9], '—');
    expect(row.last, contains('no milk price'));
    expect(row[7], '\$12.00', reason: 'vet and medicine together');
  });
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}
