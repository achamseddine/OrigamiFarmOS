import 'package:flutter/material.dart';
import '../core/widgets/nav_rail.dart';
import '../domain/entities/user_profile.dart';
import '../features/animals/animal_status_screen.dart';
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

/// Builds the role/department-filtered (nav entries, screens) pair for the
/// signed-in [user] — index-aligned 1:1 with `kNavEntries`
/// (`core/widgets/nav_rail.dart`) so the two can never drift out of sync.
///
/// An owner/manager sees every entry, matching the request that the farm
/// manager reviews and manages everything. An employee sees only the
/// general entries (no `departments` set — Tasks, Settings) plus the one
/// entry matching their own `department`; `managerOnly` entries (Morning
/// Briefing, Sales & Finance) never show for an employee, whatever their
/// department is.
({List<NavEntry> entries, List<Widget> screens}) buildNavForUser(UserProfile user) {
  final allScreens = <Widget>[
    const MorningBriefingScreen(),
    const AnimalStatusScreen(),
    const FeedInventoryScreen(),
    const MilkProductionScreen(),
    const EggProductionScreen(),
    const HealthIntelligenceScreen(),
    const ProduceHarvestScreen(),
    const MounehModuleScreen(),
    const VisitsModuleScreen(),
    const SalesFinanceScreen(),
    const TasksScreen(),
    const SettingsScreen(),
  ];
  assert(allScreens.length == kNavEntries.length, 'kNavEntries and the screens list must stay index-aligned');

  final entries = <NavEntry>[];
  final screens = <Widget>[];
  for (var i = 0; i < kNavEntries.length; i++) {
    final entry = kNavEntries[i];
    final visible = user.isManager || (!entry.managerOnly && (entry.departments == null || (user.department != null && entry.departments!.contains(user.department))));
    if (visible) {
      entries.add(entry);
      screens.add(allScreens[i]);
    }
  }
  return (entries: entries, screens: screens);
}
