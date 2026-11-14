import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:farmos/app/app.dart';
import 'package:farmos/auth/session_controller.dart';
import 'package:farmos/features/auth/login_screen.dart';
import 'package:farmos/api/api_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a fresh controller starts at credentials and defaults to Azure staging API', () {
    final session = SessionController();
    addTearDown(session.dispose);
    expect(session.status, SessionStatus.loggedOut);
    expect(session.apiClient.baseUrl,
        'https://leb-container-test-staging.azurewebsites.net/api/v1');
    expect(ApiClient.networkTimeout, lessThanOrEqualTo(const Duration(seconds: 15)));
  });

  test('the retired restore method never signs in or deletes queued records', () async {
    SharedPreferences.setMockInitialValues({
      'auth_token': 'old-server-token',
      'api_base_url': 'http://10.0.2.2:8000/api/v1',
    });
    final session = SessionController();
    addTearDown(session.dispose);

    await session.restore();

    expect(session.status, SessionStatus.loggedOut);
    expect(session.user, isNull);
    expect(session.apiClient.token, isNull);
    expect(session.apiClient.baseUrl, kDefaultApiBaseUrl,
        reason: 'cached server preferences must never override the requested default');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('auth_token'), 'old-server-token',
        reason: 'recovery does not wipe storage or queue items');
  });

  testWidgets('existing saved credentials never hide login fields at startup', (tester) async {
    SharedPreferences.setMockInitialValues({
      'auth_token': 'old-server-token',
      'api_base_url': 'http://10.0.2.2:8000/api/v1',
      'farmos.locale': 'en',
    });
    await tester.pumpWidget(const FarmOSApp());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byType(LoginScreen), findsOneWidget);
    expect(find.byType(TextField), findsNWidgets(2));
    expect(find.text('Restoring your saved session…'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('portrait login fields are visible without scrolling', (tester) async {
    tester.view.physicalSize = const Size(390, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final session = SessionController();
    addTearDown(session.dispose);
    await tester.pumpWidget(ChangeNotifierProvider<SessionController>.value(
      value: session,
      child: const MaterialApp(home: LoginScreen()),
    ));
    await tester.pump(const Duration(milliseconds: 50));

    final fields = find.byType(TextField);
    expect(fields, findsNWidgets(2));
    expect(tester.getTopLeft(fields.at(0)).dy, lessThan(740));
    expect(tester.getTopLeft(fields.at(1)).dy, lessThan(740));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('landscape login shows editable credentials without hero art', (tester) async {
    tester.view.physicalSize = const Size(1024, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final session = SessionController();
    addTearDown(session.dispose);
    await tester.pumpWidget(ChangeNotifierProvider<SessionController>.value(
      value: session,
      child: const MaterialApp(home: LoginScreen()),
    ));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byType(TextField), findsNWidgets(2));
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
