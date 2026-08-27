import 'local_store.dart';

/// What a write queued offline should do to the cached lists, so the
/// worker sees the entry they just made instead of watching it vanish.
///
/// Without this, a farmhand who records milk in a field with no signal
/// gets an empty list back and records it again — the exact double entry
/// the outbox exists to prevent. These effects are a *local prediction*
/// of the server's answer: the record appears immediately, flagged
/// [kPendingFlag], and is replaced by the server's own copy on the first
/// refresh after the queue drains.
sealed class CacheEffect {
  const CacheEffect(this.collectionPath, {this.listKey});

  /// The GET path whose cached body should change. Not derived from the
  /// write path — fields are created at `POST /fields` but read at
  /// `GET /production/fields`, so the pair is stated explicitly.
  final String collectionPath;

  /// Set when the response is an envelope (`{"notifications": [...]}`)
  /// rather than a bare JSON array.
  final String? listKey;
}

/// A record created offline, prepended to the cached list.
class AppendRecord extends CacheEffect {
  const AppendRecord(super.collectionPath, this.record, {super.listKey});
  final Map<String, dynamic> record;
}

/// A shallow field-by-field patch onto the cached record with this id.
class MergeRecord extends CacheEffect {
  const MergeRecord(super.collectionPath, this.id, this.patch, {super.listKey, this.idField = 'id'});
  final String id;
  final Map<String, dynamic> patch;

  /// Which field identifies the record. Nearly always `id`, but a module
  /// licence is identified by its `module_code`.
  final String idField;
}

class RemoveRecord extends CacheEffect {
  const RemoveRecord(super.collectionPath, this.id, {super.listKey, this.idField = 'id'});
  final String id;
  final String idField;
}

/// The same patch applied to every record in the list — "mark everything
/// read", and nothing else so far.
class PatchAll extends CacheEffect {
  const PatchAll(super.collectionPath, this.patch, {super.listKey});
  final Map<String, dynamic> patch;
}

/// A patch onto a cached response whose body is a single record rather
/// than a list — an animal's Digital Twin, a Mouneh product's detail.
class PatchDocument extends CacheEffect {
  const PatchDocument(super.collectionPath, this.patch);
  final Map<String, dynamic> patch;
}

/// Adds [delta] to one numeric field of the cached record — stock moving
/// in or out, where the new value depends on the old one.
class AdjustNumber extends CacheEffect {
  const AdjustNumber(super.collectionPath, this.id, this.field, this.delta, {super.listKey});
  final String id;
  final String field;
  final double delta;
}

typedef _EffectBuilder = List<CacheEffect> Function(_Match match);

class _Match {
  const _Match(this.ids, this.body, this.localId);
  final List<String> ids;
  final Map<String, dynamic> body;

  /// The temporary id to give a record created offline. Supplied by the
  /// caller (and stored on the outbox row) so the sync pass can later
  /// rewrite anything that referred to it.
  final String localId;
}

class _Rule {
  _Rule(this.method, String pattern, this.build) : matcher = RegExp('^$pattern\$');
  final String method;
  final RegExp matcher;
  final _EffectBuilder build;
}

/// A record the server has not seen yet: give it its temporary id so the
/// UI has something to key on, and flag it as unsynced.
Map<String, dynamic> _newRecord(_Match match, {Map<String, dynamic> extra = const {}}) => {
      'id': match.localId,
      ...match.body,
      ...extra,
      kPendingFlag: true,
    };

/// One `/…/{id}` segment.
const String _id = r'([^/]+)';

/// Timestamps the API would set server-side. UTC ISO-8601, matching what
/// every entity's `fromJson` parses.
String _now() => DateTime.now().toUtc().toIso8601String();

/// Straightforward "POST to a list, PATCH/DELETE an item in it" endpoints,
/// where the read path and the write path are the same.
List<_Rule> _crud(String path, {String? readPath, bool update = true, bool remove = false}) {
  final collection = readPath ?? path;
  return [
    _Rule('POST', path, (m) => [AppendRecord(collection, _newRecord(m))]),
    if (update) ...[
      _Rule('PATCH', '$path/$_id', (m) => [MergeRecord(collection, m.ids[0], m.body)]),
      _Rule('PUT', '$path/$_id', (m) => [MergeRecord(collection, m.ids[0], m.body)]),
    ],
    if (remove) _Rule('DELETE', '$path/$_id', (m) => [RemoveRecord(collection, m.ids[0])]),
  ];
}

