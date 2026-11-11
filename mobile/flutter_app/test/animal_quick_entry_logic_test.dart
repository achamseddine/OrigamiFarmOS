import 'package:flutter_test/flutter_test.dart';
import 'package:farmos/core/util/number_input.dart';
import 'package:farmos/features/animals/animal_scan.dart';

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

  test('scan accepts canonical animal QR only, no arbitrary URL', () {
    expect(animalIdFromScan('origami://animal/1234'), '1234');
    expect(animalIdFromScan(' 214 '), '214');
    expect(animalIdFromScan('https://evil.example/animal/1234'), isNull);
    expect(animalIdFromScan('origami://animal/1234?redirect=evil'), isNull);
    expect(animalIdFromScan('origami://pen/1234'), isNull);
    expect(animalIdFromScan(''), isNull);
  });
}
