import 'dart:convert';
import 'package:flutter/foundation.dart' show protected;
import 'package:http/http.dart' as http;

import '../data/local/cache_effects.dart';
import '../data/local/connection_monitor.dart';
import '../data/local/local_store.dart';
import '../data/local/outbox_labels.dart';

/// Thrown by [ApiClient] for any non-2xx response. `message` is the
/// backend's own `detail` string where available (FastAPI's standard
/// error shape), so it's already suitable to show a user directly.
///
/// `statusCode == 0` means the server was never reached at all — the
/// tablet is out of coverage, or the server URL is wrong. That case is
/// handled quite differently from a rejection, so it has its own test:
/// [isOffline].
class ApiException implements Exception {
  ApiException(this.statusCode, this.message);
  final int statusCode;
  final String message;

  /// The request never got an answer. Reads fall back to the cache and
  /// writes go to the outbox; the session is *not* signed out.
  bool get isOffline => statusCode == 0;

  /// The server found a record that already says this (the same milking,
  /// the same delivery note, …) and asks whether this is a second one —
  /// backend app/core/duplicates.py. Resent with `confirm_duplicate: true`
  /// it is recorded.
  bool get isPossibleDuplicate => statusCode == 409 && message.startsWith(kPossibleDuplicate);

  /// The server's sentence without its "Possible duplicate:" lead-in.
  String get duplicateDetail => message.replaceFirst(kPossibleDuplicate, '').trim();

  @override
  String toString() => message;
}

/// How the server starts a refusal that a person may override by saying
/// "this is a second one" (backend app/core/duplicates.py PREFIX).
const kPossibleDuplicate = 'Possible duplicate:';

/// Same success/error shape every write screen in this app already
/// expects (`result.success`, `result.error`), plus [queued] for a write
/// that is safely on the tablet but has not reached the server yet.
class WriteResult {
  const WriteResult.ok([this.data]) : error = null, queued = false, statusCode = null;
  const WriteResult.queued([this.data]) : error = null, queued = true, statusCode = null;
  const WriteResult.fail(this.error, {this.statusCode}) : queued = false, data = null;

  final String? error;

  /// The HTTP status of a refusal, when there was one.
  final int? statusCode;

  /// Refused as already on record, and the person chose not to record it
  /// again (see [ApiClient.confirmPossibleDuplicate]).
  bool get isPossibleDuplicate => statusCode == 409 && (error ?? '').startsWith(kPossibleDuplicate);

  /// What the server answered (the created record), or the outbox's local
  /// placeholder when [queued] — whose `id` the server does not know yet.
  final Object? data;

  /// The id the server gave a created record; null while it is queued.
  String? get serverId => !queued && data is Map ? (data as Map)['id'] as String? : null;

  /// True when the write went to the outbox instead of the server. It is
  /// saved — on this tablet — and will be sent on the next sync.
  final bool queued;

  bool get success => error == null;
}

/// JSON/HTTP client for the FastAPI backend, with the offline behaviour
/// the farm actually needs: **online the first time, then usable in the
/// field**.
///
/// * **Reads** go to the network when the server is reachable and every
///   response is cached. When it isn't, the cached answer is served, so a
///   worker standing in a field still sees their animals, tasks and
///   fields exactly as they were when the tablet last had signal.
/// * **Writes** go straight to the server when it is reachable. When it
///   isn't, the request itself is queued in the outbox and the cached
///   lists are updated locally so the entry appears immediately. The
///   queue is replayed, in order, the moment the server answers again.
///
/// Storing the *request* rather than a translated "event" is what makes
/// this general: any endpoint the app calls works offline without a
/// matching branch on the server.
class ApiClient {
  /// Asked when the server answers a write with "Possible duplicate: …"
  /// (the same fact already on record). True resends that one request with
  /// `confirm_duplicate: true`; false leaves it unrecorded and the form
  /// shows the server's sentence. Installed once by the app shell
  /// (core/widgets/duplicate_confirmation.dart) — every form gets it.
  static Future<bool> Function(String detail)? confirmPossibleDuplicate;

