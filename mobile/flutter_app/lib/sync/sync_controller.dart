import 'package:flutter/foundation.dart';

import '../api/api_client.dart';
import '../data/local/local_store.dart';

/// How a sync attempt ended, for the pill and the panel.
enum SyncOutcome {
  /// Nothing was waiting.
  nothingToDo,

  /// Everything queued reached the server.
  sent,

  /// Still no route to the server; the queue is untouched.
  stillOffline,

  /// The server rejected one or more items outright (a 4xx). They stay in
  /// the queue, flagged, for the farmer to look at.
  rejected,

  /// The server is reachable but erroring (a 5xx). Retried automatically.
  serverError,
}

/// Drains the outbox when the farm server comes back, and tells the rest
/// of the app when it has.
///
/// The trigger is the connection itself, not a button: a worker who spent
/// the morning in a field and walks back into the yard should find their
/// records already uploaded, without being asked to do anything. The
/// manual "Sync now" in the panel exists for the case where they want to
/// watch it happen.
class SyncController extends ChangeNotifier {
  SyncController({required ApiClient api}) : _api = api {
    _api.monitor.addListener(_onConnectionChanged);
    _api.monitor.onReconnected = _handleReconnected;
  }

  final ApiClient _api;

  void _handleReconnected() => syncNow(reason: SyncTrigger.reconnected);

  LocalStore? get _store => _api.store;

  /// False in standalone mode: the tablet's own database is the farm, so
  /// there is nothing to sync *to*. A queue and a "3 waiting" badge would
  /// be describing work that does not exist.
  bool get enabled => _api.offlineCapable && !_api.standalone;
  bool get online => _api.monitor.online;

  int pendingCount = 0;
  int failedCount = 0;

  /// Records queued by a different sign-in on this tablet. They are not
  /// this user's to send, but the panel says so rather than showing an
  /// empty queue to someone who knows data was entered.
  int otherUsersPending = 0;
  bool syncing = false;
  DateTime? lastSyncAt;
  SyncOutcome? lastOutcome;

  /// Set by the app's data loader: refresh every provider once queued
  /// work has actually landed, so the farmer sees server truth (real ids,
  /// server-computed totals) rather than the local prediction.
  Future<void> Function()? onSynced;

  bool get hasPending => pendingCount > 0;
  bool get hasFailed => failedCount > 0;

  /// The banner state the top bar renders from.
  SyncBadge get badge {
    if (!enabled) return SyncBadge.disabled;
    if (syncing) return SyncBadge.syncing;
    if (!online) return SyncBadge.offline;
    if (failedCount > 0) return SyncBadge.attention;
    if (pendingCount > 0) return SyncBadge.pending;
    return SyncBadge.synced;
  }

  Future<void> start() async {
    final store = _store;
    if (store == null || !store.available || !enabled) return;
    final raw = await store.meta(LocalStore.metaLastSync);
    lastSyncAt = raw == null ? null : DateTime.tryParse(raw);
    await refreshCounts();
    // A tablet that was closed mid-queue picks up where it left off.
    if (pendingCount > 0) await syncNow(reason: SyncTrigger.startup);
  }

  Future<void> refreshCounts() async {
    final store = _store;
    if (store == null || !store.available) return;
    final pending = await store.pendingCount();
    final failed = await store.failedCount();
    final others = await store.otherUsersPendingCount();
    final ids = await store.pendingLocalIds();
    if (pending == pendingCount &&
        failed == failedCount &&
        others == otherUsersPending &&
        setEquals(ids, _pendingIds)) {
      return;
    }
    pendingCount = pending;
    failedCount = failed;
    otherUsersPending = others;
    _pendingIds = ids;
    notifyListeners();
  }

  Set<String> _pendingIds = const {};

  /// True for a record that was created on this tablet and has not
  /// reached the server yet — what a list shows a "Not synced" chip
  /// against. Works for any entity: an offline record keeps the same
  /// temporary id in the cache and in its outbox row.
  bool isPending(String id) => _pendingIds.contains(id);

  void _onConnectionChanged() => notifyListeners();

