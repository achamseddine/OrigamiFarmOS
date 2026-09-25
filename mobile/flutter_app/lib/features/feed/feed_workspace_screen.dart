import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/farm_icon_map.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/widgets/app_icon.dart';
import '../../core/widgets/hero_band.dart';
import '../../core/widgets/status_pill.dart';
import '../../domain/entities/access.dart';
import '../../providers/access_provider.dart';
import '../../providers/feeding_provider.dart';
import 'feed_inventory_screen.dart';
import 'feed_movement_dialog.dart';
import 'tabs/costs_tab.dart';
import 'tabs/daily_feeding_tab.dart';
import 'tabs/feeds_and_lots_tab.dart';
import 'tabs/formulas_tab.dart';
import 'tabs/mixing_tab.dart';
import 'tabs/nutrition_tab.dart';
import 'tabs/programs_tab.dart';
import 'tabs/traceability_tab.dart';

/// The Feed workspace (generic feed architecture §17): the tabs the spec
/// names, over one provider. The first tab is the stock screen the app
/// already had; the rest are the architecture — feeds and lots, formulas,
/// mixing, programs, today's feeding, nutrition, costs and traceability.
class FeedWorkspaceScreen extends StatefulWidget {
  const FeedWorkspaceScreen({super.key});

  @override
  State<FeedWorkspaceScreen> createState() => _FeedWorkspaceScreenState();
}

class _FeedWorkspaceScreenState extends State<FeedWorkspaceScreen> {
  int _tab = 0;

  static const _tabs = [
    'feedTabInventory', 'feedTabFeeds', 'feedTabFormulas', 'feedTabMixing', 'feedTabPrograms',
    'feedTabDaily', 'feedTabNutrition', 'feedTabCosts', 'feedTabTrace',
  ];

  @override
  Widget build(BuildContext context) {
    final access = context.watch<AccessProvider>();
    final feeding = context.watch<FeedingProvider>();
    final canRecord = access.canCreate(FarmModule.feedNutrition) || access.canCreate(FarmModule.inventory);
    final atRisk = feeding.reorder.where((r) => r.coveredByTaskId == null).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        HeroBand(
          title: context.t('feedInventoryTitle'),
          subtitle: context.t('feedWorkspaceSubtitle'),
          icon: FarmIcon.feedBag,
          trailing: atRisk == 0
              ? null
              : StatusPill(label: '$atRisk ${context.t('stockoutRisk')}', level: FarmStatusLevel.alert),
          actions: [
            if (canRecord)
              HeroAction(
                primary: true,
                icon: FarmIconMap.add,
                label: context.t('addFeed'),
                onPressed: () => showFeedMovementDialog(context, direction: FeedMovementDirection.inbound),
              ),
            if (canRecord)
              HeroAction(
                icon: FarmIcon.feedBag,
                label: context.t('feedTabDaily'),
                onPressed: () => setState(() => _tab = 5),
              ),
          ],
        ),
        const SizedBox(height: FarmSpacing.md),
        _TabStrip(labels: [for (final k in _tabs) context.t(k)], selected: _tab, onSelect: (i) => setState(() => _tab = i)),
        const SizedBox(height: FarmSpacing.md),
        Expanded(
          child: IndexedStack(
            index: _tab,
            children: const [
              FeedInventoryScreen(embedded: true),
              FeedsAndLotsTab(),
              FormulasTab(),
              MixingTab(),
              ProgramsTab(),
              DailyFeedingTab(),
              NutritionTab(),
              CostsTab(),
              TraceabilityTab(),
            ],
          ),
        ),
      ],
    );
  }
}

class _TabStrip extends StatelessWidget {
  const _TabStrip({required this.labels, required this.selected, required this.onSelect});
  final List<String> labels;
  final int selected;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (var i = 0; i < labels.length; i++)
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 8),
              child: Material(
                color: i == selected ? FarmColors.cedar : FarmColors.sand,
                borderRadius: BorderRadius.circular(FarmRadii.pill),
                child: InkWell(
                  onTap: () => onSelect(i),
                  borderRadius: BorderRadius.circular(FarmRadii.pill),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    child: Text(
                      labels[i],
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

/// Small shared pieces for the tabs.
class FeedTabScaffold extends StatelessWidget {
  const FeedTabScaffold({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < children.length; i++) ...[
            children[i],
            if (i != children.length - 1) const SizedBox(height: FarmSpacing.md),
          ],
        ],
      ),
    );
  }
}

class FeedEmpty extends StatelessWidget {
  const FeedEmpty(this.textKey, {super.key});
  final String textKey;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Text(context.t(textKey), style: FarmTypography.textTheme.bodySmall),
      );
}

class FeedKeyValue extends StatelessWidget {
  const FeedKeyValue(this.label, this.value, {super.key, this.valueColor, this.bold = false});
  final String label;
  final String value;
  final Color? valueColor;
  final bool bold;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: Text(label, style: FarmTypography.textTheme.bodySmall)),
            Flexible(
              child: Text(
                value,
                textAlign: TextAlign.end,
                style: (bold ? FarmTypography.textTheme.titleSmall : FarmTypography.textTheme.bodyMedium)?.copyWith(color: valueColor),
              ),
            ),
          ],
        ),
      );
}

/// The status colour for a lot / batch / reconciliation state.
FarmStatusLevel feedStatusLevel(String status) => switch (status) {
      'active' || 'completed' || 'closed' || 'ok' => FarmStatusLevel.good,
      'in_progress' || 'planned' || 'open' || 'reorder' || 'draft' || 'depleted' => FarmStatusLevel.watch,
      'quarantined' || 'blocked' || 'recalled' || 'expired' || 'stockout_risk' || 'below_minimum' || 'cancelled' => FarmStatusLevel.alert,
      _ => FarmStatusLevel.neutral,
    };

String feedNumber(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

String feedMoney(double v) => '\$${v.toStringAsFixed(v >= 100 ? 0 : 2)}';

String feedDate(DateTime d) {
  final l = d.toLocal();
  return '${l.day}/${l.month}/${l.year}';
}
