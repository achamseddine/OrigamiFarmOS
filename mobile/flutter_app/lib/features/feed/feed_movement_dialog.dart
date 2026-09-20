import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/typography.dart';
import '../../providers/feed_provider.dart';

/// Which way stock moves: feed that arrived, or feed that was used up.
enum FeedMovementDirection { inbound, outbound }

/// One dialog for both directions, because to the person holding the
/// tablet they are the same job — "some feed moved, write it down" — and
/// the only difference is which button they came in through. The record
/// sheet opens it for *used*; the feed screen's "add feed" button and the
/// per-row menu open it for either, with the row's item already chosen.
Future<void> showFeedMovementDialog(
  BuildContext context, {
  required FeedMovementDirection direction,
  String? itemId,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => FeedMovementDialog(direction: direction, itemId: itemId),
  );
}

class FeedMovementDialog extends StatefulWidget {
  const FeedMovementDialog({super.key, required this.direction, this.itemId});

  final FeedMovementDirection direction;

  /// Preselects an item — the row whose menu was tapped.
  final String? itemId;

  @override
  State<FeedMovementDialog> createState() => _FeedMovementDialogState();
}

class _FeedMovementDialogState extends State<FeedMovementDialog> {
  String? _itemId;
  String _reason = 'feeding';
  final _quantity = TextEditingController();
  bool _saving = false;
  String? _error;

  bool get _inbound => widget.direction == FeedMovementDirection.inbound;

  @override
  void initState() {
    super.initState();
    _itemId = widget.itemId;
  }

  @override
  void dispose() {
    _quantity.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final items = context.watch<FeedProvider>().items;
    final title = context.t(_inbound ? 'recordPurchase' : 'recordDistribution');
    if (items.isEmpty) {
      return AlertDialog(
        title: Text(title),
        content: Text(context.t('noFeedItems'), style: FarmTypography.textTheme.bodyMedium),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(context.t('close'))),
        ],
      );
    }
    final selected = items.any((i) => i.id == _itemId) ? _itemId! : items.first.id;
    final selectedItem = items.firstWhere((i) => i.id == selected);

    return AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DropdownButtonFormField<String>(
              value: selected,
              decoration: InputDecoration(labelText: context.t('feedItem')),
              items: [
                for (final item in items)
                  DropdownMenuItem(
                    value: item.id,
                    child: Text('${item.name} — ${item.currentQty.toStringAsFixed(0)} ${item.unit}'),
                  ),
              ],
              onChanged: (v) => setState(() => _itemId = v ?? selected),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _quantity,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(labelText: '${context.t('quantity')} (${selectedItem.unit})'),
            ),
            if (!_inbound) ...[
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: _reason,
                decoration: InputDecoration(labelText: context.t('reason')),
                items: [
                  DropdownMenuItem(value: 'feeding', child: Text(context.t('reasonFeeding'))),
                  DropdownMenuItem(value: 'waste', child: Text(context.t('reasonWaste'))),
                  DropdownMenuItem(value: 'transfer', child: Text(context.t('reasonTransfer'))),
                ],
                onChanged: (v) => setState(() => _reason = v ?? _reason),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: const TextStyle(color: FarmColors.danger, fontSize: 12)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(context.t('cancel'))),
        FilledButton(
          onPressed: _saving ? null : () => _submit(selected),
          child: _saving
              ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : Text(context.t('save')),
        ),
      ],
    );
  }

  Future<void> _submit(String itemId) async {
    final quantity = double.tryParse(_quantity.text.trim());
    if (quantity == null || quantity <= 0) {
      setState(() => _error = context.t('valueMustBePositive'));
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final feed = context.read<FeedProvider>();
    final result = _inbound
        ? await feed.recordPurchase(itemId: itemId, quantityKg: quantity)
        : await feed.recordDistribution(itemId: itemId, quantityKg: quantity, reason: _reason);
    if (!mounted) return;
    if (result.success) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.t('saved'))));
    } else {
      setState(() {
        _saving = false;
        _error = result.error;
      });
    }
  }
}