  ApiClient({required String baseUrl, this.token, LocalStore? store})
      : baseUrl = _trimTrailingSlash(baseUrl),
        _store = store {
    monitor = ConnectionMonitor(probe: ping);
  }

  String baseUrl;
  String? token;
  final http.Client _http = http.Client();
  final LocalStore? _store;

  late final ConnectionMonitor monitor;

  /// Standalone mode: there is no server at all, and the tablet's own
  /// database *is* the farm. Reads come from it, writes edit it in place,
  /// and nothing is queued — a queue implies something to send to.
  ///
  /// This is the same storage and the same code path as offline mode; the
  /// difference is only that there is no server to reconcile with, so the
  /// sync machinery stands down instead of counting up work that will
  /// never be sent.
  bool standalone = false;

  /// True when this tablet has working local storage. False in the
  /// `flutter test` VM and on a desktop debug run, where the client
  /// simply behaves as an online-only client.
  bool get offlineCapable => _store?.available ?? false;

  bool get online => monitor.online;

  LocalStore? get store => _store;

  static String _trimTrailingSlash(String url) => url.endsWith('/') ? url.substring(0, url.length - 1) : url;

  void updateBaseUrl(String url) => baseUrl = _trimTrailingSlash(url);

  Uri _uri(String path, Map<String, dynamic>? query) {
    final full = Uri.parse('$baseUrl$path');
    if (query == null || query.isEmpty) return full;
    final params = <String, String>{...full.queryParameters};
    for (final entry in query.entries) {
      if (entry.value == null) continue;
      params[entry.key] = entry.value.toString();
    }
    return full.replace(queryParameters: params);
  }

  Map<String, String> _headers({String? idempotencyKey}) => {
        'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
        if (idempotencyKey != null) 'Idempotency-Key': idempotencyKey,
      };

  /// Cheap reachability check against the API's unauthenticated health
  /// endpoint. Uses the origin, not the `/api/v1` prefix, because the
  /// prefixed `/health` route is the *animal* health module.
  Future<bool> ping() async {
    try {
      final origin = Uri.parse(baseUrl).replace(path: '/health', query: null);
      final response = await _http.get(origin).timeout(const Duration(seconds: 4));
      return response.statusCode < 500;
    } catch (_) {
      return false;
    }
  }

  // ------------------------------------------------------------------
  // Reads
  // ------------------------------------------------------------------

  Future<dynamic> get(String path, {Map<String, dynamic>? query}) async {
    final store = _store;
    if (store == null || !store.available) return send('GET', path, query: query);

    final key = LocalStore.cacheKey(path, query);

    if (standalone) return _readLocal(store, path, query, key);

    if (monitor.offline) {
      final cached = await store.readCache(key);
      if (cached != null) return cached.body;
      throw ApiException(0, _noCacheMessage);
    }

    try {
      final body = await send('GET', path, query: query);
      await store.writeCache(key, body);
      return body;
    } on ApiException catch (e) {
      if (!e.isOffline) rethrow;
      final cached = await store.readCache(key);
      if (cached != null) return cached.body;
      throw ApiException(0, _noCacheMessage);
    }
  }

  static const _noCacheMessage =
      "This hasn't been downloaded to the tablet yet, and the farm server can't be reached. "
      'Connect to the farm network once and it will be available offline afterwards.';

  /// A read in standalone mode, where the local store is the only source
  /// of truth and must always answer.
  ///
  /// Falls back from the exact request to the same path without its
  /// query, because a filtered view — `/priorities?module=animals` — is a
  /// narrowing of a list the snapshot already holds, and returning the
  /// unfiltered list is far better than an error. The screens filter
  /// client-side anyway. An unknown path answers empty rather than
  /// throwing: a section with no data should look empty, not broken.
  Future<dynamic> _readLocal(LocalStore store, String path, Map<String, dynamic>? query, String key) async {
    final exact = await store.readCache(key);
    if (exact != null) return exact.body;

    if (query != null && query.isNotEmpty) {
      final base = await store.readCache(LocalStore.cacheKey(path, null));
      if (base != null) return base.body;
    }

    // Any sibling response for this path — how a list written by a
    // different query variant is still found.
    for (final candidate in await store.cacheKeysForPath(path)) {
      final cached = await store.readCache(candidate);
      if (cached != null) return cached.body;
    }

    // A detail request for a record created on this tablet: the snapshot
    // has no `/animals/{new-id}` response, but the animal itself is in
    // the `/animals` list. Without this, adding an animal and then
    // opening it would fail — the one path a demo user is most likely to
    // walk. Screens null-guard the extra nested lists a real detail
    // response carries.
    final detail = await _detailFromCollection(store, path);
    if (detail != null) return detail;

    return const <dynamic>[];
  }

