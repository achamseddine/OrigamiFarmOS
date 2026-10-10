import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:farmos/domain/entities/pharmacy.dart';

/// The farm pharmacy as the tablet parses it, against the bundled
/// snapshot: eligible stays apart from on hand, every lot says why it
/// does not count, thresholds and alerts arrive intact, and a dose is
/// bound to its lot.
void main() {
  late Map<String, dynamic> snapshot;

  setUpAll(() async {
    snapshot = jsonDecode(await File('assets/demo/snapshot.json').readAsString()) as Map<String, dynamic>;
  });

  List<Map<String, dynamic>> rows(String key) => [for (final e in snapshot[key] as List<dynamic>) e as Map<String, dynamic>];

  test('the summary counts essentials, shortages and alerts', () {
    final s = PharmacySummary.fromJson(snapshot['GET /pharmacy/summary'] as Map<String, dynamic>);
    expect(s.medicines, 6);
    expect(s.essential, 5);
    expect(s.short, 2, reason: 'IV fluids below minimum, the vaccine out (its only lot is under a cold-chain exception)');
    expect(s.openAlerts, 6);
    expect(s.unseenAlerts, 6);
  });

  test('the dashboard keeps eligible apart from on hand', () {
    final medicines = {for (final m in rows('GET /pharmacy/medicines')) m['inventory_item_id'] as String: Medicine.fromJson(m)};
    final oxy = medicines['med-oxytet']!;
    expect(oxy.onHand, 160);
    expect(oxy.eligibleAvailable, 100);
    expect(oxy.expired, 60);
    expect(oxy.status, 'OK');
    expect(oxy.prescriptionRequired, isTrue);
    expect(oxy.withdrawalRules['meat_days'], 28);
    expect(oxy.categoryCodes, ['ANTIBIOTIC']);
    final vaccine = medicines['med-vaccine']!;
    expect(vaccine.storageException, isTrue);
    expect(vaccine.eligibleAvailable, 0);
    expect(vaccine.status, 'OUT');
    final nacl = medicines['med-nacl']!;
    expect(nacl.status, 'LOW');
    expect(nacl.policy!.minimum, 12);
    expect(nacl.policy!.essential, isTrue);
    expect(nacl.recommendedReorder, 16);
    expect(medicines['med-ivermectin']!.policy, isNull);
  });

  test('a lot says why it does not count', () {
    final nacl = Medicine.fromJson(snapshot['GET /pharmacy/medicines/med-nacl'] as Map<String, dynamic>);
    expect(nacl.lots, hasLength(1));
    expect(nacl.lots.single.lotCode, 'NACL-2607');
    expect(nacl.lots.single.eligible, isTrue);
    expect(nacl.lots.single.expiryDate, isNotNull);
    final vaccine = Medicine.fromJson(snapshot['GET /pharmacy/medicines/med-vaccine'] as Map<String, dynamic>);
    expect(vaccine.lots.single.eligible, isFalse);
    expect(vaccine.lots.single.ineligibleReason, 'storage_exception');
    expect(vaccine.lots.single.coldChainException, isTrue);
    final oxy = Medicine.fromJson(snapshot['GET /pharmacy/medicines/med-oxytet'] as Map<String, dynamic>);
    expect(oxy.lots.where((l) => l.ineligibleReason == 'expired').single.lotCode, 'OXY-2602');
    expect(oxy.alerts.map((a) => a.alertType), contains('EXPIRED_STOCK'));
  });

  test('alerts carry the figures and are shortages or conditions', () {
    final alerts = [for (final a in rows('GET /pharmacy/alerts')) PharmacyAlert.fromJson(a)];
    expect(alerts, hasLength(6));
    final low = alerts.firstWhere((a) => a.alertType == 'BELOW_MINIMUM_STOCK');
    expect(low.medicineName, contains('Sodium chloride'));
    expect(low.eligible, 8);
    expect(low.minimum, 12);
    expect(low.recommendedReorder, 16);
    expect(low.isShortage, isTrue);
    expect(low.isOpen, isTrue);
    expect(low.explanation, contains('not treatment advice'));
    final out = alerts.firstWhere((a) => a.alertType == 'OUT_OF_STOCK');
    expect(out.severity, 'critical');
    expect(alerts.firstWhere((a) => a.alertType == 'STORAGE_EXCEPTION').isShortage, isFalse);
  });

  test('a dose is bound to its lot and carries the authorised withdrawal', () {
    final doses = [for (final a in rows('GET /pharmacy/administrations')) MedicationAdministration.fromJson(a)];
    final willow = doses.firstWhere((a) => a.subjectId == 'goat-willow');
    expect(willow.lotCode, 'FLX-2611');
    expect(willow.treatmentId, 'treat-willow-flx');
    expect(willow.quantityConsumed, 1.5);
    expect(willow.withdrawalMeatUntil, isNotNull);
    expect(willow.withdrawalMilkUntil, isNotNull);
    expect(willow.isReversed, isFalse);
    final ducks = doses.firstWhere((a) => a.subjectType == 'group');
    expect(ducks.headCount, 5);
    expect(ducks.quantityConsumed, 5);
    expect(ducks.withdrawalMeatUntil, isNull, reason: 'the electrolyte has no withdrawal rule');
  });

  test('categories label in either language', () {
    final cats = [for (final c in rows('GET /pharmacy/categories')) MedicineCategory.fromJson(c)];
    final iv = cats.firstWhere((c) => c.code == 'IV_FLUID');
    expect(iv.label('en'), 'IV fluids');
    expect(iv.label('ar'), isNot('IV fluids'));
  });
}
