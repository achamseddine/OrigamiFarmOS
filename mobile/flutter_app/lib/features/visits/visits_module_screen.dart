import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/widgets/app_icon.dart';
import '../../core/widgets/hero_band.dart';
import '../../core/widgets/module_workspace.dart';
import '../../core/widgets/status_pill.dart';
import '../../providers/visits_provider.dart';
import 'activity_manager_tab.dart';
import 'booking_form_tab.dart';
import 'farm_shop_pos_tab.dart';
import 'opening_calendar_tab.dart';
import 'package_builder_tab.dart';
import 'staff_roster_costs_tab.dart';
import 'visit_day_briefing_tab.dart';
import 'visitor_checkin_tab.dart';
import 'visitor_profitability_tab.dart';
import 'visits_dashboard_tab.dart';

const List<String> kVisitsTabLabels = [
  'Dashboard',
  'Opening Calendar',
  'Package Builder',
  'Activity Manager',
  'Booking Form',
  'Visit-Day Briefing',
  'Visitor Check-in',
  'Farm Shop / POS',
  'Staff Roster & Costs',
  'Profitability Report',
];

/// Top-level "Farm Visits & Agri-Tourism" nav entry (tech spec v0.6 §6 "UI
/// Requirements" — 10 screens). Hosts them behind one internal tab row,
/// exactly like [MounehModuleScreen], and enforces the module license the
/// same way the backend does: an inactive license shows a locked state
/// instead of the sub-screens (RULE-VIS-001).
class VisitsModuleScreen extends StatefulWidget {
  const VisitsModuleScreen({super.key});

  @override
  State<VisitsModuleScreen> createState() => _VisitsModuleScreenState();
}

class _VisitsModuleScreenState extends State<VisitsModuleScreen> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<VisitsProvider>();

    final hero = HeroBand(
      eyebrow: context.t('ebVisits'),
      title: context.t('navVisits'),
      subtitle: context.t('navVisitsSub'),
      icon: FarmIcon.calendar,
      scenery: false,
      trailing: StatusPill(
        // Included, not bought: this used to say Active/Inactive,
        // when it was an add-on a farm turned on for itself.
        label: context.t(provider.isActive ? 'moduleIncluded' : 'moduleUnavailable'),
        level: provider.isActive ? FarmStatusLevel.good : FarmStatusLevel.alert,
      ),
    );

    if (!provider.isActive) {
      return SingleChildScrollView(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          hero,
          const SizedBox(height: FarmSpacing.xl),
          _LockedState(),
        ]),
      );
    }
    // The same one-page layout and tab bar as Feed, Health and Mouneh:
    // the band scrolls away, the tabs stay at the top, and a tab — the
    // profitability report included — is read at its full height.
    return ModuleWorkspace(
      header: [hero],
      labels: kVisitsTabLabels,
      selected: _tab,
      onSelect: (i) => setState(() => _tab = i),
      tabBuilder: (context, i) => switch (i) {
        0 => VisitsDashboardTab(onNavigate: (i) => setState(() => _tab = i)),
        1 => const OpeningCalendarTab(),
        2 => const PackageBuilderTab(),
        3 => const ActivityManagerTab(),
        4 => const BookingFormTab(),
        5 => const VisitDayBriefingTab(),
        6 => const VisitorCheckinTab(),
        7 => const FarmShopPosTab(),
        8 => const StaffRosterCostsTab(),
        _ => const VisitorProfitabilityTab(),
      },
    );
  }
}

class _LockedState extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: const BoxDecoration(color: FarmColors.mist, shape: BoxShape.circle),
            child: const Center(child: AppIcon(FarmIcon.calendar, size: 28, color: FarmColors.muted)),
          ),
          const SizedBox(height: FarmSpacing.md),
          Text('Farm Visits is not loading right now', style: FarmTypography.textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(
            'It is included in your subscription, so this is a connection or a server '
            'problem rather than something you need to buy. Try again once the tablet '
            'is back on the farm network.',
            style: FarmTypography.textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
