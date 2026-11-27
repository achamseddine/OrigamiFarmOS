import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api/api_client.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../domain/entities/access.dart';
import '../../domain/entities/crop.dart';
import '../../domain/entities/inventory.dart';
import '../../providers/access_provider.dart';
import '../../providers/agriculture_provider.dart';
import '../../providers/feed_provider.dart';
import '../../providers/production_provider.dart';

/// The work done on a crop (master prompt Package 7; CROPS-SCHEMA §5).
const List<String> kCropOperationTypes = ['plant', 'fertilize', 'spray', 'weed', 'prune', 'irrigate', 'harvest_prep', 'other'];
const List<String> kWaterSources = ['well', 'network', 'canal', 'rain_tank'];

/// The four parts of a crop cycle's workplace.
enum CropCyclePart { work, water, sell, margin }

/// Opens the crop cycle's workplace: the work done on it and the stock it
/// used, the water it was given, its produce sold, and its margin.
void showCropCycleSheet(BuildContext context, CropPlanting planting) {
  showDialog<void>(context: context, builder: (_) => CropCycleSheet(planting: planting));
}

/// Each part is shown only to whoever may do it: the field team records the
/// work and the water; sales or finance sell; whoever reads the farm's money
/// sees the margin. The server checks the same rules on every write.
class CropCycleSheet extends StatefulWidget {
  const CropCycleSheet({super.key, required this.planting});
  final CropPlanting planting;

  @override
  State<CropCycleSheet> createState() => _CropCycleSheetState();
}

class _CropCycleSheetState extends State<CropCycleSheet> {
  CropCyclePart? _part;
  bool _closing = false;
  bool _closedHere = false;

  CropPlanting get _p => widget.planting;
  bool get _closed => _p.closed || _closedHere;

  List<CropCyclePart> _parts(AccessProvider access) => [
        if (!_closed && (access.canCreate(FarmModule.agriculture) || access.canCreate(FarmModule.produceHarvest))) ...[
          CropCyclePart.work,
          CropCyclePart.water,
        ],
        if (access.canRecordSale) CropCyclePart.sell,
        if (access.canSeeMoney) CropCyclePart.margin,
      ];

