import '../../domain/entities/animal.dart';
import '../../domain/entities/livestock.dart';

/// The QR grammar of the worker workflow (docs/QR-ANIMAL-QUICK-ENTRY.md,
/// architecture/ADR-003-QR-SCANNING-AND-LABELS.md).
///
///   `origami://animal/{animal uuid}`   a label on the animal's own tag
///   `origami://group/{group uuid}`     a label on a pen, a herd board, a coop
///
/// The payload is an opaque canonical id — never an authorization token,
/// never a name or a health fact. A label on a stall is a *group* label: it
/// opens the pen, never "whichever animal stood there yesterday". Anything
/// else — a foreign URL, an unknown or retired tag, a tag two animals share
/// — resolves to nothing, and nothing is written.

const _scheme = 'origami';

String animalQrPayload(String animalId) => '$_scheme://animal/$animalId';
String groupQrPayload(String groupId) => '$_scheme://group/$groupId';

/// The canonical animal id inside an `origami://animal/…` code, or the
/// trimmed text itself when it is not a URL (a typed tag). Null for any
/// other URL.
String? animalIdFromScan(String raw) {
  final parsed = parseScan(raw);
  return switch (parsed) {
    ScanCode(:final kind, :final value) when kind == ScanKind.animal || kind == ScanKind.typed => value,
    _ => null,
  };
}

enum ScanKind { animal, group, typed }

class ScanCode {
  const ScanCode(this.kind, this.value);
  final ScanKind kind;
  final String value;
}

/// What a scanned or typed string says, before anything is looked up.
ScanCode? parseScan(String raw) {
  final input = raw.trim();
  if (input.isEmpty) return null;
  if (!input.contains('://')) return ScanCode(ScanKind.typed, input);
  final uri = Uri.tryParse(input);
  if (uri == null ||
      uri.scheme != _scheme ||
      uri.pathSegments.length != 1 ||
      uri.pathSegments.single.isEmpty ||
      uri.query.isNotEmpty ||
      uri.fragment.isNotEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasPort) {
    return null;
  }
  return switch (uri.host) {
    'animal' => ScanCode(ScanKind.animal, uri.pathSegments.single),
    'group' => ScanCode(ScanKind.group, uri.pathSegments.single),
    _ => null,
  };
}

/// Never fall back to the first animal. Duplicate/retired identifiers and
/// unknown codes must fail closed and ask the worker to verify the label.
Animal? resolveAnimalScan(String raw, Iterable<Animal> animals) {
  final code = parseScan(raw);
  if (code == null || code.kind == ScanKind.group) return null;
  final value = code.value;
  if (code.kind == ScanKind.animal) {
    final byId = animals.where((a) => a.id == value && a.onFarm).toList();
    return byId.length == 1 ? byId.single : null;
  }
  final needle = value.toLowerCase();
  final matches = animals.where((animal) =>
      animal.onFarm &&
      (animal.id == value ||
          (animal.identifiers.isEmpty && animal.tag != null && animal.tag!.toLowerCase() == needle) ||
          animal.activeIdentifiers.any((i) => i.value.toLowerCase() == needle))).toList();
  return matches.length == 1 ? matches.single : null;
}

/// What a scan points at, on this farm.
sealed class ScanTarget {
  const ScanTarget();
}

class AnimalScanTarget extends ScanTarget {
  const AnimalScanTarget(this.animal);
  final Animal animal;
}

class GroupScanTarget extends ScanTarget {
  const GroupScanTarget(this.group);
  final AnimalGroup group;
}

/// Why a scan opened nothing — said to the worker in plain words.
enum ScanMiss { notOurs, unknown, ambiguous }

class NoScanTarget extends ScanTarget {
  const NoScanTarget(this.reason);
  final ScanMiss reason;
}

/// Resolves a scan against this farm's animals and groups only — the lists
/// the signed-in person was given — so a label from another farm, or one
/// for an animal that left, opens nothing.
ScanTarget resolveScan(String raw, {required Iterable<Animal> animals, required Iterable<AnimalGroup> groups}) {
  final code = parseScan(raw);
  if (code == null) return const NoScanTarget(ScanMiss.notOurs);
  if (code.kind == ScanKind.group) {
    final hits = groups.where((g) => g.id == code.value).toList();
    return hits.length == 1 ? GroupScanTarget(hits.single) : const NoScanTarget(ScanMiss.unknown);
  }
  final animal = resolveAnimalScan(raw, animals);
  if (animal != null) return AnimalScanTarget(animal);
  if (code.kind == ScanKind.typed) {
    final needle = code.value.toLowerCase();
    final shared = animals.where((a) => a.onFarm && a.activeIdentifiers.any((i) => i.value.toLowerCase() == needle)).length;
    if (shared > 1) return const NoScanTarget(ScanMiss.ambiguous);
  }
  return const NoScanTarget(ScanMiss.unknown);
}

/// Session is a suggestion based on local farm time, not evidence of milking.
String milkSessionForHour(int hour) => hour < 13 ? 'morning' : 'evening';
