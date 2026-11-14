import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:farmos/auth/session_controller.dart';
import 'package:farmos/features/auth/login_screen.dart';
import 'package:farmos/api/api_client.dart';

void main() {
  test('a stalled saved-session restore has a non-destructive escape', () {
    final session = SessionController();
    addTearDown(session.dispose);
    session.apiClient.token = 'preserved-pending-token';
    expect(session.status, SessionStatus.checking);

    session.showLoginInstead();

    expect(session.status, SessionStatus.loggedOut);
    expect(session.apiClient.token, 'preserved-pending-token',
        reason: 'showing the login form must not erase saved credentials or outbox data');
    expect(ApiClient.networkTimeout, lessThanOrEqualTo(const Duration(seconds: 15)));
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
    final first = tester.getTopLeft(fields.at(0));
    final second = tester.getTopLeft(fields.at(1));
    expect(first.dy, lessThan(740));
    expect(second.dy, lessThan(740),
        reason: 'the fixed-height landscape artwork used to push password below the screen');

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
