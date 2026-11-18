import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:farmos/api/api_client.dart';

const requiredPaths = {
  '/api/v1/auth/login': {'post': {}},
  '/api/v1/auth/me': {'get': {}},
  '/api/v1/me/access': {'get': {}},
  '/api/v1/modules/catalog': {'get': {}},
};

void main() {
  test('verifies staging Origami Server API via OpenAPI without user credentials', () async {
    final paths = <String>[];
    final fake = MockClient((request) async {
      paths.add(request.url.path);
      expect(request.headers.containsKey('Authorization'), isFalse);
      expect(request.method, 'GET');
      if (request.url.path == '/health') {
        return http.Response(jsonEncode({'status': 'ok', 'version': '1e4634b'}), 200);
      }
      if (request.url.path == '/openapi.json') {
        return http.Response(jsonEncode({'info': {'title': 'Origami Server API'}, 'paths': requiredPaths}), 200);
      }
      return http.Response('Not Found', 404);
    });
    final api = ApiClient(baseUrl: 'https://example.org/api/v1', token: 'sensitive', httpClient: fake);
    final result = await api.checkBackend();
    expect(result.verified, isTrue);
    expect(result.statusCode, 200);
    expect(result.message, contains('API ENDPOINTS VERIFIED'));
    expect(paths, ['/health', '/openapi.json']);
  });

  test('a generic website returning HTTP 200 is never called Origami', () async {
    final fake = MockClient((request) async => http.Response('<html>Welcome</html>', 200));
    final api = ApiClient(baseUrl: 'https://example.org/api/v1', httpClient: fake);
    final result = await api.checkBackend();
    expect(result.verified, isFalse);
    expect(result.statusCode, 200);
    expect(result.message, contains('not JSON'));
  });

  test('unrelated OpenAPI title is rejected even with matching routes', () async {
    final fake = MockClient((request) async {
      if (request.url.path == '/health') {
        return http.Response(jsonEncode({'status': 'ok'}), 200);
      }
      return http.Response(jsonEncode({'info': {'title': 'Unrelated Service'}, 'paths': requiredPaths}), 200);
    });
    final api = ApiClient(baseUrl: 'https://example.org/api/v1', httpClient: fake);
    final result = await api.checkBackend();
    expect(result.verified, isFalse);
    expect(result.message, contains('another service'));
  });

  test('a compatible API title missing required routes is rejected', () async {
    final fake = MockClient((request) async {
      if (request.url.path == '/health') {
        return http.Response(jsonEncode({'status': 'ok'}), 200);
      }
      return http.Response(jsonEncode({'info': {'title': 'Origami Server API'}, 'paths': {'/api/v1/auth/login': {'post': {}}}}), 200);
    });
    final api = ApiClient(baseUrl: 'https://example.org/api/v1', httpClient: fake);
    final result = await api.checkBackend();
    expect(result.verified, isFalse);
    expect(result.message, contains('missing required farm routes'));
  });

  test('HTTP error from backend health probe is shown', () async {
    final fake = MockClient((request) async => http.Response('Unauthorized', 401));
    final api = ApiClient(baseUrl: 'https://example.org/api/v1', httpClient: fake);
    final result = await api.checkBackend();
    expect(result.verified, isFalse);
    expect(result.statusCode, 401);
    expect(result.message, contains('HTTP 401'));
  });

  test('health failure is visible before checking OpenAPI', () async {
    final paths = <String>[];
    final fake = MockClient((request) async {
      paths.add(request.url.path);
      return http.Response('Service Unavailable', 503);
    });
    final api = ApiClient(baseUrl: 'https://example.org/api/v1', httpClient: fake);
    final result = await api.checkBackend();
    expect(result.verified, isFalse);
    expect(result.statusCode, 503);
    expect(result.message, contains('Health'));
    expect(paths, ['/health']);
  });
}
