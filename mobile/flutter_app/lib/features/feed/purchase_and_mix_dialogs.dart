import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/util/number_input.dart';
import '../../core/util/record_dates.dart';
import '../../core/widgets/section_card.dart';
import '../../core/widgets/ux_blocks.dart';
import '../../domain/entities/access.dart';
import '../../domain/entities/feeding.dart';
import '../../providers/access_provider.dart';
import '../../providers/feeding_provider.dart';

/// The feed room's three everyday records, each one form (generic feed
/// architecture §3, §5a):
///
/// 1. **a purchase** — grain, corn silage, wheat straw…: what came, how
///    much, from which supplier, when, and its quality (grade, moisture,
///    what was seen). It becomes a lot; stock is the ledger, never a typed
///    balance.
/// 2. **a mix** — the date, the ingredients as weighed, the output: one
///    numbered mix, its ingredient lots drawn FIFO, its output lot ready
///    to feed. No formula has to be set up first.
/// 3. **a feeding** — the animal feeding form (feeding_event_dialog.dart).

const _kinds = ['grain', 'forage', 'complete', 'mineral'];

Future<void> showRecordPurchaseDialog(BuildContext context, {String? productId}) =>
    showDialog<void>(context: context, builder: (_) => _PurchaseDialog(productId: productId));

class _PurchaseDialog extends StatefulWidget {
  const _PurchaseDialog({this.productId});
  final String? productId;

  @override
  State<_PurchaseDialog> createState() => _PurchaseDialogState();
}

