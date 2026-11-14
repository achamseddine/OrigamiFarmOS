import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/farm_icon_map.dart';
import '../../core/theme/spacing.dart';
import '../../core/widgets/app_icon.dart';
import '../../core/widgets/hero_band.dart';
import '../../core/widgets/kpi_card.dart';
import '../../core/widgets/status_pill.dart';
import '../../core/widgets/ux_blocks.dart';
import '../../providers/mouneh_provider.dart';
import 'cost_preview_tab.dart';
import 'finished_goods_tab.dart';
import 'mouneh_dashboard_tab.dart';
import 'product_builder_tab.dart';
import 'production_batch_tab.dart';
import 'recipe_setup_tab.dart';
import 'sales_profitability_tab.dart';

/// The module's screens (tech spec v0.5 §6), in the order the work goes:
/// what is sold and made, then what it is made from and costs, then the
/// making, the store and the selling.
enum MounehTab { dashboard, products, recipes, costPreview, batches, finishedGoods, sales }

const _tabKeys = {
  MounehTab.dashboard: 'mnTabDashboard',
  MounehTab.products: 'mnTabProducts',
  MounehTab.recipes: 'mnTabRecipes',
  MounehTab.costPreview: 'mnTabCost',
  MounehTab.batches: 'mnTabBatches',
  MounehTab.finishedGoods: 'mnTabStock',
  MounehTab.sales: 'mnTabSales',
};

/// Top-level "Mouneh & Farm Products" entry, laid out the way the V3
/// prototype lays out a module: an eyebrow header with the module's main
/// actions, four figures that hold across every tab, underlined tabs.
/// The module is part of every subscription; when its data cannot be
/// loaded the screen says so instead of showing empty tabs.
class MounehModuleScreen extends StatefulWidget {
  const MounehModuleScreen({super.key});

  @override
  State<MounehModuleScreen> createState() => _MounehModuleScreenState();
}

class _MounehModuleScreenState extends State<MounehModuleScreen> {
  MounehTab _tab = MounehTab.dashboard;

  void _go(MounehTab tab) => setState(() => _tab = tab);

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<MounehProvider>();
    final tabs = MounehTab.values;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        HeroBand(
          eyebrow: context.t('ebMouneh'),
          title: context.t('navMouneh'),
          subtitle: context.t('mnSubtitle'),
          icon: FarmIcon.package,
          scenery: false,
          trailing: StatusPill(
            // Included, not bought: this used to say Active/Inactive,
            // when it was an add-on a farm turned on for itself.
            label: context.t(provider.isActive ? 'moduleIncluded' : 'moduleUnavailable'),
            level: provider.isActive ? FarmStatusLevel.good : FarmStatusLevel.alert,
          ),
          actions: provider.isActive
              ? [
                  HeroAction(primary: true, icon: FarmIconMap.add, label: context.t('mnStartBatch'), onPressed: () => showStartMounehBatchDialog(context)),
                  HeroAction(icon: FarmIcon.money, label: context.t('mnRecordSale'), onPressed: () => _go(MounehTab.sales)),
                  HeroAction(icon: FarmIcon.package, label: context.t('mnNewProduct'), onPressed: () => _go(MounehTab.products)),
                ]
              : const [],
        ),
        const SizedBox(height: FarmSpacing.md),
        if (!provider.isActive)
          const Expanded(child: _LockedState())
        else ...[
          const MounehKpiRow(),
          const SizedBox(height: FarmSpacing.sm),
          UnderlineTabs(
            labels: [for (final t in tabs) context.t(_tabKeys[t]!)],
            selected: tabs.indexOf(_tab),
            onSelect: (i) => _go(tabs[i]),
          ),
          const SizedBox(height: FarmSpacing.md),
          Expanded(
            child: IndexedStack(
              index: tabs.indexOf(_tab),
              children: [
                MounehDashboardTab(onNavigate: (i) => _go(tabs[i])),
                const ProductBuilderTab(),
                const RecipeSetupTab(),
                const CostPreviewTab(),
                const ProductionBatchTab(),
                const FinishedGoodsTab(),
                const SalesProfitabilityTab(),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// Products, batches in the making, what is in the store and what the
/// sales recorded so far made — each saying what it counts.
class MounehKpiRow extends StatelessWidget {
  const MounehKpiRow({super.key});

  @override
  Widget build(BuildContext context) {
    final p = context.watch<MounehProvider>();
    return EqualGrid(minTileWidth: 200, children: [
      KpiCard(icon: FarmIcon.package, label: context.t('mnKpiProducts'), value: '${p.products.length}', caption: '${p.rawMaterials.length} ${context.t('mnKpiMaterials')}'),
      KpiCard(icon: FarmIcon.barn, label: context.t('mnKpiBatches'), value: '${p.activeBatchCount}', caption: '${p.batches.where((b) => b.isCompleted).length} ${context.t('mnKpiCompleted')}'),
      KpiCard(
        icon: FarmIcon.inventory,
        label: context.t('mnKpiStock'),
        value: p.totalFinishedUnits.toStringAsFixed(0),
        caption: '${context.t('mnKpiValuedAt')} \$${p.totalStockValue.toStringAsFixed(0)}',
      ),
      KpiCard(
        icon: FarmIcon.money,
        label: context.t('mnKpiProfit'),
        value: '\$${p.totalProfit.toStringAsFixed(0)}',
        caption: '${context.t('mnKpiRevenue')} \$${p.totalRevenue.toStringAsFixed(0)}',
        tint: p.totalProfit < 0 ? FarmColors.danger : null,
      ),
    ]);
  }
}

class _LockedState extends StatelessWidget {
  const _LockedState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(FarmSpacing.lg),
        child: EmptyState(icon: FarmIcon.inventory, message: context.t('mnLockedTitle'), detail: context.t('mnLockedBody')),
      ),
    );
  }
}
