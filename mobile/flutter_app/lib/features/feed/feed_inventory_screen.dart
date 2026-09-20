import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/farm_icon_map.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/widgets/app_icon.dart';
import '../../core/widgets/data_table_card.dart';
import '../../core/widgets/hero_band.dart';
import '../../core/widgets/kpi_card.dart';
import '../../core/widgets/section_card.dart';
import '../../core/widgets/status_pill.dart';
import '../../domain/entities/access.dart';
import '../../domain/entities/inventory.dart';
import '../../providers/access_provider.dart';
import '../../providers/feed_provider.dart';
import 'feed_movement_dialog.dart';

/// Feed & Inventory, laid out as the v1 pack's screen build map has it:
/// the valley band with the screen's two buttons on it, the three
/// figures, a search box and category chips over the stock table, each
/// row with its own menu, and the recent movements beside the reorder
/// list — so "what came in this week" is answered on the same screen as
/// "what is running out".
class FeedInventoryScreen extends StatefulWidget {
  const FeedInventoryScreen({super.key});

  @override
  State<FeedInventoryScreen> createState() => _FeedInventoryScreenState();
}

class _FeedInventoryScreenState extends State<FeedInventoryScreen> {
  String _query = '';
  String? _category;
  final _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    // The stock list is loaded for everyone at sign-in; the movement
    // history is only wanted here, so it is fetched when the screen opens.
    Future.microtask(() {
      if (mounted) context.read<FeedProvider>().loadTransactions();
    });
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final feed = context.watch<FeedProvider>();
    final access = context.watch<AccessProvider>();
    final items = feed.items;
    final canRecord = access.canCreate(FarmModule.feedNutrition) || access.canCreate(FarmModule.inventory);
    final canExport = access.can(FarmModule.feedNutrition, PermissionAction.export);

    final totalStockMT = items.fold<double>(0, (sum, i) => sum + (i.unit == 'kg' ? i.currentQty : 0)) / 1000;
    final lowStock = items.where((i) => i.status != StockStatus.good).toList();
    final monthlyCost = items.fold<double>(0, (sum, i) => sum + (i.unitCost ?? 0) * i.currentQty * 0.3);

