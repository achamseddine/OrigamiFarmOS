import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:farmos/domain/entities/emergency.dart';

/// The emergency protocol engine as the tablet parses it, against the
/// bundled snapshot: a matched case with its evidence and warnings, an
/// escalated case with its reasons, the approved protocols with their
/// approval provenance, and the sign vocabulary.
void main() {
  late Map<String, dynamic> snapshot;

  setUpAll(() async {
    snapshot = jsonDecode(await File('assets/demo/snapshot.json').readAsString()) as Map<String, dynamic>;
  });

  List<Map<String, dynamic>> rows(String key) => [for (final e in snapshot[key] as List<dynamic>) e as Map<String, dynamic>];

  test('the summary counts protocols and live cases', () {
    final s = EmergencySummary.fromJson(snapshot['GET /emergency/summary'] as Map<String, dynamic>);
    expect(s.protocols, 3);
    expect(s.activeProtocols, 2, reason: 'the equine colic draft is not operational');
    expect(s.openAssessments, 1);
    expect(s.escalated, 1);
    expect(s.modelReference, 'origami.emergency.deterministic');
  });

  test('a matched case explains itself and waits for a person', () {
    final cases = [for (final a in rows('GET /emergency/assessments?status=active')) EmergencyAssessment.fromJson(a)];
    final bella = cases.firstWhere((a) => a.subjectId == 'cow-744');
    expect(bella.awaitingConfirmation, isTrue);
    expect(bella.triageLevel, 'HIGH');
    expect(bella.confidence, greaterThan(0.85));
    final match = bella.selectedMatch!;
    expect(match.protocolCode, 'BOVINE-FEVER-SUPPORT');
    expect(match.startable, isTrue);
    expect(match.eligibilityResult, 'WARN');
    expect(match.supporting.map((e) => e['code']), containsAll(['temperature_c', 'fever', 'appetite']));
    expect(match.missing.map((e) => e['code']), contains('rumination'));
    expect(match.warnings.any((w) => w.contains('Pregnant')), isTrue);
    expect(bella.explanation, contains('Confirm to start the protocol'));
    expect(bella.observedSigns.where((s) => s['source'] == 'observation'), isNotEmpty, reason: 'the morning fever observation counts as evidence');
  });

  test('an escalated case names its reasons and shows no drug', () {
    final cases = [for (final a in rows('GET /emergency/assessments?status=active')) EmergencyAssessment.fromJson(a)];
    final rasha = cases.firstWhere((a) => a.subjectId == 'goat-189');
    expect(rasha.isEscalated, isTrue);
    expect(rasha.selectedMatch, isNull);
    expect(rasha.matches, isEmpty);
    expect(rasha.escalationReasons.single, contains('no current veterinarian-approved protocol'));
    expect(rasha.explanation, contains('No drug, dose or route is shown'));
  });

  test('protocols carry their approval provenance and the medication rule', () {
    final protocols = [for (final p in rows('GET /emergency/protocols')) EmergencyProtocol.fromJson(p)];
    final bovine = protocols.firstWhere((p) => p.code == 'BOVINE-FEVER-SUPPORT');
    expect(bovine.isActive, isTrue);
    expect(bovine.approvedByName, 'Dr. Layla Haddad');
    expect(bovine.approvalReference, 'VET-2026-014');
    expect(bovine.offlineEligible, isTrue);
    final med = bovine.steps.firstWhere((s) => s.isMedication).medication!;
    expect(med['dose_rule_type'], 'PER_WEIGHT');
    expect(med['maximum_dose_quantity'], 30);
    expect(med['route_code'], 'IM');
    final draft = protocols.firstWhere((p) => p.code == 'EQUINE-COLIC-SUPPORT');
    expect(draft.isActive, isFalse);
    expect(draft.currentVersionNo, isNull);
    expect(draft.steps, isEmpty, reason: 'a draft has no current version to run');
  });

  test('the sign vocabulary has measurements, choices and yes/no', () {
    final codes = [for (final c in rows('GET /emergency/sign-codes')) SignCode.fromJson(c)];
    final temp = codes.firstWhere((c) => c.code == 'temperature_c');
    expect(temp.kind, 'numeric');
    expect(temp.unit, '°C');
    final appetite = codes.firstWhere((c) => c.code == 'appetite');
    expect(appetite.kind, 'categorical');
    expect(appetite.options, contains('reduced'));
    expect(codes.firstWhere((c) => c.code == 'panting').kind, 'boolean');
  });

  test('a run parses its steps and the prepared dose', () {
    final run = EmergencyRun.fromJson({
      'id': 'run-1', 'assessment_id': 'a-1', 'protocol_code': 'BOVINE-FEVER-SUPPORT', 'version_no': 1, 'approval_reference': 'VET-2026-014',
      'subject_type': 'animal', 'subject_id': 'cow-744', 'status': 'in_progress', 'next_step_id': 's-3', 'reassessment_overdue': false,
      'steps': [
        {'id': 's-1', 'sequence': 0, 'status': 'completed', 'result': {}, 'step': {'id': 'p1', 'step_no': 1, 'step_type': 'ASSESS', 'title': 'Check', 'instructions': 'x', 'required': true}},
        {'id': 's-3', 'sequence': 2, 'status': 'presented', 'result': {'dose_quantity': 27.28, 'dose_unit': 'ml', 'route_code': 'IM', 'lot_code': 'FLX-2611', 'problems': []},
         'step': {'id': 'p3', 'step_no': 3, 'step_type': 'MEDICATION', 'title': 'Flunixin', 'instructions': 'x', 'required': true,
                  'medication': {'medicine_name': 'Flunixin', 'route_code': 'IM', 'dose_rule_type': 'PER_WEIGHT', 'dose_per_weight_quantity': 0.044, 'dose_unit': 'ml', 'weight_unit': 'kg'}}},
      ],
    });
    expect(run.isActive, isTrue);
    expect(run.nextStep!.step.isMedication, isTrue);
    expect(run.nextStep!.result['lot_code'], 'FLX-2611');
    expect(run.nextStep!.problems, isEmpty);
    expect(run.steps.first.isDone, isTrue);
  });
}