  Future<void> _close() async {
    final code = _p.cycleCode ?? context.t('ccNoCode');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ctx.t('ccCloseCycle')),
        content: Text(ctx.t('ccCloseConfirm').replaceAll('{code}', code)),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: Text(ctx.t('cancel'))),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: Text(ctx.t('ccCloseCycle'))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _closing = true);
    final result = await context.read<AgricultureProvider>().closeCycle(_p.id);
    if (!mounted) return;
    setState(() {
      _closing = false;
      if (result.success) _closedHere = true;
    });
    _report(result, 'ccClosedSaved');
  }

  void _report(WriteResult result, String savedKey) {
    final text = !result.success ? (result.error ?? context.t('ccFailed')) : (result.queued ? context.t('finSavedOffline') : context.t(savedKey));
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final access = context.watch<AccessProvider>();
    final agriculture = context.watch<AgricultureProvider>();
    final fields = context.watch<ProductionProvider>().fields;
    final parts = _parts(access);
    final part = parts.contains(_part) ? _part : (parts.isEmpty ? null : parts.first);
    String fieldName = _p.fieldId;
    for (final f in fields) {
      if (f.id == _p.fieldId) fieldName = f.name;
    }
    final cropName = agriculture.cropName(_p.cropId);

    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720, maxHeight: 680),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(FarmSpacing.lg, FarmSpacing.lg, FarmSpacing.sm, 0),
              child: Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(_p.cycleCode == null ? context.t('ccNoCode') : context.t('ccTitle').replaceAll('{code}', _p.cycleCode!),
                        style: FarmTypography.display(size: 22)),
                    const SizedBox(height: 2),
                    Text(context.t('ccSubtitle').replaceAll('{crop}', cropName).replaceAll('{field}', fieldName),
                        style: FarmTypography.textTheme.bodySmall),
                  ]),
                ),
                Chip(
                  label: Text(context.t(_closed ? 'ccClosed' : 'ccActive')),
                  backgroundColor: FarmColors.tint(_closed ? FarmColors.muted : FarmColors.olive, 0.15),
                ),
                IconButton(onPressed: () => Navigator.of(context).pop(), icon: const Icon(Icons.close), tooltip: context.t('cancel')),
              ]),
            ),
            if (_closed)
              Padding(
                padding: const EdgeInsets.fromLTRB(FarmSpacing.lg, 8, FarmSpacing.lg, 0),
                child: Text(context.t('ccClosedNote'), style: const TextStyle(fontSize: 12.5, color: FarmColors.muted)),
              ),
            if (parts.length > 1)
              Padding(
                padding: const EdgeInsets.fromLTRB(FarmSpacing.lg, 12, FarmSpacing.lg, 0),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SegmentedButton<CropCyclePart>(
                    segments: [
                      for (final p in parts) ButtonSegment(value: p, label: Text(context.t(_partKey(p))), icon: Icon(_partIcon(p), size: 17)),
                    ],
                    selected: {part!},
                    onSelectionChanged: (s) => setState(() => _part = s.first),
                  ),
                ),
              ),
            const Divider(height: 24, color: FarmColors.border),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(FarmSpacing.lg, 0, FarmSpacing.lg, FarmSpacing.lg),
                child: switch (part) {
                  CropCyclePart.work => _WorkForm(planting: _p, onDone: _report),
                  CropCyclePart.water => _WaterForm(planting: _p, onDone: _report),
                  CropCyclePart.sell => _SellForm(planting: _p, cropName: cropName, onDone: _report),
                  CropCyclePart.margin => _MarginView(planting: _p, key: ValueKey('margin-${_p.id}-$_closedHere')),
                  null => Text(context.t('ccNothingForYou'), style: FarmTypography.textTheme.bodySmall),
                },
              ),
            ),
            if (!_closed && access.canEdit(FarmModule.agriculture)) ...[
              const Divider(height: 1, color: FarmColors.border),
              Padding(
                padding: const EdgeInsets.fromLTRB(FarmSpacing.lg, 10, FarmSpacing.lg, FarmSpacing.md),
                child: Row(children: [
                  const Spacer(),
                  OutlinedButton.icon(
                    onPressed: _closing ? null : _close,
                    icon: const Icon(Icons.lock_outline, size: 17),
                    label: Text(context.t('ccCloseCycle')),
                  ),
                ]),
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String _partKey(CropCyclePart p) => switch (p) {
        CropCyclePart.work => 'ccPartWork',
        CropCyclePart.water => 'ccPartWater',
        CropCyclePart.sell => 'ccPartSell',
        CropCyclePart.margin => 'ccPartMargin',
      };

  static IconData _partIcon(CropCyclePart p) => switch (p) {
        CropCyclePart.work => Icons.handyman_outlined,
        CropCyclePart.water => Icons.water_drop_outlined,
        CropCyclePart.sell => Icons.sell_outlined,
        CropCyclePart.margin => Icons.calculate_outlined,
      };
}

typedef _Done = void Function(WriteResult result, String savedKey);

double? _num(TextEditingController c) => double.tryParse(c.text.trim().replaceAll(',', '.'));

String _fmt(num v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(v.abs() < 10 ? 2 : 1);

class _SubmitRow extends StatelessWidget {
  const _SubmitRow({required this.label, required this.saving, required this.onPressed, this.error});
  final String label;
  final bool saving;
  final VoidCallback onPressed;
  final String? error;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: FarmSpacing.md),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(error!, style: const TextStyle(color: FarmColors.danger, fontSize: 12.5)),
          ),
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: FilledButton(
            onPressed: saving ? null : onPressed,
            child: saving ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2)) : Text(label),
          ),
        ),
      ]),
    );
  }
}

// ------------------------------------------------------------------ work
class _WorkForm extends StatefulWidget {
  const _WorkForm({required this.planting, required this.onDone});
  final CropPlanting planting;
  final _Done onDone;

  @override
  State<_WorkForm> createState() => _WorkFormState();
}

