import 'package:flutter_test/flutter_test.dart';
import 'package:farmos/core/util/number_input.dart';
import 'package:farmos/features/animals/animal_scan.dart';
import 'package:farmos/domain/entities/animal.dart';
import 'package:farmos/domain/entities/livestock.dart';

void main() {
  test('localized decimal and integer inputs', () {
    expect(parseLocalizedDouble('١٢٫٥'), 12.5);
    expect(parseLocalizedDouble('12,5'), 12.5);
    expect(parseLocalizedDouble('12.5'), 12.5);
    expect(parseLocalizedInt(' ٣ '), 3);
    expect(parseLocalizedDouble('abc'), isNull);
    expect(parseLocalizedDouble('1,234.5'), isNull);
    expect(parseLocalizedDouble(''), isNull);
    expect(parseLocalizedInt('١٢٫٥'), isNull);
  });

  test('session defaults at 13:00 local time', () {
    expect(milkSessionForHour(6), 'morning');
    expect(milkSessionForHour(12), 'morning');
    expect(milkSessionForHour(13), 'evening');
    expect(milkSessionForHour(18), 'evening');
  });

  test('scan resolves only one active animal, not a retired or ambiguous tag', () {
    Animal animal(String id, String tag, {String status = 'active'}) => Animal(
      id: id,
      name: 'Test animal',
      species: 'cow',
      breed: 'Holstein',
      sex: 'F',
      birthDate: DateTime(2021),
      status: AnimalHealthStatus.healthy,
      location: 'Barn',
      healthScore: 100,
      identifiers: [
        AnimalIdentifier(id: 'identifier-$id', type: 'EAR_TAG', value: tag, isPrimary: true, status: status),
      ],
    );
    final first = animal('a1', '214');
    final second = animal('a2', '214');
    final retired = animal('a3', 'old', status: 'retired');
    expect(resolveAnimalScan('origami://animal/a1', [first, second]), first);
    expect(resolveAnimalScan('214', [first, second]), isNull);
    expect(resolveAnimalScan('old', [retired]), isNull);
    expect(resolveAnimalScan('unknown', [first]), isNull);
  });

  test('scan accepts canonical animal QR only, no arbitrary URL', () {
    expect(animalIdFromScan('origami://animal/1234'), '1234');
    expect(animalIdFromScan(' 214 '), '214');
    expect(animalIdFromScan('https://evil.example/animal/1234'), isNull);
    expect(animalIdFromScan('origami://animal/1234?redirect=evil'), isNull);
    expect(animalIdFromScan('origami://pen/1234'), isNull);
    expect(animalIdFromScan(''), isNull);
  });
}