class _PurchaseDialogState extends State<_PurchaseDialog> {
  static const _newFeed = '__new__';
  late String? _productId = widget.productId;
  final _name = TextEditingController();
  String _kind = 'grain';
  String _unit = 'kg';
  DateTime _day = DateTime.now();
  final _qty = TextEditingController();
  final _rejected = TextEditingController();
  final _supplier = TextEditingController();
  final _reference = TextEditingController();
  final _cost = TextEditingController();
  final _moisture = TextEditingController();
  final _qualityNotes = TextEditingController();
  String? _grade;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_name, _qty, _rejected, _supplier, _reference, _cost, _moisture, _qualityNotes]) {
      c.dispose();
    }
    super.dispose();
  }

  Map<String, dynamic> _newProductBody() {
    final name = _name.text.trim();
    return {
      'name': name,
      'unit': _unit,
      'source_type': 'purchased',
      'category': switch (_kind) { 'grain' => 'concentrate', 'forage' => 'forage', 'mineral' => 'mineral', _ => 'complete_feed' },
      // Grain and minerals go into mixes and can be fed straight; a bought
      // complete feed is fed as it is.
      'is_ingredient': _kind != 'complete',
      'is_feedable': true,
    };
  }

  Future<void> _submit() async {
    final qty = parseLocalizedDouble(_qty.text);
    final rejected = _rejected.text.trim().isEmpty ? 0.0 : parseLocalizedDouble(_rejected.text);
    final moisture = _moisture.text.trim().isEmpty ? null : parseLocalizedDouble(_moisture.text);
    final cost = _cost.text.trim().isEmpty ? null : parseLocalizedDouble(_cost.text);
    if (_productId == null || (_productId == _newFeed && _name.text.trim().isEmpty)) {
      setState(() => _error = context.t('fpChooseFeed'));
      return;
    }
    if (qty == null || qty <= 0 || rejected == null || rejected < 0 || rejected > qty) {
      setState(() => _error = context.t('valueMustBePositive'));
      return;
    }
    if (moisture != null && (moisture < 0 || moisture > 100)) {
      setState(() => _error = context.t('fpMoistureRange'));
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final result = await context.read<FeedingProvider>().recordPurchase(
      newProduct: _productId == _newFeed ? _newProductBody() : null,
      lot: {
        if (_productId != _newFeed) 'feed_product_id': _productId,
        'quantity': qty,
        'rejected_quantity': rejected,
        'received_at': recordedInstant(_day).toUtc().toIso8601String(),
        if (_supplier.text.trim().isNotEmpty) 'supplier_label': _supplier.text.trim(),
        if (_reference.text.trim().isNotEmpty) 'reference': _reference.text.trim(),
        'unit_cost': ?cost,
        'quality_grade': ?_grade,
        'moisture_pct': ?moisture,
        if (_qualityNotes.text.trim().isNotEmpty) 'quality_notes': _qualityNotes.text.trim(),
      },
    );
    if (!mounted) return;
    if (result.success) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(result.queued ? context.t('workingOffline') : context.t('deliveryReceived'))));
      return;
    }
    setState(() {
      _saving = false;
      _error = result.error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final feeding = context.watch<FeedingProvider>();
    final lang = Localizations.localeOf(context).languageCode;
    final products = [for (final p in feeding.products) if (p.status == 'active') p]..sort((a, b) => a.label(lang).compareTo(b.label(lang)));
    final product = products.where((p) => p.id == _productId).firstOrNull;
    final unit = _productId == _newFeed ? _unit : (product?.unit ?? 'kg');
    return AlertDialog(
      title: Text(context.t('fpRecordPurchase')),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            DropdownButtonFormField<String>(
              initialValue: _productId == _newFeed || products.any((p) => p.id == _productId) ? _productId : null,
              isExpanded: true,
              decoration: InputDecoration(labelText: context.t('fpWhatArrived')),
              items: [
                for (final p in products) DropdownMenuItem(value: p.id, child: Text(p.label(lang), overflow: TextOverflow.ellipsis)),
                DropdownMenuItem(value: _newFeed, child: Text('+ ${context.t('fpNewFeed')}')),
              ],
              onChanged: (v) => setState(() => _productId = v),
            ),
            if (_productId == _newFeed) ...[
              const SizedBox(height: 10),
              TextField(controller: _name, decoration: InputDecoration(labelText: context.t('fpNewFeedName'), hintText: context.t('fpNewFeedHint'))),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final k in _kinds) ChoiceChip(label: Text(context.t('fpKind_$k')), selected: _kind == k, onSelected: (_) => setState(() => _kind = k)),
              ]),
              const SizedBox(height: 8),
              Wrap(spacing: 8, children: [
                for (final u in const ['kg', 't', 'bale']) ChoiceChip(label: Text(u), selected: _unit == u, onSelected: (_) => setState(() => _unit = u)),
              ]),
            ],
            const SizedBox(height: 12),
            RecordDateButton(label: context.t('fpReceivedOn'), value: _day, onPicked: (d) => setState(() => _day = d)),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _qty,
                  autofocus: widget.productId != null,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(labelText: context.t('received'), suffixText: unit),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _rejected,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(labelText: context.t('rejected'), suffixText: unit, hintText: context.t('optional')),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _cost,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(labelText: '${context.t('unitCost')} / $unit', hintText: context.t('optional')),
                ),
              ),
            ]),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(child: TextField(controller: _supplier, decoration: InputDecoration(labelText: context.t('supplier')))),
              const SizedBox(width: 10),
              Expanded(child: TextField(controller: _reference, decoration: InputDecoration(labelText: context.t('fpInvoice'), hintText: context.t('optional')))),
            ]),
            const SizedBox(height: 14),
            Text(context.t('fpQuality'), style: FarmTypography.textTheme.titleSmall),
            const SizedBox(height: 6),
            Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
              for (final g in const ['good', 'fair', 'poor'])
                ChoiceChip(label: Text(context.t('fpGrade_$g')), selected: _grade == g, onSelected: (on) => setState(() => _grade = on ? g : null)),
              SizedBox(
                width: 150,
                child: TextField(
                  controller: _moisture,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(labelText: context.t('fpMoisture'), suffixText: '%', isDense: true),
                ),
              ),
            ]),
            const SizedBox(height: 8),
            TextField(controller: _qualityNotes, decoration: InputDecoration(labelText: context.t('fpQualityNotes'), hintText: context.t('fpQualityNotesHint'))),
            if (_error != null) ...[const SizedBox(height: 8), Text(_error!, style: const TextStyle(color: FarmColors.danger, fontSize: 12.5))],
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(context.t('cancel'))),
        FilledButton(
          onPressed: _saving ? null : _submit,
          child: _saving ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2)) : Text(context.t('save')),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------- mix
Future<void> showRecordMixDialog(BuildContext context, {String? productId}) =>
    showDialog<void>(context: context, builder: (_) => _MixDialog(productId: productId));

class _MixLine {
  _MixLine({this.productId, double? qty}) : qty = TextEditingController(text: qty == null ? '' : _fmt(qty));
  String? productId;
  final TextEditingController qty;
}

