import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:farmos/core/widgets/form_dialog.dart';
import 'package:farmos/features/feed/feed_workspace_screen.dart';
import 'package:farmos/features/feed/feeding_event_dialog.dart';
import 'package:farmos/features/feed/purchase_and_mix_dialogs.dart';
import 'package:farmos/features/health/health_intelligence_screen.dart';
import 'package:farmos/features/mouneh/mouneh_module_screen.dart';
import 'package:farmos/features/visits/visits_module_screen.dart';

import '../support/snapshot_farm.dart';

/// The module pages and the feed forms on a real tablet screen (tablet and
/// web, one codebase). They used to show the chosen tab in a window a few
/// lines tall under the header — a mix, the day's feeding or a report
/// scrolled inside it unreadably — and the mix form left a small window
/// above the keyboard.
void main() {
  const tablet = Size(1280, 800);

  Future<void> show(WidgetTester tester, Widget screen, {Size size = tablet}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final farm = await SnapshotFarm.open();
    await tester.pumpWidget(farm.app(Scaffold(body: screen)));
    await settle(tester);
  }

  Finder tab(int i) => find.byKey(ValueKey('underline-tab-$i'));

  /// Every vertical scrolling area on screen and its height (a text box
  /// of several lines scrolls its own text: that is not a page area).
  List<double> scrollHeights(WidgetTester tester) => [
        for (final e in find.byType(Scrollable).evaluate())
          if (axisDirectionToAxis((e.widget as Scrollable).axisDirection) == Axis.vertical &&
              find.ancestor(of: find.byWidget(e.widget), matching: find.byType(EditableText)).evaluate().isEmpty)
            (e.renderObject! as RenderBox).size.height,
      ];

  final modules = <String, (Widget, int)>{
    'Feed': (const FeedWorkspaceScreen(), 10),
    'Health': (const HealthIntelligenceScreen(), 5),
    'Mouneh': (const MounehModuleScreen(), 7),
    'Visits': (const VisitsModuleScreen(), 10),
  };

  for (final m in modules.entries) {
    testWidgets('${m.key}: every tab is read at full height, in one page scroll', (tester) async {
      await show(tester, m.value.$1);
      for (var i = 0; i < m.value.$2; i++) {
        await tester.ensureVisible(tab(i));
        await tester.tap(tab(i));
        await settle(tester);
        final heights = scrollHeights(tester);
        expect(heights, isNotEmpty);
        expect(heights.reduce((a, b) => a < b ? a : b), tablet.height,
            reason: 'tab $i: the page is the only vertical scroll, the whole screen tall — no window inside it');
      }
    });
  }

  testWidgets('the tab bar stays at the top and a newly chosen tab starts from its beginning', (tester) async {
    await show(tester, const FeedWorkspaceScreen());
    await tester.tap(find.text('Feed intake'));
    await settle(tester);
    final page = find.byType(Scrollable).first;
    await tester.drag(page, const Offset(0, -3000));
    await settle(tester);
    expect(tester.getTopLeft(tab(0)).dy, 0, reason: 'scrolled down, the tabs are pinned to the top');
    final pinnedAt = tester.state<ScrollableState>(page).position.pixels;

    await tester.tap(find.text('Mix production'));
    await settle(tester);
    expect(tester.getTopLeft(tab(0)).dy, 0);
    final position = tester.state<ScrollableState>(page).position;
    expect(position.pixels, lessThanOrEqualTo(pinnedAt));
    expect(find.textContaining('it is never typed in'), findsOneWidget, reason: 'the mix tab is shown from its first section');
    expect(tester.getTopLeft(find.textContaining('it is never typed in')).dy, lessThan(tablet.height));
  });

  testWidgets('a tab keeps what was typed while another tab is shown', (tester) async {
    await show(tester, const VisitsModuleScreen());
    await tester.ensureVisible(find.text('Booking Form'));
    await tester.tap(find.text('Booking Form'));
    await settle(tester);
    final start = find.widgetWithText(TextField, 'Start (HH:MM)');
    await tester.ensureVisible(start);
    await tester.enterText(start, '09:30');
    await tester.ensureVisible(tab(0));
    await tester.tap(tab(0));
    await settle(tester);
    expect(find.text('09:30'), findsNothing, reason: 'only the shown tab is on screen');
    await tester.ensureVisible(find.text('Booking Form'));
    await tester.tap(find.text('Booking Form'));
    await settle(tester);
    expect(find.text('09:30'), findsOneWidget);
  });

  testWidgets('a report is shown to its last line: Mouneh sales and profitability', (tester) async {
    await show(tester, const MounehModuleScreen());
    await tester.tap(find.text('Sales & profit').first, warnIfMissed: false);
    await settle(tester);
    final caveat = find.textContaining('Costs nobody recorded');
    await tester.scrollUntilVisible(caveat, 300, scrollable: find.byType(Scrollable).first);
    await settle(tester);
    final rect = tester.getRect(caveat);
    expect(rect.top, greaterThanOrEqualTo(0));
    expect(rect.bottom, lessThanOrEqualTo(tablet.height), reason: 'the report\'s last note can be read in full');
  });

  testWidgets('a report is shown to its last line: Visits profitability', (tester) async {
    await show(tester, const VisitsModuleScreen());
    await tester.ensureVisible(find.text('Profitability Report'));
    await tester.tap(find.text('Profitability Report'));
    await settle(tester);
    final last = find.text('Activity Utilization');
    await tester.scrollUntilVisible(last, 300, scrollable: find.byType(Scrollable).first);
    await settle(tester);
    expect(tester.getRect(last).bottom, lessThanOrEqualTo(tablet.height));
  });

  group('feed forms', () {
    Future<void> openForm(WidgetTester tester, void Function(BuildContext) open, {Size size = tablet}) async {
      await show(
        tester,
        Builder(builder: (c) => Center(child: TextButton(onPressed: () => open(c), child: const Text('open')))),
        size: size,
      );
      await tester.tap(find.text('open'));
      await settle(tester);
    }

    final forms = <String, (void Function(BuildContext), String)>{
      'mix': ((c) => showRecordMixDialog(c), 'Save the mix'),
      'purchase': ((c) => showRecordPurchaseDialog(c), 'Save'),
      'feeding': ((c) => showFeedingEventDialog(c, subjectType: 'animal', subjectId: 'cow-744', subjectName: 'Bella'), 'Save'),
    };

    for (final f in forms.entries) {
      testWidgets('${f.key}: full screen on a tablet, Save above the keyboard', (tester) async {
        await openForm(tester, f.value.$1);
        expect(find.byKey(const ValueKey('form-full-screen')), findsOneWidget);
        // The keyboard up: the form scrolls, the buttons stay in sight.
        tester.view.viewInsets = const FakeViewPadding(bottom: 360);
        addTearDown(tester.view.resetViewInsets);
        await settle(tester);
        final save = find.widgetWithText(FilledButton, f.value.$2).last;
        expect(tester.getRect(save).bottom, lessThanOrEqualTo(tablet.height - 360));
        await tester.tap(find.byTooltip('Close'));
        await settle(tester);
        expect(find.byKey(const ValueKey('form-full-screen')), findsNothing);
      });
    }

    testWidgets('a dialog on a large desktop screen', (tester) async {
      await openForm(tester, (c) => showRecordMixDialog(c), size: const Size(1920, 1080));
      expect(find.byKey(const ValueKey('form-full-screen')), findsNothing);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(FarmFormDialog.fullScreenBelow, greaterThan(800), reason: 'a 10" tablet in either orientation is full screen');
    });

    testWidgets('the mix form\'s ingredient rows do not run into each other', (tester) async {
      await openForm(tester, (c) => showRecordMixDialog(c));
      final labels = find.text('Ingredient');
      if (labels.evaluate().length < 2) return; // fewer than two rows on this farm
      final rows = [for (final e in labels.evaluate()) tester.getRect(find.byWidget(e.widget).first)];
      rows.sort((a, b) => a.top.compareTo(b.top));
      final helpers = find.textContaining('in stock');
      for (final h in helpers.evaluate()) {
        final r = tester.getRect(find.byWidget(h.widget).first);
        for (final l in rows) {
          expect(r.overlaps(l), isFalse, reason: 'a stock line and the next row\'s label overlap');
        }
      }
    });
  });
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}
