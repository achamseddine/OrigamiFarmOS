import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/i18n/strings.dart';
import '../../../core/theme/colors.dart';
import '../../../core/theme/spacing.dart';
import '../../../core/theme/typography.dart';
import '../../../core/widgets/section_card.dart';
import '../../../core/widgets/status_pill.dart';
import '../../../domain/entities/access.dart';
import '../../../domain/entities/feeding.dart';
import '../../../providers/access_provider.dart';
import '../../../providers/feeding_provider.dart';
import '../feed_workspace_screen.dart';

/// Feed products and their lots (§2.1, §2.2, §3, §25, §26): what can be
/// fed or mixed, what is on hand, reserved and usable, and the lots it is
/// held in — with a delivery receipt that keeps ordered / received /
/// accepted / rejected apart.
class FeedsAndLotsTab extends StatelessWidget {
  const FeedsAndLotsTab({super.key});

  @override
  Widget build(BuildContext context) {
    final feeding = context.watch<FeedingProvider>();
    final access = context.watch<AccessProvider>();
    final lang = Localizations.localeOf(context).languageCode;
    final canCreate = access.canCreate(FarmModule.feedNutrition);
    final canApprove = access.can(FarmModule.feedNutrition, PermissionAction.approve);

    return FeedTabScaffold(children: [
      SectionCard(
        title: context.t('feedTabFeeds'),
        subtitle: context.t('feedsAndLotsSubtitle'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (canCreate)
              Wrap(spacing: 8, runSpacing: 8, children: [
                FilledButton.icon(onPressed: () => _showNewFeedDialog(context), icon: const Icon(Icons.add, size: 16), label: Text(context.t('newFeed'))),
                OutlinedButton.icon(onPressed: () => _showReceiveDialog(context), icon: const Icon(Icons.local_shipping_outlined, size: 16), label: Text(context.t('receiveDelivery'))),
                OutlinedButton.icon(onPressed: () => _showReserveDialog(context), icon: const Icon(Icons.lock_outline, size: 16), label: Text(context.t('reserveStock'))),
              ]),
            if (feeding.products.isEmpty) const FeedEmpty('noFeedItems'),
            for (final p in feeding.products) ...[
              const SizedBox(height: 10),
              _ProductCard(product: p, lang: lang, canApprove: canApprove),
            ],
          ],
        ),
      ),
      if (feeding.allocations.isNotEmpty)
        SectionCard(
          title: context.t('allocations'),
          subtitle: context.t('allocationsSubtitle'),
          child: Column(children: [
            for (final a in feeding.allocations) ...[
              Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${feeding.productName(a.feedProductId, lang)} — ${feedNumber(a.remainingQuantity)} / ${feedNumber(a.allocatedQuantity)} ${a.unit}', style: FarmTypography.textTheme.titleSmall),
                    Text(
                      [if (a.speciesCode != null) a.speciesCode!.replaceAll('_', ' '), if (a.subjectId != null) '${a.subjectType}: ${a.subjectId}', if (a.purpose != null) a.purpose!].join(' · '),
                      style: FarmTypography.textTheme.bodySmall,
                    ),
                  ]),
                ),
                StatusPill(label: a.transferable ? context.t('transferable') : context.t('notTransferable'), level: FarmStatusLevel.neutral, dense: true),
                if (canApprove) ...[
                  const SizedBox(width: 6),
                  TextButton(onPressed: () => _release(context, a), child: Text(context.t('releaseReservation'))),
                ],
              ]),
              const Divider(height: 16, color: FarmColors.border),
            ],
          ]),
        ),
    ]);
  }

  Future<void> _release(BuildContext context, FeedAllocation a) async {
    final result = await context.read<FeedingProvider>().releaseAllocation(a.id);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(result.success ? context.t('saved') : (result.error ?? context.t('couldNotSave')))));
  }
}

class _ProductCard extends StatelessWidget {
  const _ProductCard({required this.product, required this.lang, required this.canApprove});
  final FeedProduct product;
  final String lang;
  final bool canApprove;

