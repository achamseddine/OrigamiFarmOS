import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:farmos/app/nav_config.dart';
import 'package:farmos/features/reports/report_docs.dart';
import 'package:farmos/features/reports/report_export.dart';
import 'package:farmos/features/reports/reports_screen.dart';
import 'package:farmos/providers/access_provider.dart';
import 'package:farmos/providers/reports_provider.dart';

import '../support/snapshot_farm.dart';

/// Reports (v0.7.9): milk, feed, the herd and the money for a chosen
/// period, worked out by the farm server from the records; read on
/// screen, printed or saved as PDF, exported as a spreadsheet. The same
/// page on the tablet and the web.
void main() {
  const me = 'user-ali-demo';
  Map<String, Object?> access(Map<String, Object?> modules) => {'user_id': me, 'role': 'worker', 'full_access': false, 'modules': modules};

  Future<SnapshotFarm> open(WidgetTester tester, Widget home, {Map<String, Object?>? me, Map<String, Object?> extra = const {}, Locale locale = const Locale('en')}) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final farm = await SnapshotFarm.open();
    if (me != null) farm.api.snapshot['GET /me/access'] = me;
    farm.api.snapshot.addAll(extra);
    await tester.pumpWidget(farm.app(Scaffold(body: home), locale: locale));
    await settle(tester);
    return farm;
  }

  group('the Reports page', () {
    testWidgets('the manager reads every report; milk first with its money', (tester) async {
      await open(tester, const ReportsScreen());
      for (final tab in ['Milk', 'Feed', 'Herd', 'Finance']) {
        expect(find.text(tab), findsWidgets, reason: tab);
      }
      expect(find.text('Milk report'), findsOneWidget);
      expect(find.text('Milk produced'), findsOneWidget);
      expect(find.text('617.3 L'), findsWidgets);
      expect(find.text('Revenue'), findsOneWidget);
      expect(find.text('Per animal'), findsOneWidget);
      expect(find.text('Litres per day'), findsOneWidget);
      // Ready to print, save and export.
      for (final key in ['report-print', 'report-pdf', 'report-csv']) {
        final button = tester.widget<ButtonStyleButton>(find.descendant(of: find.byKey(ValueKey(key)), matching: find.byWidgetPredicate((w) => w is ButtonStyleButton)));
        expect(button.onPressed, isNotNull, reason: key);
      }
    });

    testWidgets('each tab is its report', (tester) async {
      await open(tester, const ReportsScreen());
      await tester.tap(find.byKey(const ValueKey('underline-tab-1')));
      await settle(tester);
      expect(find.text('Feed report'), findsOneWidget);
      expect(find.text('In stock now'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('underline-tab-2')));
      await settle(tester);
      expect(find.text('Herd report'), findsOneWidget);
      expect(find.text('By species'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('underline-tab-3')));
      await settle(tester);
      expect(find.text('Finance report'), findsOneWidget);
      expect(find.text('Revenue by product'), findsOneWidget);
    });

    testWidgets('a period is chosen and that period is asked for', (tester) async {
      final today = DateTime(2026, 11, 23);
      await open(tester, ReportsScreen(today: today));
      final reports = tester.element(find.byType(ReportsScreen)).read<ReportsProvider>();
      expect(reports.report('milk', ReportPeriod.lastDays(30, today: today)), isNotNull);
      await tester.tap(find.byKey(const ValueKey('report-period-last7')));
      await settle(tester);
      expect(reports.report('milk', ReportPeriod.lastDays(7, today: today)), isNotNull);
      await tester.tap(find.byKey(const ValueKey('report-period-lastMonth')));
      await settle(tester);
      final last = ReportPeriod.lastMonth(today: today);
      expect(last.startIso, '2026-10-01');
      expect(last.endIso, '2026-10-31');
      expect(reports.report('milk', last), isNotNull);
    });

    testWidgets('opened from the Milk page on the milk report, in its own page', (tester) async {
      await open(tester, Builder(builder: (c) => Center(child: TextButton(onPressed: () => openReport(c, 'herd'), child: const Text('open')))));
      await tester.tap(find.text('open'));
      await settle(tester);
      expect(find.text('Herd report'), findsOneWidget);
      expect(find.widgetWithText(AppBar, 'Reports'), findsOneWidget);
    });

    testWidgets('opened again, a report has what was recorded since — not the first answer', (tester) async {
      final farm = await open(tester, Builder(builder: (c) => Center(child: TextButton(onPressed: () => openReport(c, 'milk'), child: const Text('open')))));
      await tester.tap(find.text('open'));
      await settle(tester);
      expect(find.text('617.3 L'), findsWidgets);
      Navigator.of(tester.element(find.byType(ReportsScreen))).pop();
      await settle(tester);
      // A milking and a sale later, the server works out a new report.
      final later = jsonCopy(farm.api.snapshot['GET /reports/milk']);
      (later['kpis'] as Map)['total_l'] = 640.5;
      farm.api.snapshot['GET /reports/milk'] = later;
      await tester.tap(find.text('open'));
      await settle(tester);
      expect(find.text('640.5 L'), findsOneWidget);
    });

    testWidgets('kept hidden in the menu, it asks for nothing until it is shown', (tester) async {
      var shown = 0;
      await open(tester, StatefulBuilder(builder: (c, setState) => Column(children: [
            TextButton(onPressed: () => setState(() => shown = 1), child: const Text('show reports')),
            Expanded(child: IndexedStack(index: shown, children: const [SizedBox(), ReportsScreen()])),
          ])));
      final reports = tester.element(find.text('show reports')).read<ReportsProvider>();
      expect(reports.report('milk', ReportPeriod.lastDays(30)), isNull, reason: 'not fetched at sign-in');
      await tester.tap(find.text('show reports'));
      await settle(tester);
      expect(reports.report('milk', ReportPeriod.lastDays(30)), isNotNull);
    });

    testWidgets('an employee reads only the areas they work in, without money', (tester) async {
      final milkOnly = <String, dynamic>{
        ...(loadSnapshot()['GET /reports/milk'] as Map).cast<String, dynamic>(),
      };
      final kpis = (milkOnly['kpis'] as Map).cast<String, dynamic>()
        ..remove('sold_l')
        ..remove('revenue')
        ..remove('avg_price_per_liter')
        ..remove('pending_amount');
      milkOnly['kpis'] = kpis;
      milkOnly.remove('sales');
      milkOnly.remove('by_buyer');
      await open(tester, const ReportsScreen(),
          me: access({'milk_production': {'view': true, 'create': true}}), extra: {'GET /reports/milk': milkOnly});
      expect(find.text('Milk report'), findsOneWidget);
      expect(find.byKey(const ValueKey('underline-tab-1')), findsNothing, reason: 'one report only');
      expect(find.text('Revenue'), findsNothing);
      expect(find.text('Milk sales'), findsNothing);
    });

    testWidgets('no area, no reports — said in words', (tester) async {
      await open(tester, const ReportsScreen(), me: access({'tasks': {'view': true}}));
      expect(find.text('You have no reports to read. Ask the farm manager for access.'), findsOneWidget);
    });

    testWidgets('a report that cannot be loaded says so and can be retried', (tester) async {
      final farm = await SnapshotFarm.open();
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      farm.api.snapshot['GET /reports/milk'] = 'not a report';
      await tester.pumpWidget(farm.app(const Scaffold(body: ReportsScreen())));
      await settle(tester);
      expect(find.text('The report could not be loaded'), findsOneWidget);
      expect(find.byKey(const ValueKey('report-retry-milk')), findsOneWidget);
    });

    testWidgets('in Arabic', (tester) async {
      await open(tester, const ReportsScreen(), locale: const Locale('ar'));
      expect(find.text('تقرير الحليب'), findsOneWidget);
      expect(find.text('الحليب المنتج'), findsOneWidget);
    });
  });

  group('the spreadsheet', () {
    testWidgets('the milk report as a CSV: title, period, figures, tables', (tester) async {
      late ReportDoc doc;
      await open(tester, Builder(builder: (c) {
        doc = buildReportDoc(c, 'milk', (loadSnapshot()['GET /reports/milk'] as Map).cast<String, dynamic>(), speciesName: (s) => s);
        return const SizedBox();
      }));
      final csv = doc.toCsv();
      expect(csv.startsWith('﻿'), isTrue, reason: 'Excel reads UTF-8 (Arabic) with the mark');
      final lines = csv.substring(1).split('\n');
      expect(lines.first, 'Milk report');
      expect(lines[1], startsWith('Period:'));
      expect(csv, contains('Milk produced,617.3 L'));
      expect(csv, contains('Day by day'));
      expect(csv, contains('Date,Morning'));
      expect(doc.fileStem, startsWith('origami-milk-'));
    });

    test('cells with commas, quotes or lines are quoted', () {
      const doc = ReportDoc(title: 'T', period: 'P', kpis: [('Buyer', 'Laiterie, Bekaa')], tables: [
        ReportTable(title: 'Sales', columns: ['Buyer', 'Note'], rows: [['Abu "Ali"', 'two\nlines']]),
      ]);
      final csv = doc.toCsv();
      expect(csv, contains('Buyer,"Laiterie, Bekaa"'));
      expect(csv, contains('"Abu ""Ali""","two\nlines"'));
    });
  });

  testWidgets('the PDF is drawn from the report on screen', (tester) async {
    await open(tester, const ReportsScreen());
    final view = tester.widget<ReportView>(find.byType(ReportView).first);
    final bytes = await tester.runAsync(() => reportPdf(view.blocks, title: view.doc.title));
    expect(bytes, isNotNull);
    expect(String.fromCharCodes(bytes!.take(4)), '%PDF');
  });

  test('periods count farm days, both ends included', () {
    final today = DateTime(2026, 3, 15);
    expect(ReportPeriod.lastDays(7, today: today).startIso, '2026-03-09');
    expect(ReportPeriod.lastDays(7, today: today).days, 7);
    expect(ReportPeriod.thisMonth(today: today).startIso, '2026-03-01');
    expect(ReportPeriod.lastMonth(today: DateTime(2026, 1, 10)).startIso, '2025-12-01');
    expect(ReportPeriod.lastMonth(today: DateTime(2026, 1, 10)).endIso, '2025-12-31');
    expect(ReportPeriod.lastMonth(today: today).days, 28);
  });

  testWidgets('Reports is in the menu for the manager, not for an employee without it', (tester) async {
    final farm = await open(tester, const SizedBox());
    final manager = tester.element(find.byType(SizedBox).first).read<AccessProvider>();
    expect(buildNavForAccess(manager).entries.map((e) => e.labelKey), contains('navReports'));
    farm.api.snapshot['GET /me/access'] = access({'milk_production': {'view': true, 'create': true}});
    await manager.load();
    expect(buildNavForAccess(manager).entries.map((e) => e.labelKey), isNot(contains('navReports')));
  });
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}

Map<String, dynamic> jsonCopy(Object? body) => (jsonDecode(jsonEncode(body)) as Map).cast<String, dynamic>();