    final categories = <String>{for (final i in items) i.category}.toList()..sort();
    final query = _query.trim().toLowerCase();
    final visible = items.where((i) {
      final categoryOk = _category == null || i.category == _category;
      final queryOk = query.isEmpty || i.name.toLowerCase().contains(query) || i.supplier.toLowerCase().contains(query);
      return categoryOk && queryOk;
    }).toList();

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          HeroBand(
            title: context.t('feedInventoryTitle'),
            subtitle: context.t('feedInventorySubtitle'),
            icon: FarmIcon.feedBag,
            actions: [
              if (canRecord)
                HeroAction(
                  primary: true,
                  icon: FarmIconMap.add,
                  label: context.t('addFeed'),
                  onPressed: () => showFeedMovementDialog(context, direction: FeedMovementDirection.inbound),
                ),
              if (canExport)
                HeroAction(
                  icon: FarmIconMap.download,
                  label: context.t('exportReport'),
                  // There is no report endpoint yet. Saying so beats a
                  // button that does nothing.
                  onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(context.t('reportsNotYet'))),
                  ),
                ),
            ],
          ),
          const SizedBox(height: FarmSpacing.md),
          LayoutBuilder(builder: (context, c) {
            final perRow = c.maxWidth > 700 ? 3 : 2;
            final w = (c.maxWidth - FarmSpacing.md * (perRow - 1)) / perRow;
            final cards = [
              KpiCard(icon: FarmIcon.inventory, label: context.t('totalFeedStock'), value: totalStockMT.toStringAsFixed(1), unit: 'MT', accent: FarmColors.cedar2),
              KpiCard(
                icon: FarmIcon.warning,
                label: context.t('lowStockItems'),
                value: '${lowStock.length}',
                caption: context.t('viewAndReorder'),
                tint: lowStock.isEmpty ? null : FarmColors.warning,
                accent: lowStock.isEmpty ? FarmColors.olive : null,
              ),
              KpiCard(icon: FarmIcon.coins, label: context.t('monthlyFeedCost'), value: '\$${monthlyCost.toStringAsFixed(0)}', accent: FarmColors.gold),
            ];
            return Wrap(spacing: FarmSpacing.md, runSpacing: FarmSpacing.md, children: [for (final c2 in cards) SizedBox(width: w, child: c2)]);
          }),
          const SizedBox(height: FarmSpacing.md),
          _SearchRow(
            controller: _search,
            categories: categories,
            selected: _category,
            onQuery: (v) => setState(() => _query = v),
            onCategory: (v) => setState(() => _category = v),
          ),
          const SizedBox(height: FarmSpacing.md),
          LayoutBuilder(builder: (context, c) {
            final wide = c.maxWidth > kTabletBreakpoint;
            final table = SectionCard(
              title: context.t('allFeed'),
              child: items.isEmpty
                  ? Text(context.t('noInventoryYet'), style: FarmTypography.textTheme.bodySmall)
                  : visible.isEmpty
                      ? Text(context.t('noMatches'), style: FarmTypography.textTheme.bodySmall)
                      : FarmDataTable(
                          columns: [
                            context.t('feedItem'),
                            context.t('quantity'),
                            context.t('reorderLevel'),
                            context.t('supplier'),
                            context.t('status'),
                            if (canRecord) '',
                          ],
                          columnFlex: [3, 2, 2, 2, 2, if (canRecord) 1],
                          rows: [
                            for (final item in visible)
                              [
                                Row(children: [
                                  AppIcon(FarmIconMap.feedCategory(item.category), size: 16, color: FarmColors.cedar),
                                  const SizedBox(width: 8),
                                  Flexible(child: Text(item.name, style: FarmTypography.textTheme.titleSmall, overflow: TextOverflow.ellipsis)),
                                ]),
                                Text('${item.currentQty.toStringAsFixed(0)} ${item.unit}'),
                                Text('${item.reorderLevel.toStringAsFixed(0)} ${item.unit}'),
                                Text(item.supplier, style: FarmTypography.textTheme.bodySmall, overflow: TextOverflow.ellipsis),
                                StatusPill(
                                  label: item.status == StockStatus.good ? context.t('statusGood') : context.t('statusLow'),
                                  level: switch (item.status) {
                                    StockStatus.good => FarmStatusLevel.good,
                                    StockStatus.low => FarmStatusLevel.watch,
                                    StockStatus.critical => FarmStatusLevel.alert,
                                  },
                                  dense: true,
                                ),
                                if (canRecord) _RowMenu(item: item),
                              ],
                          ],
                        ),
            );
            final reorder = SectionCard(
              title: context.t('reorderRecommendations'),
              child: Column(
                children: [
                  for (final item in lowStock) ...[
                    _ReorderCard(item: item, canRecord: canRecord),
                    const SizedBox(height: 10),
                  ],
                  if (lowStock.isEmpty)
                    Text(
                      items.isEmpty ? context.t('noInventoryYet') : context.t('aboveReorderLevel'),
                      style: FarmTypography.textTheme.bodySmall,
                    ),
                ],
              ),
            );
            final movements = _RecentMovements(transactions: feed.transactions.take(8).toList(), feed: feed);
            final side = Column(children: [reorder, const SizedBox(height: FarmSpacing.md), movements]);
            if (!wide) return Column(children: [table, const SizedBox(height: FarmSpacing.md), side]);
            return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(flex: 6, child: table),
              const SizedBox(width: FarmSpacing.md),
              Expanded(flex: 4, child: side),
            ]);
          }),
        ],
      ),
    );
  }
}

/// A search box and a row of category chips, built from whatever
/// categories the farm's own stock actually has.
class _SearchRow extends StatelessWidget {
  const _SearchRow({
    required this.controller,
    required this.categories,
    required this.selected,
    required this.onQuery,
    required this.onCategory,
  });

  final TextEditingController controller;
  final List<String> categories;
  final String? selected;
  final ValueChanged<String> onQuery;
  final ValueChanged<String?> onCategory;

  @override
  Widget build(BuildContext context) {
    final chips = [
      _Chip(label: context.t('allCategories'), selected: selected == null, onTap: () => onCategory(null)),
      for (final c in categories) _Chip(label: c, selected: selected == c, onTap: () => onCategory(c)),
    ];
    return LayoutBuilder(builder: (context, c) {
      final wide = c.maxWidth > 700;
      final search = SizedBox(
        width: wide ? 320 : double.infinity,
        child: TextField(
          controller: controller,
          onChanged: onQuery,
          decoration: InputDecoration(
            hintText: context.t('searchFeed'),
            prefixIcon: const Padding(
              padding: EdgeInsetsDirectional.only(start: 14, end: 8),
              child: AppIcon(FarmIcon.search, size: 18, color: FarmColors.muted),
            ),
            prefixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
            isDense: true,
          ),
        ),
      );
      final strip = SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [for (final chip in chips) ...[chip, const SizedBox(width: 8)]]),
      );
      if (!wide) return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [search, const SizedBox(height: 10), strip]);
      return Row(children: [search, const SizedBox(width: FarmSpacing.md), Expanded(child: strip)]);
    });
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? FarmColors.cedar : FarmColors.sand,
      borderRadius: BorderRadius.circular(FarmRadii.pill),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(FarmRadii.pill),
        child: Container(
          constraints: const BoxConstraints(minHeight: 40),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(color: selected ? FarmColors.white : FarmColors.ink, fontWeight: FontWeight.w600, fontSize: 13),
          ),
        ),
      ),
    );
  }
}

