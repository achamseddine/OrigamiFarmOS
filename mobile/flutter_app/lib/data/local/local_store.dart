import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// The tablet's own copy of the farm: a response cache so every screen
/// still opens in a field with no signal, and an outbox so anything the
/// worker records out there reaches the server when the tablet comes back
/// into coverage.
///
/// Three tables, deliberately generic:
///
///  * `cache`  — one row per GET (`"GET /animals?farm_id=…"` → the JSON
///    body). Keyed by the request, not by entity, so a new endpoint is
///    cached the day it is added with no schema change here.
///  * `outbox` — one row per write made while offline, stored as the HTTP
///    request itself (method + path + body) rather than as a translated
///    "event". Replaying it later is the *same* call the app would have
///    made online, so every endpoint works offline without the server
///    needing a matching reconciliation branch.
///  * `meta`   — small key/value state that has to survive a restart:
///    the cached session, the last successful sync, whose data this is.
///
/// Everything here degrades to a no-op when SQLite is unavailable (the
/// `flutter test` VM has no platform channels, and a desktop debug run has
/// no sqflite implementation). [available] is false in that case and the
/// app behaves exactly as it did before offline support: online-only.
class LocalStore {
  LocalStore._(this._db);

  final Database? _db;

  /// Who the cached data and the outbox belong to. Set once the session
  /// is known; see [setActiveUser].
  String? activeUserId;

  static LocalStore? _instance;

  /// True when SQLite really opened. When false every method below is a
  /// safe no-op and callers fall through to the network.
  bool get available => _db != null;

  static const _dbName = 'farmos_offline.db';
  static const _schemaVersion = 1;

  /// Opens (once) the on-device database. Never throws: a tablet that
  /// cannot open SQLite must still run the app online.
  static Future<LocalStore> open() async {
    if (_instance != null) return _instance!;
    Database? db;
    try {
      final dir = await getDatabasesPath();
      db = await openDatabase(
        p.join(dir, _dbName),
        version: _schemaVersion,
        onCreate: (database, _) async {
          final batch = database.batch();
          for (final statement in _schema) {
            batch.execute(statement);
          }
          await batch.commit(noResult: true);
        },
      );
    } catch (e) {
      debugPrint('LocalStore: offline storage unavailable ($e) — running online-only.');
      db = null;
    }
    return _instance = LocalStore._(db);
  }

  static const List<String> _schema = [
    '''
    CREATE TABLE cache (
      key TEXT PRIMARY KEY,
      body TEXT NOT NULL,
      fetched_at INTEGER NOT NULL
    )
    ''',
    '''
    CREATE TABLE outbox (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      method TEXT NOT NULL,
      path TEXT NOT NULL,
      query TEXT,
      body TEXT,
      idempotency_key TEXT NOT NULL UNIQUE,
      local_id TEXT,
      user_id TEXT,
      label TEXT NOT NULL,
      module_code TEXT,
      created_at INTEGER NOT NULL,
      attempts INTEGER NOT NULL DEFAULT 0,
      last_error TEXT,
      status TEXT NOT NULL DEFAULT 'pending'
    )
    ''',
    'CREATE INDEX outbox_status_idx ON outbox (status, id)',
    'CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT)',
  ];

  // ------------------------------------------------------------------
  // Response cache
  // ------------------------------------------------------------------

  /// Cache key for a GET. The query string is part of the key because
  /// `/priorities?module=animals` and `/priorities` are different answers.
  static String cacheKey(String path, Map<String, dynamic>? query) {
    if (query == null || query.isEmpty) return 'GET $path';
    final entries = query.entries.where((e) => e.value != null).map((e) => '${e.key}=${e.value}').toList()..sort();
    if (entries.isEmpty) return 'GET $path';
    return 'GET $path?${entries.join('&')}';
  }

