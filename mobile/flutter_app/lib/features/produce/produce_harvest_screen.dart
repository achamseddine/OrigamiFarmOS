import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/widgets/app_icon.dart';
import '../../core/widgets/charts/bar_trend_chart.dart';
import '../../core/widgets/kpi_card.dart';
import '../../core/widgets/photo_slot.dart';
import '../../core/widgets/section_card.dart';
import '../../domain/entities/field.dart';
import '../../domain/entities/production_records.dart';
import '../../providers/feed_provider.dart';
import '../../providers/production_provider.dart';

/// Produce & Harvest is always-online now: [ProductionProvider] (fields +
/// harvest history) and [FeedProvider] (the whole farm's generic inventory,
/// filtered to produce-looking categories) are already loaded once at app
/// startup — see app/app.dart's `_DataLoader` — so this screen just watches
/// them instead of reading the old fabricated `DemoData` dataset.
bool _isProduceCategory(String category) {
  final c = category.toLowerCase();
  return c.contains('produce') || c.contains('vegetable') || c.contains('veg') || c.contains('fruit') || c.contains('crop');
}

/// One point per of the last 7 days, oldest first — same day-bucketing
/// pattern as `ProductionProvider.milkByDay`/`eggsByDay`, applied here to
/// kg-denominated harvest records since the provider has no dedicated
/// weekly-yield getter.
List<double> _weeklyYieldKg(List<HarvestRecord> records) {
  final now = DateTime.now();
  final start = DateTime(now.year, now.month, now.day).subtract(const Duration(days: 6));
  final buckets = List<double>.filled(7, 0);
  for (final r in records) {
    if (r.unit.toLowerCase() != 'kg') continue;
    final day = DateTime(r.recordedAt.year, r.recordedAt.month, r.recordedAt.day);
    final idx = day.difference(start).inDays;
    if (idx >= 0 && idx < 7) buckets[idx] += r.quantity;
  }
  return buckets;
}

List<String> _last7DaysLabels() => [for (var i = 6; i >= 0; i--) i == 0 ? 'Today' : (i == 1 ? 'Yesterday' : 'D-$i')];

class ProduceHarvestScreen extends StatelessWidget {
  const ProduceHarvestScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final production = context.watch<ProductionProvider>();
    final feed = context.watch<FeedProvider>();
    final fields = production.fields;
    final harvestRecords = production.harvestRecords;
    final now = DateTime.now();

    final harvestReady = fields.where((f) {
      final d = f.expectedHarvestDate;
      return d != null && d.difference(now).inHours <= 48;
    }).length;

    Field? upcoming;
    for (final f in fields) {
      final d = f.expectedHarvestDate;
      if (d != null && d.difference(now).inHours <= 48) {
        upcoming = f;
        break;
      }
    }

    final weeklyYield = _weeklyYieldKg(harvestRecords);
    final kgThisWeek = weeklyYield.fold<double>(0, (a, b) => a + b);
    final weeklyLabels = _last7DaysLabels();