final List<_Rule> _rules = [
  // --- Daily field work: the writes a worker actually makes out of range.
  ..._crud('/tasks', remove: true),
  ..._crud('/animals'),
  _Rule('POST', '/health/treatments', (m) => [AppendRecord('/health/treatments', _newRecord(m))]),
  _Rule('POST', '/production/milk', (m) => [AppendRecord('/production/milk', _newRecord(m))]),
  _Rule('POST', '/production/eggs', (m) => [AppendRecord('/production/eggs', _newRecord(m))]),
  _Rule('POST', '/production/harvest', (m) => [AppendRecord('/production/harvest', _newRecord(m))]),

  // Agriculture: created at /fields, read back at /production/fields.
  ..._crud('/fields', readPath: '/production/fields'),
  ..._crud('/crops', update: false, remove: true),
  ..._crud('/crop-plantings'),

  // Feed movements change a quantity rather than adding a row.
  _Rule('POST', '/feed/transactions', (m) {
    final itemId = m.body['item_id'] as String?;
    final quantity = (m.body['quantity'] as num?)?.toDouble();
    if (itemId == null || quantity == null) return const [];
    final delta = m.body['direction'] == 'out' ? -quantity : quantity;
    return [AdjustNumber('/feed/items', itemId, 'current_qty', delta)];
  }),

  // Recommendations: the decision is the patch.
  _Rule('PATCH', '/recommendations/$_id/decision', (m) => [MergeRecord('/recommendations', m.ids[0], m.body)]),

  // Agriculture's daily harvest. The server also moves the sellable part
  // into produce inventory and advances the planting; locally we predict
  // only the harvest row, which is what the screen shows back.
  _Rule('POST', '/harvest', (m) {
    final total = (m.body['total_quantity'] as num?)?.toDouble() ?? 0;
    final waste = (m.body['waste_quantity'] as num?)?.toDouble() ?? 0;
    return [
      AppendRecord('/production/harvest', {
        'id': m.localId,
        'field_id': m.body['field_id'],
        'product_name': m.body['product_name'] ?? 'Harvest',
        'quantity': total,
        'waste_qty': waste,
        'unit': m.body['unit'] ?? 'kg',
        'destination': m.body['destination'],
        'recorded_at': _now(),
        kPendingFlag: true,
      }),
    ];
  }),

  // An observation shows up on the animal's own Digital Twin, which is a
  // single-record response with the list nested inside it.
  _Rule('POST', '/observations', (m) {
    final animalId = m.body['entity_id'] as String?;
    if (m.body['entity_type'] != 'animal' || animalId == null) return const [];
    return [
      AppendRecord('/animals/$animalId', {
        'id': m.localId,
        'observation_type': m.body['observation_type'],
        'quality': m.body['quality'],
        'severity': m.body['severity'],
        'notes': m.body['notes'],
        'observed_at': _now(),
        kPendingFlag: true,
      }, listKey: 'recent_observations'),
    ];
  }),

  // The bell: marking read must survive being done offline, or the badge
  // comes back on the next launch and the farmer clears it twice.
  _Rule('POST', '/notifications/$_id/read', (m) {
    return [MergeRecord('/notifications', m.ids[0], {'read_at': _now()}, listKey: 'notifications')];
  }),
  _Rule('POST', '/notifications/read-all', (m) {
    return [
      PatchAll('/notifications', {'read_at': _now()}, listKey: 'notifications'),
      PatchDocument('/notifications', const {'unread_count': 0}),
    ];
  }),

  // --- Management. Rarely done in the field, but queueing beats losing.
  ..._crud('/employees', remove: true),
  // Replacing an employee's responsibilities rewrites the whole set.
  _Rule('PUT', '/employees/$_id/permissions', (m) {
    final granted = m.body['permissions'];
    if (granted is! List) return const [];
    return [MergeRecord('/employees', m.ids[0], {'permissions': granted})];
  }),
  // Turning a licensed module on or off, keyed by module_code.
  _Rule('POST', '/modules/$_id/$_id', (m) {
    final status = switch (m.ids[1]) { 'activate' => 'active', 'deactivate' => 'inactive', _ => null };
    if (status == null) return const [];
    return [MergeRecord('/modules', m.ids[0], {'status': status}, idField: 'module_code')];
  }),

  // --- Mouneh production.
  ..._crud('/mouneh/products', update: false),
  ..._crud('/mouneh/raw-materials', update: false),
  _Rule('POST', '/mouneh/batches', (m) => [AppendRecord('/mouneh/batches', _newRecord(m, extra: {'status': 'planned'}))]),
  _Rule('POST', '/mouneh/sales', (m) => [AppendRecord('/mouneh/sales', _newRecord(m))]),
  // Batch lifecycle: consuming inputs starts it, completing it finishes.
  _Rule('POST', '/mouneh/batches/$_id/consume', (m) => [
        MergeRecord('/mouneh/batches', m.ids[0], {'status': 'in_progress', 'started_at': _now()}),
      ]),
  _Rule('POST', '/mouneh/batches/$_id/complete', (m) => [
        MergeRecord('/mouneh/batches', m.ids[0], {
          'status': 'completed',
          'completed_at': _now(),
          if (m.body['actual_output_qty'] != null) 'actual_output_qty': m.body['actual_output_qty'],
        }),
      ]),
  // A new recipe version becomes the product's active one.
  _Rule('POST', '/mouneh/products/$_id/recipes', (m) => [
        PatchDocument('/mouneh/products/${m.ids[0]}', {
          'active_recipe': <String, dynamic>{'id': m.localId, ...m.body, 'status': 'active'},
        }),
      ]),

  // --- Farm visits.
  ..._crud('/visit-calendar', update: false),
  ..._crud('/visit-sessions'),
  ..._crud('/visit-packages', update: false),
  ..._crud('/visit-activities', update: false),
  ..._crud('/visitors', update: false),
  ..._crud('/visit-bookings', update: false),
  // The booking status machine: confirm -> check-in -> complete, or off
  // to cancelled/no-show/refunded. Each step stamps its own timestamp
  // field, the same one the server sets.
  _Rule('POST', '/visit-bookings/$_id/$_id', (m) {
    const transitions = {
      'confirm': ('confirmed', 'confirmed_at'),
      'check-in': ('checked_in', 'checked_in_at'),
      'complete': ('completed', 'completed_at'),
      'cancel': ('cancelled', 'cancelled_at'),
      'no-show': ('no_show', 'cancelled_at'),
      'refund': ('refunded', 'refunded_at'),
    };
    final step = transitions[m.ids[1]];
    if (step == null) return const [];
    return [
      MergeRecord('/visit-bookings', m.ids[0], {'status': step.$1, step.$2: _now()}),
    ];
  }),
  ..._crud('/visit-staff-roster', update: false),
  ..._crud('/visit-costs', update: false),
  ..._crud('/visit-retail-sales', update: false),
  ..._crud('/visit-incidents', update: false),
  ..._crud('/visitor-feedback', update: false),
];

