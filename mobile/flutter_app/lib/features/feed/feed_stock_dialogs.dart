import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/util/number_input.dart';
import '../../core/util/record_dates.dart';
import '../../core/widgets/form_dialog.dart';
import '../../core/widgets/ux_blocks.dart';
import '../../domain/entities/feeding.dart';
import '../../providers/feed_provider.dart';
import '../../providers/feeding_provider.dart';
import 'feed_workspace_screen.dart' show feedMoney, feedNumber;

/// What the animals are fed (v0.8.3): the farm's concentrate, corn silage,
/// and hay & straw. Anything else is a raw material for mixes — the server
/// refuses it on a feeding (backend catalog.RATION_TYPES).
const feedRationTypes = ['concentrate', 'silage', 'hay_straw'];
const feedRawMaterial = 'raw_material';

/// "Concentrate", "Corn silage", "Hay & straw", or "Raw material — for mixing".
String rationTypeLabel(BuildContext context, String? rationType) => context.t(switch (rationType) {
      'concentrate' => 'rationConcentrate',
      'silage' => 'rationSilage',
      'hay_straw' => 'rationHayStraw',
      _ => 'rationRaw',
    });

/// The category a feed of [rationType] is filed under.
String categoryForRation(String rationType, {String rawCategory = 'concentrate'}) => switch (rationType) {
      'concentrate' => 'concentrate',
      'silage' || 'hay_straw' => 'forage',
      _ => rawCategory,
    };

/// "$0.12/kg", or the words for no price.
String feedPriceLabel(BuildContext context, FeedProduct p) =>
    p.currentUnitCost == null ? context.t('feedNoPrice') : '${feedMoney(p.currentUnitCost!)}/${p.unit}';

/// The four answers to "What is it?": the three feeds, or a raw material.
class FeedTypeChooser extends StatelessWidget {
  const FeedTypeChooser({super.key, required this.value, required this.onChanged, this.enabled = true});
  final String value;
  final ValueChanged<String> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text(context.t('feedWhatIsIt'), style: FarmTypography.textTheme.labelLarge),
      const SizedBox(height: 6),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final t in [...feedRationTypes, feedRawMaterial])
          ChoiceChip(
            key: ValueKey('feed-type-$t'),
            label: Text(rationTypeLabel(context, t == feedRawMaterial ? null : t)),
            selected: value == t,
            onSelected: enabled ? (_) => onChanged(t) : null,
          ),
      ]),
      const SizedBox(height: 6),
      Text(context.t('feedWhatIsItHint'), style: FarmTypography.textTheme.bodySmall),
    ]);
  }
}

// ---------------------------------------------------------- stock count
/// Count the stock on inspection (v0.8.3): what was counted becomes the
/// stock; the server posts the difference with the records as a count
/// correction, so the history says why it changed.
Future<void> showStockCountDialog(BuildContext context, {String? productId}) =>
    showDialog<void>(context: context, builder: (_) => _StockCountDialog(productId: productId));

class _StockCountDialog extends StatefulWidget {
  const _StockCountDialog({this.productId});
  final String? productId;

  @override
  State<_StockCountDialog> createState() => _StockCountDialogState();
}

