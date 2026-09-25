import 'package:flutter_test/flutter_test.dart';

/// What `SessionController.login` sends, and what it must still send when
/// the tablet cannot tell the app which install it is.
///
/// Tablets used to reach their farm's device list by being paired: an
/// admin generated a key and somebody typed it into the app. Device
/// licences are gone with the move to one subscription, so nothing
/// creates that row any anymore unless the app volunteers it — which is
/// what `installation_id` is for.
///
/// The rule worth pinning is the failure mode, not the happy path: a
/// device list is a convenience for whoever runs the platform, and a farm
/// worker standing in a field at six in the morning must not be kept out
/// of the app because a preferences read failed. This mirrors the server,
/// which accepts a login with no id and simply records nothing.
void main() {
  /// The body `SessionController.login` builds, with the same conditions.
  Map<String, Object?> loginBody({
    required String email,
    required String password,
    required String? install,
    required String appVersion,
  }) {
    return {
      'email': email.trim(),
      'password': password,
      if (install != null) 'installation_id': install,
      if (install != null) 'device_name': 'Origami tablet',
      if (install != null) 'app_version': appVersion,
    };
  }

  group('login request', () {
    test('a tablet that knows its install id sends it', () {
      final body = loginBody(
        email: 'owner@riyak-farm.com',
        password: 'secret',
        install: 'ins-0123456789abcdef0123456789abcdef',
        appVersion: '1a2b3c4',
      );

      expect(body['installation_id'], 'ins-0123456789abcdef0123456789abcdef');
      expect(body['device_name'], 'Origami tablet');
      expect(body['app_version'], '1a2b3c4');
    });

    test('a tablet that does not can still sign in', () {
      final body = loginBody(
        email: 'owner@riyak-farm.com',
        password: 'secret',
        install: null,
        appVersion: 'dev',
      );

      // Credentials only — and crucially not `installation_id: null`,
      // which would be the app asserting something about a device it
      // cannot identify.
      expect(body.keys.toSet(), {'email', 'password'});
      expect(body['password'], 'secret');
    });

    test('the email is trimmed, because a tablet keyboard adds spaces', () {
      final body = loginBody(
        email: '  owner@riyak-farm.com ',
        password: 'secret',
        install: null,
        appVersion: 'dev',
      );
      expect(body['email'], 'owner@riyak-farm.com');
    });
  });
}
