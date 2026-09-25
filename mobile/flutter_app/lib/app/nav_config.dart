import 'package:flutter/material.dart';
import '../core/theme/colors.dart';
import '../core/widgets/app_icon.dart';
import '../core/widgets/nav_rail.dart';
import '../domain/entities/access.dart';
import '../features/animals/animal_status_screen.dart';
import '../features/employees/employees_screen.dart';
import '../features/feed/feed_workspace_screen.dart';
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
  const _Destination(this.icon, this.labelKey, this.builder,
      {required this.modules, this.alwaysVisible = false, this.accent = FarmColors.cedar});

  final FarmIcon icon;
  final String labelKey;
  final Widget Function() builder;

  /// Colour of this destination's roundel in the More sheet.
  final Color accent;

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
      accent: FarmColors.gold, modules: [FarmModule.morningOperations]),
  _Destination(FarmIcon.cow, 'navAnimals', () => const AnimalStatusScreen(),
      accent: FarmColors.cedar, modules: [FarmModule.animals, FarmModule.animalHealth]),
  _Destination(FarmIcon.feedBag, 'navFeedInventory', () => const FeedWorkspaceScreen(),
      accent: FarmColors.olive, modules: [FarmModule.feedNutrition, FarmModule.inventory]),
  _Destination(FarmIcon.milkBottle, 'navMilk', () => const MilkProductionScreen(),
      accent: FarmColors.milkBlue, modules: [FarmModule.milkProduction]),
  _Destination(FarmIcon.egg, 'navEggs', () => const EggProductionScreen(),
      accent: FarmColors.gold, modules: [FarmModule.eggProduction]),
  _Destination(FarmIcon.stethoscope, 'navHealth', () => const HealthIntelligenceScreen(),
      accent: FarmColors.danger, modules: [FarmModule.animalHealth, FarmModule.aiIntelligence]),
  _Destination(FarmIcon.harvestBasket, 'navProduce', () => const ProduceHarvestScreen(),
      accent: FarmColors.olive, modules: [FarmModule.agriculture, FarmModule.produceHarvest]),
  _Destination(FarmIcon.inventory, 'navMouneh', () => const MounehModuleScreen(),
      accent: FarmColors.clay, modules: [FarmModule.mounehProduction, FarmModule.mounehInventory]),
  _Destination(FarmIcon.calendar, 'navVisits', () => const VisitsModuleScreen(),
      accent: FarmColors.lilac, modules: [FarmModule.farmVisits]),
  _Destination(FarmIcon.money, 'navSales', () => const SalesFinanceScreen(),
      accent: FarmColors.cedar2, modules: [FarmModule.finance, FarmModule.sales, FarmModule.expenses]),
  _Destination(FarmIcon.task, 'navTasks', () => const TasksScreen(), accent: FarmColors.cedar, modules: [FarmModule.tasks]),
  _Destination(FarmIcon.people, 'navEmployees', () => const EmployeesScreen(), accent: FarmColors.milkBlue, modules: [FarmModule.employees]),
  _Destination(FarmIcon.settings, 'navSettings', () => const SettingsScreen(),
      accent: FarmColors.muted, modules: [FarmModule.settings], alwaysVisible: true),
];

/// The nav entries, screens, and module->tab index map for one user.
typedef NavPlan = ({List<NavEntry> entries, List<Widget> screens, Map<String, int> moduleIndex});

/// Builds the navigation for the signed-in user from their actual module
/// responsibilities (tech spec §20).
///
/// An employee responsible only for Animals gets Morning, Animals, Tasks
/// and Settings; add Agriculture to the same person and Produce appears
/// too. A farm manager holds every module, so they see everything —
/// including Mouneh and Farm Visits, which used to be hidden until the
/// farm bought them and are now part of the one subscription.
NavPlan buildNavForAccess(AccessProvider access) {
  final entries = <NavEntry>[];
  final screens = <Widget>[];
  final moduleIndex = <String, int>{};

  for (final destination in _destinations) {
    final visible = destination.alwaysVisible || destination.modules.any(access.isModuleAvailable);
    if (!visible) continue;

    final index = entries.length;
    entries.add(NavEntry(destination.icon, destination.labelKey, accent: destination.accent));
    screens.add(destination.builder());
    for (final module in destination.modules) {
      // First tab that serves a module wins, so a deep link lands on the
      // most specific screen for it rather than a later general one.
      moduleIndex.putIfAbsent(module, () => index);
    }
  }

  // A user who has been given no modules at all would otherwise face an
  // empty shell; Settings is alwaysVisible precisely to prevent that.
  return (entries: entries, screens: screens, moduleIndex: moduleIndex);
}