class _WorkFormState extends State<_WorkForm> {
  final _hours = TextEditingController();
  final _cost = TextEditingController();
  final _qty = TextEditingController();
  final _notes = TextEditingController();
  String _type = 'fertilize';
  String? _itemId;
  late final Future<List<Map<String, dynamic>>> _inputs = context.read<AgricultureProvider>().cropInputs();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_hours, _cost, _qty, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    final qty = _num(_qty);
    if (_itemId != null && (qty == null || qty <= 0)) {
      setState(() => _error = context.t('ccEnterQty'));
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final result = await context.read<AgricultureProvider>().recordWork(widget.planting.id,
        operationType: _type,
        completedAt: DateTime.now(),
        labourHours: _num(_hours),
        labourCost: _num(_cost),
        itemId: _itemId,
        quantity: _itemId == null ? null : qty,
        notes: _notes.text);
    if (!mounted) return;
    if (result.success) {
      // An input left stock: the farm's stock lines are stale.
      if (!result.queued && _itemId != null) await context.read<FeedProvider>().load();
      if (!mounted) return;
      for (final c in [_hours, _cost, _qty, _notes]) {
        c.clear();
      }
      setState(() {
        _saving = false;
        _itemId = null;
      });
      widget.onDone(result, 'ccWorkSaved');
      return;
    }
    setState(() {
      _saving = false;
      _error = result.error;
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _inputs,
      builder: (context, snap) {
        final inputs = snap.data ?? const <Map<String, dynamic>>[];
        Map<String, dynamic>? chosen;
        for (final i in inputs) {
          if (i['id'] == _itemId) chosen = i;
        }
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          DropdownButtonFormField<String>(
            key: const ValueKey('cc-work-type'),
            isExpanded: true,
            value: _type,
            decoration: InputDecoration(labelText: context.t('ccWorkType')),
            items: [for (final t in kCropOperationTypes) DropdownMenuItem(value: t, child: Text(context.t('ccOp_$t')))],
            onChanged: (v) => setState(() => _type = v ?? _type),
          ),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: TextField(
                key: const ValueKey('cc-work-hours'),
                controller: _hours,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(labelText: context.t('ccLabourHours')),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                key: const ValueKey('cc-work-cost'),
                controller: _cost,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(labelText: context.t('ccLabourCost')),
              ),
            ),
          ]),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(context.t('ccLabourCostHelper'), style: const TextStyle(fontSize: 11.5, color: FarmColors.muted)),
          ),
          const SizedBox(height: 12),
          if (snap.connectionState == ConnectionState.done && inputs.isEmpty)
            Text(context.t('ccNoInputsInStock'), style: const TextStyle(fontSize: 12.5, color: FarmColors.muted))
          else
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                flex: 3,
                child: DropdownButtonFormField<String?>(
                  key: const ValueKey('cc-work-input'),
                  isExpanded: true,
                  value: _itemId,
                  decoration: InputDecoration(
                    labelText: context.t('ccInput'),
                    helperText: chosen == null
                        ? null
                        : context.t('ccInStock').replaceAll('{qty}', _fmt((chosen['current_qty'] as num?) ?? 0)).replaceAll('{unit}', '${chosen['unit']}'),
                  ),
                  items: [
                    DropdownMenuItem<String?>(value: null, child: Text(context.t('ccNoInput'))),
                    for (final i in inputs) DropdownMenuItem<String?>(value: i['id'] as String, child: Text('${i['name']}', overflow: TextOverflow.ellipsis)),
                  ],
                  onChanged: (v) => setState(() => _itemId = v),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: TextField(
                  key: const ValueKey('cc-work-qty'),
                  controller: _qty,
                  enabled: _itemId != null,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(labelText: context.t('ccInputQty').replaceAll('{unit}', '${chosen?['unit'] ?? ''}')),
                ),
              ),
            ]),
          const SizedBox(height: 12),
          TextField(controller: _notes, maxLines: 2, decoration: InputDecoration(labelText: context.t('notes'))),
          _SubmitRow(label: context.t('ccRecordWork'), saving: _saving, onPressed: _submit, error: _error),
        ]);
      },
    );
  }
}

// ----------------------------------------------------------------- water
class _WaterForm extends StatefulWidget {
  const _WaterForm({required this.planting, required this.onDone});
  final CropPlanting planting;
  final _Done onDone;

  @override
  State<_WaterForm> createState() => _WaterFormState();
}

