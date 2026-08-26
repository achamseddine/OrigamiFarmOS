import 'package:flutter/material.dart';
import '../core/widgets/app_icon.dart';
import '../core/widgets/nav_rail.dart';
import '../domain/entities/access.dart';
import '../features/animals/animal_status_screen.dart';
import '../features/employees/employees_screen.dart';
import '../features/feed/feed_inventory_screen.dart';
import '../features/finance/sales_finance_screen.dart';
import '../features/health/health_intelligence_screen.dart';
import '../features/morning/morning_briefing_screen.dart';
import '../features/mouneh/mouneh_module_screen.dart';
import '../features/produce/produce_harvest_screen.dart';
import '../features/production/egg_production_screen.dart';
import '../features/production/milk_production_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/tasks/tasks_screen.dart';
import '../features/visits/visits_module_screen.dart';
import '../providers/access_provider.dart';

/// One navigable destination: a screen, the label to show for it, and the
/// modules that unlock it.
class _Destination {
  const _Destination(this.icon, this.labelKey, this.builder, {required this.modules, this.alwaysVisible = false});

  final FarmIcon icon;
  final String labelKey;
  final Widget Function() builder;

  /// Holding *any* of these grants the tab — the Animals screen serves
  /// whoever looks after animals, whether their grant says Animals,
  /// Animal Health or Milk Production.
  final List<String> modules;

  /// Shown to everyone regardless of grants (Settings — every user needs
  /// somewhere to change their language and sign out).
  final bool alwaysVisible;
}

/// The full destination list, in nav-rail order. What each user actually
/// sees is derived from this by [buildNavForAccess].
final List<_Destination> _destinations = [
  _Destination(FarmIcon.sun, 'navMorningBriefing', () => const MorningBriefingScreen(),
      modules: [FarmModule.morningOperations]),
  _Destination(FarmIcon.cow, 'navAnimals', () => const AnimalStatusScreen(),
      modules: [FarmModule.animals, FarmModule.animalHealth]),
  _Destination(FarmIcon.feedBag, 'navFeedInventory', () => const FeedInventoryScreen(),
      modules: [FarmModule.feedNutrition, FarmModule.inventory]),
  _Destination(FarmIcon.milkBottle, 'navMilk', () => const MilkProductionScreen(),
      modules: [FarmModule.milkProduction]),
  _Destination(FarmIcon.egg, 'navEggs', () => const EggProductionScreen(),
      modules: [FarmModule.eggProduction]),
  _Destination(FarmIcon.stethoscope, 'navHealth', () => const HealthIntelligenceScreen(),
      modules: [FarmModule.animalHealth, FarmModule.aiIntelligence]),
  _Destination(FarmIcon.harvestBasket, 'navProduce', () => const ProduceHarvestScreen(),
      modules: [FarmModule.agriculture, FarmModule.produceHarvest]),
  _Destination(FarmIcon.inventory, 'navMouneh', () => const MounehModuleScreen(),
      modules: [FarmModule.mounehProduction, FarmModule.mounehInventory]),
  _Destination(FarmIcon.calendar, 'navVisits', () => const VisitsModuleScreen(),
      modules: [FarmModule.farmVisits]),
  _Destination(FarmIcon.money, 'navSales', () => const SalesFinanceScreen(),
      modules: [FarmModule.finance, FarmModule.sales, FarmModule.expenses]),
  _Destination(FarmIcon.task, 'navTasks', () => const TasksScreen(), modules: [FarmModule.tasks]),
  _Destination(FarmIcon.people, 'navEmployees', () => const EmployeesScreen(), modules: [FarmModule.employees]),
  _Destination(FarmIcon.settings, 'navSettings', () => const SettingsScreen(),
      modules: [FarmModule.settings], alwaysVisible: true),
];

/// The nav entries, screens, and module->tab index map for one user.
typedef NavPlan = ({List<NavEntry> entries, List<Widget> screens, Map<String, int> moduleIndex});

/// Builds the navigation for the signed-in user from their actual module
/// responsibilities (tech spec §20).
///
/// An employee responsible only for Animals gets Morning, Animals, Tasks
/// and Settings; add Agriculture to the same person and Produce appears
/// too. A farm manager holds every module, so they see everything. A
/// licensed-but-unlicensed module (Mouneh, Visits) is hidden even from a
/// manager, because the farm has not bought it.
NavPlan buildNavForAccess(AccessProvider access) {
  final entries = <NavEntry>[];
  final screens = <Widget>[];
  final moduleIndex = <String, int>{};

  for (final destination in _destinations) {
    final visible = destination.alwaysVisible || destination.modules.any(access.isModuleAvailable);
    if (!visible) continue;

    final index = entries.length;
    entries.add(NavEntry(destination.icon, destination.labelKey));
    screens.add(destination.builder());
    for (final module in destination.modules) {
      // First tab that serves a module wins, so a deep link lands on the
      // most specific screen for it rather than a later general one.
      moduleIndex.putIfAbsent(module, () => index);
    }
  }

  // A user whose farm has licensed nothing they hold would otherwise face
  // an empty shell; Settings is alwaysVisible precisely to prevent that.
  return (entries: entries, screens: screens, moduleIndex: moduleIndex);
}
