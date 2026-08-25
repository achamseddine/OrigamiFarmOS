import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/widgets/app_icon.dart';
import '../../core/widgets/status_pill.dart';
import '../../providers/mouneh_provider.dart';
import 'cost_preview_tab.dart';
import 'finished_goods_tab.dart';
import 'mouneh_dashboard_tab.dart';
import 'product_builder_tab.dart';
import 'production_batch_tab.dart';
import 'recipe_setup_tab.dart';
import 'sales_profitability_tab.dart';

const List<String> kMounehTabLabels = [
  'Dashboard',
  'Product Builder',
  'Recipes & Materials',
  'Cost Preview',
  'Production Batches',
  'Finished Goods',
  'Sales & Profitability',
];

/// Top-level "Mouneh & Farm Products" nav entry. Hosts the module's 7
/// screens (tech spec v0.5 §6 "UI Requirements") behind one internal tab
/// row rather than 7 separate rail entries, and enforces the module
/// license the same way the backend does: an inactive license shows a
/// locked state instead of the sub-screens.
class MounehModuleScreen extends StatefulWidget {
  const MounehModuleScreen({super.key});

  @override
  State<MounehModuleScreen> createState() => _MounehModuleScreenState();
}

class _MounehModuleScreenState extends State<MounehModuleScreen> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<MounehProvider>();

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
                  Text('Mouneh & Farm Products', style: FarmTypography.display(size: 28)),
                  const SizedBox(height: 2),
                  Text('Turn raw harvest into priced, sellable jars — costed automatically, batch by batch.', style: FarmTypography.textTheme.bodyMedium),
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
                MounehDashboardTab(onNavigate: (i) => setState(() => _tab = i)),
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
          for (var i = 0; i < kMounehTabLabels.length; i++)
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
                      kMounehTabLabels[i],
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
            child: const Center(child: AppIcon(FarmIcon.inventory, size: 28, color: FarmColors.muted)),
          ),
          const SizedBox(height: FarmSpacing.md),
          Text('The Mouneh module is not active for this farm', style: FarmTypography.textTheme.titleMedium),
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
