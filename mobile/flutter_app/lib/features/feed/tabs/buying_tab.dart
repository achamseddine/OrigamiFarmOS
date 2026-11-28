import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../api/api_client.dart' show WriteResult;
import '../../../core/i18n/strings.dart';
import '../../../core/theme/colors.dart';
import '../../../core/theme/spacing.dart';
import '../../../core/theme/typography.dart';
import '../../../core/util/number_input.dart';
import '../../../core/widgets/form_dialog.dart';
import '../../../core/widgets/section_card.dart';
import '../../../core/widgets/status_pill.dart';
import '../../../domain/entities/feeding.dart';
import '../../../domain/entities/purchase_orders.dart';
import '../../../providers/access_provider.dart';
import '../../../providers/feeding_provider.dart';
import '../../../providers/purchase_orders_provider.dart';
import '../../health/pharmacy_tab.dart' show askReason;
import '../feed_workspace_screen.dart';

/// Buying feed (master prompt Package 2): who sells each ingredient for how
/// much, the orders placed with them, the deliveries received against an
/// order — accepted and rejected — and each order's match: ordered,
/// received, accepted, billed, paid and owed. The same screen on the
/// tablet and in the browser; the server decides who may do what.
class BuyingTab extends StatefulWidget {
  const BuyingTab({super.key});

  @override
  State<BuyingTab> createState() => _BuyingTabState();
}

class _BuyingTabState extends State<BuyingTab> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<PurchaseOrdersProvider>().load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final orders = context.watch<PurchaseOrdersProvider>();
    final access = context.watch<AccessProvider>();
    return FeedTabScaffold(children: [
      SectionCard(
        key: const ValueKey('purchase-orders-card'),
        title: context.t('poTitle'),
        subtitle: context.t('poSubtitle'),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (access.canAskToBuyFeed || access.canBuyFeed)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: FilledButton.icon(
                key: const ValueKey('po-new'),
                onPressed: () => showNewOrderDialog(context),
                icon: const Icon(Icons.add_shopping_cart, size: 16),
                label: Text(context.t('poNew')),
              ),
            ),
          const SizedBox(height: 10),
          if (orders.orders.isEmpty)
            Text(context.t('poNone'), style: FarmTypography.textTheme.bodySmall)
          else
            for (final o in orders.orders.take(30)) _OrderRow(order: o),
        ]),
      ),
      const SizedBox(height: FarmSpacing.md),
      const _QuotesCard(),
    ]);
  }
}

String _qty(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);
String _money(double v, String currency) => currency == 'LBP' ? '${v.toStringAsFixed(0)} LBP' : '\$${v.toStringAsFixed(2)}';

(String, FarmStatusLevel) _statusOf(BuildContext context, String status) => switch (status) {
      'draft' => (context.t('poDraft'), FarmStatusLevel.neutral),
      'approved' => (context.t('poApproved'), FarmStatusLevel.info),
      'partially_received' => (context.t('poPartly'), FarmStatusLevel.watch),
      'received' => (context.t('poReceived'), FarmStatusLevel.good),
      'closed' => (context.t('poClosed'), FarmStatusLevel.neutral),
      'cancelled' => (context.t('poCancelled'), FarmStatusLevel.neutral),
      _ => (status, FarmStatusLevel.neutral),
    };

class _OrderRow extends StatelessWidget {
  const _OrderRow({required this.order});
  final PurchaseOrder order;

