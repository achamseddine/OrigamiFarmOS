import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:farmos/data/local/outbox_labels.dart';
import 'package:farmos/domain/entities/access.dart';
import 'package:farmos/domain/entities/nutrition.dart';
import 'package:farmos/features/feed/tabs/nutrition_assessment.dart';
import 'package:farmos/features/feed/tabs/nutrition_tab.dart';

import '../support/snapshot_farm.dart';

/// Nutrient requirements and the assessment of a formula (master prompt
/// Package 11) on the tablet and the web: the requirement sets with their
/// source, a formula assessed with its ration and a premix on top, the
/// 1,210 kg base kept, insufficient data named, never a ration.
void main() {
  final requirementSet = {
    'id': 'rs-1', 'code': 'DAIRY-EARLY', 'version': 1, 'name': 'Early lactation, 650 kg', 'species_code': 'cow', 'production_stage': 'early_lactation',
    'reference_body_weight_kg': 650, 'expected_dmi_kg': 22, 'source_type': 'nutritionist', 'source_reference': 'Farm nutritionist 2026-09', 'status': 'active',
    'values': [
      {'nutrient_code': 'CP', 'name': 'Crude protein', 'name_ar': 'البروتين الخام', 'min_value': 16, 'max_value': 18, 'unit': '%'},
      {'nutrient_code': 'CA', 'name': 'Calcium', 'name_ar': 'الكالسيوم', 'min_value': 0.6, 'unit': '%'},
    ],
  };
  Map<String, dynamic> component(String name, double kg, {String? source = 'declared'}) => {
        'name': name, 'quantity_kg': kg, 'inclusion_pct': kg / 1222 * 100, 'dm_pct': source == null ? null : 88,
        'profile': source == null ? null : {'source_type': source, 'basis': 'as_fed'},
      };
  Map<String, dynamic> assessment({String status = 'does_not_meet', List<Map<String, dynamic>> missing = const [], String? recommendation}) => {
        'id': 'as-1', 'status': status, 'created_at': '2026-11-27T08:00:00Z', 'created_by_name': 'Rami',
        'mix': {
          'formula_name': 'Base concentrate', 'formula_version': 1, 'base_total_kg': 1210, 'total_kg': 1222,
          'premix': {'name': 'Cattle Dairy Premix', 'quantity_kg': 12, 'inclusion_pct': 0.98, 'profile': null},
          'components': [
            component('Corn grain', 350), component('Soybean meal', 260, source: status == 'insufficient_data' ? null : 'declared'),
            component('Barley grain', 200), component('Wheat bran', 200), component('Cottonseed', 100), component('Beet pulp', 100),
          ],
          'dry_matter_kg': 1076.2, 'dm_pct': 88.9,
          'nutrients': [{'nutrient_code': 'CP', 'name': 'Crude protein', 'name_ar': 'البروتين الخام', 'unit': '%', 'as_fed_value': 16.4, 'dry_matter_value': 18.4, 'coverage_pct': 100}],
        },
        'ration': {
          'dry_matter_intake_kg': 20.54, 'expected_dmi_kg': 22, 'intake_status': 'as_expected',
          'nutrients': [
            {'nutrient_code': 'CP', 'name': 'Crude protein', 'name_ar': 'البروتين الخام', 'unit': '%', 'min_value': 16, 'max_value': 18, 'value': 13.1,
             'status': status == 'insufficient_data' ? 'insufficient_data' : 'below'},
            {'nutrient_code': 'CA', 'name': 'Calcium', 'name_ar': 'الكالسيوم', 'unit': '%', 'min_value': 0.6, 'value': 0.21,
             'status': status == 'insufficient_data' ? 'insufficient_data' : 'below'},
          ],
        },
        'missing': missing,
        'recommendation': recommendation,
        'requirement_set': {'code': 'DAIRY-EARLY', 'version': 1, 'source_reference': 'Farm nutritionist 2026-09'},
      };

  Future<SnapshotFarm> open(WidgetTester tester, {Map<String, Object?>? access, Locale locale = const Locale('en'), Map<String, Object?> extra = const {}}) async {
    tester.view.physicalSize = const Size(1200, 3200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final farm = await SnapshotFarm.open();
    if (access != null) farm.api.snapshot['GET /me/access'] = access;
    farm.api.snapshot.addAll({
      'GET /nutrition/requirement-sets': [requirementSet],
      'GET /nutrition/assessments': [assessment(recommendation: 'Calcium is 0.21 % … This is an assessment, not a ration.')],
      ...extra,
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

  group('requirements and assessments', () {
    testWidgets('the requirement sets with their source, and the assessments made', (tester) async {
      await open(tester);
      expect(find.text('DAIRY-EARLY v1 · Early lactation, 650 kg'), findsOneWidget);
      expect(find.text('Source: Farm nutritionist 2026-09'), findsOneWidget);
      expect(find.text('Crude protein 16–18 %'), findsOneWidget);
      expect(find.text('Calcium ≥ 0.6 %'), findsOneWidget);
      expect(find.text('Base concentrate v1 · DAIRY-EARLY v1'), findsOneWidget);
      expect(find.text('Does not meet'), findsOneWidget);
    });

    testWidgets('a formula assessed in its ration, with a premix on top', (tester) async {
      final farm = await open(tester);
      await tester.tap(find.byKey(const ValueKey('nu-assess')));
      await settle(tester);
      await pick(tester, 'nu-assess-formula', 'Dairy Mix 24L v2 · 1,000 kg');
      await pick(tester, 'nu-assess-set', 'DAIRY-EARLY v1 · Early lactation, 650 kg');
      await tester.enterText(find.byKey(const ValueKey('nu-assess-conc')), '9');
      await pick(tester, 'nu-assess-forage', 'Corn Silage');
      await tester.enterText(find.byKey(const ValueKey('nu-assess-forage-kg')), '38');
      await tester.enterText(find.byKey(const ValueKey('nu-assess-weight')), '640');
      await tester.tap(find.byKey(const ValueKey('nu-assess-premix')));
      await settle(tester);
      await pick(tester, 'nu-assess-premix-product', 'Cattle Dairy Premix');
      await tester.enterText(find.byKey(const ValueKey('nu-assess-premix-kg')), '12');
      await tester.tap(find.byKey(const ValueKey('nu-assess-save')));
      await settle(tester);
      final sent = body(farm, '/nutrition/assessments');
      expect(sent['formula_version_id'], '2298d8a1-8789-48f2-a105-1eaf8f553e7d');
      expect(sent['requirement_set_id'], 'rs-1');
      expect(sent['concentrate_kg_per_head'], 9);
      expect(sent['forages'], [{'feed_product_id': 'fp-corn-silage', 'as_fed_kg': 38}]);
      expect(sent['body_weight_kg'], 640);
      expect(sent['no_forage'], false);
      expect(sent['premix'], {'feed_product_id': 'fp-dairy-premix', 'quantity_kg': 12});
    });

    testWidgets('unknowns are left out, not guessed: the server is told nothing it was not given', (tester) async {
      final farm = await open(tester);
      await tester.tap(find.byKey(const ValueKey('nu-assess')));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('nu-assess-save')));
      await settle(tester);
      expect(find.text('Choose the formula and the requirements.'), findsOneWidget);
      await pick(tester, 'nu-assess-formula', 'Dairy Mix 24L v2 · 1,000 kg');
      await pick(tester, 'nu-assess-set', 'DAIRY-EARLY v1 · Early lactation, 650 kg');
      await tester.tap(find.byKey(const ValueKey('nu-assess-save')));
      await settle(tester);
      final sent = body(farm, '/nutrition/assessments');
      expect(sent.containsKey('concentrate_kg_per_head'), isFalse);
      expect(sent.containsKey('body_weight_kg'), isFalse);
      expect(sent['forages'], isEmpty);
    });

    testWidgets('the result: 1,210 kg before premix, 1,222 kg with it, each requirement and the explanation', (tester) async {
      await open(tester);
      await tester.tap(find.byKey(const ValueKey('nu-a-as-1')));
      await settle(tester);
      expect(find.byKey(const ValueKey('nu-result')), findsOneWidget);
      expect(find.text('Total before any premix'), findsOneWidget);
      expect(find.text('1,210 kg'), findsOneWidget);
      expect(find.text('1,222 kg'), findsOneWidget);
      expect(find.text('+ 12 kg · 0.98 %'), findsOneWidget);
      expect(find.text('350 kg · 28.64 %'), findsOneWidget);
      expect(find.text('13.1 %'), findsOneWidget);
      expect(find.text('Below'), findsNWidgets(2));
      expect((tester.widget<Text>(find.byKey(const ValueKey('nu-recommendation'))).data ?? ''), contains('not a ration'));
    });

    testWidgets('insufficient data names what is missing and recommends nothing', (tester) async {
      final a = NutritionAssessment.fromJson(assessment(status: 'insufficient_data', missing: [
        {'code': 'analysis_unknown', 'detail': 'Soybean meal has no analysis (declared or lab): its nutrients are not known.'},
        {'code': 'intake_unknown', 'detail': 'How much of this concentrate each animal eats a day is not given.'},
      ]));
      await open(tester);
      showAssessmentResult(tester.element(find.byType(NutritionTab)), a);
      await settle(tester);
      expect(find.text('Insufficient data: what is not known'), findsOneWidget);
      expect(find.textContaining('Soybean meal has no analysis'), findsOneWidget);
      expect(find.text('Soybean meal · no analysis'), findsOneWidget);
      expect(find.text('No recommendation: what is missing must be known first.'), findsOneWidget);
      expect(a.recommendation, isNull);
    });

    testWidgets('the manager adds requirements with their source', (tester) async {
      final farm = await open(tester);
      await tester.tap(find.byKey(const ValueKey('nu-req-add')));
      await settle(tester);
      await tester.enterText(find.byKey(const ValueKey('nu-req-code')), 'EWE-LATE');
      await pick(tester, 'nu-req-species', 'Sheep');
      await tester.enterText(find.byKey(const ValueKey('nu-req-name')), 'Ewes, late gestation');
      await tester.enterText(find.byKey(const ValueKey('nu-req-min-CP')), '12');
      await tester.enterText(find.byKey(const ValueKey('nu-req-max-CP')), '14');
      await tester.tap(find.byKey(const ValueKey('nu-req-save')));
      await settle(tester);
      expect(find.text('Say where these figures come from.'), findsOneWidget);
      expect(farm.api.writes.where((w) => w.$2 == '/nutrition/requirement-sets'), isEmpty);
      await tester.enterText(find.byKey(const ValueKey('nu-req-source')), 'Vet, flock plan 2026-11');
      await tester.tap(find.byKey(const ValueKey('nu-req-save')));
      await settle(tester);
      final sent = body(farm, '/nutrition/requirement-sets');
      expect(sent['code'], 'EWE-LATE');
      expect(sent['species_code'], 'sheep');
      expect(sent['source_reference'], 'Vet, flock plan 2026-11');
      expect(sent['values'], [{'nutrient_code': 'CP', 'min_value': 12, 'max_value': 14}]);
    });

    testWidgets('a revision is a new version with its own source, the old values offered', (tester) async {
      final farm = await open(tester);
      await tester.tap(find.byKey(const ValueKey('nu-req-revise-rs-1')));
      await settle(tester);
      expect(find.text('New version · DAIRY-EARLY v2'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('nu-req-min-CA')), '0.7');
      await tester.enterText(find.byKey(const ValueKey('nu-req-source')), 'Nutritionist revision 2026-11');
      await tester.tap(find.byKey(const ValueKey('nu-req-save')));
      await settle(tester);
      final sent = body(farm, '/nutrition/requirement-sets/rs-1/versions');
      expect(sent['source_reference'], 'Nutritionist revision 2026-11');
      expect(sent.containsKey('code'), isFalse);
      expect((sent['values'] as List).firstWhere((v) => v['nutrient_code'] == 'CA')['min_value'], 0.7);
      expect((sent['values'] as List).firstWhere((v) => v['nutrient_code'] == 'CP'), {'nutrient_code': 'CP', 'min_value': 16, 'max_value': 18});
    });
  });

  group('who may', () {
    testWidgets('someone who only views the feed reads, and changes nothing', (tester) async {
      await open(tester, access: {
        'user_id': 'user-view', 'role': 'worker', 'full_access': false,
        'modules': {FarmModule.feedNutrition: {'view': true}},
      });
      expect(find.text('DAIRY-EARLY v1 · Early lactation, 650 kg'), findsOneWidget);
      expect(find.byKey(const ValueKey('nu-assess')), findsNothing);
      expect(find.byKey(const ValueKey('nu-req-add')), findsNothing);
      expect(find.byKey(const ValueKey('nu-req-revise-rs-1')), findsNothing);
    });

    testWidgets('who makes feed assesses, but sets no requirements', (tester) async {
      await open(tester, access: {
        'user_id': 'user-mix', 'role': 'worker', 'full_access': false,
        'modules': {FarmModule.feedNutrition: {'view': true, 'create': true}},
      });
      expect(find.byKey(const ValueKey('nu-assess')), findsOneWidget);
      expect(find.byKey(const ValueKey('nu-req-add')), findsNothing);
    });

    testWidgets('in Arabic', (tester) async {
      await open(tester, locale: const Locale('ar'));
      expect(find.text('العليقة مزبوطة؟'), findsOneWidget);
      expect(find.text('شو بدّن الحيوانات'), findsOneWidget);
      expect(find.text('البروتين الخام 16–18 %'), findsOneWidget);
      expect(find.text('ما بيلبّي'), findsOneWidget);
    });

    test('its writes are named in the sync panel', () {
      expect(describeWrite('/nutrition/assessments'), (labelKey: 'outboxNutrition', moduleCode: FarmModule.feedNutrition));
      expect(describeWrite('/nutrition/requirement-sets/rs-1/versions').labelKey, 'outboxNutrition');
    });
  });
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}
