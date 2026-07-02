import 'package:flutter_test/flutter_test.dart';
import 'package:farmos/main.dart';

void main() {
  testWidgets('Morning Briefing loads successfully', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const FarmOSApp());

    // Verify that Morning Briefing is displayed.
    expect(find.text('Morning Briefing'), findsOneWidget);
    expect(find.text('Welcome to FarmOS'), findsOneWidget);
  });
}