  Future<void> _say(BuildContext context, WriteResult r, String ok) async {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(r.success ? context.t(r.queued ? 'workingOffline' : ok) : (r.error ?? context.t('couldNotSave')))));
    if (r.success && !r.queued) await context.read<FeedingProvider>().load();
  }

  @override
  Widget build(BuildContext context) {
    final o = order;
    final access = context.watch<AccessProvider>();
    final provider = context.read<PurchaseOrdersProvider>();
    final (label, level) = _statusOf(context, o.status);
    return Container(
      key: ValueKey('po-${o.id}'),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      decoration: BoxDecoration(color: FarmColors.stone, borderRadius: BorderRadius.circular(10), border: Border.all(color: FarmColors.border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(child: Text('${o.poNo} · ${o.supplierName}', style: FarmTypography.textTheme.titleSmall)),
          StatusPill(label: label, level: level, dense: true),
        ]),
        for (final l in o.lines)
          Text(
            '${l.name}: ${_qty(l.orderedQuantity)} ${l.unit} × ${_money(l.unitPrice, o.currency)}'
            '${l.receivedQuantity > 0 ? ' · ${context.t('poReceivedQty').replaceAll('{qty}', '${_qty(l.receivedQuantity)} ${l.unit}')}' : ''}'
            '${l.rejectedQuantity > 0 ? ' · ${context.t('poRejectedQty').replaceAll('{qty}', '${_qty(l.rejectedQuantity)} ${l.unit}')}' : ''}'
            '${o.isOpen && l.remainingQuantity > 0 ? ' · ${context.t('poToCome').replaceAll('{qty}', '${_qty(l.remainingQuantity)} ${l.unit}')}' : ''}',
            style: FarmTypography.textTheme.bodySmall,
          ),
        Text('${context.t('poTotal')} ${_money(o.totalAmount, o.currency)} · ${context.t(o.paymentTerms == 'paid' ? 'poPaidOnDelivery' : 'poOnCredit')}',
            style: const TextStyle(fontSize: 12, color: FarmColors.muted)),
        Wrap(spacing: 8, children: [
          if (o.isDraft && access.canBuyFeed)
            FilledButton.tonal(
              key: ValueKey('po-approve-${o.id}'),
              onPressed: () async => _say(context, await provider.approve(o), 'poPlaced'),
              child: Text(context.t('poApprove')),
            ),
          if (o.isOpen && (access.canAskToBuyFeed || access.canBuyFeed))
            FilledButton.tonal(
              key: ValueKey('po-receive-${o.id}'),
              onPressed: () => showReceiveOrderDialog(context, o),
              child: Text(context.t('poReceive')),
            ),
          if (!o.pending)
            TextButton(key: ValueKey('po-match-${o.id}'), onPressed: () => showOrderMatchDialog(context, o), child: Text(context.t('poMatch'))),
          if (o.isOpen && o.anythingReceived && access.canBuyFeed)
            TextButton(
              key: ValueKey('po-close-${o.id}'),
              onPressed: () async {
                final why = await askReason(context, title: context.t('poClose'), label: context.t('poCloseWhy'));
                if (why == null || !context.mounted) return;
                await _say(context, await provider.close(o, why), 'poClosedDone');
              },
              child: Text(context.t('poClose')),
            ),
          if ((o.isDraft || (o.isOpen && !o.anythingReceived)) && (access.canBuyFeed || o.isDraft))
            TextButton(
              key: ValueKey('po-cancel-${o.id}'),
              onPressed: () async {
                final why = await askReason(context, title: context.t('poCancel'), label: context.t('poCancelWhy'));
                if (why == null || !context.mounted) return;
                await _say(context, await provider.cancel(o, why), 'poCancelledDone');
              },
              child: Text(context.t('poCancel')),
            ),
        ]),
      ]),
    );
  }
}

/// The purchasable feeds: bought in, not mixed or grown on the farm.
List<FeedProduct> _buyable(FeedingProvider feeding) => [for (final p in feeding.products) if (p.sourceType == 'purchased') p];

// ------------------------------------------------------------ new order
Future<void> showNewOrderDialog(BuildContext context) =>
    showDialog<void>(context: context, builder: (_) => const _NewOrderDialog());

class _NewOrderDialog extends StatefulWidget {
  const _NewOrderDialog();

  @override
  State<_NewOrderDialog> createState() => _NewOrderDialogState();
}

