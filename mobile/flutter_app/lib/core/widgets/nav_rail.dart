import 'package:flutter/material.dart';
import 'app_icon.dart';
import 'bekaa_backdrop.dart';
import '../i18n/strings.dart';
import '../theme/colors.dart';
import '../theme/spacing.dart';
import '../theme/typography.dart';

class NavEntry {
  const NavEntry(this.icon, this.labelKey);
  final FarmIcon icon;
  final String labelKey;
}

const List<NavEntry> kNavEntries = [
  NavEntry(FarmIcon.sun, 'navMorningBriefing'),
  NavEntry(FarmIcon.cow, 'navAnimals'),
  NavEntry(FarmIcon.feedBag, 'navFeedInventory'),
  NavEntry(FarmIcon.milkBottle, 'navMilk'),
  NavEntry(FarmIcon.egg, 'navEggs'),
  NavEntry(FarmIcon.stethoscope, 'navHealth'),
  NavEntry(FarmIcon.harvestBasket, 'navProduce'),
  NavEntry(FarmIcon.inventory, 'navMouneh'),
  NavEntry(FarmIcon.calendar, 'navVisits'),
  NavEntry(FarmIcon.money, 'navSales'),
  NavEntry(FarmIcon.task, 'navTasks'),
  NavEntry(FarmIcon.settings, 'navSettings'),
];

/// Left navigation rail (tech spec §7 / component-spec.md "SidebarNav").
class NavRail extends StatelessWidget {
  const NavRail({
    super.key,
    required this.selectedIndex,
    required this.onSelect,
    this.compact = false,
  });

  final int selectedIndex;
  final ValueChanged<int> onSelect;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: compact ? 84 : 232,
      color: FarmColors.stone,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(compact ? 0 : FarmSpacing.lg, FarmSpacing.lg, FarmSpacing.md, FarmSpacing.md),
            child: compact
                ? const Center(child: _BrandMark())
                : Row(
                    children: [
                      const _BrandMark(),
                      const SizedBox(width: 10),
                      Expanded(
                        child: RichText(
                          text: TextSpan(
                            style: FarmTypography.textTheme.titleMedium,
                            children: const [
                              TextSpan(text: 'Origami\n', style: TextStyle(color: FarmColors.cedar)),
                              TextSpan(text: 'FarmOS', style: TextStyle(color: FarmColors.olive)),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
          ),
          const SizedBox(height: 4),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              itemCount: kNavEntries.length,
              itemBuilder: (context, i) {
                final entry = kNavEntries[i];
                final selected = i == selectedIndex;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Material(
                    color: selected ? FarmColors.cedar : Colors.transparent,
                    borderRadius: BorderRadius.circular(FarmRadii.sm),
                    child: InkWell(
                      onTap: () => onSelect(i),
                      borderRadius: BorderRadius.circular(FarmRadii.sm),
                      child: Container(
                        constraints: const BoxConstraints(minHeight: kFarmTouchTarget),
                        padding: EdgeInsets.symmetric(horizontal: compact ? 0 : 14, vertical: 10),
                        alignment: compact ? Alignment.center : Alignment.centerLeft,
                        child: compact
                            ? AppIcon(entry.icon, size: 20, color: selected ? FarmColors.white : FarmColors.cedar)
                            : Row(
                                children: [
                                  AppIcon(entry.icon, size: 19, color: selected ? FarmColors.white : FarmColors.cedar),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Text(
                                      context.t(entry.labelKey),
                                      style: FarmTypography.textTheme.titleSmall?.copyWith(
                                        color: selected ? FarmColors.white : FarmColors.ink,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          if (!compact)
            Padding(
              padding: const EdgeInsets.all(FarmSpacing.md),
              child: ClipRRect(
                borderRadius: FarmRadii.card,
                child: SizedBox(
                  height: 110,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      const BekaaBackdrop(),
                      Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [Colors.transparent, FarmColors.ink.withOpacity(0.55)],
                          ),
                        ),
                      ),
                      Positioned(
                        left: 12,
                        right: 12,
                        bottom: 10,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              context.t('builtForLebaneseFarms'),
                              style: const TextStyle(
                                color: FarmColors.white,
                                fontWeight: FontWeight.w700,
                                fontSize: 12.5,
                              ),
                            ),
                            Text(
                              context.t('localInsightsLocalSupport'),
                              style: TextStyle(color: FarmColors.white.withOpacity(0.85), fontSize: 10.5),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _BrandMark extends StatelessWidget {
  const _BrandMark();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(9),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [FarmColors.cedar, FarmColors.olive, FarmColors.gold],
        ),
      ),
      child: const Icon(Icons.spa, color: FarmColors.white, size: 18),
    );
  }
}