  Future<void> writeCache(String key, Object? body) async {
    final db = _db;
    if (db == null) return;
    await db.insert(
      'cache',
      {'key': key, 'body': jsonEncode(body), 'fetched_at': DateTime.now().millisecondsSinceEpoch},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<CachedResponse?> readCache(String key) async {
    final db = _db;
    if (db == null) return null;
    final rows = await db.query('cache', where: 'key = ?', whereArgs: [key], limit: 1);
    if (rows.isEmpty) return null;
    final row = rows.first;
    try {
      return CachedResponse(
        jsonDecode(row['body'] as String),
        DateTime.fromMillisecondsSinceEpoch(row['fetched_at'] as int),
      );
    } catch (_) {
      return null; // corrupt row — treat as a miss
    }
  }

  /// Every cached GET whose path matches, regardless of query string —
  /// how a queued write finds the lists it should appear in.
  Future<List<String>> cacheKeysForPath(String path) async {
    final db = _db;
    if (db == null) return const [];
    final rows = await db.query(
      'cache',
      columns: ['key'],
      where: 'key = ? OR key LIKE ?',
      whereArgs: ['GET $path', 'GET $path?%'],
    );
    return [for (final row in rows) row['key'] as String];
  }

  Future<void> clearCache() async {
    await _db?.delete('cache');
  }

  // ------------------------------------------------------------------
  // Outbox
  // ------------------------------------------------------------------

  Future<OutboxItem?> enqueue({
    required String method,
    required String path,
    Map<String, dynamic>? query,
    Object? body,
    required String label,
    String? moduleCode,
    String? idempotencyKey,
    String? localId,
  }) async {
    final db = _db;
    if (db == null) return null;
    final item = OutboxItem(
      id: 0,
      method: method,
      path: path,
      query: query,
      body: body,
      // Reuses the key the failed direct attempt already sent, so a write
      // whose *response* was lost in transit is recognised as a replay
      // rather than recorded twice.
      idempotencyKey: idempotencyKey ?? newIdempotencyKey(),
      localId: localId,
      label: label,
      moduleCode: moduleCode,
      createdAt: DateTime.now(),
      attempts: 0,
      lastError: null,
      status: OutboxStatus.pending,
    );
    final id = await db.insert('outbox', {
      'method': item.method,
      'path': item.path,
      'query': item.query == null ? null : jsonEncode(item.query),
      'body': item.body == null ? null : jsonEncode(item.body),
      'idempotency_key': item.idempotencyKey,
      'local_id': item.localId,
      'user_id': activeUserId,
      'label': item.label,
      'module_code': item.moduleCode,
      'created_at': item.createdAt.millisecondsSinceEpoch,
      'attempts': 0,
      'status': item.status.name,
    });
    return item.copyWith(id: id);
  }

  /// Queued writes in the order they were made. Order matters: creating a
  /// field and then planting a crop in it must reach the server that way
  /// round.
  ///
  /// Only the signed-in user's own queue is returned. A tablet shared
  /// between a morning and an afternoon shift must never replay one
  /// worker's unsent records under the other's token — the server would
  /// attribute them to the wrong person, and the audit trail would be
  /// quietly wrong. The rows stay put until their own author signs back in.
  Future<List<OutboxItem>> outbox({bool pendingOnly = false}) async {
    final db = _db;
    if (db == null) return const [];
    final rows = await db.query(
      'outbox',
      where: pendingOnly ? 'status = ? AND $_ownerClause' : _ownerClause,
      whereArgs: pendingOnly ? [OutboxStatus.pending.name, activeUserId] : [activeUserId],
      orderBy: 'id ASC',
    );
    return [for (final row in rows) OutboxItem.fromRow(row)];
  }

  Future<int> pendingCount() => _countByStatus(OutboxStatus.pending);
  Future<int> failedCount() => _countByStatus(OutboxStatus.failed);

  /// Rows queued by a *different* sign-in on this tablet — surfaced in
  /// the sync panel so nobody assumes the queue is empty when it isn't.
  Future<int> otherUsersPendingCount() async {
    final db = _db;
    if (db == null) return 0;
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS n FROM outbox WHERE user_id IS NOT NULL AND user_id != ?',
      [activeUserId ?? ''],
    );
    return (rows.first['n'] as int?) ?? 0;
  }

  /// The temporary IDs of records that exist only on this tablet so far.
  ///
  /// Any list can mark its unsynced rows from this without every entity
  /// class needing an `isPending` field: a record created offline carries
  /// the same id in the cache and in its outbox row.
  Future<Set<String>> pendingLocalIds() async {
    final db = _db;
    if (db == null) return const {};
    final rows = await db.query(
      'outbox',
      columns: ['local_id'],
      where: 'local_id IS NOT NULL AND $_ownerClause',
      whereArgs: [activeUserId],
    );
    return {for (final row in rows) row['local_id'] as String};
  }

  static const _ownerClause = '(user_id IS NULL OR user_id = ?)';

  Future<int> _countByStatus(OutboxStatus status) async {
    final db = _db;
    if (db == null) return 0;
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS n FROM outbox WHERE status = ? AND $_ownerClause',
      [status.name, activeUserId],
    );
    return (rows.first['n'] as int?) ?? 0;
  }

