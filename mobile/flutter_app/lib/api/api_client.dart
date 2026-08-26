import 'dart:convert';
import 'package:http/http.dart' as http;

/// Thrown by [ApiClient] for any non-2xx response. `message` is the
/// backend's own `detail` string where available (FastAPI's standard
/// error shape), so it's already suitable to show a user directly.
class ApiException implements Exception {
  ApiException(this.statusCode, this.message);
  final int statusCode;
  final String message;

  @override
  String toString() => message;
}

/// Same success/error shape every write screen in this app already
/// expects (`result.success`, `result.error`) — kept as its canonical
/// home now that the old offline write services are gone, so provider
/// write methods barely change shape even though they now call the
/// network instead of SQLite.
class WriteResult {
  const WriteResult.ok() : error = null;
  const WriteResult.fail(this.error);
  final String? error;
  bool get success => error == null;
}

/// Minimal JSON/HTTP client for the FastAPI backend — this app is
/// always-online (no local cache/offline queue): every screen reads and
/// writes straight through this client.
class ApiClient {
  ApiClient({required String baseUrl, this.token}) : baseUrl = _trimTrailingSlash(baseUrl);

  String baseUrl;
  String? token;
  final http.Client _http = http.Client();

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

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      };

  Future<dynamic> get(String path, {Map<String, dynamic>? query}) => _send('GET', path, query: query);
  Future<dynamic> post(String path, {Object? body, Map<String, dynamic>? query}) => _send('POST', path, body: body, query: query);
  Future<dynamic> patch(String path, {Object? body}) => _send('PATCH', path, body: body);
  Future<dynamic> delete(String path) => _send('DELETE', path);

  Future<dynamic> _send(String method, String path, {Object? body, Map<String, dynamic>? query}) async {
    final uri = _uri(path, query);
    final encodedBody = body == null ? null : jsonEncode(body);
    late http.Response response;
    try {
      switch (method) {
        case 'GET':
          response = await _http.get(uri, headers: _headers);
        case 'POST':
          response = await _http.post(uri, headers: _headers, body: encodedBody);
        case 'PATCH':
          response = await _http.patch(uri, headers: _headers, body: encodedBody);
        case 'DELETE':
          response = await _http.delete(uri, headers: _headers);
        default:
          throw ArgumentError('Unsupported method: $method');
      }
    } catch (e) {
      if (e is ApiException) rethrow;
      throw ApiException(0, "Couldn't reach the server at $baseUrl — check the server URL and your connection.");
    }

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
  /// [WriteResult] instead of letting it escape as an exception —
  /// exactly the try/catch every Mouneh/Visits write method used to do
  /// around its local write service.
  Future<WriteResult> write(Future<void> Function() action) async {
    try {
      await action();
      return const WriteResult.ok();
    } on ApiException catch (e) {
      return WriteResult.fail(e.message);
    }
  }
}
