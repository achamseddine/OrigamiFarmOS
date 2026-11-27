import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:farmos/domain/entities/access.dart';
import 'package:farmos/domain/entities/nutrition.dart';
import 'package:farmos/features/feed/tabs/least_cost.dart';
import 'package:farmos/features/feed/tabs/nutrition_tab.dart';

import '../support/snapshot_farm.dart';

/// Least-cost drafts (master prompt Package 12) on the tablet and the web:
/// the runs, their three drafts at today's prices, infeasible and
/// insufficient data said plainly, and the manager's approval of one draft.
void main() {
  final requirementSet = {
    'id': 'rs-1', 'code': 'DAIRY-EARLY', 'version': 1, 'name': 'Early lactation', 'species_code': 'cow', 'source_type': 'nutritionist',
    'source_reference': 'Farm nutritionist 2026-09', 'status': 'active',
    'values': [{'nutrient_code': 'CP', 'name': 'Crude protein', 'name_ar': 'البروتين الخام', 'min_value': 15, 'max_value': 18, 'unit': '%'}],
  };
  Map<String, dynamic> draft(String key, String label, double cost, {double? changed}) => {
        'key': key, 'label': label, 'batch_kg': 1210, 'total_kg': 1210, 'cost': cost, 'cost_per_kg': cost / 1210, 'saving': 420.0 - cost,
        'changed_kg': changed,
        'components': [
          {'name': 'Corn grain', 'quantity_kg': 420.0, 'inclusion_pct': 34.71, 'price_per_kg': 0.30, 'cost': 126.0},
          {'name': 'Soybean meal', 'quantity_kg': 300.5, 'inclusion_pct': 24.83, 'price_per_kg': 0.62, 'cost': 186.31},
          {'name': 'Wheat bran', 'quantity_kg': 489.5, 'inclusion_pct': 40.45, 'price_per_kg': 0.22, 'cost': 107.69},
        ],
        'nutrients': [{'nutrient_code': 'CP', 'name': 'Crude protein', 'name_ar': 'البروتين الخام', 'unit': '%', 'min_value': 15, 'max_value': 18, 'value': 15.02, 'status': 'met'}],
      };
  final drafts = {
    'id': 'run-1', 'status': 'drafts', 'created_at': '2026-11-27T08:00:00Z', 'batch_size_kg': 1210,
    'base': {'formula_name': 'Base concentrate', 'version': 1, 'cost_today': 420.0},
    'requirement_set': {'code': 'DAIRY-EARLY', 'version': 1},
    'drafts': [draft('A', 'least_cost', 400.0), draft('B', 'with_margin', 405.5), draft('C', 'least_change', 410.2, changed: 96.4)],
    'infeasible': [], 'missing': [], 'approval': null,
  };

  Future<SnapshotFarm> open(WidgetTester tester, {Map<String, Object?>? access, Locale locale = const Locale('en'), List<Object?>? runs}) async {
    tester.view.physicalSize = const Size(1200, 3600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final farm = await SnapshotFarm.open();
    if (access != null) farm.api.snapshot['GET /me/access'] = access;
    farm.api.snapshot.addAll({
      'GET /nutrition/requirement-sets': [requirementSet],
      'GET /nutrition/assessments': <Object?>[],
      'GET /nutrition/least-cost': runs ?? [drafts],
    });
    await tester.pumpWidget(farm.app(const Scaffold(body: SingleChildScrollView(child: NutritionTab())), locale: locale));
    await settle(tester);
    return farm;
  }

  Map body(SnapshotFarm farm, String path) => farm.api.writes.lastWhere((w) => w.$1 == 'POST' && w.$2 == path).$3! as Map;

  Future<void> pick(WidgetTester tester, String key, String label) async {
    await tester.tap(find.byKey(ValueKey(key)));
    await settle(tester);
    await tester.tap(find.text(label).last);
    await settle(tester);
  }

  testWidgets('a run and its three drafts, costed against today\'s formula', (tester) async {
    await open(tester);
    expect(find.text('Base concentrate v1 · DAIRY-EARLY v1'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('lc-r-run-1')));
    await settle(tester);
    expect(find.text("Today's formula costs \$420.00 at today's prices."), findsOneWidget);
    expect(find.text('A · the cheapest'), findsOneWidget);
    expect(find.text('B · with a safety margin'), findsOneWidget);
    expect(find.text("C · closest to today's formula"), findsOneWidget);
    expect(find.text('Saves \$20.00 a batch'), findsOneWidget);
    expect(find.text("96.4 kg changed from today's formula"), findsOneWidget);
    expect(find.text('420 kg · 34.71 % · \$126.00'), findsNWidgets(3));
    expect(find.byKey(const ValueKey('lc-approve-A')), findsOneWidget);
  });

  testWidgets('the manager approves one draft, with a reason', (tester) async {
    final farm = await open(tester);
    await tester.tap(find.byKey(const ValueKey('lc-r-run-1')));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('lc-approve-A')));
    await settle(tester);
    expect(find.text('Approve draft A'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, 'Reviewed with the nutritionist');
    await tester.tap(find.text('Save').last);
    await settle(tester);
    expect(body(farm, '/nutrition/least-cost/run-1/approve'), {'draft': 'A', 'note': 'Reviewed with the nutritionist'});
  });

  testWidgets('a draft approved shows so, and cannot be approved again', (tester) async {
    await open(tester, runs: [{...drafts, 'approval': {'draft': 'A', 'note': 'Nutritionist OK'}}]);
    await tester.tap(find.byKey(const ValueKey('lc-r-run-1')));
    await settle(tester);
    expect(find.text('Draft A approved: Nutritionist OK'), findsOneWidget);
    expect(find.byKey(const ValueKey('lc-approve-B')), findsNothing);
  });

  testWidgets('finding drafts sends the formula, the requirements and the ration', (tester) async {
    final farm = await open(tester);
    await tester.tap(find.byKey(const ValueKey('lc-run')));
    await settle(tester);
    await pick(tester, 'lc-formula', 'Dairy Mix 24L v2 · 1,000 kg');
    await pick(tester, 'lc-set', 'DAIRY-EARLY v1 · Early lactation');
    await tester.enterText(find.byKey(const ValueKey('lc-conc')), '9');
    await pick(tester, 'lc-forage', 'Corn Silage');
    await tester.enterText(find.byKey(const ValueKey('lc-forage-kg')), '38');
    await tester.enterText(find.byKey(const ValueKey('lc-weight')), '640');
    await tester.tap(find.byKey(const ValueKey('lc-save')));
    await settle(tester);
    final sent = body(farm, '/nutrition/least-cost');
    expect(sent['base_formula_version_id'], '2298d8a1-8789-48f2-a105-1eaf8f553e7d');
    expect(sent['requirement_set_id'], 'rs-1');
    expect(sent['concentrate_kg_per_head'], 9);
    expect(sent['forages'], [{'feed_product_id': 'fp-corn-silage', 'as_fed_kg': 38}]);
    expect(sent['margin_pct'], 3);
  });

  testWidgets('infeasible and insufficient data are said, and nothing is offered to approve', (tester) async {
    final infeasible = LeastCostRun.fromJson({...drafts, 'id': 'run-2', 'status': 'infeasible', 'drafts': <Object?>[],
        'infeasible': [{'nutrient_code': 'CA', 'detail': 'Calcium ≥ 0.6: not reachable with these ingredients and limits.'}]});
    final unknown = LeastCostRun.fromJson({...drafts, 'id': 'run-3', 'status': 'insufficient_data', 'drafts': <Object?>[],
        'missing': [{'code': 'price_unknown', 'detail': 'Beet pulp has no price: it cannot be costed.'}]});
    await open(tester);
    showLeastCostResult(tester.element(find.byType(NutritionTab)), infeasible);
    await settle(tester);
    expect(find.text('Cannot be met with these ingredients and limits'), findsOneWidget);
    expect(find.textContaining('Calcium ≥ 0.6'), findsOneWidget);
    expect(find.byKey(const ValueKey('lc-approve-A')), findsNothing);
    await tester.tap(find.text('Close'));
    await settle(tester);
    showLeastCostResult(tester.element(find.byType(NutritionTab)), unknown);
    await settle(tester);
    expect(find.textContaining('Beet pulp has no price'), findsOneWidget);
    expect(find.text('No draft is made on unknowns.'), findsOneWidget);
  });

  testWidgets('who only views the feed reads the drafts and approves nothing', (tester) async {
    await open(tester, access: {'user_id': 'user-view', 'role': 'worker', 'full_access': false, 'modules': {FarmModule.feedNutrition: {'view': true}}});
    expect(find.byKey(const ValueKey('lc-run')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('lc-r-run-1')));
    await settle(tester);
    expect(find.text('A · the cheapest'), findsOneWidget);
    expect(find.byKey(const ValueKey('lc-approve-A')), findsNothing);
  });

  testWidgets('in Arabic', (tester) async {
    await open(tester, locale: const Locale('ar'));
    expect(find.text('مسودّات بأقلّ كلفة'), findsOneWidget);
    expect(find.text('مسودّات'), findsWidgets);
  });
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}