    final produceStock = feed.items.where((i) => _isProduceCategory(i.category)).toList();
    final recentHarvests = [...harvestRecords]..sort((a, b) => b.recordedAt.compareTo(a.recordedAt));
    final recentTop = recentHarvests.take(6).toList();

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(context.t('produceHarvestTitle'), style: FarmTypography.display(size: 28)),
                    const SizedBox(height: 2),
                    Text(context.t('produceHarvestSubtitle'), style: FarmTypography.textTheme.bodyMedium),
                  ],
                ),
              ),
              if (upcoming != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(color: FarmColors.tint(FarmColors.warning, 0.14), borderRadius: BorderRadius.circular(FarmRadii.sm)),
                  child: Row(children: [
                    const Icon(Icons.notifications_active_outlined, color: FarmColors.warning, size: 18),
                    const SizedBox(width: 8),
                    Text('Reminder: ${upcoming.cropType ?? 'Crop'} in ${upcoming.name} ready for harvest soon.', style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
                  ]),
                ),
            ],
          ),
          const SizedBox(height: FarmSpacing.md),
          LayoutBuilder(builder: (context, c) {
            final perRow = c.maxWidth > 900 ? 4 : 2;
            final w = (c.maxWidth - FarmSpacing.md * (perRow - 1)) / perRow;
            final cards = [
              KpiCard(icon: FarmIcon.leaf, label: context.t('activeFields'), value: '${fields.length}'),
              KpiCard(icon: FarmIcon.harvestBasket, label: context.t('harvestReady'), value: '$harvestReady', unit: context.t('fields')),
              KpiCard(icon: FarmIcon.scale, label: context.t('kgThisWeek'), value: kgThisWeek.toStringAsFixed(0), unit: 'kg'),
              KpiCard(icon: FarmIcon.inventory, label: 'Harvest Records', value: '${harvestRecords.length}'),
            ];
            return Wrap(spacing: FarmSpacing.md, runSpacing: FarmSpacing.md, children: [for (final c2 in cards) SizedBox(width: w, child: c2)]);
          }),
          const SizedBox(height: FarmSpacing.md),
          LayoutBuilder(builder: (context, c) {
            final wide = c.maxWidth > kTabletBreakpoint;
            final overview = SectionCard(
              title: context.t('fieldOverview'),
              trailing: context.t('viewAllFields'),
              child: fields.isEmpty
                  ? Text('No fields recorded yet.', style: FarmTypography.textTheme.bodySmall)
                  : Column(children: [for (final f in fields) ...[_FieldRow(field: f), const Divider(height: 18, color: FarmColors.border)]]),
            );
            final calendar = SectionCard(
              title: context.t('harvestCalendar'),
              child: fields.isEmpty
                  ? Text('No fields recorded yet.', style: FarmTypography.textTheme.bodySmall)
                  : Column(children: [for (final f in fields) _CalendarRow(field: f)]),
            );
            if (!wide) return Column(children: [overview, const SizedBox(height: FarmSpacing.md), calendar]);
            return IntrinsicHeight(
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(flex: 5, child: overview),
                const SizedBox(width: FarmSpacing.md),
                Expanded(flex: 5, child: calendar),
              ]),
            );
          }),
          const SizedBox(height: FarmSpacing.md),
          SectionCard(
            title: context.t('weeklyYield'),
            child: harvestRecords.isEmpty
                ? Text('No harvest recorded yet.', style: FarmTypography.textTheme.bodySmall)
                : BarTrendChart(
                    bars: [for (var i = 0; i < weeklyYield.length; i++) BarGroup(label: weeklyLabels[i], segments: [weeklyYield[i]])],
                    segmentColors: const [FarmColors.olive],
                    height: 200,
                  ),
          ),
          const SizedBox(height: FarmSpacing.md),
          LayoutBuilder(builder: (context, c) {
            final wide = c.maxWidth > kTabletBreakpoint;
            final inventory = SectionCard(
              title: context.t('inventoryOverview'),
              trailing: context.t('viewAllInventory'),
              child: produceStock.isEmpty
                  ? Text('No produce inventory recorded yet.', style: FarmTypography.textTheme.bodySmall)
                  : _ProduceGrid(
                      items: [for (final item in produceStock) {'name': item.name, 'qty': _fmtQty(item.currentQty), 'unit': item.unit}],
                      subLabelKey: 'inStorage',
                    ),
            );
            final ready = SectionCard(
              title: context.t('readyForSale'),
              trailing: context.t('viewSalesOrders'),
              child: recentTop.isEmpty
                  ? Text('No recent harvests recorded yet.', style: FarmTypography.textTheme.bodySmall)
                  : _ProduceGrid(
                      items: [for (final r in recentTop) {'name': r.productName, 'qty': _fmtQty(r.quantity), 'unit': r.unit}],
                      subLabelKey: 'ready',
                    ),
            );
            if (!wide) return Column(children: [inventory, const SizedBox(height: FarmSpacing.md), ready]);
            return Row(children: [Expanded(child: inventory), const SizedBox(width: FarmSpacing.md), Expanded(child: ready)]);
          }),
        ],
      ),
    );
  }
}

