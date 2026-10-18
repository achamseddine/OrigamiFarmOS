import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:farmos/domain/entities/animal.dart';
import 'package:farmos/domain/entities/emergency.dart';
import 'package:farmos/emergency/offline_engine.dart';

/// Offline execution (§14): the tablet triages from the signed package
/// with the server's own arithmetic, calculates a dose only from the
/// approved rule inside the approved limits against the package's stock
/// snapshot, and escalates on anything else. Proven on a hand-built
/// package with every edge on it, and on the bundled farm's real one.
void main() {
  // A one-protocol package: a cow fever protocol with a required
  // temperature rule, an appetite rule, a danger sign, three eligibility
  // rules and a per-weight medication step with approved limits.
  final packageJson = <String, dynamic>{
    'signature': 'a' * 64,
    'generated_at': '2026-10-18T06:00:00Z',
    'stock_as_of': '2026-10-18T06:00:00Z',
    'model_reference': 'origami.emergency.deterministic',
    'model_version': '1.1',
    'sign_codes': const [],
    'versions': [
      {
        'id': 'v-fever-1',
        'protocol_id': 'p-fever',
        'protocol_code': 'TEST-FEVER',
        'protocol_title': 'Test fever support',
        'version_no': 1,
        'species_code': 'cow',
        'subject_scope': 'animal',
        'minimum_match_confidence': 0.6,
        'offline_eligible': true,
        'approval_reference': 'VET-TEST-1',
        'approved_by_name': 'Dr. Test',
        'trigger_rules': [
          {'observation_code': 'temperature_c', 'operator': '>=', 'threshold_numeric': 39.5, 'threshold_unit': '°C', 'required': true, 'weight': 2, 'danger_sign': false, 'label': 'Temperature'},
          {'observation_code': 'appetite', 'operator': '==', 'expected_value_code': 'reduced', 'required': false, 'weight': 1, 'danger_sign': false},
          {'observation_code': 'recumbent', 'operator': 'present', 'required': false, 'weight': 1, 'danger_sign': true, 'label': 'Down'},
        ],
        'eligibility_rules': [
          {'rule_type': 'species', 'rule_payload': {'in': ['cow']}, 'failure_action': 'BLOCK', 'message': 'Cattle only'},
          {'rule_type': 'pregnant', 'rule_payload': {'value': false}, 'failure_action': 'WARN', 'message': 'Pregnant: watch closely'},
          {'rule_type': 'allergy', 'rule_payload': {'not': 'flunixin_meglumine'}, 'failure_action': 'REQUIRE_VET', 'message': 'Recorded flunixin reaction: the vet decides'},
        ],
        'steps': [
          {'id': 's-check', 'step_no': 1, 'step_type': 'ASSESS', 'title': 'Check', 'instructions': 'Shade and water', 'required': true, 'requires_confirmation': true},
          {
            'id': 's-med',
            'step_no': 2,
            'step_type': 'MEDICATION',
            'title': 'Anti-inflammatory',
            'instructions': 'Slow IM',
            'required': true,
            'requires_confirmation': true,
            'medication': {
              'medicine_product_id': 'med-flunixin',
              'medicine_name': 'Flunixin',
              'route_code': 'IM',
              'dose_rule_type': 'PER_WEIGHT',
              'dose_per_weight_quantity': 0.044,
              'dose_unit': 'ml',
              'weight_unit': 'kg',
              'minimum_dose_quantity': 5,
              'maximum_dose_quantity': 30,
              'weight_max_age_days': 30,
              'repeat_interval_minutes': 1440,
              'maximum_administrations': 3,
            },
          },
        ],
      },
    ],
    'medicines': [
      {
        'medicine_product_id': 'med-flunixin',
        'name': 'Flunixin',
        'unit': 'ml',
        'administration_routes': ['IM'],
        'species_codes': ['cow'],
        'prescription_required': true,
        'ingredient_codes': ['flunixin_meglumine'],
        'withdrawal_rules': {'milk_hours': 36},
        'eligible_lots': [
          {'lot_id': 'lot-a', 'lot_code': 'A', 'quantity_on_hand': 10, 'free_quantity': 10, 'expiry_date': '2027-01-01T00:00:00Z'},
          {'lot_id': 'lot-b', 'lot_code': 'B', 'quantity_on_hand': 100, 'free_quantity': 100, 'expiry_date': '2027-06-01T00:00:00Z'},
        ],
      },
    ],
  };
  final package = OfflinePackage.fromJson(packageJson);
  final version = package.versions.single;
  final medStep = version.steps.last;

  Map<String, dynamic> cow({double? weight, int? weightAge, bool pregnant = false, List<String> allergies = const [], String species = 'cow'}) => {
        'subject_type': 'animal',
        'species': species,
        'sex': 'F',
        'life_stage': 'adult',
        'management_profile': 'dairy',
        'status': 'healthy',
        'weight_kg': weight,
        'weight_known': weight != null,
        'weight_age_days': weightAge,
        'weight_source': weightAge == null ? 'animal_record' : 'record',
        'age_days': 1500,
        'pregnant': pregnant,
        'lactating': true,
        'withdrawal_active': false,
        'allergies': allergies,
        'conditions': const <String>[],
        'active_diagnoses': const <String>[],
        'recent_medications': const <Map<String, dynamic>>[],
      };
  final fever = [
    {'code': 'temperature_c', 'value_numeric': 40.2},
    {'code': 'appetite', 'value_text': 'reduced'},
  ];

  group('triage from the package', () {
    test('the signs that satisfy the rules match the version with the server\'s score', () {
      final r = triageOffline(package: package, facts: cow(weight: 500), signs: fever, subjectName: 'Bella');
      expect(r.escalated, isFalse);
      expect(r.match!.version.id, 'v-fever-1');
      expect(r.match!.score, 1.0);
      expect(r.triageLevel, 'HIGH');
      expect(r.match!.eligibility, 'ELIGIBLE');
      expect(r.explanation, contains('offline package'));
      expect(r.explanation, contains('Confirm to start the protocol'));
    });

    test('a partial fit below the threshold escalates and names the threshold', () {
      final r = triageOffline(package: package, facts: cow(weight: 500), signs: [
        {'code': 'appetite', 'value_text': 'reduced'},
      ]);
      // Temperature (weight 2) is required and missing: 1/3 < 0.6, and the
      // required observation is named.
      expect(r.escalated, isTrue);
      expect(r.match, isNull);
      expect(r.triageLevel, 'MODERATE', reason: 'some rule fired, so there is a pattern');
      expect(r.escalationReasons.join(' '), contains('confidence threshold'));
      expect(r.explanation, contains('No drug, dose or route is shown'));
    });

    test('the threshold is met but a required observation is missing → escalate', () {
      // Appetite alone can never reach 0.6; use a version where it could:
      // lower the threshold in a copy of the package.
      final copy = Map<String, dynamic>.from(packageJson);
      copy['versions'] = [
        {...(packageJson['versions'] as List).first as Map<String, dynamic>, 'minimum_match_confidence': 0.3},
      ];
      final r = triageOffline(package: OfflinePackage.fromJson(copy), facts: cow(weight: 500), signs: [
        {'code': 'appetite', 'value_text': 'reduced'},
      ]);
      expect(r.escalated, isTrue);
      expect(r.escalationReasons.single, contains('required observation missing — temperature_c'));
    });

    test('a danger sign is CRITICAL and escalates whatever else matched', () {
      final r = triageOffline(package: package, facts: cow(weight: 500), signs: [
        ...fever,
        {'code': 'recumbent', 'present': true},
      ]);
      expect(r.triageLevel, 'CRITICAL');
      expect(r.escalated, isTrue);
      expect(r.escalationReasons.first, startsWith('danger sign'));
      expect(r.match, isNull);
    });

    test('no signs at all is a low triage with no match', () {
      final r = triageOffline(package: package, facts: cow(weight: 500), signs: const []);
      expect(r.escalated, isTrue);
      expect(r.triageLevel, 'LOW');
    });

    test('a version for another species is never a candidate', () {
      final r = triageOffline(package: package, facts: cow(weight: 60, species: 'goat'), signs: fever);
      expect(r.candidates, isEmpty);
      expect(r.escalated, isTrue);
      expect(r.escalationReasons.single, contains('no offline-eligible veterinarian-approved protocol'));
    });

    test('a WARN rule still allows the match, with the warning shown', () {
      final r = triageOffline(package: package, facts: cow(weight: 500, pregnant: true), signs: fever);
      expect(r.escalated, isFalse);
      expect(r.match!.eligibility, 'WARN');
      expect(r.match!.warnings.single, contains('Pregnant'));
      expect(r.match!.startable, isTrue);
    });

    test('a recorded allergy to the ingredient requires the vet: escalated, no drug', () {
      final r = triageOffline(package: package, facts: cow(weight: 500, allergies: ['flunixin_meglumine']), signs: fever);
      expect(r.escalated, isTrue);
      expect(r.escalationReasons.single, contains('requires the veterinarian'));
      expect(r.escalationReasons.single, contains('flunixin reaction'));
    });

    test('a fact the tablet does not hold is reported as not checked, never passed silently', () {
      final facts = cow(weight: 500)..remove('allergies');
      final r = triageOffline(package: package, facts: facts, signs: fever);
      final allergy = r.candidates.single.outcomes.firstWhere((o) => o['rule_type'] == 'allergy');
      expect(allergy['checked'], isFalse);
      expect(allergy['passed'], isFalse);
      expect(allergy['message'], contains('could not be checked offline'));
      // REQUIRE_VET when unknown: the person is told to call, the server settles it at sync.
      expect(r.escalated, isTrue);
    });
  });

  group('the approved dose from the package', () {
    test('per-weight dose inside the limits, from the first lot that holds it', () {
      final d = prepareOfflineDose(step: medStep, package: package, facts: cow(weight: 500, weightAge: 3));
      expect(d.blocked, isFalse);
      expect(d.doseQuantity, 22.0);
      expect(d.doseUnit, 'ml');
      expect(d.weightUsedKg, 500);
      expect(d.weightSource, contains('3 day(s) old'));
      expect(d.quantityConsumed, 22.0);
      expect(d.lot!.lotCode, 'B', reason: 'lot A holds only 10 ml; first expiry first among lots that can serve the dose');
      expect(d.toResult()['source'], contains('offline package'));
    });

    test('a weight entered now wins and is used as is', () {
      final d = prepareOfflineDose(step: medStep, package: package, facts: cow(weight: 500, weightAge: 3), enteredWeightKg: 400);
      expect(d.doseQuantity, 17.6);
      expect(d.weightSource, 'entered now');
    });

    test('no weight → no dose; the problem says so', () {
      final d = prepareOfflineDose(step: medStep, package: package, facts: cow());
      expect(d.blocked, isTrue);
      expect(d.doseQuantity, isNull);
      expect(d.problems.single, contains('weight unknown'));
    });

    test('a weight older than the protocol allows blocks the step', () {
      final d = prepareOfflineDose(step: medStep, package: package, facts: cow(weight: 500, weightAge: 45));
      expect(d.blocked, isTrue);
      expect(d.problems.single, contains('no older than 30 day(s)'));
      expect(d.problems.single, contains('45 day(s) old'));
    });

    test('an undated weight on the animal record is refused when the protocol wants a dated one', () {
      final d = prepareOfflineDose(step: medStep, package: package, facts: cow(weight: 500));
      expect(d.blocked, isTrue);
      expect(d.problems.single, contains('undated'));
    });

    test('the approved minimum and maximum are never crossed', () {
      final low = prepareOfflineDose(step: medStep, package: package, facts: cow(weight: 50, weightAge: 1));
      expect(low.problems.single, contains('below the approved minimum 5'));
      final high = prepareOfflineDose(step: medStep, package: package, facts: cow(weight: 800, weightAge: 1));
      expect(high.problems.single, contains('exceeds the approved maximum 30'));
    });

    test('a recorded allergy to the ingredient blocks the step whatever the protocol says', () {
      final d = prepareOfflineDose(step: medStep, package: package, facts: cow(weight: 500, weightAge: 1, allergies: ['flunixin_meglumine']));
      expect(d.blocked, isTrue);
      expect(d.problems.single, contains('allergy / adverse reaction to flunixin_meglumine'));
    });

    test('the repeat interval and the maximum number of administrations hold', () {
      final now = DateTime.utc(2026, 10, 18, 12);
      final tooSoon = prepareOfflineDose(step: medStep, package: package, facts: cow(weight: 500, weightAge: 1), now: now, earlierDoses: [
        {'protocol_step_id': 's-med', 'status': 'completed', 'occurred_at': now.subtract(const Duration(hours: 2)).toIso8601String()},
      ]);
      expect(tooSoon.problems.single, contains('repeat interval of 1440 min'));
      final exhausted = prepareOfflineDose(step: medStep, package: package, facts: cow(weight: 500, weightAge: 1), now: now, earlierDoses: [
        for (var i = 1; i <= 3; i++) {'protocol_step_id': 's-med', 'status': 'completed', 'occurred_at': now.subtract(Duration(days: i)).toIso8601String()},
      ]);
      expect(exhausted.problems.any((p) => p.contains('maximum of 3 administration')), isTrue);
    });

    test('stock the package does not list as eligible is not used', () {
      final copy = jsonDecode(jsonEncode(packageJson)) as Map<String, dynamic>;
      (copy['medicines'] as List).first['eligible_lots'] = [
        {'lot_id': 'lot-a', 'lot_code': 'A', 'quantity_on_hand': 10, 'free_quantity': 4, 'expiry_date': '2027-01-01T00:00:00Z'},
      ];
      final d = prepareOfflineDose(step: medStep, package: OfflinePackage.fromJson(copy), facts: cow(weight: 500, weightAge: 1));
      expect(d.blocked, isTrue);
      expect(d.lot, isNull);
      expect(d.problems.single, contains('no eligible lot in the package holds 22 ml'));
    });

    test('a dose unit that cannot become the stock unit is a problem, not a guess', () {
      final copy = jsonDecode(jsonEncode(packageJson)) as Map<String, dynamic>;
      (copy['medicines'] as List).first['unit'] = 'sachet';
      final d = prepareOfflineDose(step: medStep, package: OfflinePackage.fromJson(copy), facts: cow(weight: 500, weightAge: 1));
      expect(d.problems.single, contains('cannot be converted to the stock unit sachet'));
    });
  });

  group('the offline run the server revalidates', () {
    test('carries the operation id, the package signature and what was shown and done', () {
      final triage = triageOffline(package: package, facts: cow(weight: 500, weightAge: 1), signs: fever, subjectName: 'Bella');
      final dose = prepareOfflineDose(step: medStep, package: package, facts: cow(weight: 500, weightAge: 1));
      final body = offlineRunPayload(
        operationId: 'op-1',
        deviceId: 'ins-1',
        package: package,
        subjectType: 'animal',
        subjectId: 'cow-744',
        signs: fever,
        triage: triage,
        steps: [
          {'protocol_step_id': 's-check', 'status': 'completed', 'occurred_at': '2026-10-18T07:00:00Z', 'result': const {'offline': true}},
          {
            'protocol_step_id': 's-med',
            'status': 'completed',
            'occurred_at': '2026-10-18T07:05:00Z',
            'result': dose.toResult(),
            'medication': {'dose_quantity': dose.doseQuantity, 'dose_unit': dose.doseUnit, 'lot_id': dose.lot!.lotId, 'weight_used_kg': 500, 'head_count': 1},
          },
        ],
        occurredAt: DateTime.utc(2026, 10, 18, 7),
      );
      expect(body['operation_id'], 'op-1');
      expect(body['package_signature'], 'a' * 64);
      expect(body['shown'], {'protocol_version_id': 'v-fever-1', 'match_score': 1.0, 'triage_level': 'HIGH', 'escalated': false, 'escalation_reasons': <String>[]});
      expect((body['steps'] as List).last['medication']['lot_id'], 'lot-b');
      expect(body['occurred_at'], '2026-10-18T07:00:00.000Z');
    });

    test('an escalation is recorded as shown, with no version and no steps', () {
      final triage = triageOffline(package: package, facts: cow(weight: 500), signs: const []);
      final body = offlineRunPayload(operationId: 'op-2', deviceId: null, package: package, subjectType: 'animal', subjectId: 'cow-744', signs: const [], triage: triage, steps: const []);
      final shown = body['shown'] as Map<String, dynamic>;
      expect(shown['escalated'], isTrue);
      expect(shown['protocol_version_id'], isNull);
      expect(shown['escalation_reasons'], isNotEmpty);
      expect(body['steps'], isEmpty);
    });
  });

  group('the bundled farm\'s package', () {
    late Map<String, dynamic> snapshot;
    late OfflinePackage real;

    setUpAll(() async {
      snapshot = jsonDecode(await File('assets/demo/snapshot.json').readAsString()) as Map<String, dynamic>;
      real = OfflinePackage.fromJson(snapshot['GET /emergency/offline-package'] as Map<String, dynamic>);
    });

    test('is signed and holds only offline-eligible versions, with their species and scope', () {
      expect(real.signature, hasLength(64));
      expect(real.versions, isNotEmpty);
      expect(real.versions.every((v) => v.offlineEligible), isTrue);
      expect(real.versions.map((v) => v.protocolCode), contains('BOVINE-FEVER-SUPPORT'));
      expect(real.versions.firstWhere((v) => v.protocolCode == 'BOVINE-FEVER-SUPPORT').speciesCode, 'cow');
      expect(real.medicines, isNotEmpty);
      expect(real.medicines.values.every((m) => m.eligibleLots.isNotEmpty), isTrue, reason: 'the stock snapshot travels with the package');
    });

    test('Bella\'s facts come from the herd record and her Digital Twin', () {
      final animals = [for (final a in snapshot['GET /animals?farm_id=farm-origami'] as List<dynamic>) Animal.fromJson(a as Map<String, dynamic>)];
      final bella = animals.firstWhere((a) => a.id == 'cow-744');
      final twin = snapshot['GET /animals/cow-744'] as Map<String, dynamic>;
      final facts = factsForAnimal(bella, twin: twin, now: DateTime.now());
      expect(facts['species'], 'cow');
      expect(facts['pregnant'], isTrue);
      expect(facts['lactating'], isTrue);
      expect(facts['allergies'], isEmpty);
      expect(facts['recent_medications'], isA<List>());
      // Luna carries the recorded penicillin reaction the engine must read.
      final luna = animals.firstWhere((a) => a.id == 'cow-214');
      expect(factsForAnimal(luna, twin: snapshot['GET /animals/cow-214'] as Map<String, dynamic>)['allergies'], ['penicillin_g']);
    });

    test('the bovine fever signs match the real protocol on the device as they do on the server', () {
      final animals = [for (final a in snapshot['GET /animals?farm_id=farm-origami'] as List<dynamic>) Animal.fromJson(a as Map<String, dynamic>)];
      final bella = animals.firstWhere((a) => a.id == 'cow-744');
      final facts = factsForAnimal(bella, twin: snapshot['GET /animals/cow-744'] as Map<String, dynamic>);
      final r = triageOffline(package: real, facts: facts, signs: [
        {'code': 'temperature_c', 'value_numeric': 40.4},
        {'code': 'appetite', 'value_text': 'reduced'},
        {'code': 'fever', 'present': true},
      ], subjectName: bella.name);
      expect(r.escalated, isFalse, reason: r.escalationReasons.join('; '));
      expect(r.match!.version.protocolCode, 'BOVINE-FEVER-SUPPORT');
      expect(r.match!.score, greaterThanOrEqualTo(r.match!.version.minimumMatchConfidence));
      // The same case the server triaged for the snapshot: same version, same eligibility class.
      final server = [for (final a in snapshot['GET /emergency/assessments?status=active'] as List<dynamic>) EmergencyAssessment.fromJson(a as Map<String, dynamic>)].firstWhere((a) => a.subjectId == 'cow-744');
      expect(server.selectedMatch!.protocolVersionId, r.match!.version.id);
      expect(r.match!.eligibility, server.selectedMatch!.eligibilityResult);
    });
  });
}