class _NewOrderDialogState extends State<_NewOrderDialog> {
  String? _productId;
  String? _supplierId;
  final _newSupplier = TextEditingController();
  final _quantity = TextEditingController();
  final _price = TextEditingController();
  String _currency = 'USD';
  final _rate = TextEditingController();
  String _terms = 'credit';
  List<SupplierQuote> _quotes = const [];
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_newSupplier, _quantity, _price, _rate]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pickProduct(String? id) async {
    setState(() {
      _productId = id;
      _quotes = const [];
    });
    if (id == null) return;
    final quotes = await context.read<PurchaseOrdersProvider>().quotes(id);
    if (!mounted) return;
    setState(() => _quotes = quotes);
    if (quotes.isNotEmpty && _supplierId == null) _pickQuote(quotes.first);
  }

  void _pickQuote(SupplierQuote q) => setState(() {
        _supplierId = q.supplierId;
        _currency = q.currency;
        if (q.unitPrice != null) _price.text = q.unitPrice!.toString();
      });

  Future<void> _save({required bool place}) async {
    final feeding = context.read<FeedingProvider>();
    final product = _productId == null ? null : feeding.productById(_productId!);
    final qty = parseLocalizedDouble(_quantity.text.trim());
    final price = _price.text.trim().isEmpty ? null : parseLocalizedDouble(_price.text.trim());
    final rate = _rate.text.trim().isEmpty ? null : parseLocalizedDouble(_rate.text.trim());
    if (product == null || qty == null || qty <= 0 || (_supplierId == null && _newSupplier.text.trim().isEmpty) || (price != null && price < 0)) {
      setState(() => _error = context.t('poFormIncomplete'));
      return;
    }
    if (_currency == 'LBP' && (rate == null || rate <= 0)) {
      setState(() => _error = context.t('poRateNeeded'));
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final r = await context.read<PurchaseOrdersProvider>().createOrder(
          supplierId: _supplierId,
          supplierName: _supplierId == null ? _newSupplier.text : null,
          feedProductId: product.id,
          quantity: qty,
          unit: product.unit,
          unitPrice: price,
          currency: _currency,
          exchangeRate: _currency == 'LBP' ? rate : null,
          paymentTerms: _terms,
          approve: place,
        );
    if (!mounted) return;
    if (!r.success) {
      setState(() {
        _saving = false;
        _error = r.error;
      });
      return;
    }
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.t(r.queued ? 'workingOffline' : (place ? 'poPlaced' : 'poDrafted')))));
  }

  @override
  Widget build(BuildContext context) {
    final feeding = context.watch<FeedingProvider>();
    final orders = context.watch<PurchaseOrdersProvider>();
    final access = context.watch<AccessProvider>();
    final lang = Localizations.localeOf(context).languageCode;
    final product = _productId == null ? null : feeding.productById(_productId!);
    final suppliers = {for (final s in orders.suppliers) s.id: s.name, for (final q in _quotes) q.supplierId: q.supplierName};
    return FarmFormDialog(
      title: Text(context.t('poNew')),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        DropdownButtonFormField<String>(
          key: const ValueKey('po-feed'),
          isExpanded: true,
          value: _productId,
          decoration: InputDecoration(labelText: context.t('poFeed')),
          items: [for (final p in _buyable(feeding)) DropdownMenuItem(value: p.id, child: Text(p.label(lang)))],
          onChanged: _pickProduct,
        ),
        if (_quotes.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text(context.t('poQuotes'), style: FarmTypography.textTheme.titleSmall),
          for (final q in _quotes)
            InkWell(
              key: ValueKey('po-quote-${q.supplierId}'),
              onTap: () => _pickQuote(q),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(children: [
                  Icon(_supplierId == q.supplierId ? Icons.radio_button_checked : Icons.radio_button_unchecked, size: 18, color: FarmColors.cedar),
                  const SizedBox(width: 8),
                  Expanded(
                      child: Text('${q.supplierName} — ${q.unitPrice == null ? '—' : '${_money(q.unitPrice!, q.currency)}/${q.purchaseUom}'}'
                          '${q.lastDeliveryUsd != null ? ' · ${context.t('poLastDelivery')} \$${q.lastDeliveryUsd!.toStringAsFixed(3)}' : ''}')),
                ]),
              ),
            ),
        ],
        const SizedBox(height: 10),
        DropdownButtonFormField<String?>(
          key: const ValueKey('po-supplier'),
          isExpanded: true,
          value: suppliers.containsKey(_supplierId) ? _supplierId : null,
          decoration: InputDecoration(labelText: context.t('poSupplier')),
          items: [
            for (final e in suppliers.entries) DropdownMenuItem<String?>(value: e.key, child: Text(e.value)),
            DropdownMenuItem<String?>(value: null, child: Text(context.t('poNewSupplier'))),
          ],
          onChanged: (v) => setState(() => _supplierId = v),
        ),
        if (_supplierId == null)
          TextField(key: const ValueKey('po-supplier-name'), controller: _newSupplier, decoration: InputDecoration(labelText: context.t('poSupplierName'))),
        const SizedBox(height: 10),
        TextField(
          key: const ValueKey('po-quantity'),
          controller: _quantity,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(labelText: '${context.t('poQuantity')}${product == null ? '' : ' (${product.unit})'}'),
        ),
        Row(children: [
          Expanded(
            child: TextField(
              key: const ValueKey('po-price'),
              controller: _price,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(labelText: '${context.t('poPrice')}${product == null ? '' : ' / ${product.unit}'}', helperText: context.t('poPriceHelp')),
            ),
          ),
          const SizedBox(width: 10),
          DropdownButton<String>(
            key: const ValueKey('po-currency'),
            value: _currency,
            items: const [DropdownMenuItem(value: 'USD', child: Text('USD')), DropdownMenuItem(value: 'LBP', child: Text('LBP'))],
            onChanged: (v) => setState(() => _currency = v ?? _currency),
          ),
        ]),
        if (_currency == 'LBP')
          TextField(
            key: const ValueKey('po-rate'),
            controller: _rate,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(labelText: context.t('poRate')),
          ),
        const SizedBox(height: 10),
        DropdownButtonFormField<String>(
          key: const ValueKey('po-terms'),
          value: _terms,
          decoration: InputDecoration(labelText: context.t('poTerms')),
          items: [
            DropdownMenuItem(value: 'credit', child: Text(context.t('poOnCredit'))),
            DropdownMenuItem(value: 'paid', child: Text(context.t('poPaidOnDelivery'))),
          ],
          onChanged: (v) => setState(() => _terms = v ?? _terms),
        ),
        if (!access.canBuyFeed)
          Padding(padding: const EdgeInsets.only(top: 8), child: Text(context.t('poDraftForManager'), style: FarmTypography.textTheme.bodySmall)),
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: const TextStyle(color: FarmColors.danger))),
      ]),
      actions: [
        TextButton(onPressed: _saving ? null : () => Navigator.of(context).pop(), child: Text(context.t('cancel'))),
        OutlinedButton(key: const ValueKey('po-save-draft'), onPressed: _saving ? null : () => _save(place: false), child: Text(context.t('poSaveDraft'))),
        if (access.canBuyFeed)
          FilledButton(key: const ValueKey('po-place'), onPressed: _saving ? null : () => _save(place: true), child: Text(context.t('poPlace'))),
      ],
    );
  }
}