String _fmtQty(double qty) => qty == qty.roundToDouble() ? qty.toStringAsFixed(0) : qty.toStringAsFixed(1);

class _FieldRow extends StatelessWidget {
  const _FieldRow({required this.field});
  final Field field;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 52, height: 52, child: PhotoSlot(icon: FarmIcon.leaf, borderRadius: BorderRadius.circular(FarmRadii.sm))),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(field.name, style: FarmTypography.textTheme.titleSmall),
              Text('Stage: ${field.stage ?? '—'}', style: FarmTypography.textTheme.bodySmall),
              Text('${context.t('nextHarvest')}: ${field.expectedHarvestDate != null ? _fmt(field.expectedHarvestDate!) : '—'}', style: const TextStyle(fontSize: 11, color: FarmColors.muted)),
            ],
          ),
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(context.t('estYield'), style: const TextStyle(fontSize: 10.5, color: FarmColors.muted)),
            Text(field.estYieldKg != null ? '${field.estYieldKg!.toStringAsFixed(0)} kg' : '—', style: FarmTypography.textTheme.titleSmall),
          ],
        ),
      ],
    );
  }

  String _fmt(DateTime d) {
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${months[d.month - 1]} ${d.day}';
  }
}

class _CalendarRow extends StatelessWidget {
  const _CalendarRow({required this.field});
  final Field field;

  @override
  Widget build(BuildContext context) {
    final harvestDate = field.expectedHarvestDate;
    final daysUntilRaw = harvestDate?.difference(DateTime.now()).inDays;
    final daysUntil = daysUntilRaw == null ? null : (daysUntilRaw < 0 ? 0 : (daysUntilRaw > 21 ? 21 : daysUntilRaw));
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox(width: 90, child: Text(field.cropType ?? '—', style: FarmTypography.textTheme.bodySmall)),
          Expanded(
            child: Stack(
              children: [
                Container(height: 10, decoration: BoxDecoration(color: FarmColors.mist, borderRadius: BorderRadius.circular(6))),
                FractionallySizedBox(
                  widthFactor: daysUntil == null ? 0.04 : (1 - daysUntil / 21).clamp(0.04, 1.0).toDouble(),
                  child: Container(height: 10, decoration: BoxDecoration(color: FarmColors.olive, borderRadius: BorderRadius.circular(6))),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(width: 54, child: Text(daysUntil == null ? '—' : '$daysUntil d', textAlign: TextAlign.right, style: const TextStyle(fontSize: 11, color: FarmColors.muted))),
        ],
      ),
    );
  }
}

class _ProduceGrid extends StatelessWidget {
  const _ProduceGrid({required this.items, required this.subLabelKey});
  final List<Map<String, Object>> items;
  final String subLabelKey;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final perRow = c.maxWidth > 420 ? 4 : 2;
      final w = (c.maxWidth - 8 * (perRow - 1)) / perRow;
      return Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final item in items)
            Container(
              width: w,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(FarmRadii.sm), border: Border.all(color: FarmColors.border)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const AppIcon(FarmIcon.leaf, size: 16, color: FarmColors.olive),
                  const SizedBox(height: 6),
                  Text('${item['qty']} ${item['unit']}', style: FarmTypography.textTheme.titleSmall),
                  Text(item['name'] as String, style: FarmTypography.textTheme.bodySmall),
                  Text(context.t(subLabelKey), style: const TextStyle(fontSize: 10, color: FarmColors.muted)),
                ],
              ),
            ),
        ],
      );
    });
  }
}