  Future<Map<String, dynamic>?> _detailFromCollection(LocalStore store, String path) async {
    final segments = path.split('/').where((s) => s.isNotEmpty).toList();
    if (segments.length < 2) return null;
    final id = segments.removeLast();
    final collection = '/${segments.join('/')}';

    for (final key in await store.cacheKeysForPath(collection)) {
      final body = (await store.readCache(key))?.body;
      if (body is! List) continue;
      for (final entry in body) {
        if (entry is Map<String, dynamic> && entry['id'] == id) return entry;
      }
    }
    return null;
  }

  // ------------------------------------------------------------------
  // Writes
  // ------------------------------------------------------------------

  Future<dynamic> post(String path, {Object? body, Map<String, dynamic>? query}) =>
      _write('POST', path, body: body, query: query);
  Future<dynamic> patch(String path, {Object? body}) => _write('PATCH', path, body: body);
  Future<dynamic> put(String path, {Object? body}) => _write('PUT', path, body: body);
  Future<dynamic> delete(String path) => _write('DELETE', path);

  /// Signing in is the one write that is never queued: without a token
  /// from the server there is no session to work offline *with*. This is
  /// the "internet required the first time" rule.
  Future<dynamic> authenticate(String path, {Object? body}) => send('POST', path, body: body);

  Future<dynamic> _write(String method, String path, {Object? body, Map<String, dynamic>? query}) async {
    final store = _store;
    if (store == null || !store.available) {
      return _sendAsking(method, path, body: body, query: query, idempotencyKey: newIdempotencyKey());
    }

    if (standalone) return _writeLocal(store, method, path, body);

    // One key per logical write, used for both the direct attempt and the
    // queued replay — see [LocalStore.enqueue].
    final idempotencyKey = newIdempotencyKey();

    if (monitor.online) {
      try {
        return await _sendAsking(method, path, body: body, query: query, idempotencyKey: idempotencyKey);
      } on ApiException catch (e) {
        if (!e.isOffline) rethrow;
        // Fall through: the tablet lost the server mid-write.
      }
    }

    return _queue(store, method, path, body: body, query: query, idempotencyKey: idempotencyKey);
  }

