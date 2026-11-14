import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:farmos/core/i18n/locale_controller.dart';
import 'package:farmos/features/animals/add_animal_form.dart';
import 'package:farmos/features/animals/animal_digital_twin_screen.dart';
import 'package:farmos/features/animals/animal_quick_actions.dart';
import 'package:farmos/features/animals/animal_quick_entry_screen.dart';
import 'package:farmos/features/animals/animal_status_screen.dart';
import 'package:farmos/features/animals/group_form.dart';
import 'package:farmos/features/employees/employees_screen.dart';
import 'package:farmos/features/feed/feed_workspace_screen.dart';
import 'package:farmos/features/feed/feeding_event_dialog.dart';
import 'package:farmos/features/feed/purchase_and_mix_dialogs.dart';
import 'package:farmos/features/finance/sales_finance_screen.dart';
import 'package:farmos/features/health/health_cases.dart';
import 'package:farmos/features/health/health_intelligence_screen.dart';
import 'package:farmos/features/health/pharmacy_tab.dart';
import 'package:farmos/features/morning/morning_briefing_screen.dart';
import 'package:farmos/features/mouneh/mouneh_module_screen.dart';
import 'package:farmos/features/produce/produce_harvest_screen.dart';
import 'package:farmos/features/production/egg_production_screen.dart';
import 'package:farmos/features/production/milk_production_screen.dart';
import 'package:farmos/features/settings/settings_screen.dart';
import 'package:farmos/features/tasks/tasks_screen.dart';
import 'package:farmos/features/visits/visits_module_screen.dart';
import 'package:farmos/providers/animals_provider.dart';

import '../support/snapshot_farm.dart';

/// Every main screen and the forms a worker fills in, drawn over the demo
/// farm at the sizes real tablets give the content area — a 10" in
/// landscape and portrait, a small 8" in portrait — in English and Arabic.
/// Anything that overflows its space or throws while building fails here
/// rather than on the farm.
void main() {
  const sizes = <String, Size>{
    '10in landscape': Size(1040, 720),
    '10in portrait': Size(800, 1180),
    '8in portrait': Size(600, 900),
  };

  final screens = <String, Widget Function()>{
    'My Day': () => const MorningBriefingScreen(),
    'Animals': () => const AnimalStatusScreen(),
    'Feed': () => const FeedWorkspaceScreen(),
    'Milk': () => const MilkProductionScreen(),
    'Eggs': () => const EggProductionScreen(),
    'Health': () => const HealthIntelligenceScreen(),
    'Produce': () => const ProduceHarvestScreen(),
    'Mouneh': () => const MounehModuleScreen(),
    'Visits': () => const VisitsModuleScreen(),
    'Sales': () => const SalesFinanceScreen(),
    'Tasks': () => const TasksScreen(),
    'Employees': () => const EmployeesScreen(),
    'Settings': () => const SettingsScreen(),
    'Digital twin': () => const AnimalDigitalTwinScreen(animalId: 'cow-744'),
    'Quick entry': () => const AnimalQuickEntryScreen(initialAnimalId: 'cow-744'),
  };

  final forms = <String, void Function(BuildContext)>{
    'add animal': (c) => showAnimalForm(c),
    'edit animal': (c) => showAnimalForm(c, animal: c.read<AnimalsProvider>().find('cow-744')!),
    'milk': (c) => showMilkDialog(c, c.read<AnimalsProvider>().find('cow-744')!),
    'observation': (c) => showObserveDialog(c, 'cow-744'),
    'feeding': (c) => showFeedingEventDialog(c, subjectType: 'animal', subjectId: 'cow-744', subjectName: 'Bella'),
    'purchase': (c) => showRecordPurchaseDialog(c),
    'mix': (c) => showRecordMixDialog(c),
    'new group': (c) => showNewGroupForm(c),
    'open health case': (c) => showOpenCaseForm(c),
    'give medicine': (c) => showAdministerDialog(c, subjectType: 'animal', subjectId: 'cow-744'),
    'receive medicine': (c) => showReceiveMedicineDialog(c),
  };

  /// Draws [build] at [size] in [locale]; returns what went wrong, one line each.
  Future<List<String>> problems(WidgetTester tester, Size size, Locale locale, Widget Function() build,
      {void Function(BuildContext)? open, bool tabs = false}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final found = <String>[];
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      final text = details.toString();
      final where = RegExp(r'(lib/[\w/]+\.dart:\d+)').firstMatch(text)?.group(1);
      final creator = where != null ? null : RegExp(r'creator: ([^\n]{0,260})').firstMatch(text)?.group(1);
      final line = '${details.exceptionAsString().split('\n').first}${where == null ? '' : ' — $where'}${creator == null ? '' : ' — $creator'} @${size.width.toInt()}';
      if (!found.contains(line)) found.add(line);
    };
    try {
      final farm = await SnapshotFarm.open();
      await tester.pumpWidget(farm.app(
        ChangeNotifierProvider(
          create: (_) => LocaleController(),
          child: Scaffold(
            body: open == null
                ? build()
                : Builder(builder: (context) => Center(child: TextButton(onPressed: () => open(context), child: const Text('open')))),
          ),
        ),
        locale: locale,
      ));
      await settle(tester);
      if (open != null) {
        await tester.tap(find.text('open'));
        await settle(tester);
      }
      if (tabs) {
        // Every tab of the screen, not only the one it opens on.
        final count = find.byType(Tab).evaluate().length;
        for (var i = 0; i < count; i++) {
          final tab = find.byType(Tab).at(i);
          if (tab.evaluate().isEmpty) break;
          await tester.ensureVisible(tab);
          await tester.tap(tab, warnIfMissed: false);
          await settle(tester);
        }
      }
    } finally {
      FlutterError.onError = previous;
    }
    return found;
  }

  for (final locale in const [Locale('en'), Locale('ar')]) {
    for (final size in sizes.entries) {
      testWidgets('screens fit a ${size.key} tablet (${locale.languageCode})', (tester) async {
        final report = <String>[];
        for (final screen in screens.entries) {
          for (final p in await problems(tester, size.value, locale, screen.value, tabs: true)) {
            report.add('${screen.key}: $p');
          }
        }
        expect(report, isEmpty, reason: report.join('\n'));
      });

      testWidgets('forms fit a ${size.key} tablet (${locale.languageCode})', (tester) async {
        final report = <String>[];
        for (final form in forms.entries) {
          for (final p in await problems(tester, size.value, locale, () => const SizedBox(), open: form.value)) {
            report.add('${form.key}: $p');
          }
        }
        expect(report, isEmpty, reason: report.join('\n'));
      });
    }
  }
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}