// --------------------------------------------------------------- receive
Future<void> showReceiveOrderDialog(BuildContext context, PurchaseOrder order) =>
    showDialog<void>(context: context, builder: (_) => _ReceiveDialog(order: order));

class _ReceiveDialog extends StatefulWidget {
  const _ReceiveDialog({required this.order});
  final PurchaseOrder order;

  @override
  State<_ReceiveDialog> createState() => _ReceiveDialogState();
}

class _ReceiveDialogState extends State<_ReceiveDialog> {
  late final _received = {for (final l in widget.order.lines) l.id: TextEditingController(text: l.remainingQuantity > 0 ? _qty(l.remainingQuantity) : '')};
  late final _rejected = {for (final l in widget.order.lines) l.id: TextEditingController()};
  late final _reason = {for (final l in widget.order.lines) l.id: TextEditingController()};
  late final _quality = {for (final l in widget.order.lines) l.id: 'good'};
  final _note = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [..._received.values, ..._rejected.values, ..._reason.values, _note]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final lines = <({String lineId, double received, double rejected, String? reason, String quality})>[];
    for (final l in widget.order.lines) {
      final got = _received[l.id]!.text.trim();
      if (got.isEmpty) continue;
      final received = parseLocalizedDouble(got);
      final rejected = _rejected[l.id]!.text.trim().isEmpty ? 0.0 : parseLocalizedDouble(_rejected[l.id]!.text.trim());
      if (received == null || received < 0 || rejected == null || rejected < 0 || rejected > received) {
        setState(() => _error = context.t('poReceiveInvalid'));
        return;
      }
      if (rejected > 0 && _reason[l.id]!.text.trim().isEmpty) {
        setState(() => _error = context.t('poRejectWhy'));
        return;
      }
      lines.add((lineId: l.id, received: received, rejected: rejected, reason: _reason[l.id]!.text, quality: _quality[l.id]!));
    }
    if (lines.isEmpty) {
      setState(() => _error = context.t('poReceiveInvalid'));
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final r = await context.read<PurchaseOrdersProvider>().receive(widget.order, lines: lines, deliveryNote: _note.text);
    if (!mounted) return;
    if (!r.success) {
      setState(() {
        _saving = false;
        _error = r.error;
      });
      return;
    }
    if (!r.queued) await context.read<FeedingProvider>().load();
    if (!mounted) return;
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.t(r.queued ? 'workingOffline' : 'poReceivedDone'))));
  }

  @override
  Widget build(BuildContext context) {
    final o = widget.order;
    return FarmFormDialog(
      title: Text('${context.t('poReceive')} — ${o.poNo} · ${o.supplierName}'),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final l in o.lines) ...[
          Text('${l.name}: ${context.t('poToCome').replaceAll('{qty}', '${_qty(l.remainingQuantity)} ${l.unit}')}', style: FarmTypography.textTheme.titleSmall),
          Row(children: [
            Expanded(
              child: TextField(
                key: ValueKey('po-received-${l.id}'),
                controller: _received[l.id],
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(labelText: '${context.t('poCame')} (${l.unit})'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                key: ValueKey('po-rejected-${l.id}'),
                controller: _rejected[l.id],
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(labelText: '${context.t('poRejected')} (${l.unit})'),
              ),
            ),
          ]),
          TextField(key: ValueKey('po-reason-${l.id}'), controller: _reason[l.id], decoration: InputDecoration(labelText: context.t('poRejectReason'))),
          DropdownButtonFormField<String>(
            key: ValueKey('po-quality-${l.id}'),
            value: _quality[l.id],
            decoration: InputDecoration(labelText: context.t('poQuality')),
            items: [
              DropdownMenuItem(value: 'good', child: Text(context.t('poQualityGood'))),
              DropdownMenuItem(value: 'fair', child: Text(context.t('poQualityFair'))),
              DropdownMenuItem(value: 'poor', child: Text(context.t('poQualityPoor'))),
            ],
            onChanged: (v) => setState(() => _quality[l.id] = v ?? 'good'),
          ),
          const SizedBox(height: 12),
        ],
        TextField(key: const ValueKey('po-delivery-note'), controller: _note, decoration: InputDecoration(labelText: context.t('poDeliveryNote'))),
        Padding(padding: const EdgeInsets.only(top: 8), child: Text(context.t('poReceiveNote'), style: FarmTypography.textTheme.bodySmall)),
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: const TextStyle(color: FarmColors.danger))),
      ]),
      actions: [
        TextButton(onPressed: _saving ? null : () => Navigator.of(context).pop(), child: Text(context.t('cancel'))),
        FilledButton(key: const ValueKey('po-receive-save'), onPressed: _saving ? null : _save, child: Text(context.t('save'))),
      ],
    );
  }
}

