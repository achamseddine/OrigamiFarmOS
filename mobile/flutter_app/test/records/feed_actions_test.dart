import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:farmos/domain/entities/access.dart';
import 'package:farmos/features/feed/tabs/performance_tab.dart';

import '../support/snapshot_farm.dart';

/// Feed performance → the manager's action → its measured outcome (master
/// prompt Package 13) on the tablet and the web: record an action on an
/// alert, see it being measured, its outcome with its confidence, review it.
void main() {
  final alert = {
    'id': 'al-1', 'alert_type': 'PRODUCTION_DECLINE_AFTER_FEED_CHANGE', 'severity': 'high', 'status': 'open', 'title': 'Gigi: milk 20% down after Goat Mix',
    'explanation': '20.0% below the rolling subject baseline.', 'confidence_score': 0.6, 'subject_type': 'animal', 'subject_id': 'goat-gigi',
    'subject_name': 'Gigi', 'assessment_id': 'as-1', 'detected_at': '2026-11-20T07:00:00Z', 'evidence_json': {},
  };
  Map<String, dynamic> action({String status = 'measuring', String? outcome, String? explanation, String? reviewed}) => {
        'id': 'act-1', 'alert_id': 'al-1', 'action_type': 'change_lot', 'description': 'Back to the previous lot', 'expected_effect': 'increase',
        'status': status, 'measure_from': '2026-11-28T07:00:00Z', 'outcome': outcome, 'explanation': explanation, 'confidence_score': outcome == null ? null : 0.62,
        'reviewed_at': reviewed,
      };

  Future<SnapshotFarm> open(WidgetTester tester, {List<Object?> actions = const [], Map<String, Object?>? access, Locale locale = const Locale('en')}) async {
    tester.view.physicalSize = const Size(1200, 3600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final farm = await SnapshotFarm.open();
    if (access != null) farm.api.snapshot['GET /me/access'] = access;
    farm.api.snapshot.addAll({'GET /feed-performance/alerts': [alert], 'GET /feed-performance/actions': actions});
    await tester.pumpWidget(farm.app(const Scaffold(body: SingleChildScrollView(child: PerformanceTab())), locale: locale));
    await settle(tester);
    return farm;
  }

  Map body(SnapshotFarm farm, String path) => farm.api.writes.lastWhere((w) => w.$1 == 'POST' && w.$2 == path).$3! as Map;

  testWidgets('the manager records what was done about an alert', (tester) async {
    final farm = await open(tester);
    await tester.tap(find.byKey(const ValueKey('perf-act-al-1')));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('fa-save')));
    await settle(tester);
    expect(find.text('Say what was done.'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('fa-what')), 'Back to the previous lot');
    await tester.enterText(find.byKey(const ValueKey('fa-days')), '7');
    await tester.tap(find.byKey(const ValueKey('fa-save')));
    await settle(tester);
    expect(body(farm, '/feed-performance/alerts/al-1/actions'), {
      'action_type': 'change_lot', 'description': 'Back to the previous lot', 'expected_effect': 'increase', 'measure_after_days': 7, 'baseline_days': 7,
    });
  });

  testWidgets('an action being measured shows when, and no second action is offered', (tester) async {
    await open(tester, actions: [action()]);
    expect(find.text('Changed the lot · Back to the previous lot'), findsOneWidget);
    expect(find.text('Measuring'), findsOneWidget);
    expect(find.textContaining('Measured from'), findsOneWidget);
    expect(find.byKey(const ValueKey('perf-act-al-1')), findsNothing);
    expect(find.byKey(const ValueKey('perf-measure-act-1')), findsOneWidget);
  });

  testWidgets('the outcome, its confidence and its review', (tester) async {
    final farm = await open(tester, actions: [
      action(status: 'measured', outcome: 'as_expected',
          explanation: '2.81 → 3.10 L per head per day (+10.2 %): as expected. Confidence 0.62. An association with the action, not proof that it caused it.'),
    ]);
    expect(find.text('As expected'), findsOneWidget);
    expect(find.textContaining('not proof that it caused it'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('perf-review-act-1')));
    await settle(tester);
    expect(farm.api.writes.any((w) => w.$2 == '/feed-performance/actions/act-1/review'), isTrue);
  });

  testWidgets('who only edits the feed records no action', (tester) async {
    await open(tester, access: {'user_id': 'user-w', 'role': 'worker', 'full_access': false, 'modules': {FarmModule.feedNutrition: {'view': true, 'edit': true}}},
        actions: [action()]);
    expect(find.byKey(const ValueKey('perf-act-al-1')), findsNothing);
    expect(find.byKey(const ValueKey('perf-measure-act-1')), findsNothing);
  });

  testWidgets('in Arabic', (tester) async {
    await open(tester, actions: [action(status: 'measured', outcome: 'insufficient_data', explanation: 'Not enough records')], locale: const Locale('ar'));
    expect(find.text('غيّرنا الدفعة · Back to the previous lot'), findsOneWidget);
    expect(find.text('ما في معلومات كفاية'), findsOneWidget);
  });
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}