  @override
  Widget build(BuildContext context) {
    final a = product.availability;
    final lots = a.lots.isNotEmpty ? a.lots : context.read<FeedingProvider>().lotsFor(product.id);
    return Container(
      decoration: BoxDecoration(color: FarmColors.stone, borderRadius: BorderRadius.circular(FarmRadii.md)),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 14),
        childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
        title: Row(children: [
          Expanded(child: Text(product.label(lang), style: FarmTypography.textTheme.titleSmall)),
          Text('${feedNumber(a.available)} / ${feedNumber(a.onHand)} ${product.unit}', style: FarmTypography.textTheme.titleSmall),
        ]),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Wrap(spacing: 6, runSpacing: 4, children: [
            StatusPill(label: context.t(product.isFarmProduced ? 'farmProducedFeed' : 'purchasedFeed'), level: FarmStatusLevel.neutral, dense: true),
            if (product.isIngredient) StatusPill(label: context.t('ingredient'), level: FarmStatusLevel.info, dense: true),
            if (product.isFeedable) StatusPill(label: context.t('feedable'), level: FarmStatusLevel.good, dense: true),
            if (product.isRestricted) StatusPill(label: context.t('restrictedFeed'), level: FarmStatusLevel.alert, dense: true),
            if (a.reserved > 0) StatusPill(label: '${context.t('reserved')} ${feedNumber(a.reserved)}', level: FarmStatusLevel.watch, dense: true),
            if (a.unusable > 0) StatusPill(label: '${context.t('unusable')} ${feedNumber(a.unusable)}', level: FarmStatusLevel.alert, dense: true),
          ]),
        ),
        children: [
          FeedKeyValue(context.t('onHand'), '${feedNumber(a.onHand)} ${product.unit}'),
          FeedKeyValue(context.t('reserved'), '${feedNumber(a.reserved)} ${product.unit}'),
          FeedKeyValue(context.t('unusable'), '${feedNumber(a.unusable)} ${product.unit}'),
          FeedKeyValue(context.t('available'), '${feedNumber(a.available)} ${product.unit}', bold: true),
          if (product.policyNames.isNotEmpty) FeedKeyValue(context.t('restrictedFeed'), product.policyNames.join(', ')),
          const SizedBox(height: 8),
          Text(context.t('lots'), style: const TextStyle(fontSize: 11, color: FarmColors.muted, fontWeight: FontWeight.w700, letterSpacing: 0.4)),
          if (lots.isEmpty) const FeedEmpty('noLotsYet'),
          for (final lot in lots)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(lot.lotCode, style: FarmTypography.textTheme.bodyMedium),
                    Text(
                      [
                        context.t('lotSource_${lot.sourceType}'),
                        if (lot.supplierLabel != null) lot.supplierLabel!,
                        feedDate(lot.receivedAt),
                        if (lot.expiryDate != null) '${context.t('expiry')} ${feedDate(lot.expiryDate!)}',
                        if (lot.unitCost != null) '${feedMoney(lot.unitCost!)}/${lot.unit}',
                      ].join(' · '),
                      style: FarmTypography.textTheme.bodySmall,
                    ),
                  ]),
                ),
                Text('${feedNumber(lot.quantityOnHand)} ${lot.unit}', style: FarmTypography.textTheme.titleSmall),
                const SizedBox(width: 8),
                StatusPill(label: context.t('lotStatus_${lot.status}'), level: feedStatusLevel(lot.status), dense: true),
                if (canApprove)
                  PopupMenuButton<String>(
                    tooltip: lot.lotCode,
                    icon: const Icon(Icons.more_vert, size: 18, color: FarmColors.muted),
                    onSelected: (status) => _setStatus(context, lot, status),
                    itemBuilder: (_) => [
                      if (lot.status != 'quarantined') PopupMenuItem(value: 'quarantined', child: Text(context.t('quarantine'))),
                      if (lot.status != 'blocked') PopupMenuItem(value: 'blocked', child: Text(context.t('block'))),
                      if (lot.status != 'recalled') PopupMenuItem(value: 'recalled', child: Text(context.t('recall'))),
                      if (lot.status != 'active') PopupMenuItem(value: 'active', child: Text(context.t('release'))),
                    ],
                  ),
              ]),
            ),
        ],
      ),
    );
  }

  Future<void> _setStatus(BuildContext context, FeedLot lot, String status) async {
    final reason = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final c = TextEditingController();
        return AlertDialog(
          title: Text('${context.t('lotStatus_$status')} — ${lot.lotCode}'),
          content: TextField(controller: c, autofocus: true, decoration: InputDecoration(labelText: ctx.t('reasonPrompt'))),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text(ctx.t('cancel'))),
            FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: Text(ctx.t('save'))),
          ],
        );
      },
    );
    if (reason == null || !context.mounted) return;
    final result = await context.read<FeedingProvider>().setLotStatus(lot.id, status, reason: reason.isEmpty ? null : reason);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(result.success ? context.t('lotStatusUpdated') : (result.error ?? context.t('couldNotSave')))));
  }
}

