import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:farmos/app/app.dart';

// NOTE: These widget tests exercise the app shell without a real device —
// SQLite (sqflite) and shared_preferences calls fall back gracefully (see
// `_RootRouter._start` and `LocaleController._restore`) when no platform
// channel is registered, so the UI still renders. Run with
// `flutter test` (see mobile/flutter_app/README.md).
void main() {
  testWidgets('Welcome screen shows the practical greeting and CTAs', (WidgetTester tester) async {
    await tester.pumpWidget(const FarmOSApp());
    await tester.pump();

    expect(find.text('Start My Day'), findsOneWidget);
    expect(find.text('View Demo Farm'), findsOneWidget);
    expect(find.textContaining('Good Morning'), findsOneWidget);
  });

  testWidgets('Start My Day navigates into the Morning Briefing shell', (WidgetTester tester) async {
    await tester.pumpWidget(const FarmOSApp());
    await tester.pump();

    await tester.tap(find.text('Start My Day'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text("Today's Priorities"), findsOneWidget);
  });
}