class _WaterFormState extends State<_WaterForm> {
  final _water = TextEditingController();
  final _energy = TextEditingController();
  String _source = 'well';
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _water.dispose();
    _energy.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    final result = await context.read<AgricultureProvider>().recordIrrigation(widget.planting.id,
        startedAt: DateTime.now(), waterM3: _num(_water), energyCost: _num(_energy), source: _source);
    if (!mounted) return;
    if (result.success) {
      _water.clear();
      _energy.clear();
      setState(() => _saving = false);
      widget.onDone(result, 'ccWaterSaved');
      return;
    }
    setState(() {
      _saving = false;
      _error = result.error;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(
          child: TextField(
            key: const ValueKey('cc-water-m3'),
            controller: _water,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(labelText: context.t('ccWater')),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: DropdownButtonFormField<String>(
            isExpanded: true,
            value: _source,
            decoration: InputDecoration(labelText: context.t('ccWaterSource')),
            items: [for (final s in kWaterSources) DropdownMenuItem(value: s, child: Text(context.t('ccSrc_$s')))],
            onChanged: (v) => setState(() => _source = v ?? _source),
          ),
        ),
      ]),
      const SizedBox(height: 12),
      TextField(
        key: const ValueKey('cc-water-energy'),
        controller: _energy,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(labelText: context.t('ccEnergyCost'), helperText: context.t('ccEnergyHelper')),
      ),
      _SubmitRow(label: context.t('ccRecordWater'), saving: _saving, onPressed: _submit, error: _error),
    ]);
  }
}

// ------------------------------------------------------------------ sell
class _SellForm extends StatefulWidget {
  const _SellForm({required this.planting, required this.cropName, required this.onDone});
  final CropPlanting planting;
  final String cropName;
  final _Done onDone;

  @override
  State<_SellForm> createState() => _SellFormState();
}

class _SellFormState extends State<_SellForm> {
  final _qty = TextEditingController();
  final _price = TextEditingController();
  final _buyer = TextEditingController();
  String _currency = 'USD';
  bool _paid = true;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_qty, _price, _buyer]) {
      c.dispose();
    }
    super.dispose();
  }

  /// The stock line its produce is held on (the first harvest made it).
  InventoryItem? _stock(List<InventoryItem> items) {
    for (final i in items) {
      if (i.category.toLowerCase() == 'produce' && i.name == widget.cropName) return i;
    }
    return null;
  }

  Future<void> _submit() async {
    final qty = _num(_qty);
    final price = _num(_price);
    if (qty == null || qty <= 0 || price == null || price < 0) {
      setState(() => _error = context.t('ccEnterSale'));
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final result = await context
        .read<AgricultureProvider>()
        .sellProduce(widget.planting.id, quantity: qty, unitPrice: price, currency: _currency, buyer: _buyer.text, paid: _paid);
    if (!mounted) return;
    if (result.success) {
      if (!result.queued) await context.read<FeedProvider>().load();
      if (!mounted) return;
      for (final c in [_qty, _price, _buyer]) {
        c.clear();
      }
      setState(() => _saving = false);
      widget.onDone(result, 'ccSaleSaved');
      return;
    }
    setState(() {
      _saving = false;
      _error = result.error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final stock = _stock(context.watch<FeedProvider>().items);
    final unit = stock?.unit ?? 'kg';
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(
        stock == null || stock.currentQty <= 0
            ? context.t('ccNoProduceInStock').replaceAll('{crop}', widget.cropName)
            : context.t('ccProduceInStock').replaceAll('{qty}', _fmt(stock.currentQty)).replaceAll('{unit}', unit).replaceAll('{crop}', widget.cropName),
        style: TextStyle(fontSize: 12.5, color: stock == null || stock.currentQty <= 0 ? FarmColors.warning : FarmColors.muted),
      ),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(
          child: TextField(
            key: const ValueKey('cc-sell-qty'),
            controller: _qty,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(labelText: context.t('ccSellQty').replaceAll('{unit}', unit)),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: TextField(
            key: const ValueKey('cc-sell-price'),
            controller: _price,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(labelText: context.t('ccUnitPrice').replaceAll('{unit}', unit)),
          ),
        ),
        const SizedBox(width: 12),
        SizedBox(
          width: 100,
          child: DropdownButtonFormField<String>(
            isExpanded: true,
            value: _currency,
            decoration: InputDecoration(labelText: context.t('ccCurrency')),
            items: const [DropdownMenuItem(value: 'USD', child: Text('USD')), DropdownMenuItem(value: 'LBP', child: Text('LBP'))],
            onChanged: (v) => setState(() => _currency = v ?? _currency),
          ),
        ),
      ]),
      const SizedBox(height: 12),
      TextField(controller: _buyer, decoration: InputDecoration(labelText: context.t('ccBuyer'))),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        value: _paid,
        onChanged: (v) => setState(() => _paid = v),
        title: Text(context.t('ccPaidNow')),
      ),
      _SubmitRow(label: context.t('ccSell'), saving: _saving, onPressed: _submit, error: _error),
    ]);
  }
}