String _fmt(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

class _MixDialog extends StatefulWidget {
  const _MixDialog({this.productId});
  final String? productId;

  @override
  State<_MixDialog> createState() => _MixDialogState();
}

class _MixDialogState extends State<_MixDialog> {
  static const _newMix = '__new__';
  String? _output;
  final _newName = TextEditingController();
  DateTime _day = DateTime.now();
  final List<_MixLine> _lines = [];
  final _outputQty = TextEditingController();
  bool _outputEdited = false;
  bool _overrideStock = false;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final feeding = context.read<FeedingProvider>();
    final outputs = _outputs(feeding);
    final concentrate = feeding.feedSlots.where((s) => s.slot == 'concentrate').firstOrNull?.feedProductId;
    // The feed the farm usually mixes: the standard concentrate when it is
    // farm-made, else a farm-made feed that has a recipe, else a new one.
    final withRecipe = [for (final p in outputs) if (feeding.formulas.any((f) => f.feedProductId == p.id && f.active != null)) p];
    _output = widget.productId ??
        (outputs.any((p) => p.id == concentrate)
            ? concentrate
            : (withRecipe.isNotEmpty ? withRecipe.first.id : (outputs.isNotEmpty ? outputs.first.id : _newMix)));
    if (_output == _newMix) _newName.text = 'Concentrate';
    _prefill(feeding);
  }

  @override
  void dispose() {
    _newName.dispose();
    _outputQty.dispose();
    for (final l in _lines) {
      l.qty.dispose();
    }
    super.dispose();
  }

  List<FeedProduct> _outputs(FeedingProvider f) => [for (final p in f.products) if (p.status == 'active' && p.isFarmProduced && p.isFeedable) p];

  /// The output's recipe as rows to check and correct, or three empty rows.
  void _prefill(FeedingProvider feeding) {
    for (final l in _lines) {
      l.qty.dispose();
    }
    _lines.clear();
    final formula = feeding.formulas.where((f) => f.feedProductId == _output && f.active != null).firstOrNull;
    final version = formula?.active;
    if (version != null) {
      for (final c in version.components) {
        _lines.add(_MixLine(productId: c.feedProductId, qty: c.targetQuantity));
      }
    }
    while (_lines.length < 3) {
      _lines.add(_MixLine());
    }
    _syncOutput();
  }

  double get _ingredientsTotal => _lines.fold(0.0, (sum, l) => sum + (parseLocalizedDouble(l.qty.text) ?? 0));

  void _syncOutput() {
    if (!_outputEdited) _outputQty.text = _ingredientsTotal > 0 ? _fmt(_ingredientsTotal) : '';
  }

  List<(FeedProduct, double)> _shortfalls(FeedingProvider feeding) {
    final out = <(FeedProduct, double)>[];
    for (final l in _lines) {
      final id = l.productId;
      final qty = parseLocalizedDouble(l.qty.text) ?? 0;
      final p = id == null ? null : feeding.productById(id);
      if (p != null && qty > p.availability.available + 0.0005) out.add((p, qty));
    }
    return out;
  }

  Future<void> _submit() async {
    final feeding = context.read<FeedingProvider>();
    final components = <Map<String, dynamic>>[];
    for (final l in _lines) {
      final raw = l.qty.text.trim();
      if (raw.isEmpty) continue;
      final q = parseLocalizedDouble(raw);
      if (q == null || q < 0 || l.productId == null) {
        setState(() => _error = context.t('fmCheckRows'));
        return;
      }
      if (q > 0) components.add({'feed_product_id': l.productId, 'actual_quantity': q});
    }
    if (components.isEmpty) {
      setState(() => _error = context.t('fmNeedIngredient'));
      return;
    }
    if (_output == null || (_output == _newMix && _newName.text.trim().isEmpty)) {
      setState(() => _error = context.t('fmChooseOutput'));
      return;
    }
    final output = parseLocalizedDouble(_outputQty.text);
    if (_shortfalls(feeding).isNotEmpty && !_overrideStock) {
      setState(() => _error = context.t('feedStockShortConfirm'));
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final result = await feeding.recordMix({
      if (_output != _newMix) 'feed_product_id': _output,
      if (_output == _newMix) 'new_product_name': _newName.text.trim(),
      'components': components,
      'output_quantity': ?output,
      'produced_at': recordedInstant(_day).toUtc().toIso8601String(),
      if (_overrideStock) 'allow_negative': true,
    });
    if (!mounted) return;
    if (result.success) {
      final code = result.data is Map ? (result.data! as Map)['mix_code'] as String? : null;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(result.queued ? context.t('fmSavedOffline') : '${context.t('fmSaved')}${code != null ? ' — $code' : ''}'),
      ));
      return;
    }
    final message = result.error ?? context.t('couldNotSave');
    setState(() {
      _saving = false;
      _error = message.replaceAll(RegExp(r'\s*Pass allow_negative=true to override\.?'), '');
    });
  }

  @override
  Widget build(BuildContext context) {
    final feeding = context.watch<FeedingProvider>();
    final lang = Localizations.localeOf(context).languageCode;
    final outputs = _outputs(feeding);
    final ingredients = [for (final p in feeding.products) if (p.status == 'active' && p.isIngredient && p.id != _output) p]
      ..sort((a, b) => a.label(lang).compareTo(b.label(lang)));
    final shortfalls = _shortfalls(feeding);
    return AlertDialog(
      title: Text(context.t('fmTitle')),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            DropdownButtonFormField<String>(
              initialValue: _output == _newMix || outputs.any((p) => p.id == _output) ? _output : null,
              isExpanded: true,
              decoration: InputDecoration(labelText: context.t('fmMakes')),
              items: [
                for (final p in outputs) DropdownMenuItem(value: p.id, child: Text(p.label(lang), overflow: TextOverflow.ellipsis)),
                DropdownMenuItem(value: _newMix, child: Text('+ ${context.t('fmNewMixFeed')}')),
              ],
              onChanged: (v) => setState(() {
                _output = v;
                _prefill(feeding);
              }),
            ),
            if (_output == _newMix) ...[
              const SizedBox(height: 8),
              TextField(controller: _newName, decoration: InputDecoration(labelText: context.t('fmNewMixName'))),
            ],
            const SizedBox(height: 12),
            RecordDateButton(label: context.t('fmMixedOn'), value: _day, onPicked: (d) => setState(() => _day = d)),
            const SizedBox(height: 12),
            Text(context.t('fmIngredients'), style: FarmTypography.textTheme.titleSmall),
            Text(context.t('fmIngredientsHint'), style: FarmTypography.textTheme.bodySmall),
            const SizedBox(height: 8),
            if (ingredients.isEmpty) Text(context.t('fmNoIngredients'), style: FarmTypography.textTheme.bodySmall),
            for (var i = 0; i < _lines.length; i++) ...[
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                  flex: 3,
                  child: DropdownButtonFormField<String>(
                    key: ObjectKey(_lines[i]),
                    initialValue: ingredients.any((p) => p.id == _lines[i].productId) ? _lines[i].productId : null,
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: context.t('fmIngredient'),
                      helperText: _lines[i].productId == null
                          ? null
                          : '${_fmt(feeding.productById(_lines[i].productId!)?.availability.available ?? 0)} ${feeding.productById(_lines[i].productId!)?.unit ?? 'kg'} ${context.t('feedInStock')}',
                    ),
                    items: [for (final p in ingredients) DropdownMenuItem(value: p.id, child: Text(p.label(lang), overflow: TextOverflow.ellipsis))],
                    onChanged: (v) => setState(() => _lines[i].productId = v),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: _lines[i].qty,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    onChanged: (_) => setState(_syncOutput),
                    decoration: InputDecoration(labelText: context.t('quantity'), suffixText: 'kg'),
                  ),
                ),
                IconButton(
                  onPressed: _lines.length > 1 ? () => setState(() {
                        _lines.removeAt(i).qty.dispose();
                        _syncOutput();
                      }) : null,
                  tooltip: context.t('remove'),
                  icon: const Icon(Icons.remove_circle_outline, size: 18, color: FarmColors.muted),
                ),
              ]),
              const SizedBox(height: 8),
            ],
            TextButton.icon(
              onPressed: () => setState(() => _lines.add(_MixLine())),
              icon: const Icon(Icons.add, size: 16),
              label: Text(context.t('fmAddIngredient')),
            ),
            const SizedBox(height: 6),
            SizedBox(
              width: 240,
              child: TextField(
                controller: _outputQty,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                onChanged: (_) => _outputEdited = true,
                decoration: InputDecoration(labelText: context.t('fmOutput'), suffixText: 'kg', helperText: context.t('fmOutputHint')),
              ),
            ),
            if (shortfalls.isNotEmpty) ...[
              const SizedBox(height: 12),
              NoticeBanner(
                title: context.t('feedStockShortTitle'),
                text: [
                  for (final (p, q) in shortfalls) '${p.label(lang)}: ${_fmt(p.availability.available)} ${p.unit} ${context.t('feedInStock')}, ${_fmt(q)} ${p.unit} ${context.t('feedEntered')}',
                  context.t('fmStockShortBody'),
                ].join('\n'),
              ),
              Material(
                type: MaterialType.transparency,
                child: CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  dense: true,
                  value: _overrideStock,
                  title: Text(context.t('feedRecordAnyway')),
                  onChanged: (v) => setState(() => _overrideStock = v ?? false),
                ),
              ),
            ],
            if (_error != null) ...[const SizedBox(height: 8), Text(_error!, style: const TextStyle(color: FarmColors.danger, fontSize: 12.5))],
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(context.t('cancel'))),
        FilledButton(
          onPressed: _saving ? null : _submit,
          child: _saving ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2)) : Text(context.t('fmSave')),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------- getting started