// ------------------------------------------------------------- dialogs
Future<void> _showNewFeedDialog(BuildContext context) {
  return showDialog<void>(context: context, builder: (_) => const _NewFeedDialog());
}

class _NewFeedDialog extends StatefulWidget {
  const _NewFeedDialog();
  @override
  State<_NewFeedDialog> createState() => _NewFeedDialogState();
}

class _NewFeedDialogState extends State<_NewFeedDialog> {
  final _name = TextEditingController();
  final _nameAr = TextEditingController();
  final _cost = TextEditingController();
  final _opening = TextEditingController();
  final _supplier = TextEditingController();
  String _unit = 'kg';
  String _source = 'purchased';
  String _category = 'concentrate';
  bool _ingredient = true;
  bool _feedable = true;
  bool _saving = false;
  String? _error;

  static const _categories = ['forage', 'concentrate', 'premix', 'mineral', 'complete_feed', 'byproduct', 'other'];

  @override
  void dispose() {
    for (final c in [_name, _nameAr, _cost, _opening, _supplier]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    if (_name.text.trim().isEmpty) {
      setState(() => _error = context.t('nameRequired'));
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final result = await context.read<FeedingProvider>().createProduct({
      'name': _name.text.trim(),
      if (_nameAr.text.trim().isNotEmpty) 'name_ar': _nameAr.text.trim(),
      'unit': _unit,
      'source_type': _source,
      'is_ingredient': _ingredient,
      'is_feedable': _feedable,
      'category': _category,
      'unit_cost': double.tryParse(_cost.text),
      'opening_quantity': double.tryParse(_opening.text) ?? 0,
      if (_supplier.text.trim().isNotEmpty) 'supplier_label': _supplier.text.trim(),
    });
    if (!mounted) return;
    if (result.success) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.t('feedCreated'))));
      return;
    }
    setState(() {
      _saving = false;
      _error = result.error;
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(context.t('newFeed')),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: _name, autofocus: true, decoration: InputDecoration(labelText: context.t('feedName'))),
            const SizedBox(height: 10),
            TextField(controller: _nameAr, decoration: InputDecoration(labelText: '${context.t('feedName')} (AR)')),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  value: _source,
                  decoration: InputDecoration(labelText: context.t('sourceType')),
                  items: [
                    DropdownMenuItem(value: 'purchased', child: Text(context.t('purchasedFeed'))),
                    DropdownMenuItem(value: 'farm_produced', child: Text(context.t('farmProducedFeed'))),
                  ],
                  onChanged: (v) => setState(() => _source = v ?? _source),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: DropdownButtonFormField<String>(
                  value: _category,
                  decoration: InputDecoration(labelText: context.t('category')),
                  items: [for (final c in _categories) DropdownMenuItem(value: c, child: Text(context.t('feedCategory_$c')))],
                  onChanged: (v) => setState(() => _category = v ?? _category),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 90,
                child: DropdownButtonFormField<String>(
                  value: _unit,
                  decoration: const InputDecoration(labelText: 'Unit'),
                  items: const [
                    DropdownMenuItem(value: 'kg', child: Text('kg')),
                    DropdownMenuItem(value: 't', child: Text('t')),
                    DropdownMenuItem(value: 'l', child: Text('L')),
                    DropdownMenuItem(value: 'bale', child: Text('bale')),
                  ],
                  onChanged: (v) => setState(() => _unit = v ?? _unit),
                ),
              ),
            ]),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero, dense: true, controlAffinity: ListTileControlAffinity.leading,
              value: _ingredient, title: Text(context.t('ingredient')), subtitle: Text(context.t('ingredientHint')),
              onChanged: (v) => setState(() => _ingredient = v ?? false),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero, dense: true, controlAffinity: ListTileControlAffinity.leading,
              value: _feedable, title: Text(context.t('feedable')), subtitle: Text(context.t('feedableHint')),
              onChanged: (v) => setState(() => _feedable = v ?? false),
            ),
            Row(children: [
              Expanded(child: TextField(controller: _cost, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: context.t('unitCost')))),
              const SizedBox(width: 10),
              Expanded(child: TextField(controller: _opening, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: context.t('openingQuantity')))),
            ]),
            const SizedBox(height: 10),
            TextField(controller: _supplier, decoration: InputDecoration(labelText: context.t('supplier'))),
            if (_error != null) ...[const SizedBox(height: 8), Text(_error!, style: const TextStyle(color: FarmColors.danger, fontSize: 12.5))],
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(context.t('cancel'))),
        FilledButton(onPressed: _saving ? null : _submit, child: Text(context.t('save'))),
      ],
    );
  }
}

