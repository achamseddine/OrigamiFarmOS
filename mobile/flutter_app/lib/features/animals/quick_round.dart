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
      final inRound = [for (final a in animals) if (a.onFarm && a.lactating && milked(a)) a];
      final recorded = {for (final r in milk) if (r.session == round.session && _sameDay(r.recordedAt, today)) r.animalId};
      return RoundStatus([for (final a in inRound) RoundEntry(a, done: recorded.contains(a.id))]);
    case RoundKind.feeding:
      final byId = {for (final a in animals) if (a.onFarm) a.id: a};
      return RoundStatus([
        for (final line in plan.lines)
          if (line.subjectType == 'animal' && line.program != null && byId.containsKey(line.subjectId))
            RoundEntry(byId[line.subjectId]!, done: fedToday(line.subjectId).length >= (line.program!.feedingsPerDay < 1 ? 1 : line.program!.feedingsPerDay)),
      ]);
  }
}

/// This animal's milkings recorded today, earliest first.
List<MilkRecord> milkToday(String animalId, List<MilkRecord> milk, {DateTime? now}) {
  final today = now ?? DateTime.now();
  return [for (final r in milk) if (r.animalId == animalId && _sameDay(r.recordedAt, today)) r]..sort((a, b) => a.recordedAt.compareTo(b.recordedAt));
}

/// A milking already recorded today in [session] — what a second save in
/// that session would duplicate.
MilkRecord? sameSessionToday(String animalId, String session, List<MilkRecord> milk, {DateTime? now}) {
  for (final r in milkToday(animalId, milk, now: now)) {
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

/// The feedings recorded today for one subject (not reversed).
int feedingsToday(String subjectId, List<FeedingEvent> events, {DateTime? now}) {
  final today = now ?? DateTime.now();
  return events.where((e) => e.subjectId == subjectId && e.status == 'recorded' && _sameDay(e.occurredAt, today)).length;
}
