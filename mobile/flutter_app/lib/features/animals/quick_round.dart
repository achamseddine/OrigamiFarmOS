import '../../core/util/number_input.dart';
import '../../domain/entities/animal.dart';
import '../../domain/entities/feeding.dart';
import '../../domain/entities/production_records.dart';

/// The rules under the scan-first worker screen, kept apart from the
/// widgets so they are tested on their own:
///
///   - a **round** (the 06:00 milking, the individual feeding round) and
///     which of its animals are already recorded today;
///   - what was **already recorded today** for one animal, so a second
///     morning milking is a decision, not an accident;
///   - the **feed rows** an animal's own program gives, with the planned
///     amount per feeding as a hint — never as a recorded fact.

bool _sameDay(DateTime a, DateTime b) {
  final l = a.toLocal();
  return l.year == b.year && l.month == b.month && l.day == b.day;
}

enum RoundKind { milking, feeding }

/// A round a worker walks: a milking session, or the animals fed on a
/// program of their own.
class QuickRound {
  const QuickRound.milking(this.session) : kind = RoundKind.milking;
  const QuickRound.feeding()
      : kind = RoundKind.feeding,
        session = null;

  final RoundKind kind;

  /// morning | evening — for a milking round.
  final String? session;
}

class RoundEntry {
  const RoundEntry(this.animal, {required this.done});
  final Animal animal;
  final bool done;
}

class RoundStatus {
  const RoundStatus(this.entries);
  final List<RoundEntry> entries;

  int get done => entries.where((e) => e.done).length;
  int get total => entries.length;
  bool get complete => total > 0 && done == total;
  List<Animal> get pending => [for (final e in entries) if (!e.done) e.animal];
  bool contains(String animalId) => entries.any((e) => e.animal.id == animalId);
}

/// Who is in [round] and who is already recorded today. A milking round is
/// the animals in milk that are milked at all; a feeding round is every
/// animal on a program of its own, done once today's feedings reach the
/// program's feedings per day.
/// The order a worker walks a queue: by tag in natural order — the letters
/// before the number first (plain numbers, then "G-…", then "S-…"), then
/// the number as a number, so cow 9 comes before cow 10 — then by name.
int queueOrder(Animal a, Animal b) {
  (String, int?, String) key(Animal x) {
    final tag = (x.tag ?? '').trim().toUpperCase();
    // An animal with no tag comes after every tagged one.
    if (tag.isEmpty) return ('\u{10FFFF}', null, '');
    final m = RegExp(r'^([^0-9]*)([0-9]+)(.*)$').firstMatch(tag);
    if (m == null) return (tag, null, '');
    return (m.group(1)!.replaceAll(RegExp(r'[^A-Z]'), ''), int.parse(m.group(2)!), m.group(3)!);
  }

  final (pa, na, ra) = key(a);
  final (pb, nb, rb) = key(b);
  if (pa != pb) return pa.compareTo(pb);
  if (na != null && nb != null && na != nb) return na.compareTo(nb);
  if (na != null && nb == null) return -1;
  if (na == null && nb != null) return 1;
  final rest = ra.compareTo(rb);
  return rest != 0 ? rest : a.name.toLowerCase().compareTo(b.name.toLowerCase());
}

/// The order a milking is walked (v0.8.2): the cows' numbers in the
/// milking queue first — the manager sets them, the line the cows come in
/// — then any cow without a number, by tag as [queueOrder]. The farm
/// server's milk report uses the same order (farm_reports_service.queue_key).
int milkingQueueOrder(Animal a, Animal b) {
  final na = a.milkingQueueNumber;
  final nb = b.milkingQueueNumber;
  if (na != null && nb != null && na != nb) return na.compareTo(nb);
  if (na != null && nb == null) return -1;
  if (na == null && nb != null) return 1;
  return queueOrder(a, b);
}

/// The animal in [status] holding queue number [typed] ("4", "No. 4",
/// "#4"), or null — a cow opened by her number when it is typed in.
Animal? byQueueNumber(RoundStatus status, String typed) {
  final m = RegExp(r'^\s*(?:no\.?|#|n°|رقم)?\s*([0-9\u0660-\u0669\u06F0-\u06F9]{1,3})\s*$', caseSensitive: false).firstMatch(typed);
  if (m == null) return null;
  final n = parseLocalizedInt(m.group(1)!);
  if (n == null) return null;
  for (final e in status.entries) {
    if (e.animal.milkingQueueNumber == n) return e.animal;
  }
  return null;
}

