import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:farmos/domain/entities/feeding.dart';

/// The generic feed architecture as the tablet parses it, against the
/// bundled snapshot the standalone build runs on — so a shape change on
/// the server shows up here before it shows up as an empty tab.
void main() {
  late Map<String, dynamic> snapshot;

  setUpAll(() async {
    snapshot = jsonDecode(await File('assets/demo/snapshot.json').readAsString()) as Map<String, dynamic>;
  });

  List<Map<String, dynamic>> rows(String key) => [for (final e in snapshot[key] as List<dynamic>) e as Map<String, dynamic>];

  group('products and lots', () {
    test('a product carries its availability, and availability excludes reserved and unusable stock', () {
      final products = [for (final p in rows('GET /feed-products')) FeedProduct.fromJson(p)];
      expect(products, isNotEmpty);
      final premix = products.singleWhere((p) => p.id == 'fp-dairy-premix');
      expect(premix.isRestricted, isTrue, reason: 'the premix has a usage policy');
      expect(premix.availability.reserved, greaterThan(0), reason: 'the seed reserves 400 kg for the dairy herd');
      expect(premix.availability.available, premix.availability.onHand - premix.availability.reserved - premix.availability.unusable);
      final mix = products.singleWhere((p) => p.id == 'fp-dairy-mix');
      expect(mix.isFarmProduced, isTrue);
      expect(mix.hasActiveFormula, isTrue);
    });

    test('a lot knows where it came from and whether it may be fed', () {
      final lots = [for (final l in rows('GET /feed-lots')) FeedLot.fromJson(l)];
      expect(lots.map((l) => l.sourceType).toSet(), containsAll(['purchased', 'farm_produced', 'opening_balance']));
      final produced = lots.firstWhere((l) => l.sourceType == 'farm_produced');
      expect(produced.feedBatchId, isNotNull, reason: 'a farm-made lot points back at the batch that made it');
      expect(lots.where((l) => l.usable), isNotEmpty);
    });
  });

  group('formulas and batches', () {
    test('a used formula version is locked and a newer one is active', () {
      final formulas = [for (final f in rows('GET /feed-formulas')) FeedFormula.fromJson(f)];
      final dairy = formulas.singleWhere((f) => f.code == 'DAIRY-MIX-24L');
      expect(dairy.versions.where((v) => v.locked), isNotEmpty);
      expect(dairy.active, isNotNull);
      expect(dairy.active!.components.map((c) => c.targetQuantity).fold(0.0, (a, b) => a + b), closeTo(dairy.active!.batchSize, 0.01));
    });

    test('a completed batch has actuals, a cost and an output lot; an open one has none', () {
      final batches = [for (final b in rows('GET /feed-batches')) FeedBatch.fromJson(b)];
      final done = batches.singleWhere((b) => b.batchCode == 'MIX-2609-01');
      expect(done.status, 'completed');
      expect(done.actualCost, greaterThan(0));
      expect(done.outputLotId, isNotNull);
      final open = batches.singleWhere((b) => b.batchCode == 'MIX-2609-02');
      expect(open.isOpen, isTrue);
      expect(open.outputLotId, isNull);
    });
  });

  group('programs and the plan', () {
    test('programs are generic: rules name a species and states, never a species module', () {
      final programs = [for (final p in rows('GET /feeding-programs')) FeedingProgram.fromJson(p)];
      final species = {
        for (final p in programs)
          for (final v in p.versions)
            for (final r in v.rules)
              if (r.speciesCode != null) r.speciesCode!,
      };
      expect(species.length, greaterThan(3), reason: 'cows, goats, sheep, horses, hens share one model');
      final high = programs.singleWhere((p) => p.id == 'prog-dairy-high');
      expect(high.active, isNotNull);
      expect(high.active!.rules.any((r) => r.productionMin != null), isTrue, reason: 'the high band is a production rule');
    });

    test('a cow in the herd inherits the group program and keeps her own supplement', () {
      final plan = FeedingPlan.fromJson(snapshot['GET /livestock-subjects/cow-744/feeding-plan'] as Map<String, dynamic>);
      expect(plan.program, isNotNull);
      expect(plan.program!.isInherited, isTrue);
      expect(plan.program!.inheritedFromGroupName, isNotNull);
      expect(plan.supplements, hasLength(1));
      expect(plan.dailyTargets, isNotEmpty);
      expect(plan.recentEvents, isNotEmpty);
    });

    test("today's plan totals what every group and animal should get", () {
      final plan = DailyPlan.fromJson(snapshot['GET /feeding-plan/today'] as Map<String, dynamic>);
      expect(plan.lines, isNotEmpty);
      expect(plan.totals, isNotEmpty);
      expect(plan.lines.any((l) => l.subjectType == 'group'), isTrue);
    });
  });

  group('feeding events', () {
    test('an event is components drawn from lots, priced from them', () {
      final events = [for (final e in rows('GET /feeding-events?days=7')) FeedingEvent.fromJson(e)];
      expect(events, isNotEmpty);
      final priced = events.firstWhere((e) => (e.totalCost ?? 0) > 0);
      expect(priced.components.every((c) => c.lotId != null), isTrue);
      expect(priced.totalQuantity, greaterThan(0));
    });
  });

  group('stock control', () {
    test('days of cover come from program demand and flag what is at risk', () {
      final cover = [for (final c in rows('GET /feed-inventory/days-of-cover')) FeedCover.fromJson(c)];
      expect(cover.where((c) => c.demandSource == 'programs'), isNotEmpty);
      final reorder = [for (final c in rows('GET /feed-inventory/reorder-recommendations')) FeedCover.fromJson(c)];
      expect(reorder.every((r) => r.atRisk), isTrue);
      expect(reorder.every((r) => r.reasons.isNotEmpty), isTrue, reason: 'a recommendation always says why');
    });

    test('a reconciliation carries the ledger breakdown and the variance', () {
      final recs = [for (final r in rows('GET /feed-reconciliations')) FeedReconciliation.fromJson(r)];
      final open = recs.firstWhere((r) => r.status == 'open');
      expect(open.countedClosing, isNotNull);
      expect(open.varianceQuantity, isNotNull);
      expect(open.varianceQuantity, closeTo(open.countedClosing! - open.expectedClosing, 0.01));
    });

    test('costs are summarised by subject, by feed and by batch', () {
      final costs = FeedCostSummary.fromJson(snapshot['GET /feed-costs?days=30'] as Map<String, dynamic>);
      expect(costs.totalFeedingCost, greaterThan(0));
      expect(costs.bySubject, isNotEmpty);
      expect(costs.byProduct, isNotEmpty);
      expect(costs.batches, isNotEmpty);
    });
  });
}