class _StockCountDialogState extends State<_StockCountDialog> {
  late String? _productId = widget.productId;
  final _counted = TextEditingController();
  final _notes = TextEditingController();
  DateTime _day = DateTime.now();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _counted.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _save(FeedProduct product) async {
    final counted = parseLocalizedDouble(_counted.text);
    if (counted == null || counted < 0) {
      setState(() => _error = context.t('countInvalid'));
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final result = await context.read<FeedingProvider>().countStock(
          productId: product.id,
          counted: counted,
          unit: product.unit,
          // Today's count is now; an earlier day's is that day, as recorded.
          countedAt: isToday(_day) ? null : recordedInstant(_day),
          notes: _notes.text,
        );
    if (!mounted) return;
    if (!result.success) {
      setState(() {
        _saving = false;
        _error = result.error ?? context.t('couldNotSave');
      });
      return;
    }
    // The Stock tab reads the stock lines; they move with the count.
    context.read<FeedProvider>().load();
    final lang = Localizations.localeOf(context).languageCode;
    Navigator.pop(context);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(result.queued
          ? context.t('workingOffline')
          : context.t('countSaved').replaceAll('{product}', product.label(lang)).replaceAll('{qty}', '${feedNumber(counted)} ${product.unit}')),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final feeding = context.watch<FeedingProvider>();
    final lang = Localizations.localeOf(context).languageCode;
    final products = [for (final p in feeding.products) if (p.status == 'active') p]..sort((a, b) => a.label(lang).compareTo(b.label(lang)));
    final product = products.where((p) => p.id == _productId).firstOrNull;
    final counted = parseLocalizedDouble(_counted.text);
    final onRecords = product?.availability.onHand ?? 0;
    final diff = counted == null ? null : counted - onRecords;
    return FarmFormDialog(
      title: Text(context.t('countStockTitle')),
      width: 480,
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        DropdownButtonFormField<String>(
          key: const ValueKey('count-product'),
          initialValue: product?.id,
          isExpanded: true,
          decoration: InputDecoration(labelText: context.t('feedItem')),
          items: [
            for (final p in products)
              DropdownMenuItem(value: p.id, child: Text('${p.label(lang)} · ${rationTypeLabel(context, p.rationType)}', overflow: TextOverflow.ellipsis)),
          ],
          onChanged: _saving ? null : (v) => setState(() => _productId = v),
        ),
        if (product != null) ...[
          const SizedBox(height: 12),
          Text(
            context.t('countOnRecords').replaceAll('{qty}', '${feedNumber(onRecords)} ${product.unit}'),
            key: const ValueKey('count-on-records'),
            style: FarmTypography.textTheme.titleSmall,
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('count-quantity'),
            controller: _counted,
            enabled: !_saving,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onChanged: (_) => setState(() => _error = null),
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
            decoration: InputDecoration(labelText: context.t('countCounted'), suffixText: product.unit),
          ),
          if (diff != null) ...[
            const SizedBox(height: 8),
            Text(
              diff.abs() < 0.0005
                  ? context.t('countDiffSame')
                  : context.t(diff < 0 ? 'countDiffLess' : 'countDiffMore').replaceAll('{qty}', '${feedNumber(diff.abs())} ${product.unit}'),
              key: const ValueKey('count-difference'),
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: diff < -0.0005 ? FarmColors.warningInk : FarmColors.muted),
            ),
          ],
          const SizedBox(height: 12),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: RecordDateButton(label: context.t('countOn'), value: _day, maxDaysBack: 60, onPicked: (d) => setState(() => _day = d)),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('count-notes'),
            controller: _notes,
            enabled: !_saving,
            maxLength: 300,
            decoration: InputDecoration(labelText: context.t('countNotes')),
          ),
          Text(context.t('countHow'), style: FarmTypography.textTheme.bodySmall),
        ],
        if (_error != null) ...[
          const SizedBox(height: 8),
          NoticeBanner(tone: NoticeTone.danger, text: _error!),
        ],
      ]),
      actions: [
        TextButton(onPressed: _saving ? null : () => Navigator.pop(context), child: Text(context.t('cancel'))),
        FilledButton(
          key: const ValueKey('count-save'),
          onPressed: _saving || product == null ? null : () => _save(product),
          child: _saving ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2)) : Text(context.t('countSave')),
        ),
      ],
    );
  }
}

// ------------------------------------------------------- type and price
/// What a feed is fed as, and its price per unit (v0.8.3) — the manager's.
Future<void> showFeedTypeAndPriceDialog(BuildContext context, FeedProduct product) =>
    showDialog<void>(context: context, builder: (_) => _TypeAndPriceDialog(product: product));

class _TypeAndPriceDialog extends StatefulWidget {
  const _TypeAndPriceDialog({required this.product});
  final FeedProduct product;

  @override
  State<_TypeAndPriceDialog> createState() => _TypeAndPriceDialogState();
}

class _TypeAndPriceDialogState extends State<_TypeAndPriceDialog> {
  late String _type = widget.product.rationType ?? feedRawMaterial;
  late final _price = TextEditingController(text: widget.product.defaultUnitCost == null ? '' : _plain(widget.product.defaultUnitCost!));
  bool _saving = false;
  String? _error;

  static String _plain(double v) => v.toStringAsFixed(4).replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');

