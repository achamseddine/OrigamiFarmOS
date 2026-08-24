import 'dart:async';
import 'package:flutter/foundation.dart';

enum SyncStatus { synced, syncing, offline, error }

class SyncQueueEntry {
  SyncQueueEntry({
    required this.id,
    required this.entityType,
    required this.entityId,
    required this.operation,
    required this.queuedAt,
  });

  final String id;
  final String entityType;
  final String entityId;
  final String operation;
  final DateTime queuedAt;
}

/// Simulates the tablet's offline-first sync queue described in tech spec
/// §10/§11 (event → sync_queue item → background push when online). The
/// local SQLite writer (see `data/local`) is the real, durable part of this
/// pipeline; this controller only models the *transport* side (what the
/// FastAPI `/sync/push` and `/sync/pull` endpoints will eventually do) so
/// the UI can show REQ-SYNC-002 ("sync status visible in the top bar") end
/// to end without requiring a live backend connection from the tablet.
class SyncQueueController extends ChangeNotifier {
  SyncStatus _status = SyncStatus.synced;
  bool _online = true;
  DateTime? _lastSyncedAt = DateTime.now();
  final List<SyncQueueEntry> _queue = [];
  Timer? _flushTimer;

  SyncStatus get status => _status;
  bool get online => _online;
  int get pendingCount => _queue.length;
  DateTime? get lastSyncedAt => _lastSyncedAt;
  List<SyncQueueEntry> get queue => List.unmodifiable(_queue);

  void enqueue({required String entityType, required String entityId, required String operation}) {
    _queue.add(SyncQueueEntry(
      id: '${DateTime.now().microsecondsSinceEpoch}',
      entityType: entityType,
      entityId: entityId,
      operation: operation,
      queuedAt: DateTime.now(),
    ));
    _status = _online ? SyncStatus.syncing : SyncStatus.offline;
    notifyListeners();
    if (_online) _scheduleFlush();
  }

  void _scheduleFlush() {
    _flushTimer?.cancel();
    _flushTimer = Timer(const Duration(seconds: 2), _flush);
  }

  void _flush() {
    if (!_online || _queue.isEmpty) return;
    _queue.clear();
    _status = SyncStatus.synced;
    _lastSyncedAt = DateTime.now();
    notifyListeners();
  }

  /// Demo/testing hook: simulate airplane mode (tech spec §20 "Offline
  /// tests: airplane-mode workflow completion and later sync").
  void setOnline(bool value) {
    if (_online == value) return;
    _online = value;
    if (!value) {
      _status = SyncStatus.offline;
    } else if (_queue.isNotEmpty) {
      _status = SyncStatus.syncing;
      _scheduleFlush();
    } else {
      _status = SyncStatus.synced;
    }
    notifyListeners();
  }

  Future<void> syncNow() async {
    if (!_online) return;
    _status = SyncStatus.syncing;
    notifyListeners();
    await Future.delayed(const Duration(milliseconds: 600));
    _flush();
  }

  @override
  void dispose() {
    _flushTimer?.cancel();
    super.dispose();
  }
}
