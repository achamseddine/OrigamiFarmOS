import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/farm_icon_map.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/widgets/app_icon.dart';
import '../../core/widgets/hero_band.dart';
import '../../core/widgets/kpi_card.dart';
import '../../core/widgets/status_pill.dart';
import '../../core/widgets/ux_blocks.dart';
import '../../domain/entities/access.dart';
import '../../domain/entities/feeding.dart';
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
import 'tabs/performance_tab.dart';
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

/// The workspace's tabs, in the V3 prototype's order: making feed first,
/// then what it is made from and where it is kept, then what the animals
/// are given and what that costs and achieves.
enum FeedWorkspaceTab { mixing, materials, stock, formulas, intake, programs, nutrition, costs, trace, performance }

class _FeedWorkspaceScreenState extends State<FeedWorkspaceScreen> {
  FeedWorkspaceTab _tab = FeedWorkspaceTab.mixing;

  static const _labels = {
    FeedWorkspaceTab.mixing: 'fwTabMixing',
    FeedWorkspaceTab.materials: 'fwTabMaterials',
    FeedWorkspaceTab.stock: 'fwTabStock',
    FeedWorkspaceTab.formulas: 'feedTabFormulas',
    FeedWorkspaceTab.intake: 'fwTabIntake',
    FeedWorkspaceTab.programs: 'feedTabPrograms',
    FeedWorkspaceTab.nutrition: 'feedTabNutrition',
    FeedWorkspaceTab.costs: 'feedTabCosts',
    FeedWorkspaceTab.trace: 'feedTabTrace',
    FeedWorkspaceTab.performance: 'feedTabPerformance',
  };

  @override
  Widget build(BuildContext context) {
    final access = context.watch<AccessProvider>();
    final feeding = context.watch<FeedingProvider>();
    final canStock = access.canCreate(FarmModule.feedNutrition) || access.canCreate(FarmModule.inventory);
    final canFeed = access.canCreate(FarmModule.feedNutrition);
    final canMix = canFeed && feeding.formulas.any((f) => f.active != null);
    final atRisk = feeding.reorder.where((r) => r.coveredByTaskId == null).length;
    final tabs = FeedWorkspaceTab.values;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        HeroBand(
          eyebrow: context.t('fwEyebrow'),
          title: context.t('feedInventoryTitle'),
          subtitle: context.t('feedWorkspaceSubtitle'),
          icon: FarmIcon.feedBag,
          trailing: atRisk == 0
              ? null
              : StatusPill(label: '$atRisk ${context.t('stockoutRisk')}', level: FarmStatusLevel.alert),
          actions: [
            if (canMix)
              HeroAction(primary: true, icon: FarmIconMap.add, label: context.t('fwMakeMix'), onPressed: () => showStartMixDialog(context)),
            if (canFeed)
              HeroAction(icon: FarmIcon.feedBag, label: context.t('fwRecordFeeding'), onPressed: () => setState(() => _tab = FeedWorkspaceTab.intake)),
            if (canStock)
              HeroAction(
                icon: FarmIcon.inventory,
                label: context.t('addFeed'),
                onPressed: () => showFeedMovementDialog(context, direction: FeedMovementDirection.inbound),
              ),
          ],
        ),
        const SizedBox(height: FarmSpacing.md),
        FeedKpiRow(feeding: feeding),
        const SizedBox(height: FarmSpacing.sm),
        UnderlineTabs(
          labels: [for (final t in tabs) context.t(_labels[t]!)],
          selected: tabs.indexOf(_tab),
          onSelect: (i) => setState(() => _tab = tabs[i]),
        ),
        const SizedBox(height: FarmSpacing.md),
        Expanded(
          child: IndexedStack(
            index: tabs.indexOf(_tab),
            children: const [
              MixingTab(),
              FeedsAndLotsTab(),
              FeedInventoryScreen(embedded: true),
              FormulasTab(),
              DailyFeedingTab(),
              ProgramsTab(),
              NutritionTab(),
              CostsTab(),
              TraceabilityTab(),
              PerformanceTab(),
            ],
          ),
        ),
      ],
    );
  }
}

/// The four figures the prototype opens the feed page on, each from the
/// server's own records: numbered mixes, finished mix on hand (the stock
/// ledger's balance of mix output lots, never a typed-in number), the
/// feedings recorded this week and what feeding cost this month.
class FeedKpiRow extends StatelessWidget {
  const FeedKpiRow({super.key, required this.feeding});
  final FeedingProvider feeding;

  @override
  Widget build(BuildContext context) {
    final numbered = [for (final b in feeding.batches) if (!b.numberPending) b]..sort((a, b) => b.mixNumber.compareTo(a.mixNumber));
    final mixLots = [for (final l in feeding.lots) if (l.feedBatchId != null && l.quantityOnHand > 0) l];
    final onHand = finishedMixOnHand(feeding.lots);
    final fed = [for (final e in feeding.recentEvents) if (e.status == 'recorded') e];
    final subjects = {for (final e in fed) e.subjectId}.length;
    return EqualGrid(
      minTileWidth: 200,
      children: [
        KpiCard(
          icon: FarmIcon.feedBag,
          label: context.t('fwKpiMixes'),
          value: '${numbered.length}',
          caption: numbered.isEmpty ? context.t('fwKpiMixesNone') : '${context.t('fwLatest')} ${numbered.first.label}',
        ),
        KpiCard(
          icon: FarmIcon.inventory,
          label: context.t('fwKpiFinished'),
          value: onHand.isEmpty ? '0' : onHand.entries.map((e) => feedNumber(e.value)).join(' + '),
          unit: onHand.isEmpty ? null : onHand.keys.join(' + '),
          caption: '${mixLots.length} ${context.t('fwKpiFinishedCap')}',
        ),
        KpiCard(icon: FarmIcon.check, label: context.t('fwKpiFeedings'), value: '${fed.length}', caption: '$subjects ${context.t('fwKpiFeedingsCap')}'),
        KpiCard(
          icon: FarmIcon.money,
          label: context.t('fwKpiCost'),
          value: feedMoney(feeding.costs.totalFeedingCost),
          caption: context.t('fwKpiCostCap'),
        ),
      ],
    );
  }
}

/// Finished mix on hand, per unit: the balance of every active output lot
/// a numbered mix produced. Units are never added across — 40 kg and 3
/// bags stay two figures.
Map<String, double> finishedMixOnHand(List<FeedLot> lots) {
  final out = <String, double>{};
  for (final l in lots) {
    if (l.feedBatchId == null || l.quantityOnHand <= 0 || l.status != 'active') continue;
    out[l.unit] = (out[l.unit] ?? 0) + l.quantityOnHand;
  }
  return out;
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
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: EmptyState(message: context.t(textKey), icon: FarmIcon.feedBag, compact: true),
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