// ---------------------------------------------------------------- margin
/// Read from the farm server each time (the cycle's work, inputs, water,
/// harvests, sales and linked expenses); never kept on the tablet.
class _MarginView extends StatefulWidget {
  const _MarginView({super.key, required this.planting});
  final CropPlanting planting;

  @override
  State<_MarginView> createState() => _MarginViewState();
}

class _MarginViewState extends State<_MarginView> {
  late Future<Map<String, dynamic>?> _margin = context.read<AgricultureProvider>().cycleMargin(widget.planting.id);

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Map<String, dynamic>?>(
      future: _margin,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()));
        }
        final m = snap.data;
        if (m == null) {
          return Row(children: [
            Expanded(child: Text(context.t('ccMarginOffline'), style: FarmTypography.textTheme.bodySmall)),
            TextButton(
              onPressed: () => setState(() => _margin = context.read<AgricultureProvider>().cycleMargin(widget.planting.id)),
              child: Text(context.t('retry')),
            ),
          ]);
        }
        final costs = (m['costs'] as Map?)?.cast<String, dynamic>() ?? const {};
        final harvest = (m['harvest'] as Map?)?.cast<String, dynamic>() ?? const {};
        final unit = '${harvest['unit'] ?? 'kg'}';
        final unknown = [for (final u in (m['unknown'] as List? ?? const [])) '$u'];
        final unpriced = [for (final u in (m['unpriced_inputs'] as List? ?? const [])) '$u'];
        final marginValue = (m['margin'] as num?) ?? 0;
        final perUnit = m['cost_per_unit_harvested'] as num?;
        String usd(Object? v) => '\$${_fmt((v as num?) ?? 0)}';

        Widget line(String label, String value, {bool strong = false, Color? color}) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(children: [
                Expanded(child: Text(label, style: strong ? FarmTypography.textTheme.titleSmall : FarmTypography.textTheme.bodyMedium)),
                Text(value, style: (strong ? FarmTypography.textTheme.titleSmall : FarmTypography.textTheme.bodyMedium)?.copyWith(color: color)),
              ]),
            );

        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Wrap(spacing: 8, runSpacing: 8, children: [
            _Tile(label: context.t('ccHarvested'), value: '${_fmt((harvest['harvested'] as num?) ?? 0)} $unit'),
            _Tile(label: context.t('ccLost'), value: '${_fmt((harvest['lost'] as num?) ?? 0)} $unit'),
            _Tile(label: context.t('ccSold'), value: '${_fmt((harvest['sold'] as num?) ?? 0)} $unit'),
          ]),
          const SizedBox(height: 12),
          line(context.t('ccRevenue'), usd(m['revenue']), strong: true),
          const Divider(height: 16, color: FarmColors.border),
          line(context.t('ccCostInputs'), usd(costs['inputs'])),
          line(context.t('ccCostLabour').replaceAll('{hours}', _fmt((m['labour_hours'] as num?) ?? 0)), usd(costs['labour'])),
          line(context.t('ccCostWater').replaceAll('{m3}', _fmt((m['water_m3'] as num?) ?? 0)), usd(costs['irrigation_energy'])),
          line(context.t('ccCostOther'), usd(costs['other_expenses'])),
          line(context.t('ccCosts'), usd(costs['total_known']), strong: true),
          const Divider(height: 16, color: FarmColors.border),
          line(context.t('ccMargin'), usd(marginValue), strong: true, color: marginValue < 0 ? FarmColors.danger : FarmColors.olive),
          if (perUnit != null) line(context.t('ccCostPerUnit').replaceAll('{unit}', unit), '\$${perUnit.toStringAsFixed(3)}'),
          if (unknown.isNotEmpty)
            Container(
              key: const ValueKey('cc-margin-unknown'),
              margin: const EdgeInsets.only(top: 12),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: FarmColors.tint(FarmColors.warning, 0.14), borderRadius: BorderRadius.circular(FarmRadii.sm)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(context.t('ccUnknownNote'), style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
                for (final u in unknown)
                  Text('• ${context.t('ccUnknown_$u').replaceAll('{items}', unpriced.join(', '))}', style: const TextStyle(fontSize: 12.5)),
              ]),
            ),
        ]);
      },
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 120),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: FarmColors.stone, borderRadius: BorderRadius.circular(FarmRadii.sm)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(value, style: FarmTypography.textTheme.titleSmall),
        Text(label, style: const TextStyle(fontSize: 11, color: FarmColors.muted)),
      ]),
    );
  }
}
