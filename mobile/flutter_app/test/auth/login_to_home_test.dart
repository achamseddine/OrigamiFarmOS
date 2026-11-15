import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:farmos/api/api_client.dart';
import 'package:farmos/app/app.dart';
import 'package:farmos/auth/session_controller.dart';
import 'package:farmos/core/widgets/app_shell.dart';
import 'package:farmos/features/auth/login_screen.dart';

/// Regression: the server can accept credentials while local persistence
/// is slow. A valid login MUST replace the credential form with AppShell.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('credentials accepted -> permissions -> farm home', (tester) async {
    SharedPreferences.setMockInitialValues({'farmos.locale': 'en'});
    tester.view.physicalSize = const Size(1100, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final requested = <String>[];
    final httpClient = MockClient((request) async {
      final path = request.url.path;
      requested.add(path);
      Object response;
      if (path == '/api/v1/auth/login') {
        response = {
          'access_token': 'test-only-token',
          'user': {
            'id': 'worker-1',
            'farm_id': 'farm-1',
            'name': 'Test Worker',
            'email': 'worker@example.test',
            'role': 'employee',
            'active': true,
          },
        };
      } else if (path == '/api/v1/me/access') {
        response = {
          'user_id': 'worker-1',
          'role': 'employee',
          'full_access': false,
          'modules': {
            'morning_operations': {'view': true}
          },
        };
      } else if (path == '/api/v1/modules/catalog') {
        response = [
          {
            'code': 'morning_operations',
            'label_en': 'My Day',
            'label_ar': 'يومي',
            'group': 'farm',
          }
        ];
      } else {
        response = [];
      }
      return http.Response(jsonEncode(response), 200, headers: {'content-type': 'application/json'});
    });
    final session = SessionController(
      client: ApiClient(baseUrl: 'https://farm.example.test/api/v1', httpClient: httpClient),
    );
    addTearDown(session.dispose);

    await tester.pumpWidget(FarmOSApp(sessionController: session));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(LoginScreen), findsOneWidget);
    await tester.enterText(find.byType(TextField).at(0), 'worker@example.test');
    await tester.enterText(find.byType(TextField).at(1), 'password');
    await tester.tap(find.widgetWithText(FilledButton, 'Start My Day'));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(session.status, SessionStatus.loggedIn);
    expect(find.byType(LoginScreen), findsNothing,
        reason: 'A successful sign-in must leave the credentials page');
    expect(find.byType(AppShell), findsOneWidget);
    expect(requested, contains('/api/v1/auth/login'));
    expect(requested, contains('/api/v1/me/access'));
    expect(requested, contains('/api/v1/modules/catalog'));
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
