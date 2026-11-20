import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/typography.dart';
import '../../core/util/number_input.dart';
import '../../core/widgets/form_dialog.dart';
import '../../core/widgets/status_pill.dart';
import '../../core/widgets/ux_blocks.dart';
import '../../domain/entities/approvals.dart';
import '../../providers/approvals_provider.dart';
import '../../providers/feeding_provider.dart';
import '../feed/purchase_and_mix_dialogs.dart';

/// Buying feed, for someone who is not the farm manager (v0.7.8): ask the
/// manager to buy it, see what they decided, and record the delivery of a
/// request they approved. Nothing here adds stock until a delivery is
/// recorded — the server refuses a delivery that has no approved request.
Future<void> showAskToBuyDialog(BuildContext context, {String? productId}) =>
    showDialog<void>(context: context, builder: (_) => _AskToBuyDialog(host: context, productId: productId));

class _AskToBuyDialog extends StatefulWidget {
  const _AskToBuyDialog({required this.host, this.productId});

  /// The page the dialog was opened from, to open the delivery form on.
  final BuildContext host;
  final String? productId;

  @override
  State<_AskToBuyDialog> createState() => _AskToBuyDialogState();
}

class _AskToBuyDialogState extends State<_AskToBuyDialog> {
  late String? _productId = widget.productId;
  final _qty = TextEditingController();
  final _note = TextEditingController();
  DateTime? _neededBy;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<ApprovalsProvider>().load();
    });
  }

  @override
  void dispose() {
    _qty.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final feeding = context.read<FeedingProvider>();
    final product = _productId == null ? null : feeding.productById(_productId!);
    final qty = parseLocalizedDouble(_qty.text);
    if (product == null) {
      setState(() => _error = context.t('fpChooseFeed'));
      return;
    }
    if (qty == null || qty <= 0) {
      setState(() => _error = context.t('valueMustBePositive'));
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final result = await context
        .read<ApprovalsProvider>()
        .askToBuyFeed(
          feedProductId: product.id,
          quantity: qty,
          unit: product.unit,
          inventoryItemId: product.inventoryItemId,
          itemName: product.label(Localizations.localeOf(context).languageCode),
          neededBy: _neededBy,
          note: _note.text,
        );
    if (!mounted) return;
    if (result.success) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.t(result.queued ? 'apSentOffline' : 'prSent'))));
      return;
    }
    setState(() {
      _saving = false;
      _error = result.error;
    });
  }

  Future<void> _pickNeededBy() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _neededBy ?? now.add(const Duration(days: 3)),
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: now.add(const Duration(days: 180)),
    );
    if (picked != null) setState(() => _neededBy = picked);
  }

  void _recordDelivery(PurchaseRequest r) {
    Navigator.pop(context);
    showRecordPurchaseDialog(widget.host, request: r);
  }

  @override
  Widget build(BuildContext context) {
    final feeding = context.watch<FeedingProvider>();
    final approvals = context.watch<ApprovalsProvider>();
    final lang = Localizations.localeOf(context).languageCode;
    final products = [for (final p in feeding.products) if (p.status == 'active') p]..sort((a, b) => a.label(lang).compareTo(b.label(lang)));
    final feedItems = {for (final p in feeding.products) p.inventoryItemId};
    bool isFeed(PurchaseRequest r) => r.lines.any((l) => feedItems.contains(l.inventoryItemId));
    final deliverable = [for (final r in approvals.deliverable) if (isFeed(r)) r];
    final mine = [for (final r in approvals.myPurchases) if (isFeed(r) && !r.deliverable) r];
    final product = _productId == null ? null : feeding.productById(_productId!);

    return FarmFormDialog(
      title: Text(context.t('prAskToBuy')),
      width: 560,
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (deliverable.isNotEmpty) ...[
          Text(context.t('prApprovedArrived'), style: FarmTypography.textTheme.titleSmall),
          const SizedBox(height: 6),
          for (final r in deliverable) ...[
            _RequestRow(
              request: r,
              trailing: FilledButton.tonal(
                key: ValueKey('deliver-${r.id}'),
                onPressed: () => _recordDelivery(r),
                child: Text(context.t('prRecordDelivery')),
              ),
            ),
            const SizedBox(height: 6),
          ],
          const SizedBox(height: 14),
        ],
        NoticeBanner(title: context.t('prBuyingIsManagers'), text: context.t('prBuyingIsManagersBody')),
        const SizedBox(height: 14),
        DropdownButtonFormField<String>(
          initialValue: products.any((p) => p.id == _productId) ? _productId : null,
          isExpanded: true,
          decoration: InputDecoration(labelText: context.t('prWhichFeed')),
          items: [for (final p in products) DropdownMenuItem(value: p.id, child: Text(p.label(lang), overflow: TextOverflow.ellipsis))],
          onChanged: (v) => setState(() => _productId = v),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _qty,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(labelText: context.t('prHowMuch'), suffixText: product?.unit ?? 'kg'),
        ),
        const SizedBox(height: 12),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: OutlinedButton.icon(
            onPressed: _pickNeededBy,
            icon: const Icon(Icons.event_outlined, size: 18),
            label: Text(_neededBy == null ? context.t('prNeededByOptional') : '${context.t('prNeededBy')}: ${_neededBy!.day}/${_neededBy!.month}/${_neededBy!.year}'),
          ),
        ),
        const SizedBox(height: 12),
        TextField(controller: _note, maxLines: 2, decoration: InputDecoration(labelText: context.t('prWhy'), hintText: context.t('prWhyHint'))),
        if (mine.isNotEmpty) ...[
          const SizedBox(height: 18),
          Text(context.t('apYourRequests'), style: FarmTypography.textTheme.titleSmall),
          const SizedBox(height: 6),
          for (final r in mine) ...[_RequestRow(request: r), const SizedBox(height: 6)],
        ],
        if (_error != null) ...[const SizedBox(height: 10), Text(_error!, style: const TextStyle(color: FarmColors.danger, fontSize: 12.5))],
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(context.t('cancel'))),
        FilledButton(
          onPressed: _saving ? null : _send,
          child: _saving
              ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : Text(context.t('apSendToManager')),
        ),
      ],
    );
  }
}

class _RequestRow extends StatelessWidget {
  const _RequestRow({required this.request, this.trailing});
  final PurchaseRequest request;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(color: FarmColors.card, borderRadius: BorderRadius.circular(10), border: Border.all(color: FarmColors.border)),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${request.number} · ${request.what}', style: FarmTypography.textTheme.titleSmall),
            if (request.decisionNote != null && request.decisionNote!.isNotEmpty)
              Text(request.decisionNote!, style: FarmTypography.textTheme.bodySmall, maxLines: 2, overflow: TextOverflow.ellipsis),
          ]),
        ),
        const SizedBox(width: 8),
        trailing ?? StatusPill(label: context.t('prStatus_${request.status}'), level: purchaseStatusLevel(request.status), dense: true),
      ]),
    );
  }
}

FarmStatusLevel purchaseStatusLevel(String status) => switch (status) {
      'approved' || 'ordered' || 'received' => FarmStatusLevel.good,
      'rejected' || 'cancelled' => FarmStatusLevel.alert,
      _ => FarmStatusLevel.watch,
    };