Future<void> _showReceiveDialog(BuildContext context, {String? productId}) {
  return showDialog<void>(context: context, builder: (_) => _ReceiveDialog(productId: productId));
}

class _ReceiveDialog extends StatefulWidget {
  const _ReceiveDialog({this.productId});
  final String? productId;
  @override
  State<_ReceiveDialog> createState() => _ReceiveDialogState();
}

class _ReceiveDialogState extends State<_ReceiveDialog> {
  String? _productId;
  final _qty = TextEditingController();
  final _rejected = TextEditingController(text: '0');
  final _ordered = TextEditingController();
  final _cost = TextEditingController();
  final _lotCode = TextEditingController();
  final _supplier = TextEditingController();
  final _reference = TextEditingController();
  DateTime? _expiry;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _productId = widget.productId;
  }

  @override
  void dispose() {
    for (final c in [_qty, _rejected, _ordered, _cost, _lotCode, _supplier, _reference]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    final qty = double.tryParse(_qty.text.trim());
    if (_productId == null || qty == null || qty <= 0) {
      setState(() => _error = context.t('valueMustBePositive'));
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final result = await context.read<FeedingProvider>().receiveLot({
      'feed_product_id': _productId,
      'quantity': qty,
      'rejected_quantity': double.tryParse(_rejected.text) ?? 0,
      'ordered_quantity': double.tryParse(_ordered.text),
      'unit_cost': double.tryParse(_cost.text),
      if (_lotCode.text.trim().isNotEmpty) 'lot_code': _lotCode.text.trim(),
      if (_supplier.text.trim().isNotEmpty) 'supplier_label': _supplier.text.trim(),
      if (_reference.text.trim().isNotEmpty) 'reference': _reference.text.trim(),
      'expiry_date': _expiry?.toIso8601String(),
    });
    if (!mounted) return;
    if (result.success) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.t('deliveryReceived'))));
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
    final products = feeding.products.where((p) => p.status == 'active').toList();
    return AlertDialog(
      title: Text(context.t('receiveDelivery')),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            DropdownButtonFormField<String>(
              value: products.any((p) => p.id == _productId) ? _productId : null,
              isExpanded: true,
              decoration: InputDecoration(labelText: context.t('feedItem')),
              items: [for (final p in products) DropdownMenuItem(value: p.id, child: Text(p.label(lang), overflow: TextOverflow.ellipsis))],
              onChanged: (v) => setState(() => _productId = v),
            ),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(child: TextField(controller: _ordered, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: context.t('ordered')))),
              const SizedBox(width: 10),
              Expanded(child: TextField(controller: _qty, autofocus: true, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: context.t('received')))),
              const SizedBox(width: 10),
              Expanded(child: TextField(controller: _rejected, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: context.t('rejected')))),
            ]),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(child: TextField(controller: _lotCode, decoration: InputDecoration(labelText: context.t('lotCode')))),
              const SizedBox(width: 10),
              Expanded(child: TextField(controller: _cost, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: context.t('unitCost')))),
            ]),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(child: TextField(controller: _supplier, decoration: InputDecoration(labelText: context.t('supplier')))),
              const SizedBox(width: 10),
              Expanded(child: TextField(controller: _reference, decoration: InputDecoration(labelText: context.t('reference')))),
            ]),
            const SizedBox(height: 10),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: OutlinedButton.icon(
                onPressed: () async {
                  final picked = await showDatePicker(context: context, initialDate: DateTime.now().add(const Duration(days: 90)), firstDate: DateTime.now(), lastDate: DateTime.now().add(const Duration(days: 1500)));
                  if (picked != null) setState(() => _expiry = picked);
                },
                icon: const Icon(Icons.event, size: 16),
                label: Text(_expiry == null ? context.t('expiry') : '${context.t('expiry')} ${feedDate(_expiry!)}'),
              ),
            ),
            if (_error != null) ...[const SizedBox(height: 8), Text(_error!, style: const TextStyle(color: FarmColors.danger, fontSize: 12.5))],
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(context.t('cancel'))),
        FilledButton(onPressed: _saving ? null : _submit, child: Text(context.t('save'))),
      ],
    );
  }
}