  @override
  void dispose() {
    _price.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final p = widget.product;
    final priceText = _price.text.trim();
    final price = priceText.isEmpty ? null : parseLocalizedDouble(priceText);
    if (priceText.isNotEmpty && (price == null || price < 0)) {
      setState(() => _error = context.t('valueMustBePositive'));
      return;
    }
    final changes = <String, dynamic>{
      if (_type != (p.rationType ?? feedRawMaterial)) 'ration_type': _type,
      if (price != null && price != p.defaultUnitCost) 'default_unit_cost': price,
    };
    if (changes.isEmpty) {
      Navigator.pop(context);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final result = await context.read<FeedingProvider>().updateProduct(p.id, changes);
    if (!mounted) return;
    if (!result.success) {
      setState(() {
        _saving = false;
        _error = result.error ?? context.t('couldNotSave');
      });
      return;
    }
    context.read<FeedProvider>().load();
    Navigator.pop(context);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.t(result.queued ? 'workingOffline' : 'saved'))));
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.product;
    final lang = Localizations.localeOf(context).languageCode;
    return FarmFormDialog(
      title: Text('${context.t('feedEdit')} — ${p.label(lang)}'),
      width: 480,
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        FeedTypeChooser(value: _type, enabled: !_saving, onChanged: (t) => setState(() => _type = t)),
        const SizedBox(height: FarmSpacing.md),
        TextField(
          key: const ValueKey('feed-price'),
          controller: _price,
          enabled: !_saving,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(labelText: context.t('feedPricePerUnit').replaceAll('{unit}', p.unit), prefixText: '\$ '),
        ),
        const SizedBox(height: 6),
        Text(context.t('feedPriceHint'), style: FarmTypography.textTheme.bodySmall),
        if (p.currentUnitCost != null) ...[
          const SizedBox(height: 6),
          Text(context.t('feedNextCost').replaceAll('{price}', feedPriceLabel(context, p)), style: FarmTypography.textTheme.bodySmall),
        ],
        if (_error != null) ...[
          const SizedBox(height: 8),
          NoticeBanner(tone: NoticeTone.danger, text: _error!),
        ],
      ]),
      actions: [
        TextButton(onPressed: _saving ? null : () => Navigator.pop(context), child: Text(context.t('cancel'))),
        FilledButton(
          key: const ValueKey('feed-type-save'),
          onPressed: _saving ? null : _save,
          child: _saving ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2)) : Text(context.t('save')),
        ),
      ],
    );
  }
}

// ------------------------------------------------------ cost of a feeding
/// What [lines] — feed and quantity in its unit — cost at the price each
/// feed is fed at now (v0.8.3), and the feeds among them with no price.
(double, List<FeedProduct>) feedingCostEstimate(Iterable<(FeedProduct, double)> lines) {
  var total = 0.0;
  final unpriced = <FeedProduct>[];
  for (final (p, qty) in lines) {
    if (qty <= 0) continue;
    final price = p.currentUnitCost;
    if (price == null) {
      if (!unpriced.any((u) => u.id == p.id)) unpriced.add(p);
    } else {
      total += qty * price;
    }
  }
  return (total, unpriced);
}

/// "Cost of this feeding: $3.40", and which feeds have no price yet —
/// shown on the feeding forms before saving; the server costs the feeding
/// from the lots it is taken from.
class FeedingCostLine extends StatelessWidget {
  const FeedingCostLine({super.key, required this.lines});
  final List<(FeedProduct, double)> lines;

  @override
  Widget build(BuildContext context) {
    final entered = [for (final l in lines) if (l.$2 > 0) l];
    if (entered.isEmpty) return const SizedBox.shrink();
    final (total, unpriced) = feedingCostEstimate(entered);
    final lang = Localizations.localeOf(context).languageCode;
    return Column(key: const ValueKey('feeding-cost'), crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text(context.t('feedingCostEstimate').replaceAll('{cost}', feedMoney(total)), style: FarmTypography.textTheme.titleSmall),
      if (unpriced.isNotEmpty)
        Text(
          context.t('feedingCostUnpriced').replaceAll('{feeds}', unpriced.map((p) => p.label(lang)).join(', ')),
          style: const TextStyle(fontSize: 12.5, color: FarmColors.warningInk),
        ),
    ]);
  }
}
