import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/widgets/app_icon.dart';
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Farm Visits & Agri-Tourism', style: FarmTypography.display(size: 28)),
                  const SizedBox(height: 2),
                  Text('Open the farm on your own schedule — bookings, activities and visitor sales, costed automatically.', style: FarmTypography.textTheme.bodyMedium),
                ],
              ),
            ),
            StatusPill(
              label: provider.isActive ? 'Module Active' : 'Module Inactive',
              level: provider.isActive ? FarmStatusLevel.good : FarmStatusLevel.alert,
            ),
          ],
        ),
        const SizedBox(height: FarmSpacing.md),
        if (!provider.isActive)
          Expanded(child: _LockedState())
        else ...[
          _TabBar(selected: _tab, onSelect: (i) => setState(() => _tab = i)),
          const SizedBox(height: FarmSpacing.md),
          Expanded(
            child: IndexedStack(
              index: _tab,
              children: [
                VisitsDashboardTab(onNavigate: (i) => setState(() => _tab = i)),
                const OpeningCalendarTab(),
                const PackageBuilderTab(),
                const ActivityManagerTab(),
                const BookingFormTab(),
                const VisitDayBriefingTab(),
                const VisitorCheckinTab(),
                const FarmShopPosTab(),
                const StaffRosterCostsTab(),
                const VisitorProfitabilityTab(),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _TabBar extends StatelessWidget {
  const _TabBar({required this.selected, required this.onSelect});
  final int selected;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (var i = 0; i < kVisitsTabLabels.length; i++)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Material(
                color: i == selected ? FarmColors.cedar : FarmColors.card,
                borderRadius: BorderRadius.circular(FarmRadii.pill),
                child: InkWell(
                  onTap: () => onSelect(i),
                  borderRadius: BorderRadius.circular(FarmRadii.pill),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(FarmRadii.pill),
                      border: Border.all(color: i == selected ? FarmColors.cedar : FarmColors.border),
                    ),
                    child: Text(
                      kVisitsTabLabels[i],
                      style: FarmTypography.textTheme.labelMedium?.copyWith(color: i == selected ? FarmColors.white : FarmColors.ink),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
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
          Text('The Farm Visits module is not active for this farm', style: FarmTypography.textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(
            'A super user can activate it from Settings → Modules.',
            style: FarmTypography.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