/// The next animal still to do in [status] after [after] (going round to
/// the start of the queue), or the first one still to do when [after] is
/// null. Null when the queue is done. Animals in [passed] — saved or
/// skipped already in this run — are not offered again.
Animal? nextInQueue(RoundStatus status, {String? after, Set<String> passed = const {}}) {
  final entries = status.entries;
  if (entries.isEmpty) return null;
  final at = after == null ? -1 : entries.indexWhere((e) => e.animal.id == after);
  for (var i = 1; i <= entries.length; i++) {
    final e = entries[(at + i) % entries.length];
    if (!e.done && e.animal.id != after && !passed.contains(e.animal.id)) return e.animal;
  }
  return null;
}

/// One milking's queue on [now]'s day — [roundStatus] for a milking
/// round, for screens that hold no feeding plan (the manual milk entry).
RoundStatus milkingRoundStatus(
  String session, {
  required List<Animal> animals,
  required bool Function(Animal) milked,
  required List<MilkRecord> milk,
  DateTime? now,
}) =>
    roundStatus(QuickRound.milking(session),
        animals: animals, milked: milked, milk: milk, plan: DailyPlan.empty, fedToday: (_) => const [], now: now);

RoundStatus roundStatus(
  QuickRound round, {
  required List<Animal> animals,
  required bool Function(Animal) milked,
  required List<MilkRecord> milk,
  required DailyPlan plan,
  required List<FeedingEvent> Function(String subjectId) fedToday,
  DateTime? now,
}) {
  final today = now ?? DateTime.now();
  switch (round.kind) {
    case RoundKind.milking:
      final inRound = [for (final a in animals) if (a.onFarm && a.lactating && milked(a)) a]..sort(milkingQueueOrder);
      final recorded = {for (final r in milk) if (r.session == round.session && _sameDay(r.recordedAt, today)) r.animalId};
      return RoundStatus([for (final a in inRound) RoundEntry(a, done: recorded.contains(a.id))]);
    case RoundKind.feeding:
      final byId = {for (final a in animals) if (a.onFarm) a.id: a};
      return RoundStatus([
        for (final line in plan.lines)
          if (line.subjectType == 'animal' && line.program != null && byId.containsKey(line.subjectId))
            RoundEntry(byId[line.subjectId]!, done: fedToday(line.subjectId).length >= (line.program!.feedingsPerDay < 1 ? 1 : line.program!.feedingsPerDay)),
      ]..sort((a, b) => queueOrder(a.animal, b.animal)));
  }
}

/// This animal's milkings recorded today, earliest first.
List<MilkRecord> milkToday(String animalId, List<MilkRecord> milk, {DateTime? now}) {
  final today = now ?? DateTime.now();
  return [for (final r in milk) if (r.animalId == animalId && _sameDay(r.recordedAt, today)) r]..sort((a, b) => a.recordedAt.compareTo(b.recordedAt));
}

/// A milking already recorded today in [session] — what a second save in
/// that session would duplicate.
MilkRecord? sameSessionToday(String animalId, String session, List<MilkRecord> milk, {DateTime? now}) =>
    sameSessionOn(animalId, session, now ?? DateTime.now(), milk);

/// The same for any [day] — milk entered for an earlier day.
MilkRecord? sameSessionOn(String animalId, String session, DateTime day, List<MilkRecord> milk) {
  for (final r in milkToday(animalId, milk, now: day)) {
    if (r.session == session) return r;
  }
  return null;
}

/// One feed line the worker fills in: the product the program names, its
/// unit, and the program's amount for one feeding (a hint).
class FeedRowSeed {
  const FeedRowSeed({required this.productId, required this.productName, required this.unit, this.plannedPerFeeding});
  final String productId;
  final String productName;
  final String unit;
  final double? plannedPerFeeding;
}

/// The feed rows an animal's program gives — its own or its group's. An
/// animal on no program gets none, and the screen falls back to rows the
/// worker chooses products for.
List<FeedRowSeed> feedRowsFromPlan(FeedingPlan? plan) {
  if (plan == null) return const [];
  final perDay = plan.program?.feedingsPerDay ?? 1;
  final feedings = perDay < 1 ? 1 : perDay;
  return [
    for (final t in plan.dailyTargets)
      FeedRowSeed(
        productId: t.feedProductId,
        productName: t.productName ?? t.feedProductId,
        unit: t.unit,
        plannedPerFeeding: t.dailyTotal > 0 ? t.dailyTotal / feedings : null,
      ),
  ];
}

/// The feedings given today for one subject: recorded, not reversed, and
/// stock-moving — a refusal or an intake estimate is not a feeding
/// (v0.8.6). "Today" is the farm's day from [plan] when it has one.
int feedingsToday(String subjectId, List<FeedingEvent> events, {DateTime? now, DailyPlan? plan}) =>
    events.where((e) => e.subjectId == subjectId && e.countsAsFed && onFarmToday(e.occurredAt, plan, now: now)).length;