  /// Sends everything queued, in the order it was recorded.
  ///
  /// Order is not cosmetic: a field created at 09:10 and a crop planted
  /// in it at 09:15 have to reach the server that way round, and the
  /// planting has to be rewritten to use the id the server gave the
  /// field. [_IdRemap] does that rewriting.
  Future<SyncOutcome> syncNow({SyncTrigger reason = SyncTrigger.manual}) async {
    final store = _store;
    if (store == null || !store.available) return SyncOutcome.nothingToDo;
    if (syncing) return lastOutcome ?? SyncOutcome.nothingToDo;

    syncing = true;
    notifyListeners();
    try {
      final queued = await store.outbox(pendingOnly: true);
      if (queued.isEmpty) {
        await _finish(store, SyncOutcome.nothingToDo, touchTimestamp: reason != SyncTrigger.startup);
        return SyncOutcome.nothingToDo;
      }

      // A manual attempt should confirm the server is really there before
      // marching through the queue; a reconnect already knows it is.
      if (!online && !await _api.monitor.checkNow()) {
        await _finish(store, SyncOutcome.stillOffline, touchTimestamp: false);
        return SyncOutcome.stillOffline;
      }

      final remap = _IdRemap(await store.metaJson(_idMapKey) ?? const {});
      var sent = 0;
      var rejectedAny = false;
      var outcome = SyncOutcome.sent;

      for (final item in queued) {
        final prepared = remap.apply(item);
        try {
          final response = await _api.replay(prepared);
          remap.learn(item, response);
          await store.removeFromOutbox(item.id);
          sent++;
        } on ApiException catch (e) {
          if (e.isOffline) {
            // Went out of range again mid-queue. Everything still in the
            // outbox stays pending and goes on the next attempt.
            outcome = sent > 0 ? SyncOutcome.sent : SyncOutcome.stillOffline;
            break;
          }
          if (e.statusCode >= 400 && e.statusCode < 500) {
            // The server understood and said no — a revoked permission, a
            // duplicate ear tag, a deleted animal. Retrying will not help,
            // so flag it for a human instead of looping forever.
            await store.markOutboxFailed(item.id, e.message, permanent: true);
            rejectedAny = true;
            continue;
          }
          await store.markOutboxFailed(item.id, e.message, permanent: false);
          outcome = SyncOutcome.serverError;
          break;
        }
      }

      await store.setMetaJson(_idMapKey, remap.isEmpty ? null : remap.toJson());
      if (rejectedAny && outcome == SyncOutcome.sent) outcome = SyncOutcome.rejected;

      await _finish(store, outcome, touchTimestamp: sent > 0);
      if (sent > 0) {
        // Local predictions are now stale — replace them with the real rows.
        await onSynced?.call();
        final remaining = await store.pendingCount();
        if (remaining == 0) await store.setMeta(_idMapKey, null);
      }
      return outcome;
    } finally {
      syncing = false;
      notifyListeners();
    }
  }

  Future<void> _finish(LocalStore store, SyncOutcome outcome, {required bool touchTimestamp}) async {
    lastOutcome = outcome;
    if (touchTimestamp) {
      lastSyncAt = DateTime.now();
      await store.setMeta(LocalStore.metaLastSync, lastSyncAt!.toIso8601String());
    }
    await refreshCounts();
  }

  /// Puts a rejected item back in the queue — after the manager granted
  /// the missing permission, say.
  Future<void> retry(int id) async {
    await _store?.retryOutboxItem(id);
    await refreshCounts();
    await syncNow();
  }

  Future<void> discard(int id) async {
    await _store?.discardOutboxItem(id);
    await refreshCounts();
  }

  Future<List<OutboxItem>> queuedItems() async => await _store?.outbox() ?? const [];

  static const _idMapKey = 'sync_id_map';

  @override
  void dispose() {
    _api.monitor.removeListener(_onConnectionChanged);
    // Only clear the hook if it is still ours. Handing the tablet to a
    // colleague builds the new user's controller before the old one is
    // unmounted, and a blind `= null` here would leave the incoming
    // session with no auto-sync at all.
    // `==` rather than `identical`: Dart guarantees equality between two
    // tear-offs of the same method on the same instance, not identity.
    if (_api.monitor.onReconnected == _handleReconnected) {
      _api.monitor.onReconnected = null;
    }
    super.dispose();
  }
}

enum SyncTrigger { startup, reconnected, manual }

enum SyncBadge {
  /// This device has no local storage — the app is online-only here.
  disabled,
  synced,
  pending,
  syncing,
  offline,
  attention,
}

/// Rewrites references to records that only existed on the tablet.
///
/// A record created offline is given a temporary id so the UI has
/// something to show. Anything queued afterwards that points at it (a
/// planting's `field_id`, a task's `animal_id`) carries that temporary id
/// too. As each creation is replayed, the server's real id is learned
/// here and substituted into everything still waiting — otherwise the
/// second write would be rejected for referring to a row that never
/// existed on the server.
///
/// The map is persisted between attempts, so a queue that drains over two
/// trips into signal still resolves correctly.
class _IdRemap {
  _IdRemap(Map<String, dynamic> initial)
      : _map = {for (final e in initial.entries) e.key: e.value.toString()};

  final Map<String, String> _map;

  bool get isEmpty => _map.isEmpty;
  Map<String, dynamic> toJson() => Map<String, dynamic>.from(_map);

  void learn(OutboxItem item, dynamic response) {
    final localId = item.localId;
    if (localId == null) return;
    final serverId = response is Map ? response['id'] : null;
    if (serverId is String && serverId.isNotEmpty && serverId != localId) {
      _map[localId] = serverId;
    }
  }

  OutboxItem apply(OutboxItem item) {
    if (_map.isEmpty) return item;
    final path = _substituteString(item.path);
    final body = _substitute(item.body);
    if (path == item.path && identical(body, item.body)) return item;
    return OutboxItem(
      id: item.id,
      method: item.method,
      path: path,
      query: item.query,
      body: body,
      idempotencyKey: item.idempotencyKey,
      localId: item.localId,
      label: item.label,
      moduleCode: item.moduleCode,
      createdAt: item.createdAt,
      attempts: item.attempts,
      lastError: item.lastError,
      status: item.status,
    );
  }

  String _substituteString(String value) => _map[value] ?? value;

  Object? _substitute(Object? value) {
    if (value is String) return _substituteString(value);
    if (value is List) return [for (final v in value) _substitute(v)];
    if (value is Map) {
      return {for (final e in value.entries) e.key: _substitute(e.value)};
    }
    return value;
  }
}
