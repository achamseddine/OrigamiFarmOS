import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:farmos/domain/entities/feed_performance.dart';
import 'package:farmos/domain/entities/feeding.dart';

/// Feed performance intelligence as the tablet parses it, against the
/// bundled snapshot — the server's explanations, likelihoods and
/// confidences arrive intact, and "not measured" stays null rather than
/// becoming a perfect score.
void main() {
  late Map<String, dynamic> snapshot;

  setUpAll(() async {
    snapshot = jsonDecode(await File('assets/demo/snapshot.json').readAsString()) as Map<String, dynamic>;
  });

  List<Map<String, dynamic>> rows(String key) => [for (final e in snapshot[key] as List<dynamic>) e as Map<String, dynamic>];

  test('the summary counts what the cycle produced and names its model', () {
    final s = FeedPerformanceSummary.fromJson(snapshot['GET /feed-performance/summary'] as Map<String, dynamic>);
    expect(s.monitors, 4, reason: 'the herd on milk and the three flocks on eggs');
    expect(s.batchesScored, greaterThanOrEqualTo(1));
    expect(s.suppliersScored, greaterThanOrEqualTo(1));
    expect(s.modelReference, 'origami.feed_performance.deterministic');
    expect(s.lastEvaluatedAt, isNotNull);
  });

  test('a monitor carries its explicit baseline and its latest explained assessment', () {
    final monitors = [for (final m in rows('GET /feed-performance/monitors')) FeedPerformanceMonitor.fromJson(m)];
    expect(monitors, hasLength(4));
    final herd = monitors.firstWhere((m) => m.subjectId == 'grp-dairy-herd');
    expect(herd.metric, 'milk_l_per_day');
    expect(herd.baselineMethod, 'rolling_subject');
    expect(herd.thresholdPercent, 5);
    final latest = herd.latest!;
    expect(latest.isInsufficient, isFalse);
    expect(latest.baselineValue, isNotNull);
    expect(latest.variancePercent, isNotNull);
    expect(latest.confidence, inInclusiveRange(0.1, 0.95));
    expect(latest.explanation, contains('baseline'));
    expect(latest.missingContext, contains('environment'), reason: 'what the farm cannot see is named, and lowers the confidence');
    expect(latest.unit, 'L/head/day');
    expect(latest.feedChanges, isNotEmpty);

    final layers = monitors.firstWhere((m) => m.subjectId == 'flock-layer');
    expect(layers.metric, 'eggs_per_day');
    expect(layers.latest!.isInsufficient, isTrue);
    expect(layers.latest!.likelihood, 'INSUFFICIENT_EVIDENCE');
    expect(layers.latest!.variancePercent, isNull, reason: 'missing data is missing, not zero');
  });

  test('a mix score leaves unmeasured dimensions blank', () {
    final scores = [for (final s in rows('GET /feed-performance/batches')) FeedBatchScore.fromJson(s)];
    expect(scores, isNotEmpty);
    final first = scores.firstWhere((s) => s.mixCode == 'MIX-000001');
    expect(first.mixNumber, 1);
    expect(first.formulaCompliance, isNotNull);
    expect(first.productionResponse, isNull, reason: 'the seeded mix was never fed, so there is no production response');
    expect(first.overall, isNotNull);
    expect(first.confidence, inInclusiveRange(0, 1));
    expect(first.openAlerts, isEmpty);
    expect(first.evidence['dimensions_available'], contains('formula_compliance'));
  });

  test('supplier rows are one per ingredient', () {
    final rowsOut = [for (final s in rows('GET /feed-performance/suppliers')) SupplierPerformance.fromJson(s)];
    final mashreq = rowsOut.where((r) => r.supplierLabel == 'Al Mashreq').toList();
    expect(mashreq, hasLength(2));
    expect(mashreq.map((r) => r.productName).toSet(), hasLength(2));
    final barley = rowsOut.firstWhere((r) => r.productName == 'Barley');
    expect(barley.lotCount, 1);
    expect(barley.feedBatchCount, 1);
    expect(barley.averageUnitCost, 0.36);
    expect(barley.unit, 'kg');
    expect(barley.methodologyCode, 'deterministic_lot_lineage');
  });

  test('alerts parse, open and resolved alike', () {
    final open = [for (final a in rows('GET /feed-performance/alerts')) FeedPerformanceAlert.fromJson(a)];
    final all = [for (final a in rows('GET /feed-performance/alerts?status=all')) FeedPerformanceAlert.fromJson(a)];
    expect(all.length, greaterThanOrEqualTo(open.length));
    for (final a in all) {
      expect(a.alertType, isNotEmpty);
      expect(a.explanation, isNotEmpty);
      expect(['open', 'acknowledged', 'resolved'], contains(a.status));
    }
    final a = FeedPerformanceAlert.fromJson({
      'id': 'al-1', 'alert_type': 'FORMULA_COMPLIANCE_DEVIATION', 'severity': 'high', 'status': 'acknowledged', 'title': 'Formula deviation in MIX-000002',
      'explanation': 'Mixed off its formula.', 'confidence_score': 0.95, 'mix_code': 'MIX-000002', 'feed_batch_id': 'b2', 'detected_at': '2026-10-09T06:00:00Z',
      'evidence': {'tolerance_pct': 5},
    });
    expect(a.isOpen, isFalse);
    expect(a.isResolved, isFalse);
    expect(a.mixCode, 'MIX-000002');
    expect(a.evidence['tolerance_pct'], 5);
  });

  test('the mix timeline carries the score card when the cycle has scored it', () {
    final usage = MixUsage.fromJson(snapshot['GET /feed-mixes/1'] as Map<String, dynamic>);
    expect(usage.mixCode, 'MIX-000001');
    expect(usage.performance, isNotNull);
    expect(usage.performance!['overall_score'], isNotNull);
    expect(usage.performance!['open_alerts'], isA<List<dynamic>>());
  });
}
