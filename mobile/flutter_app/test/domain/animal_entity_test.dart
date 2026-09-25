import 'package:flutter_test/flutter_test.dart';
import 'package:farmos/domain/entities/animal.dart';

/// The generic animal model on the tablet (§1, §4): species is a code,
/// identifiers are typed rows, and an animal registered with no ear tag
/// still has something to show after the `#`.
void main() {
  Map<String, dynamic> hen({String? tag, List<Map<String, dynamic>> identifiers = const []}) => {
        'id': 'hen-1',
        'tag': tag,
        'name': 'Henrietta',
        'species': 'layer_hen',
        'breed': 'Lohmann Brown',
        'sex': 'F',
        'birth_date': '2025-03-01T00:00:00Z',
        'birth_date_estimated': true,
        'life_stage': 'adult',
        'management_profile': 'layer',
        'status': 'healthy',
        'location_label': 'Coop 2',
        'health_score': 88,
        'identifiers': identifiers,
      };

  group('Animal.fromJson', () {
    test('parses the generic model fields', () {
      final a = Animal.fromJson(hen(tag: 'LB-7', identifiers: [
        {'id': 'i1', 'identifier_type': 'LEG_BAND', 'identifier_value': 'LB-7', 'is_primary': true, 'status': 'active'},
      ]));
      expect(a.species, 'layer_hen');
      expect(a.lifeStage, 'adult');
      expect(a.managementProfile, 'layer');
      expect(a.birthDateEstimated, isTrue);
      expect(a.ageLabel, startsWith('~'));
      expect(a.identifiers.single.type, 'LEG_BAND');
      expect(a.primaryId, 'LB-7');
    });

    test('a species the app has never heard of is kept as its code, not coerced', () {
      final a = Animal.fromJson({...hen(), 'species': 'camel'});
      expect(a.species, 'camel');
    });

    test('an animal with no identifiers at all shows nothing after the #, never null', () {
      final a = Animal.fromJson(hen());
      expect(a.tag, isNull);
      expect(a.primaryId, '');
      expect(a.primaryIdentifier, isNull);
    });
  });

  group('identifiers', () {
    final a = Animal.fromJson(hen(identifiers: [
      {'id': 'old', 'identifier_type': 'LEG_BAND', 'identifier_value': 'LB-1', 'is_primary': false, 'status': 'retired'},
      {'id': 'farm', 'identifier_type': 'FARM_NUMBER', 'identifier_value': 'F-22', 'is_primary': false, 'status': 'active'},
      {'id': 'new', 'identifier_type': 'LEG_BAND', 'identifier_value': 'LB-9', 'is_primary': true, 'status': 'active'},
    ]));

    test('the primary one wins the # spot; retired ones are not shown', () {
      expect(a.primaryId, 'LB-9');
      expect(a.activeIdentifiers.map((i) => i.id), ['farm', 'new']);
    });

    test('without a primary flag the first active identifier is used', () {
      final b = Animal.fromJson(hen(identifiers: [
        {'id': 'x', 'identifier_type': 'FARM_NUMBER', 'identifier_value': 'F-1', 'is_primary': false, 'status': 'active'},
      ]));
      expect(b.primaryId, 'F-1');
    });

    test('search finds an animal by a tag it no longer wears', () {
      expect(a.matches('lb-1'), isTrue, reason: 'a retired tag still points at the animal it was on');
      expect(a.matches('f-22'), isTrue);
      expect(a.matches('henri'), isTrue);
      expect(a.matches('zzz'), isFalse);
    });

    test('copyWith carries the identifiers and the resolver inputs through', () {
      final moved = a.copyWith(location: 'Coop 3');
      expect(moved.identifiers, a.identifiers);
      expect(moved.lifeStage, 'adult');
      expect(moved.managementProfile, 'layer');
      expect(moved.location, 'Coop 3');
    });
  });
}