/// The feed room's start, in the order it happens on the farm: buy the
/// grain, buy the silage and straw, mix the concentrate, feed the animals.
/// Each step is ticked from the records — never by hand — and the card
/// goes away once all four have happened.
class FeedGettingStartedCard extends StatelessWidget {
  const FeedGettingStartedCard({super.key, required this.onFeed});
  final VoidCallback onFeed;

  @override
  Widget build(BuildContext context) {
    final feeding = context.watch<FeedingProvider>();
    final canFeed = context.watch<AccessProvider>().canCreate(FarmModule.feedNutrition);
    final slots = {for (final s in feeding.feedSlots) s.slot: s};
    final forageIds = {slots['corn_silage']?.feedProductId, slots['wheat_straw']?.feedProductId}..remove(null);
    bool hasStock(String? id) => id != null && (feeding.productById(id)?.availability.onHand ?? 0) > 0;
    final grainBought = feeding.lots.any((l) =>
        l.sourceType == 'purchased' && !forageIds.contains(l.feedProductId) && (feeding.productById(l.feedProductId)?.isIngredient ?? false));
    final forageBought = hasStock(slots['corn_silage']?.feedProductId) && hasStock(slots['wheat_straw']?.feedProductId);
    final mixed = feeding.batches.any((b) => b.status == 'completed');
    final fed = feeding.recentEvents.isNotEmpty;
    if (grainBought && forageBought && mixed && fed) return const SizedBox.shrink();
    Widget step(int n, String title, String body, bool done, VoidCallback? action, String actionLabel) => Padding(
          padding: const EdgeInsets.only(bottom: FarmSpacing.sm),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            CircleAvatar(
              radius: 13,
              backgroundColor: done ? FarmColors.success : FarmColors.mist,
              child: done ? const Icon(Icons.check, size: 16, color: Colors.white) : Text('$n', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: FarmTypography.textTheme.titleSmall),
                Text(body, style: FarmTypography.textTheme.bodySmall),
              ]),
            ),
            if (canFeed && action != null) TextButton(onPressed: action, child: Text(actionLabel)),
          ]),
        );
    return SectionCard(
      title: context.t('fgTitle'),
      subtitle: context.t('fgSubtitle'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        step(1, context.t('fgStep1'), context.t('fgStep1Body'), grainBought, () => showRecordPurchaseDialog(context), context.t('fpRecordPurchase')),
        step(2, context.t('fgStep2'), context.t('fgStep2Body'), forageBought,
            () => showRecordPurchaseDialog(context, productId: hasStock(slots['corn_silage']?.feedProductId) ? slots['wheat_straw']?.feedProductId : slots['corn_silage']?.feedProductId),
            context.t('fpRecordPurchase')),
        step(3, context.t('fgStep3'), context.t('fgStep3Body'), mixed, () => showRecordMixDialog(context), context.t('fmTitle')),
        step(4, context.t('fgStep4'), context.t('fgStep4Body'), fed, onFeed, context.t('recordFeeding')),
      ]),
    );
  }
}