// ----------------------------------------------------------------- match
Future<void> showOrderMatchDialog(BuildContext context, PurchaseOrder order) =>
    showDialog<void>(context: context, builder: (_) => _MatchDialog(order: order));

class _MatchDialog extends StatelessWidget {
  const _MatchDialog({required this.order});
  final PurchaseOrder order;

  @override
  Widget build(BuildContext context) {
    return FarmFormDialog(
      title: Text('${context.t('poMatch')} — ${order.poNo}'),
      content: FutureBuilder<OrderMatch?>(
        future: context.read<PurchaseOrdersProvider>().match(order.id),
        builder: (context, snap) {
          final m = snap.data;
          if (snap.connectionState != ConnectionState.done) return const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator()));
          if (m == null) return Text(context.t('poMatchUnavailable'));
          String money(String k) => _money(m.totals[k] ?? 0, m.currency);
          return Column(key: const ValueKey('po-match-body'), mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(context.t('poState_${m.state}'), style: FarmTypography.textTheme.titleSmall),
            const SizedBox(height: 8),
            for (final l in m.lines)
              Text(
                '${l['name']}: ${context.t('poOrderedQty').replaceAll('{qty}', '${_qty((l['ordered'] as num).toDouble())} ${l['unit']}')} · '
                '${context.t('poReceivedQty').replaceAll('{qty}', _qty((l['received'] as num).toDouble()))} · '
                '${context.t('poAcceptedQty').replaceAll('{qty}', _qty((l['accepted'] as num).toDouble()))} · '
                '${context.t('poRejectedQty').replaceAll('{qty}', _qty((l['rejected'] as num).toDouble()))}',
                style: FarmTypography.textTheme.bodySmall,
              ),
            const Divider(height: 20),
            _MatchFigure(label: context.t('poOrderedValue'), value: money('ordered_value')),
            _MatchFigure(label: context.t('poAcceptedValue'), value: money('accepted_value')),
            _MatchFigure(label: context.t('poBilled'), value: money('billed')),
            _MatchFigure(label: context.t('poPaid'), value: money('paid')),
            _MatchFigure(key: const ValueKey('po-match-owed'), label: context.t('poOwed'), value: money('owed'), strong: true),
            for (final p in m.problems)
              Padding(padding: const EdgeInsets.only(top: 6), child: Text(p, style: const TextStyle(color: FarmColors.danger, fontSize: 12))),
          ]);
        },
      ),
      actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(context.t('close')))],
    );
  }
}

