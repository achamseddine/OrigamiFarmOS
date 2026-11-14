import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:farmos/api/api_client.dart';

void main() {
  test('verifies the real Origami identity and health without credentials', () async {
    final paths = <String>[];
    final fake = MockClient((request) async {
      paths.add(request.url.path);
      expect(request.headers.containsKey('Authorization'), isFalse);
      expect(request.method, 'GET');
      if (request.url.path == '/') {
        return http.Response(jsonEncode({'name': 'Origami FarmOS API', 'status': 'ok', 'docs': '/docs'}), 200);
      }
      if (request.url.path == '/health') {
        return http.Response(jsonEncode({'status': 'ok'}), 200);
      }
      return http.Response('Not Found', 404);
    });
    final api = ApiClient(baseUrl: 'https://example.org/api/v1', token: 'sensitive', httpClient: fake);
    final result = await api.checkBackend();
    expect(result.verified, isTrue);
    expect(result.statusCode, 200);
    expect(paths, ['/', '/health']);
  });

  test('a generic website returning HTTP 200 is never marked as Origami', () async {
    final fake = MockClient((request) async => http.Response('<html>Welcome</html>', 200));
    final api = ApiClient(baseUrl: 'https://example.org/api/v1', httpClient: fake);
    final result = await api.checkBackend();
    expect(result.verified, isFalse);
    expect(result.statusCode, 200);
    expect(result.message, contains('not JSON'));
  });

  test('an unrelated JSON API is not accepted just because it returns HTTP 200', () async {
    final fake = MockClient((request) async =>
        http.Response(jsonEncode({'name': 'Other Service', 'status': 'ok'}), 200));
    final api = ApiClient(baseUrl: 'https://example.org/api/v1', httpClient: fake);
    final result = await api.checkBackend();
    expect(result.verified, isFalse);
    expect(result.message, contains('not identifying itself as Origami'));
  });

  test('HTTP error from backend identity probe is visible', () async {
    final fake = MockClient((request) async => http.Response('Unauthorized', 401));
    final api = ApiClient(baseUrl: 'https://example.org/api/v1', httpClient: fake);
    final result = await api.checkBackend();
    expect(result.verified, isFalse);
    expect(result.statusCode, 401);
    expect(result.message, contains('HTTP 401'));
  });

  test('health failures stay visible even if the root identifies as Origami', () async {
    final fake = MockClient((request) async {
      if (request.url.path == '/') {
        return http.Response(jsonEncode({'name': 'Origami FarmOS API', 'status': 'ok'}), 200);
      }
      return http.Response('Service Unavailable', 503);
    });
    final api = ApiClient(baseUrl: 'https://example.org/api/v1', httpClient: fake);
    final result = await api.checkBackend();
    expect(result.verified, isFalse);
    expect(result.statusCode, 503);
    expect(result.message, contains('health'));
  });
}
