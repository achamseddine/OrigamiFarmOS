import 'feeding.dart';

/// One round of feed is not counted twice (v0.8.7, audit I-12) — the
/// tablet's and the browser's side of `find_overlapping_feedings` on the
/// server (backend/app/services/feeding_program_service.py).
///
/// A head fed with her group and on her own, the same feed, within a
/// feeding round, may have been fed twice: the person is asked, in their
/// language, before anything is sent, and a real extra feeding goes with
/// `confirm_additional_feeding: true`. The check reads only what this
/// device already holds — today's plan (which group rations feed which
/// animals, `covered_animal_ids`; who has a supplement) and the recent
/// feedings, including ones recorded here offline — so it works without a
/// connection. The server checks again and remains the authority: what
/// this device cannot see (another tablet's feeding not synced yet) comes
/// back as "Possible duplicate: …", asked by the generic question.
const feedingRoundWindow = Duration(hours: 1);

enum FeedingOverlapKind { animalAfterGroup, groupAfterAnimal }

class FeedingOverlap {
  const FeedingOverlap({
    required this.kind,
    required this.groupId,
    required this.groupName,
    required this.animalIds,
    required this.productIds,
    required this.other,
    required this.heads,
  });

  final FeedingOverlapKind kind;
  final String groupId;
  final String groupName;

  /// The heads both feedings feed.
  final List<String> animalIds;

  /// The feeds both name.
  final List<String> productIds;

  /// The other feeding of the round — the group's, or the first animal's own.
  final FeedingEvent other;

  /// The heads the group's ration feeds.
  final int heads;
}

/// The overlap the feeding [body] (as sent to `POST /feeding-events`)
/// would make with what is already recorded, or null.
FeedingOverlap? findFeedingOverlap(Map<String, dynamic> body, {required DailyPlan plan, required List<FeedingEvent> events, DateTime? now}) {
  if (body['confirm_additional_feeding'] == true || body['confirm_duplicate'] == true) return null;
  final type = body['event_type'] as String? ?? 'offered';
  if (type != 'offered' && type != 'delivered') return null;
  final subjectType = body['subject_type'] as String?;
  final subjectId = body['subject_id'] as String?;
  if (subjectType == null || subjectId == null) return null;
  final at = DateTime.tryParse(body['occurred_at'] as String? ?? '') ?? now ?? DateTime.now();
  final products = {
    for (final c in body['components'] as List<dynamic>? ?? const [])
      if (c is Map && c['feed_product_id'] is String) c['feed_product_id'] as String,
  };
  if (products.isEmpty) return null;

  Set<String> supplementsOf(String animalId) => {
        for (final l in plan.lines)
          if (l.subjectType == 'animal' && l.subjectId == animalId && l.basis == 'supplement_only')
            for (final t in l.dailyTargets) t.feedProductId,
      };
  Set<String> productsOf(FeedingEvent e) => {for (final c in e.components) c.feedProductId};
  bool near(FeedingEvent e, DateTime t) => e.countsAsFed && e.occurredAt.difference(t).abs() <= feedingRoundWindow;

  /// Covered animals fed on their own around [t] with one of [feeds] that
  /// is not their supplement: animal id → their first such feeding.
  Map<String, (FeedingEvent, Set<String>)> fedAlone(Iterable<String> animalIds, Set<String> feeds, DateTime t) {
    final out = <String, (FeedingEvent, Set<String>)>{};
    final ids = animalIds.toSet();
    for (final e in events) {
      if (e.subjectType != 'animal' || !ids.contains(e.subjectId) || !near(e, t)) continue;
      final shared = feeds.intersection(productsOf(e)).difference(supplementsOf(e.subjectId));
      if (shared.isNotEmpty && !out.containsKey(e.subjectId)) out[e.subjectId] = (e, shared);
    }
    return out;
  }

  final groupLines = [for (final l in plan.lines) if (l.subjectType == 'group') l];
  if (subjectType == 'animal') {
    final wanted = products.difference(supplementsOf(subjectId));
    if (wanted.isEmpty) return null;
    for (final line in groupLines) {
      if (!line.coveredAnimalIds.contains(subjectId)) continue;
      for (final e in events) {
        if (e.subjectType != 'group' || e.subjectId != line.subjectId || !near(e, at)) continue;
        final shared = wanted.intersection(productsOf(e));
        if (shared.isEmpty) continue;
        final others = fedAlone([for (final a in line.coveredAnimalIds) if (a != subjectId) a], shared, e.occurredAt).length;
        final head = e.headCount;
        if (head != null && head + others + 1 <= line.headCount) continue; // a partial feeding left her out
        return FeedingOverlap(
          kind: FeedingOverlapKind.animalAfterGroup, groupId: line.subjectId, groupName: line.name, animalIds: [subjectId],
          productIds: shared.toList()..sort(), other: e, heads: line.headCount,
        );
      }
    }
    return null;
  }
  final line = groupLines.where((l) => l.subjectId == subjectId).firstOrNull;
  if (line == null) return null;
  final alone = fedAlone(line.coveredAnimalIds, products, at);
  if (alone.isEmpty) return null;
  final asked = body['head_count'] is num ? (body['head_count'] as num).toInt() : line.headCount;
  if (asked + alone.length <= line.headCount) return null; // the head count already leaves them out
  final first = alone.values.reduce((a, b) => a.$1.occurredAt.isBefore(b.$1.occurredAt) ? a : b);
  return FeedingOverlap(
    kind: FeedingOverlapKind.groupAfterAnimal, groupId: line.subjectId, groupName: line.name, animalIds: alone.keys.toList(),
    productIds: {for (final v in alone.values) ...v.$2}.toList()..sort(), other: first.$1, heads: line.headCount,
  );
}

/// The server's I-7 refusal ("Dairy Mix: 9 kg consumed is more than the
/// 5 kg offered. …") — recognised so the form can say it in the person's
/// language.
bool isConsumedOverOffered(String? message) => message != null && message.contains(' consumed is more than the ');

/// The server's I-12 refusal ("Possible duplicate: … confirm it as an
/// additional feeding …", feeding_program_service.overlap_message): an
/// overlap this device could not see, asked with the same question.
bool isAdditionalFeedingRefusal(String? message) =>
    message != null && message.startsWith('Possible duplicate:') && message.contains('as an additional feeding');

/// The server's refusal of a confirmed overlap without a reason (Session 01:
/// an extra feeding says why).
bool needsAdditionalFeedingReason(String? message) => message != null && message.contains('additional_feeding_reason');