class _MatchFigure extends StatelessWidget {
  const _MatchFigure({super.key, required this.label, required this.value, this.strong = false});
  final String label;
  final String value;
  final bool strong;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [
          Expanded(child: Text(label)),
          Text(value, style: strong ? FarmTypography.textTheme.titleSmall : null),
        ]),
      );
}

// ---------------------------------------------------------------- quotes
class _QuotesCard extends StatefulWidget {
  const _QuotesCard();

  @override
  State<_QuotesCard> createState() => _QuotesCardState();
}

class _QuotesCardState extends State<_QuotesCard> {
  String? _productId;
  Future<List<SupplierQuote>>? _quotes;

  void _load(String? id) => setState(() {
        _productId = id;
        _quotes = id == null ? null : context.read<PurchaseOrdersProvider>().quotes(id);
      });

  Future<void> _setPrice() async {
    final feeding = context.read<FeedingProvider>();
    final product = _productId == null ? null : feeding.productById(_productId!);
    if (product == null) return;
    final result = await showDialog<({String? supplierId, String? supplierName, double price, String currency})>(
      context: context,
      builder: (_) => _QuoteDialog(product: product),
    );
    if (result == null || !mounted) return;
    final r = await context.read<PurchaseOrdersProvider>().setQuote(
        supplierId: result.supplierId, supplierName: result.supplierName, feedProductId: product.id, unitPrice: result.price, currency: result.currency, unit: product.unit);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(r.success ? context.t(r.queued ? 'workingOffline' : 'saved') : (r.error ?? context.t('couldNotSave')))));
    _load(product.id);
  }

  @override
  Widget build(BuildContext context) {
    final feeding = context.watch<FeedingProvider>();
    final access = context.watch<AccessProvider>();
    final lang = Localizations.localeOf(context).languageCode;
    return SectionCard(
      key: const ValueKey('supplier-quotes-card'),
      title: context.t('poQuotesTitle'),
      subtitle: context.t('poQuotesSubtitle'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        DropdownButtonFormField<String>(
          key: const ValueKey('quotes-feed'),
          isExpanded: true,
          value: _productId,
          decoration: InputDecoration(labelText: context.t('poFeed')),
          items: [for (final p in _buyable(feeding)) DropdownMenuItem(value: p.id, child: Text(p.label(lang)))],
          onChanged: _load,
        ),
        if (_quotes != null)
          FutureBuilder<List<SupplierQuote>>(
            future: _quotes,
            builder: (context, snap) {
              final quotes = snap.data ?? const <SupplierQuote>[];
              if (snap.connectionState != ConnectionState.done) return const LinearProgressIndicator();
              return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                if (quotes.isEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Text(context.t('poNoQuotes'), style: FarmTypography.textTheme.bodySmall)),
                for (var i = 0; i < quotes.length; i++)
                  Padding(
                    key: ValueKey('quote-row-${quotes[i].supplierId}'),
                    padding: const EdgeInsets.only(top: 6),
                    child: Row(children: [
                      Expanded(child: Text(quotes[i].supplierName)),
                      if (i == 0 && quotes.length > 1) StatusPill(label: context.t('poCheapest'), level: FarmStatusLevel.good, dense: true),
                      const SizedBox(width: 8),
                      Text(quotes[i].unitPrice == null ? '—' : '${_money(quotes[i].unitPrice!, quotes[i].currency)}/${quotes[i].purchaseUom}'),
                    ]),
                  ),
              ]);
            },
          ),
        if (access.canBuyFeed && _productId != null)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(key: const ValueKey('quote-set'), onPressed: _setPrice, icon: const Icon(Icons.sell_outlined, size: 16), label: Text(context.t('poSetPrice'))),
          ),
      ]),
    );
  }
}