Future<void> _showReserveDialog(BuildContext context) {
  return showDialog<void>(context: context, builder: (_) => const _ReserveDialog());
}

class _ReserveDialog extends StatefulWidget {
  const _ReserveDialog();
  @override
  State<_ReserveDialog> createState() => _ReserveDialogState();
}

class _ReserveDialogState extends State<_ReserveDialog> {
  String? _productId;
  String? _programId;
  final _qty = TextEditingController();
  final _species = TextEditingController();
  final _purpose = TextEditingController();
  bool _transferable = false;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _qty.dispose();
    _species.dispose();
    _purpose.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final qty = double.tryParse(_qty.text.trim());
    if (_productId == null || qty == null || qty <= 0) {
      setState(() => _error = context.t('valueMustBePositive'));
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final result = await context.read<FeedingProvider>().createAllocation({
      'feed_product_id': _productId,
      'quantity': qty,
      if (_species.text.trim().isNotEmpty) 'species_code': _species.text.trim().toLowerCase().replaceAll(' ', '_'),
      if (_programId != null) 'feeding_program_id': _programId,
      if (_purpose.text.trim().isNotEmpty) 'purpose': _purpose.text.trim(),
      'transferable': _transferable,
    });
    if (!mounted) return;
    if (result.success) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.t('reservationCreated'))));
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
    return AlertDialog(
      title: Text(context.t('reserveStock')),
      content: SizedBox(
        width: 440,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          DropdownButtonFormField<String>(
            value: _productId,
            isExpanded: true,
            decoration: InputDecoration(labelText: context.t('feedItem')),
            items: [
              for (final p in feeding.products)
                DropdownMenuItem(value: p.id, child: Text('${p.label(lang)} — ${feedNumber(p.availability.available)} ${p.unit} ${context.t('available').toLowerCase()}', overflow: TextOverflow.ellipsis)),
            ],
            onChanged: (v) => setState(() => _productId = v),
          ),
          const SizedBox(height: 10),
          TextField(controller: _qty, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: context.t('quantity'))),
          const SizedBox(height: 10),
          TextField(controller: _species, decoration: InputDecoration(labelText: context.t('forSpecies'), hintText: 'cow, goat, layer_hen…')),
          const SizedBox(height: 10),
          DropdownButtonFormField<String?>(
            value: _programId,
            isExpanded: true,
            decoration: InputDecoration(labelText: context.t('feedingProgram')),
            items: [
              const DropdownMenuItem<String?>(value: null, child: Text('—')),
              for (final p in feeding.programs) DropdownMenuItem<String?>(value: p.id, child: Text(p.label(lang), overflow: TextOverflow.ellipsis)),
            ],
            onChanged: (v) => setState(() => _programId = v),
          ),
          const SizedBox(height: 10),
          TextField(controller: _purpose, decoration: InputDecoration(labelText: context.t('purpose'))),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero, dense: true, controlAffinity: ListTileControlAffinity.leading,
            value: _transferable, title: Text(context.t('transferable')),
            onChanged: (v) => setState(() => _transferable = v ?? false),
          ),
          if (_error != null) Text(_error!, style: const TextStyle(color: FarmColors.danger, fontSize: 12.5)),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(context.t('cancel'))),
        FilledButton(onPressed: _saving ? null : _submit, child: Text(context.t('save'))),
      ],
    );
  }
}