/// The two things that can happen to a row: more of it arrived, or some
/// of it was used. Both open the same dialog with this item chosen.
class _RowMenu extends StatelessWidget {
  const _RowMenu({required this.item});
  final InventoryItem item;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<FeedMovementDirection>(
      tooltip: item.name,
      icon: const Icon(Icons.more_vert, color: FarmColors.muted),
      onSelected: (direction) => showFeedMovementDialog(context, direction: direction, itemId: item.id),
      itemBuilder: (context) => [
        PopupMenuItem(
          value: FeedMovementDirection.inbound,
          child: Row(children: [
            const AppIcon(FarmIcon.plus, size: 16, color: FarmColors.cedar),
            const SizedBox(width: 10),
            Text(context.t('recordPurchase')),
          ]),
        ),
        PopupMenuItem(
          value: FeedMovementDirection.outbound,
          child: Row(children: [
            const AppIcon(FarmIcon.feedBag, size: 16, color: FarmColors.cedar),
            const SizedBox(width: 10),
            Text(context.t('recordDistribution')),
          ]),
        ),
      ],
    );
  }
}

class _ReorderCard extends StatelessWidget {
  const _ReorderCard({required this.item, required this.canRecord});
  final InventoryItem item;
  final bool canRecord;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: FarmColors.tint(FarmColors.warning, 0.1),
        borderRadius: BorderRadius.circular(FarmRadii.sm),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.name, style: FarmTypography.textTheme.titleSmall),
                Text('${context.t('current')}: ${item.currentQty.toStringAsFixed(0)} ${item.unit}', style: FarmTypography.textTheme.bodySmall),
                Text(
                  '${context.t('shortBy')} ${item.shortfall.toStringAsFixed(0)} ${item.unit}',
                  style: const TextStyle(fontSize: 11.5, color: FarmColors.danger, fontWeight: FontWeight.w700),
                ),
              ],
            ),
          ),
          if (canRecord)
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(0, 40), padding: const EdgeInsets.symmetric(horizontal: 14)),
              onPressed: () async {
                final result = await context.read<FeedProvider>().recordPurchase(itemId: item.id, quantityKg: item.shortfall + item.reorderLevel * 0.2);
                if (!context.mounted) return;
                // A failed reorder must never report "Saved." — the fallback
                // has to be a failure message, not the success one.
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(result.success ? context.t('saved') : (result.error ?? context.t('couldNotSave')))),
                );
              },
              child: Text(context.t('reorderNow')),
            ),
        ],
      ),
    );
  }
}

/// What moved in and out lately, newest first. Each line reads as a
/// sentence a worker would say: "200 kg barley — added, bought, today
/// 08:40".
class _RecentMovements extends StatelessWidget {
  const _RecentMovements({required this.transactions, required this.feed});
  final List<InventoryTransaction> transactions;
  final FeedProvider feed;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: context.t('recentMovements'),
      child: transactions.isEmpty
          ? Text(context.t('noMovementsYet'), style: FarmTypography.textTheme.bodySmall)
          : Column(
              children: [
                for (var i = 0; i < transactions.length; i++) ...[
                  _MovementRow(movement: transactions[i], item: feed.itemById(transactions[i].itemId)),
                  if (i != transactions.length - 1) const Divider(height: 16, color: FarmColors.border),
                ],
              ],
            ),
    );
  }
}

class _MovementRow extends StatelessWidget {
  const _MovementRow({required this.movement, required this.item});
  final InventoryTransaction movement;
  final InventoryItem? item;

  @override
  Widget build(BuildContext context) {
    final inbound = movement.direction == 'in';
    final color = inbound ? FarmColors.success : FarmColors.cedar2;
    final unit = item?.unit ?? '';
    final reason = switch (movement.reason) {
      'purchase' => context.t('reasonPurchase'),
      'feeding' => context.t('reasonFeeding'),
      'waste' => context.t('reasonWaste'),
      'transfer' => context.t('reasonTransfer'),
      _ => movement.reason,
    };
    return Row(
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(color: FarmColors.tint(color, 0.16), shape: BoxShape.circle),
          child: Center(child: AppIcon(inbound ? FarmIcon.plus : FarmIcon.feedBag, size: 16, color: color)),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${movement.quantity.toStringAsFixed(0)} $unit ${item?.name ?? ''}'.trim(),
                style: FarmTypography.textTheme.titleSmall,
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                [context.t(inbound ? 'movementIn' : 'movementOut'), if (reason.isNotEmpty) reason].join(' · '),
                style: FarmTypography.textTheme.bodySmall,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Text(_when(context, movement.createdAt), style: const TextStyle(fontSize: 11, color: FarmColors.muted)),
      ],
    );
  }

  String _when(BuildContext context, DateTime at) {
    final local = at.toLocal();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(local.year, local.month, local.day);
    final hm = '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
    if (day == today) return '${context.t('today')} $hm';
    if (day == today.subtract(const Duration(days: 1))) return '${context.t('yesterday')} $hm';
    return '${local.day}/${local.month} $hm';
  }
}
