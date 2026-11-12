import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:farmos/domain/entities/animal.dart';
import 'package:farmos/domain/entities/livestock.dart';
import 'package:farmos/domain/entities/reproduction.dart';

/// The livestock record as the server sends it — read from the bundled
/// snapshot, which is the API's own output (backend/app/export_demo_snapshot.py),
/// so these prove the tablet parses what the server really says.
void main() {
  late Map<String, dynamic> snapshot;
  setUpAll(() {
    snapshot = jsonDecode(File('assets/demo/snapshot.json').readAsStringSync()) as Map<String, dynamic>;
  });

  Map<String, dynamic> get(String path) => snapshot['GET $path'] as Map<String, dynamic>;
  List<dynamic> list(String path) => snapshot['GET $path'] as List<dynamic>;

  test("Bella's record: inseminated, scanned positive, pregnant and due", () {
    final t = ReproTimeline.fromJson(get('/animals/cow-744/reproduction'));
    expect(t.summary.applies.pregnancy && t.summary.applies.liveBirth && t.summary.applies.lactation, isTrue);
    expect(t.summary.pregnant, isTrue);
    expect(t.summary.pregnancy!.daysPregnant, inInclusiveRange(119, 121));
    expect(t.summary.pregnancy!.expectedDueDate, isNotNull);
    expect(t.summary.birthTerm(false), 'Calving');
    expect(t.breedings.single.eventType, 'ARTIFICIAL_INSEMINATION');
    expect(t.breedings.single.sire, contains('HOL-4471'));
    expect(t.checks.single.resultCode, 'POSITIVE');
    expect(t.summary.lactation!.number, 2);
  });

  test("Luna's calving left a heifer calf to register", () {
    final t = ReproTimeline.fromJson(get('/animals/cow-214/reproduction'));
    final birth = t.births.single;
    expect(birth.liveCount, 1);
    expect(birth.offspring.single.registrable, isTrue);
    expect(birth.offspring.single.sex, 'F');
    expect(t.lactations.first.active, isTrue);
  });

  test('a hen has no pregnancy or birth to offer', () {
    final s = ReproSummary.fromJson((get('/animals/hen-247')['reproduction'] as Map).cast<String, dynamic>());
    expect(s.applies.pregnancy, isFalse);
    expect(s.applies.liveBirth, isFalse);
  });

  test('the overview names who is due and who waits for a check', () {
    final o = ReproOverview.fromJson(get('/reproduction/overview'));
    expect(o.pregnant.map((p) => p['animal_id']), contains('cow-744'));
    expect(o.awaitingCheck.map((p) => p['animal_id']), contains('sheep-s045'));
    expect(o.inMilk, 5);
    expect(o.incubations.single.incubating, isTrue);
  });

  test('a herd counts its members; a flock keeps a ledger', () {
    final groups = [for (final g in list('/animal-groups')) AnimalGroup.fromJson(g as Map<String, dynamic>)];
    final herd = groups.firstWhere((g) => g.id == 'grp-dairy-herd');
    final layers = groups.firstWhere((g) => g.id == 'flock-layer');
    expect(herd.countsMembers, isTrue);
    expect(layers.trackingMode, 'HYBRID');
    final members = [for (final m in list('/animal-groups/grp-dairy-herd/members')) GroupMembership.fromJson(m as Map<String, dynamic>)];
    expect(members.map((m) => m.animalId).toSet(), {'cow-744', 'cow-214', 'cow-clover'});
    expect(members.every((m) => m.current), isTrue);
    final ledger = [for (final e in list('/animal-groups/flock-layer/quantity-events')) QuantityEvent.fromJson(e as Map<String, dynamic>)];
    expect(ledger.first.resulting, layers.count);
    expect(ledger.fold<int>(0, (sum, e) => sum + e.delta), layers.count);
  });

  test('the twin carries groups, parentage and the state history', () {
    final twin = get('/animals/cow-214');
    final animal = Animal.fromJson(twin);
    expect(animal.onFarm, isTrue);
    expect(animal.lifecycleStatus, 'active');
    final groups = [for (final m in twin['groups'] as List<dynamic>) GroupMembership.fromJson(m as Map<String, dynamic>)];
    expect(groups.single.groupName, 'Dairy Herd');
    final history = [for (final h in twin['recent_history'] as List<dynamic>) StateChange.fromJson(h as Map<String, dynamic>)];
    expect(history.map((h) => h.stateType).toSet(), containsAll(['STATUS', 'LIFE_STAGE', 'LOCATION']));
  });

  test('head-count signs match the server', () {
    expect(ReproCodes.sign('DEATH'), -1);
    expect(ReproCodes.sign('PURCHASE'), 1);
    expect(ReproCodes.sign('COUNT_ADJUSTMENT'), 0);
  });
}