class _QuoteDialog extends StatefulWidget {
  const _QuoteDialog({required this.product});
  final FeedProduct product;

  @override
  State<_QuoteDialog> createState() => _QuoteDialogState();
}

class _QuoteDialogState extends State<_QuoteDialog> {
  String? _supplierId;
  final _name = TextEditingController();
  final _price = TextEditingController();
  String _currency = 'USD';
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _price.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final suppliers = context.watch<PurchaseOrdersProvider>().suppliers;
    return AlertDialog(
      title: Text(context.t('poSetPrice')),
      content: SizedBox(
        width: 380,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          DropdownButtonFormField<String?>(
            key: const ValueKey('quote-supplier'),
            isExpanded: true,
            value: _supplierId,
            decoration: InputDecoration(labelText: context.t('poSupplier')),
            items: [
              for (final s in suppliers) DropdownMenuItem<String?>(value: s.id, child: Text(s.name)),
              DropdownMenuItem<String?>(value: null, child: Text(context.t('poNewSupplier'))),
            ],
            onChanged: (v) => setState(() => _supplierId = v),
          ),
          if (_supplierId == null) TextField(key: const ValueKey('quote-supplier-name'), controller: _name, decoration: InputDecoration(labelText: context.t('poSupplierName'))),
          Row(children: [
            Expanded(
              child: TextField(
                key: const ValueKey('quote-price'),
                controller: _price,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(labelText: '${context.t('poPrice')} / ${widget.product.unit}'),
              ),
            ),
            const SizedBox(width: 10),
            DropdownButton<String>(
              value: _currency,
              items: const [DropdownMenuItem(value: 'USD', child: Text('USD')), DropdownMenuItem(value: 'LBP', child: Text('LBP'))],
              onChanged: (v) => setState(() => _currency = v ?? _currency),
            ),
          ]),
          if (_error != null) Text(_error!, style: const TextStyle(color: FarmColors.danger)),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(context.t('cancel'))),
        FilledButton(
          key: const ValueKey('quote-save'),
          onPressed: () {
            final price = parseLocalizedDouble(_price.text.trim());
            if (price == null || price < 0 || (_supplierId == null && _name.text.trim().isEmpty)) {
              setState(() => _error = context.t('poFormIncomplete'));
              return;
            }
            Navigator.of(context).pop((supplierId: _supplierId, supplierName: _supplierId == null ? _name.text.trim() : null, price: price, currency: _currency));
          },
          child: Text(context.t('save')),
        ),
      ],
    );
  }
}
