import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:farmos/data/local/cache_effects.dart';
import 'package:farmos/domain/entities/health_case.dart';
import 'package:farmos/domain/entities/pharmacy.dart';
import 'package:farmos/domain/entities/production_records.dart';
import 'package:farmos/features/animals/animal_digital_twin_screen.dart';
import 'package:farmos/features/health/health_intelligence_screen.dart';
import 'package:farmos/features/health/health_overview.dart';
import 'package:farmos/features/mouneh/mouneh_module_screen.dart';

import '../support/snapshot_farm.dart';

/// The Health and Mouneh screens drawn over the bundled demo farm, and
/// the rules under them.
void main() {
  Future<void> open(WidgetTester tester, Widget home, {Locale locale = const Locale('en'), double height = 2200}) async {
    tester.view.physicalSize = Size(1280, height);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final farm = await SnapshotFarm.open();
    await tester.pumpWidget(farm.app(home, locale: locale));
    await settle(tester);
  }

  testWidgets('the health command centre: open case, withdrawal, clinical record', (tester) async {
    await open(tester, const Scaffold(body: HealthIntelligenceScreen()));
    expect(find.text('Open cases and follow-up'), findsOneWidget);
    expect(find.text('Rasha · Emergency triage'), findsOneWidget, reason: 'a case the emergency engine opened says where it came from');
    expect(find.text('Withdrawal review'), findsOneWidget);
    expect(find.textContaining('Willow'), findsWidgets);
    expect(find.textContaining('does not by itself mean milk or meat is safe'), findsOneWidget);
    expect(find.text('Bella #744 · Fever'), findsOneWidget);
    expect(find.textContaining('coming soon'), findsNothing, reason: 'the placeholder tabs are gone');
  });

  testWidgets("closed cases keep the vet's diagnosis and plan", (tester) async {
    await open(tester, const Scaffold(body: HealthIntelligenceScreen()));
    await tester.tap(find.text('Health cases · 1'));
    await settle(tester);
    expect(find.textContaining('HC-000003'), findsOneWidget);
    expect(find.textContaining('HC-000001'), findsNothing, reason: 'open cases only, by default');
    await tester.tap(find.text('All'));
    await settle(tester);
    expect(find.textContaining('HC-000001'), findsOneWidget);
    await tester.tap(find.textContaining('HC-000001'));
    await settle(tester);
    expect(find.text('Clinical mastitis, front-left quarter'), findsOneWidget);
    expect(find.textContaining('Dr. Layla Haddad'), findsWidgets);
    expect(find.textContaining('Intramammary tube once daily'), findsOneWidget);
    expect(find.text('Close case'), findsNothing, reason: 'a resolved case is not closed again');
  });

  testWidgets('recommendations lay out on a wide tablet and say what they are not', (tester) async {
    await open(tester, const Scaffold(body: HealthIntelligenceScreen()));
    await tester.tap(find.text('Recommendations · 1'));
    await settle(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('Mastitis Risk Detected'), findsWidgets);
    expect(find.textContaining('Decision support only'), findsOneWidget);
  });

  testWidgets("Bella's Health tab lists her cases", (tester) async {
    await open(tester, const AnimalDigitalTwinScreen(animalId: 'cow-744', initialTab: TwinTab.health));
    expect(find.text('Health cases'), findsOneWidget);
    expect(find.textContaining('HC-000001'), findsOneWidget);
    expect(find.textContaining('HC-000002'), findsOneWidget);
  });

  testWidgets('Mouneh: figures, tabs and the profit caveat', (tester) async {
    await open(tester, const Scaffold(body: MounehModuleScreen()), height: 1600);
    expect(find.text('Batches in progress'), findsWidgets);
    expect(find.text('Profit on recorded sales'), findsOneWidget);
    expect(find.text('Start a batch'), findsOneWidget);
    expect(find.textContaining('Costs nobody recorded'), findsOneWidget);
    await tester.tap(find.text('Production batches').first);
    await settle(tester);
    expect(find.textContaining('MOU-'), findsWidgets);
    expect(find.text('Complete batch'), findsOneWidget, reason: 'the batch in progress can be completed');
  });

  testWidgets('Mouneh speaks Arabic', (tester) async {
    await open(tester, const Scaffold(body: MounehModuleScreen()), locale: const Locale('ar'), height: 1600);
    expect(find.text('المنتجات'), findsWidgets);
    expect(find.text('دفعات الإنتاج'), findsWidgets);
    expect(find.text('Production batches'), findsNothing);
  });

  group('rules', () {
    final now = DateTime(2026, 11, 13, 12);
    test('the clinical record leaves out reversed doses and old records', () {
      MedicationAdministration dose(String id, DateTime at, {String status = 'recorded'}) => MedicationAdministration.fromJson({
            'id': id, 'subject_type': 'animal', 'subject_id': 'cow-1', 'subject_name': 'Bella', 'inventory_item_id': 'med-1', 'medicine_name': 'Med',
            'lot_id': 'lot-1', 'dose_quantity': 2, 'dose_unit': 'ml', 'route_code': 'IM', 'head_count': 1, 'quantity_consumed': 2, 'unit': 'ml',
            'administered_at': at.toIso8601String(), 'status': status,
          });
      final records = clinicalRecords(
        observations: [
          ObservationRecord(id: 'o1', entityType: 'animal', entityId: 'cow-1', type: 'fever', observedAt: DateTime(2026, 11, 12)),
          ObservationRecord(id: 'o2', entityType: 'animal', entityId: 'cow-1', type: 'limping', observedAt: DateTime(2026, 9, 1)),
        ],
        treatments: [TreatmentRecord(id: 't1', entityType: 'animal', entityId: 'cow-1', medication: 'Abx', status: 'active', startAt: DateTime(2026, 11, 10))],
        administrations: [dose('d1', DateTime(2026, 11, 11)), dose('d2', DateTime(2026, 11, 11), status: 'reversed')],
        now: now,
      );
      expect(records.map((r) => r.kind), [ClinicalKind.observation, ClinicalKind.medicine, ClinicalKind.treatment], reason: 'newest first');
    });

    test('open cases come most serious first', () {
      final cases = [
        HealthCase.fromJson({'id': 'a', 'status': 'open', 'severity_code': 'low', 'opened_at': '2026-11-12T08:00:00Z'}),
        HealthCase.fromJson({'id': 'b', 'status': 'monitoring', 'severity_code': 'critical', 'opened_at': '2026-11-01T08:00:00Z'}),
        HealthCase.fromJson({'id': 'c', 'status': 'resolved', 'severity_code': 'critical'}),
      ];
      final open = [for (final c in cases) if (c.isOpen) c]..sort((x, y) => y.severityRank.compareTo(x.severityRank));
      expect(open.map((c) => c.id), ['b', 'a']);
    });

    test('an offline case close shows on the list and on the case', () {
      final effects = effectsFor('POST', '/health/cases/hc-1/close', {'outcome': 'Sound again', 'status': 'resolved'}, localId: 'l');
      final merge = effects.whereType<MergeRecord>().single;
      expect((merge.collectionPath, merge.id, merge.patch['status']), ('/health/cases', 'hc-1', 'resolved'));
      expect(effects.whereType<PatchDocument>().single.patch['outcome'], 'Sound again');
      final opened = effectsFor('POST', '/health/cases', {'subject_type': 'animal', 'subject_id': 'cow-1'}, localId: 'local-c');
      final record = opened.whereType<AppendRecord>().single.record;
      expect((record['status'], record['case_code']), ('open', '…'));
    });
  });
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}
