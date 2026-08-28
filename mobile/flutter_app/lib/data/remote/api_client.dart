import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../core/config/app_config.dart';
import 'api_exception.dart';
import 'session_manager.dart';

/// Thin HTTP wrapper around the OrigamiFarmServer FarmOS tablet contract
/// (see ../../../../../OrigamiFarmServer/docs/FARMOS_API.md). Every
/// repository in this app goes through this one class so auth headers,
/// timeouts, and the offline/error split are handled in exactly one place.
///
/// Callers never see a raw [http.Response] — a 2xx body is decoded JSON
/// (`Map`, `List`, or `null` for an empty 204); anything else becomes an
/// [ApiException] (server answered, request was rejected) or an
/// [ApiOfflineException] (server never answered at all).
class ApiClient {
  ApiClient(this._session, {http.Client? client}) : _client = client ?? http.Client();

  final SessionManager _session;
  final http.Client _client;

  Uri _uri(String path, [Map<String, dynamic>? query]) {
    final base = _session.baseUrl;
    final normalizedBase = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    final normalizedPath = path.startsWith('/') ? path : '/$path';
    final withQuery = query == null || query.isEmpty
        ? ''
        : '?${query.entries.where((e) => e.value != null).map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent('${e.value}')}').join('&')}';
    return Uri.parse('$normalizedBase$normalizedPath$withQuery');
  }

  Map<String, String> _headers({String? idempotencyKey}) {
    final headers = <String, String>{'content-type': 'application/json'};
    final token = _session.token;
    if (token != null) headers['authorization'] = 'Bearer $token';
    if (idempotencyKey != null) headers['idempotency-key'] = idempotencyKey;
    return headers;
  }

  Future<dynamic> get(String path, {Map<String, dynamic>? query}) =>
      _send('GET', path, query: query);

  Future<dynamic> post(String path, {Object? body, String? idempotencyKey}) =>
      _send('POST', path, body: body, idempotencyKey: idempotencyKey);

  Future<dynamic> patch(String path, {Object? body}) => _send('PATCH', path, body: body);

  Future<dynamic> put(String path, {Object? body}) => _send('PUT', path, body: body);

  Future<dynamic> delete(String path) => _send('DELETE', path);

  Future<dynamic> _send(
    String method,
    String path, {
    Map<String, dynamic>? query,
    Object? body,
    String? idempotencyKey,
  }) async {
    final uri = _uri(path, query);
    final headers = _headers(idempotencyKey: idempotencyKey);
    final encodedBody = body == null ? null : jsonEncode(body);

    http.Response response;
    try {
      response = await _client
          .send(_request(method, uri, headers, encodedBody))
          .then(http.Response.fromStream)
          .timeout(AppConfig.requestTimeout);
    } on TimeoutException {
      throw ApiOfflineException('Timed out reaching the server.');
    } on SocketException {
      throw ApiOfflineException('No network connection.');
    } on http.ClientException catch (e) {
      throw ApiOfflineException(e.message);
    }

    if (response.statusCode == 204 || response.bodyBytes.isEmpty) {
      if (response.statusCode >= 200 && response.statusCode < 300) return null;
      throw ApiException(response.statusCode, 'Request failed (${response.statusCode}).');
    }

    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return decoded;
    }

    final detail = decoded is Map && decoded['detail'] != null
        ? '${decoded['detail']}'
        : 'Request failed (${response.statusCode}).';
    throw ApiException(response.statusCode, detail);
  }

  http.Request _request(String method, Uri uri, Map<String, String> headers, String? body) {
    final request = http.Request(method, uri)..headers.addAll(headers);
    if (body != null) request.body = body;
    return request;
  }

  void close() => _client.close();
}
