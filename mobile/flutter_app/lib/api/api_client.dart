import 'dart:convert';
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

  @override
  String toString() => message;
}

/// Same success/error shape every write screen in this app already
/// expects (`result.success`, `result.error`), plus [queued] for a write
/// that is safely on the tablet but has not reached the server yet.
class WriteResult {
  const WriteResult.ok() : error = null, queued = false;
  const WriteResult.queued() : error = null, queued = true;
  const WriteResult.fail(this.error) : queued = false;

  final String? error;

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
    if (store == null || !store.available) return _send('GET', path, query: query);

    final key = LocalStore.cacheKey(path, query);

    if (monitor.offline) {
      final cached = await store.readCache(key);
      if (cached != null) return cached.body;
      throw ApiException(0, _noCacheMessage);
    }

    try {
      final body = await _send('GET', path, query: query);
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
  Future<dynamic> authenticate(String path, {Object? body}) => _send('POST', path, body: body);

  Future<dynamic> _write(String method, String path, {Object? body, Map<String, dynamic>? query}) async {
    final store = _store;
    if (store == null || !store.available) return _send(method, path, body: body, query: query);

    // One key per logical write, used for both the direct attempt and the
    // queued replay — see [LocalStore.enqueue].
    final idempotencyKey = newIdempotencyKey();

    if (monitor.online) {
      try {
        return await _send(method, path, body: body, query: query, idempotencyKey: idempotencyKey);
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

  /// Replays one queued write. Used by the sync controller; the
  /// idempotency key is the stored one, so a replay of something the
  /// server already committed comes back as that original response
  /// instead of writing it twice.
  Future<dynamic> replay(OutboxItem item) => _send(
        item.method,
        item.path,
        body: item.body,
        query: item.query,
        idempotencyKey: item.idempotencyKey,
      );

  // ------------------------------------------------------------------

  Future<dynamic> _send(
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
      return queued ? const WriteResult.queued() : const WriteResult.ok();
    } on ApiException catch (e) {
      return WriteResult.fail(e.message);
    }
  }
}
