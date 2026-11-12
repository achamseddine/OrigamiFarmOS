import 'package:flutter_test/flutter_test.dart';
import 'package:farmos/data/local/cache_effects.dart';
import 'package:farmos/data/local/outbox_labels.dart';

/// What an offline (or standalone) livestock write does to the screens
/// before the server answers: the prediction, not the truth — the server's
/// own response replaces it on the first refresh after the queue drains.
void main() {
  List<CacheEffect> fx(String path, Map<String, dynamic> body) => effectsFor('POST', path, body, localId: 'local-1');

  test('a positive check marks the animal pregnant on its row, its twin and its summary', () {
    final effects = fx('/animals/cow-9/pregnancy-checks', {'result_code': 'POSITIVE', 'assessment_type': 'ULTRASOUND'});
    final row = effects.whereType<MergeRecord>().single;
    expect(row.collectionPath, '/animals');
    expect(row.patch, {'pregnant': true});
    final nested = effects.whereType<PatchNested>().single;
    expect(nested.field, 'reproduction');
    expect(nested.patch['pregnant'], isTrue);
    expect(effects.whereType<AppendRecord>().single.listKey, 'assessments');
  });

  test('an inconclusive check changes no state, only records the check', () {
    final effects = fx('/animals/cow-9/pregnancy-checks', {'result_code': 'INCONCLUSIVE'});
    expect(effects.whereType<MergeRecord>(), isEmpty);
    expect(effects.whereType<PatchNested>().single.patch.containsKey('pregnant'), isFalse);
  });

  test('a birth ends the pregnancy and, when asked, starts milking', () {
    final effects = fx('/animals/cow-9/births', {
      'start_lactation': true,
      'offspring': [
        {'outcome_code': 'LIVE'},
        {'outcome_code': 'STILLBORN'},
      ],
    });
    expect(effects.whereType<MergeRecord>().single.patch, {'pregnant': false, 'lactating': true});
    final birth = effects.whereType<AppendRecord>().single;
    expect(birth.listKey, 'births');
    expect(birth.record['live_count'], 1);
  });

  test('an exit takes the animal off the herd list and marks its record', () {
    final effects = fx('/animals/cow-9/exit', {'exit_type': 'sold'});
    expect(effects.whereType<RemoveRecord>().single.collectionPath, '/animals');
    expect(effects.whereType<PatchDocument>().single.patch['lifecycle_status'], 'sold');
  });

  test('a head-count event moves the flock count by its delta', () {
    final effects = fx('/animal-groups/flock-1/quantity-events', {'event_type': 'DEATH', 'quantity_delta': -3});
    final adjust = effects.whereType<AdjustNumber>().single;
    expect((adjust.collectionPath, adjust.id, adjust.field, adjust.delta), ('/animal-groups', 'flock-1', 'count', -3.0));
  });

  test('a hatch counts the chicks into the destination flock', () {
    final effects = fx('/incubations/inc-1/hatch', {'hatched_live': 40, 'destination_group_id': 'flock-1'});
    expect(effects.whereType<AdjustNumber>().single.delta, 40);
    expect(effects.whereType<MergeRecord>().single.patch['status'], 'hatched');
  });

  test('a group move shows the new herd name before the server answers', () {
    final effects = fx('/animal-groups/grp-1/members', {'animal_id': 'cow-9', 'group_name': 'Dry Cow Pen'});
    expect(effects.whereType<MergeRecord>().single.patch, {'group_name': 'Dry Cow Pen'});
    final end = effectsFor('POST', '/animal-groups/grp-1/members/cow-9/end', const {}, localId: 'l');
    expect(end.whereType<RemoveRecord>().single.idField, 'animal_id');
  });

  test('queued livestock writes are labelled in the outbox', () {
    expect(describeWrite('/animal-groups/grp-1/members').labelKey, 'outboxGroup');
    expect(describeWrite('/births/b-1/offspring/1/register').labelKey, 'outboxBirth');
    expect(describeWrite('/incubations').labelKey, 'outboxIncubation');
    expect(describeWrite('/animals/cow-9/births').labelKey, 'outboxAnimal');
  });
}
