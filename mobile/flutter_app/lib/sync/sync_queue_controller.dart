import 'dart:async';
import 'package:flutter/foundation.dart';
import '../data/sync/sync_engine.dart';

enum SyncStatus { synced, syncing, offline, error }

/// UI-facing wrapper around [SyncEngine] — the real push half of the
/// offline-first pipeline (tech spec §10/§11: event → sync_queue item →
/// background push when online). The local SQLite writer
/// (`data/local/farm_write_service.dart`) is the durable part of this
/// pipeline; this controller drives [SyncEngine] and exposes REQ-SYNC-002
/// ("sync status visible in the top bar") — see `core/widgets/top_bar.dart`.
class SyncQueueController extends ChangeNotifier {
  SyncQueueController({required SyncEngine engine}) : _engine = engine {
    unawaited(refreshPendingCount());
  }

  final SyncEngine _engine;
  SyncStatus _status = SyncStatus.synced;
  bool _online = true;
  DateTime? _lastSyncedAt;
  int _pendingCount = 0;
  Timer? _flushTimer;
  bool _flushing = false;

  SyncStatus get status => _status;
  bool get online => _online;
  int get pendingCount => _pendingCount;
  DateTime? get lastSyncedAt => _lastSyncedAt;

  Future<void> refreshPendingCount() async {
    _pendingCount = await _engine.countPending();
    if (_pendingCount == 0 && _status != SyncStatus.offline) {
      _status = SyncStatus.synced;
    }
    notifyListeners();
  }

  /// Called by a provider right after a local write adds a new
  /// `sync_queue` row — refreshes the pending count and, if online,
  /// triggers a background push shortly after (debounced so several quick
  /// writes in a row only cause one flush).
  void enqueue({required String entityType, required String entityId, required String operation}) {
    unawaited(refreshPendingCount());
    _status = _online ? SyncStatus.syncing : SyncStatus.offline;
    notifyListeners();
    if (_online) _scheduleFlush();
  }

  void _scheduleFlush() {
    _flushTimer?.cancel();
    _flushTimer = Timer(const Duration(seconds: 2), () => unawaited(_flush()));
  }

  Future<void> _flush() async {
    if (!_online || _flushing) return;
    _flushing = true;
    _status = SyncStatus.syncing;
    notifyListeners();
    try {
      final result = await _engine.flushPending();
      _pendingCount = await _engine.countPending();
      if (result.wentOffline) {
        _status = SyncStatus.offline;
      } else if (_pendingCount > 0) {
        _status = SyncStatus.error;
      } else {
        _status = SyncStatus.synced;
        _lastSyncedAt = DateTime.now();
      }
    } finally {
      _flushing = false;
      notifyListeners();
    }
  }

  /// Demo/testing hook: simulate airplane mode (tech spec §20 "Offline
  /// tests: airplane-mode workflow completion and later sync").
  void setOnline(bool value) {
    if (_online == value) return;
    _online = value;
    if (!value) {
      _status = SyncStatus.offline;
      notifyListeners();
    } else {
      unawaited(_flush());
    }
  }

  Future<void> syncNow() async {
    if (!_online) return;
    await _flush();
  }

  @override
  void dispose() {
    _flushTimer?.cancel();
    super.dispose();
  }
}
