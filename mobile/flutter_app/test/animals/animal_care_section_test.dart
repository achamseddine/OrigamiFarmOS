import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:farmos/core/i18n/strings.dart';
import 'package:farmos/features/animals/animal_care_section.dart';

/// The care record on the animal profile renders what the Digital Twin
/// carries — the live emergency, the open case, the withdrawal in force,
/// the doses with their lots, the standing conditions, the latest weight
/// — and says plainly when there is nothing.
void main() {
  Widget host(Widget child) => MaterialApp(home: Scaffold(body: SingleChildScrollView(child: SizedBox(width: 700, child: child))));

  // Read synchronously and outside the widget tests: real file I/O inside
  // a `testWidgets` fake-async zone never completes.
  late Map<String, dynamic> snapshot;
  setUpAll(() {
    snapshot = jsonDecode(File('assets/demo/snapshot.json').readAsStringSync()) as Map<String, dynamic>;
  });

  testWidgets('an animal with nothing on record says so', (tester) async {
    await tester.pumpWidget(host(const AnimalCareSection(twin: {}, loading: false)));
    expect(find.text(FarmStrings.of(tester.element(find.byType(AnimalCareSection)), 'twinNoAdministrations')), findsOneWidget);
    expect(find.text('No withdrawal in force.'), findsOneWidget);
  });

  testWidgets('a dose, its lot, the withdrawal it put in force, a condition and the weight all show', (tester) async {
    final until = DateTime.now().add(const Duration(days: 3)).toUtc().toIso8601String();
    await tester.pumpWidget(host(AnimalCareSection(loading: false, twin: {
      'recent_administrations': [
        {
          'id': 'adm-1', 'subject_type': 'animal', 'subject_id': 'cow-744', 'inventory_item_id': 'med-flunixin', 'medicine_name': 'Flunixin meglumine 50 mg/mL injectable',
          'inventory_lot_id': 'lot-1', 'lot_code': 'FLX-2609', 'dose_quantity': 22, 'dose_unit': 'ml', 'route_code': 'IM', 'head_count': 1, 'quantity_consumed': 22, 'unit': 'ml',
          'administered_at': '2026-10-17T08:00:00Z', 'withdrawal_milk_until': until, 'status': 'recorded',
        },
      ],
      'withdrawals': {'active': true, 'milk_until': until, 'meat_until': null, 'record_until': null, 'reason': null},
      'active_conditions': [
        {'id': 'c1', 'condition_type': 'adverse_reaction', 'code': 'penicillin_g', 'label': 'Adverse reaction to penicillin G (2025)', 'severity': 'moderate', 'active': true},
      ],
      'latest_weight': {'id': 'w1', 'weight_kg': 480, 'method': 'scale', 'measured_at': '2026-10-06T08:00:00Z'},
      'open_health_case': {'id': 'hc1', 'case_code': 'HC-000003', 'severity_code': 'high', 'status': 'open'},
      'emergency': {'id': 'as-1', 'status': 'escalated', 'triage_level': 'HIGH', 'explanation': 'ESCALATE'},
    })));
    expect(find.textContaining('Flunixin meglumine'), findsOneWidget);
    expect(find.textContaining('FLX-2609'), findsOneWidget);
    expect(find.textContaining('Milk withdrawal until'), findsOneWidget);
    expect(find.text('Adverse reaction to penicillin G (2025)'), findsOneWidget);
    expect(find.textContaining('480 kg'), findsOneWidget);
    expect(find.textContaining('HC-000003'), findsOneWidget);
    expect(find.textContaining('Live emergency'), findsOneWidget);
    expect(find.text('No withdrawal in force.'), findsNothing);
  });

  testWidgets('the bundled farm\'s twins render without error', (tester) async {
    for (final id in ['cow-744', 'cow-214', 'goat-189']) {
      await tester.pumpWidget(host(AnimalCareSection(twin: snapshot['GET /animals/$id'] as Map<String, dynamic>, loading: false)));
      expect(find.byType(AnimalCareSection), findsOneWidget);
    }
    // Luna's recorded penicillin reaction is on her card.
    await tester.pumpWidget(host(AnimalCareSection(twin: snapshot['GET /animals/cow-214'] as Map<String, dynamic>, loading: false)));
    expect(find.textContaining('penicillin'), findsOneWidget);
  });
}