  Future<dynamic> _queue(
    LocalStore store,
    String method,
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    required String idempotencyKey,
  }) async {
    final descriptor = describeWrite(path);
    final localId = newUuid();
    await store.enqueue(
      method: method,
      path: path,
      query: query,
      body: body,
      label: descriptor.labelKey,
      moduleCode: descriptor.moduleCode,
      idempotencyKey: idempotencyKey,
      localId: method == 'POST' ? localId : null,
    );
    // Show the farmer their own entry straight away, flagged unsynced —
    // otherwise they record it a second time thinking it was lost.
    await applyCacheEffects(store, effectsFor(method, path, body, localId: localId));
    return {'queued': true, kPendingFlag: true, 'id': localId};
  }

  /// A write in standalone mode: the local data *is* the farm, so the
  /// change is applied to it and that is the whole story — no outbox, no
  /// pending marker, nothing waiting to be sent.
  Future<dynamic> _writeLocal(LocalStore store, String method, String path, Object? body) async {
    final localId = newUuid();
    final effects = effectsFor(method, path, body, localId: localId);
    await applyCacheEffects(store, effects);
    // Give back something shaped like the record the server would have
    // returned, so a caller that reads the response still works.
    final created = body is Map<String, dynamic> ? {'id': localId, ...body} : {'id': localId};
    return created;
  }

  /// Sends a write; on "Possible duplicate:" asks the person and, if they
  /// say it is a second one, sends the same request again confirmed. The
  /// refusal was not stored by the server's idempotency guard (4xx never
  /// is), so the same key still names this one logical write.
  Future<dynamic> _sendAsking(String method, String path,
      {Object? body, Map<String, dynamic>? query, required String idempotencyKey}) async {
    try {
      return await send(method, path, body: body, query: query, idempotencyKey: idempotencyKey);
    } on ApiException catch (e) {
      final ask = confirmPossibleDuplicate;
      if (!e.isPossibleDuplicate || ask == null || body is! Map || body['confirm_duplicate'] == true) rethrow;
      if (!await ask(e.duplicateDetail)) rethrow;
      final confirmed = <String, dynamic>{...body.cast<String, dynamic>(), 'confirm_duplicate': true};
      return send(method, path, body: confirmed, query: query, idempotencyKey: idempotencyKey);
    }
  }

  /// Replays one queued write. Used by the sync controller; the
  /// idempotency key is the stored one, so a replay of something the
  /// server already committed comes back as that original response
  /// instead of writing it twice.
  Future<dynamic> replay(OutboxItem item) => send(
        item.method,
        item.path,
        body: item.body,
        query: item.query,
        idempotencyKey: item.idempotencyKey,
      );

  // ------------------------------------------------------------------

  /// The one network call. Protected so a test double can stand in for
  /// the server while every write still goes through [_write].
  @protected
  Future<dynamic> send(
    String method,
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    String? idempotencyKey,
  }) async {
    final uri = _uri(path, query);
    final encodedBody = body == null ? null : jsonEncode(body);
    final headers = _headers(idempotencyKey: idempotencyKey);
    late http.Response response;
    try {
      switch (method) {
        case 'GET':
          response = await _http.get(uri, headers: headers);
        case 'POST':
          response = await _http.post(uri, headers: headers, body: encodedBody);
        case 'PATCH':
          response = await _http.patch(uri, headers: headers, body: encodedBody);
        case 'PUT':
          response = await _http.put(uri, headers: headers, body: encodedBody);
        case 'DELETE':
          response = await _http.delete(uri, headers: headers);
        default:
          throw ArgumentError('Unsupported method: $method');
      }
    } catch (e) {
      if (e is ApiException) rethrow;
      monitor.reportFailure();
      throw ApiException(0, "Couldn't reach the server at $baseUrl — check the server URL and your connection.");
    }

    // The server answered, whatever it said — so the tablet is online.
    monitor.reportSuccess();

    if (response.statusCode >= 200 && response.statusCode < 300) {
      if (response.body.isEmpty) return null;
      return jsonDecode(utf8.decode(response.bodyBytes));
    }

    var message = 'Request failed (HTTP ${response.statusCode}).';
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is Map && decoded['detail'] != null) {
        final detail = decoded['detail'];
        message = detail is String ? detail : detail.toString();
      }
    } catch (_) {
      // Non-JSON error body (e.g. a proxy's HTML error page) — keep the generic message.
    }
    // A route the server does not have at all ("Method Not Allowed", a bare
    // "Not Found"): the server is older than this tablet build, or the
    // server address points at something that is not the farm API. Say
    // that, instead of the framework's two words.
    if (response.statusCode == 405 || (response.statusCode == 404 && message == 'Not Found')) {
      message = 'The farm server at $baseUrl does not have this function (HTTP ${response.statusCode}). '
          'It is probably running an older version than this app — update the server, then try again.';
    }
    throw ApiException(response.statusCode, message);
  }

  /// Runs an API call meant to report success/failure back to a form
  /// (rather than return data) and folds any [ApiException] into a
  /// [WriteResult] instead of letting it escape as an exception.
  ///
  /// A write that was queued offline reports success with [WriteResult.queued]
  /// set: it is saved on the tablet, and the sync pill in the top bar is
  /// what tells the farmer it has not reached the office yet.
  Future<WriteResult> write(Future<dynamic> Function() action) async {
    try {
      final result = await action();
      final queued = result is Map && result[kPendingFlag] == true;
      return queued ? WriteResult.queued(result) : WriteResult.ok(result);
    } on ApiException catch (e) {
      return WriteResult.fail(e.message, statusCode: e.statusCode);
    }
  }
}
