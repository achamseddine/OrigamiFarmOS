import 'package:flutter_test/flutter_test.dart';

/// The shape `SessionController.login` reads out of `POST /auth/login`,
/// and what it must do when the server does not send it.
///
/// This exists because of a real week-long failure. The server returned
/// `{"access_token": "…", "token_type": "bearer"}` with no `user`, the
/// controller did `json['user'] as Map<String, dynamic>`, and the
/// resulting TypeError was not an ApiException — so nothing caught it.
/// The sign-in button did nothing at all, while the server logged a clean
/// 200 and curl returned a valid token. Every signal pointed away from
/// the cause.
///
/// These tests pin the *reading*, not the controller (which needs
/// platform channels): a checked read that reports a missing field,
/// rather than a cast that throws past its own error handler.
void main() {
  /// The same checks `SessionController.login` performs, in the same
  /// order. Returns null when the response is usable, or the message the
  /// user should see.
  String? problemWith(Map<String, dynamic> json) {
    final token = json['access_token'];
    if (token is! String || token.isEmpty) {
      return 'Signed in, but the server sent no token. It may be running an older build.';
    }
    final profile = json['user'];
    if (profile is! Map<String, dynamic>) {
      return 'Signed in, but the server sent no user profile — it is running a build older '
          'than this app. Check http://server/health for its version.';
    }
    return null;
  }

  group('login response', () {
    test('a complete response is accepted', () {
      expect(
        problemWith({
          'access_token': 'eyJhbGciOiJIUzI1NiIs',
          'token_type': 'bearer',
          'user': {'id': 'u1', 'farm_id': 'f1', 'name': 'Rami', 'role': 'owner'},
        }),
        isNull,
      );
    });

    test('a response with no user explains itself instead of throwing', () {
      // Exactly what the staging server returned for a week.
      final problem = problemWith({
        'access_token': 'eyJhbGciOiJIUzI1NiIs',
        'token_type': 'bearer',
      });
      expect(problem, isNotNull);
      expect(problem, contains('no user profile'));
      // Naming /health is the difference between "it is broken" and a
      // next step, since that endpoint reports the build it is running.
      expect(problem, contains('/health'));
    });

    test('a response with no token explains itself', () {
      final problem = problemWith({'token_type': 'bearer', 'user': {'id': 'u1'}});
      expect(problem, isNotNull);
      expect(problem, contains('no token'));
    });

    test('a user that is not an object is treated as missing, not cast', () {
      // A cast would throw here; the check must not.
      expect(problemWith({'access_token': 'abc', 'user': 'nope'}), contains('no user profile'));
      expect(problemWith({'access_token': 'abc', 'user': null}), contains('no user profile'));
    });
  });
}
