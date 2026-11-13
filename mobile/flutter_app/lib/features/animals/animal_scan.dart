import '../../domain/entities/animal.dart';

/// The QR payload is an opaque canonical Animal UUID, never an authorization
/// token or a location/pen identifier. Keyboard-wedge scanners type it here.
/// QR generation and camera decoding are separate deployment capabilities.
String? animalIdFromScan(String raw) {
  final input = raw.trim();
  if (input.isEmpty) return null;
  if (!input.contains('://')) return input;
  final uri = Uri.tryParse(input);
  if (uri == null ||
      uri.scheme != 'origami' ||
      uri.host != 'animal' ||
      uri.pathSegments.length != 1 ||
      uri.query.isNotEmpty ||
      uri.fragment.isNotEmpty ||
      uri.userInfo.isNotEmpty) {
    return null;
  }
  return uri.pathSegments.single;
}

/// Never fall back to the first animal. Duplicate/retired identifiers and
/// unknown codes must fail closed and ask the worker to verify the label.
Animal? resolveAnimalScan(String raw, Iterable<Animal> animals) {
  final code = animalIdFromScan(raw);
  if (code == null) return null;
  final matches = animals.where((animal) =>
      animal.id == code ||
      (animal.identifiers.isEmpty && animal.tag != null && animal.tag!.toLowerCase() == code.toLowerCase()) ||
      animal.activeIdentifiers.any((i) => i.value.toLowerCase() == code.toLowerCase())).toList();
  return matches.length == 1 ? matches.single : null;
}

/// Session is a suggestion based on local farm time, not evidence of milking.
String milkSessionForHour(int hour) => hour < 13 ? 'morning' : 'evening';