/// What one write does to the locally held data — the whole story in
/// standalone mode, and a prediction of the server's answer when offline.
///
/// An empty result is a legitimate answer, not a gap. Some writes have no
/// cached list to change (`POST /mouneh/products/{id}/recipes` when that
/// product's detail was never loaded), and some have effects the tablet
/// should not guess at — the server-side half of a harvest also moves
/// stock and advances a planting. Where a prediction would be a guess,
/// this returns nothing and the real answer arrives with the next
/// refresh; offline, the write still sits safely in the outbox either
/// way.
List<CacheEffect> effectsFor(String method, String path, Object? body, {required String localId}) {
  final map = body is Map<String, dynamic> ? body : const <String, dynamic>{};
  for (final rule in _rules) {
    if (rule.method != method) continue;
    final match = rule.matcher.firstMatch(path);
    if (match == null) continue;
    final ids = [for (var i = 1; i <= match.groupCount; i++) match.group(i) ?? ''];
    return rule.build(_Match(ids, map, localId));
  }
  return const [];
}

/// Applies effects to every cached response for the affected path —
/// `/priorities` and `/priorities?module=animals` are separate cache rows
/// and both need to change.
Future<void> applyCacheEffects(LocalStore store, List<CacheEffect> effects) async {
  if (!store.available) return;
  for (final effect in effects) {
    final keys = await store.cacheKeysForPath(effect.collectionPath);
    for (final key in keys) {
      final cached = await store.readCache(key);
      if (cached == null) continue;
      final updated = _applyToBody(cached.body, effect);
      if (updated != null) await store.writeCache(key, updated);
    }
  }
}

/// Returns the new body, or null when the cached shape isn't what the
/// effect expects (in which case the cache is left untouched rather than
/// corrupted).
Object? _applyToBody(Object? body, CacheEffect effect) {
  // A document effect targets the record itself, not a list inside it.
  if (effect is PatchDocument) {
    if (body is! Map<String, dynamic>) return null;
    return <String, dynamic>{...body, ...effect.patch, kPendingFlag: true};
  }

  final listKey = effect.listKey;
  if (listKey != null) {
    if (body is! Map<String, dynamic>) return null;
    final list = body[listKey];
    if (list is! List) return null;
    final updated = _applyToList(list, effect);
    if (updated == null) return null;
    return <String, dynamic>{...body, listKey: updated};
  }
  if (body is! List) return null;
  return _applyToList(body, effect);
}

List<dynamic>? _applyToList(List<dynamic> list, CacheEffect effect) {
  switch (effect) {
    case AppendRecord(:final record):
      // Newest first: every list in this app is read that way round.
      return [record, ...list];
    case RemoveRecord(:final id, :final idField):
      return [
        for (final entry in list)
          if (!(entry is Map && entry[idField] == id)) entry,
      ];
    case MergeRecord(:final id, :final patch, :final idField):
      return [
        for (final entry in list)
          if (entry is Map<String, dynamic> && entry[idField] == id)
            <String, dynamic>{...entry, ...patch, kPendingFlag: true}
          else
            entry,
      ];
    case PatchAll(:final patch):
      return [
        for (final entry in list)
          if (entry is Map<String, dynamic>) <String, dynamic>{...entry, ...patch} else entry,
      ];
    case AdjustNumber(:final id, :final field, :final delta):
      return [
        for (final entry in list)
          if (entry is Map<String, dynamic> && entry['id'] == id)
            <String, dynamic>{...entry, field: ((entry[field] as num?)?.toDouble() ?? 0) + delta, kPendingFlag: true}
          else
            entry,
      ];
    case PatchDocument():
      return null; // handled in _applyToBody
  }
}