  Future<void> removeFromOutbox(int id) async {
    await _db?.delete('outbox', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> markOutboxFailed(int id, String error, {required bool permanent}) async {
    final db = _db;
    if (db == null) return;
    await db.rawUpdate(
      'UPDATE outbox SET attempts = attempts + 1, last_error = ?, status = ? WHERE id = ?',
      [error, permanent ? OutboxStatus.failed.name : OutboxStatus.pending.name, id],
    );
  }

  /// Puts a permanently-failed item back in the queue — the "Retry" the
  /// sync panel offers once the farmer has fixed whatever the server
  /// objected to.
  Future<void> retryOutboxItem(int id) async {
    await _db?.update(
      'outbox',
      {'status': OutboxStatus.pending.name, 'last_error': null},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> discardOutboxItem(int id) => removeFromOutbox(id);

  // ------------------------------------------------------------------
  // Meta
  // ------------------------------------------------------------------

  Future<String?> meta(String key) async {
    final db = _db;
    if (db == null) return null;
    final rows = await db.query('meta', where: 'key = ?', whereArgs: [key], limit: 1);
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  Future<void> setMeta(String key, String? value) async {
    final db = _db;
    if (db == null) return;
    if (value == null) {
      await db.delete('meta', where: 'key = ?', whereArgs: [key]);
      return;
    }
    await db.insert('meta', {'key': key, 'value': value}, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<Map<String, dynamic>?> metaJson(String key) async {
    final raw = await meta(key);
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> setMetaJson(String key, Map<String, dynamic>? value) =>
      setMeta(key, value == null ? null : jsonEncode(value));

  /// Binds this store to a signed-in user. Handing the tablet to a
  /// colleague must not leave the previous account's cached farm data
  /// readable — including modules the new user has no permission to see
  /// — so a different user id wipes the cache. The outbox is deliberately
  /// left alone: it is scoped per user (see [outbox]) and destroying
  /// unsent field work would be the worst thing this app could do.
  Future<void> setActiveUser(String? userId) async {
    activeUserId = userId;
    if (userId == null) return;
    final previous = await meta(metaUserId);
    if (previous != userId) {
      await clearCache();
      await setMeta(metaUserId, userId);
    }
  }

  /// Signing out: drop the cached farm data, keep the queue.
  Future<void> clearCachedFarmData() async {
    await clearCache();
    await setMeta(metaUserId, null);
    activeUserId = null;
  }

  static const metaUserId = 'session_user_id';
  static const metaLastSync = 'last_sync_at';
}

/// A cached GET body plus when it was fetched, so the UI can say "as of
/// 07:40" rather than presenting stale numbers as live.
class CachedResponse {
  const CachedResponse(this.body, this.fetchedAt);
  final dynamic body;
  final DateTime fetchedAt;
}

enum OutboxStatus {
  /// Waiting for a connection, or waiting to be retried.
  pending,

  /// The server rejected it for a reason retrying will not fix (a 4xx).
  /// It stays in the queue, visible in the sync panel, until the farmer
  /// retries or discards it — never silently dropped.
  failed,
}

/// One write the tablet made while it could not reach the server, stored
/// as the request itself so replaying it is byte-for-byte the call the app
/// would have made online.
class OutboxItem {
  const OutboxItem({
    required this.id,
    required this.method,
    required this.path,
    required this.query,
    required this.body,
    required this.idempotencyKey,
    required this.localId,
    required this.label,
    required this.moduleCode,
    required this.createdAt,
    required this.attempts,
    required this.lastError,
    required this.status,
  });

  final int id;
  final String method;
  final String path;
  final Map<String, dynamic>? query;
  final Object? body;

  /// Sent as the `Idempotency-Key` header. The server records it against
  /// the response, so a replay after a connection died mid-request
  /// returns the original result instead of recording the milk twice.
  final String idempotencyKey;

  /// For a record created offline: the temporary id it was given locally.
  /// The server mints its own id on replay, so anything queued *after*
  /// this that referred to the temporary one (a crop planted in a field
  /// created ten minutes earlier, in the same dead spot) is rewritten to
  /// the real id before it is sent. See `SyncController`.
  final String? localId;

  /// Plain-language description for the sync panel ("Milk — Bella").
  final String label;
  final String? moduleCode;
  final DateTime createdAt;
  final int attempts;
  final String? lastError;
  final OutboxStatus status;

  Map<String, dynamic>? get bodyMap => body is Map<String, dynamic> ? body as Map<String, dynamic> : null;

  OutboxItem copyWith({int? id, int? attempts, String? lastError, OutboxStatus? status}) => OutboxItem(
        id: id ?? this.id,
        method: method,
        path: path,
        query: query,
        body: body,
        idempotencyKey: idempotencyKey,
        localId: localId,
        label: label,
        moduleCode: moduleCode,
        createdAt: createdAt,
        attempts: attempts ?? this.attempts,
        lastError: lastError ?? this.lastError,
        status: status ?? this.status,
      );

  factory OutboxItem.fromRow(Map<String, Object?> row) {
    Object? decode(Object? raw) {
      if (raw == null) return null;
      try {
        return jsonDecode(raw as String);
      } catch (_) {
        return null;
      }
    }

    final query = decode(row['query']);
    return OutboxItem(
      id: row['id'] as int,
      method: row['method'] as String,
      path: row['path'] as String,
      query: query is Map<String, dynamic> ? query : null,
      body: decode(row['body']),
      idempotencyKey: row['idempotency_key'] as String,
      localId: row['local_id'] as String?,
      label: row['label'] as String,
      moduleCode: row['module_code'] as String?,
      createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
      attempts: (row['attempts'] as int?) ?? 0,
      lastError: row['last_error'] as String?,
      status: (row['status'] as String?) == OutboxStatus.failed.name ? OutboxStatus.failed : OutboxStatus.pending,
    );
  }
}

final _random = Random.secure();

/// A RFC-4122 v4 UUID. Used for both idempotency keys and the temporary
/// IDs given to records created offline (replaced by the server's real ID
/// on the next refresh after sync).
String newUuid() {
  final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant 1
  String hex(int start, int end) =>
      [for (var i = start; i < end; i++) bytes[i].toRadixString(16).padLeft(2, '0')].join();
  return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-${hex(8, 10)}-${hex(10, 16)}';
}

String newIdempotencyKey() => newUuid();

/// Marks a record that exists only on this tablet so far. Lists show a
/// "Not synced" chip against it; the flag disappears when the server's
/// copy replaces it on the next refresh.
const String kPendingFlag = '_pending';
