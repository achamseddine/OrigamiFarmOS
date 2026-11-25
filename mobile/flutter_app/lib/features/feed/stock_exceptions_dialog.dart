import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/typography.dart';
import '../../core/widgets/form_dialog.dart';
import '../../core/widgets/status_pill.dart';
import '../../core/widgets/ux_blocks.dart';
import '../../domain/entities/feeding.dart';
import '../../providers/feed_provider.dart';
import '../../providers/feeding_provider.dart';
import 'feed_stock_dialogs.dart' show showStockCountDialog;
import 'feed_workspace_screen.dart' show feedDate, feedNumber;

/// Feed issued with no lot (v0.8.4). Each line is an approved override:
/// how much, when, who recorded and who approved it, and why. Until it is
/// reconciled it is not available. The manager says where the feed came
/// from (a lot entered later gives the kilos up now), confirms the stock
/// was there unrecorded, or counts the stock — a count settles them all.
/// The server keeps every answer with the exception; nothing is edited.
Future<void> showStockExceptionsDialog(BuildContext context, FeedProduct product) =>
    showDialog<void>(context: context, builder: (_) => _StockExceptionsDialog(product: product));

class _StockExceptionsDialog extends StatefulWidget {
  const _StockExceptionsDialog({required this.product});
  final FeedProduct product;

  @override
  State<_StockExceptionsDialog> createState() => _StockExceptionsDialogState();
}

class _StockExceptionsDialogState extends State<_StockExceptionsDialog> {
  List<FeedStockException>? _open;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final rows = await context.read<FeedingProvider>().loadStockExceptions(productId: widget.product.id, status: 'open');
    if (mounted) setState(() => _open = rows);
  }

  @override
  Widget build(BuildContext context) {
    final lang = Localizations.localeOf(context).languageCode;
    final open = _open;
    return FarmFormDialog(
      title: Text('${context.t('sxTitle')} — ${widget.product.label(lang)}'),
      width: 560,
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(context.t('sxIntro'), style: FarmTypography.textTheme.bodySmall),
        const SizedBox(height: 12),
        if (open == null)
          const Center(child: Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator(strokeWidth: 2)))
        else if (open.isEmpty)
          Text(context.t('sxNone'), key: const ValueKey('sx-none'), style: FarmTypography.textTheme.bodyMedium)
        else
          for (final e in open) ...[
            _ExceptionTile(key: ValueKey('sx-${e.id}'), exception: e, product: widget.product, onDone: _load),
            const SizedBox(height: 8),
          ],
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(context.t('close'))),
        OutlinedButton.icon(
          key: const ValueKey('sx-count'),
          onPressed: () {
            Navigator.pop(context);
            showStockCountDialog(context, productId: widget.product.id);
          },
          icon: const Icon(Icons.fact_check_outlined, size: 16),
          label: Text(context.t('sxCountInstead')),
        ),
      ],
    );
  }
}

class _ExceptionTile extends StatefulWidget {
  const _ExceptionTile({super.key, required this.exception, required this.product, required this.onDone});
  final FeedStockException exception;
  final FeedProduct product;
  final Future<void> Function() onDone;

  @override
  State<_ExceptionTile> createState() => _ExceptionTileState();
}

class _ExceptionTileState extends State<_ExceptionTile> {
  String _mode = 'assigned_to_lot';
  String? _lotId;
  final _note = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_mode == 'assigned_to_lot' && _lotId == null) {
      setState(() => _error = context.t('sxLotNeeded'));
      return;
    }
    if (_note.text.trim().isEmpty) {
      setState(() => _error = context.t('sxNoteNeeded'));
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final result = await context.read<FeedingProvider>().resolveStockException(
          widget.exception.id,
          resolution: _mode,
          note: _note.text,
          lotId: _mode == 'assigned_to_lot' ? _lotId : null,
        );
    if (!mounted) return;
    if (!result.success) {
      setState(() {
        _saving = false;
        _error = result.error ?? context.t('couldNotSave');
      });
      return;
    }
    // The stock lines move with it.
    context.read<FeedProvider>().load();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.t(result.queued ? 'workingOffline' : 'sxSaved'))));
    await widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.exception;
    final unit = e.unit;
    // A lot the feed could have come from: this feed's lots that hold stock.
    final lots = [
      for (final l in (widget.product.availability.lots.isNotEmpty ? widget.product.availability.lots : context.read<FeedingProvider>().lotsFor(widget.product.id)))
        if (l.quantityOnHand > 0) l,
    ];
    final who = [
      if (e.isLegacy) context.t('sxLegacy'),
      if (!e.isLegacy && e.requestedByName != null) context.t('sxRecordedBy').replaceAll('{name}', e.requestedByName!),
      if (!e.isLegacy && e.approvedByName != null) context.t('sxApprovedBy').replaceAll('{name}', e.approvedByName!),
    ].join(' · ');
    return Material(
      color: FarmColors.stone,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            Expanded(child: Text('${feedNumber(e.openQuantity)} $unit · ${feedDate(e.occurredAt)}', style: FarmTypography.textTheme.titleSmall)),
            StatusPill(label: context.t('sxOpen'), level: FarmStatusLevel.alert, dense: true),
          ]),
          if (who.isNotEmpty) ...[const SizedBox(height: 4), Text(who, style: FarmTypography.textTheme.bodySmall)],
          if (e.lotCode != null) Text(context.t('sxNamedLot').replaceAll('{lot}', e.lotCode!), style: FarmTypography.textTheme.bodySmall),
          const SizedBox(height: 4),
          Text('${context.t('sxWhy')}: ${e.reason}', style: FarmTypography.textTheme.bodyMedium),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            ChoiceChip(
              key: ValueKey('sx-mode-lot-${e.id}'),
              label: Text(context.t('sxFromLot')),
              selected: _mode == 'assigned_to_lot',
              onSelected: _saving ? null : (_) => setState(() => _mode = 'assigned_to_lot'),
            ),
            ChoiceChip(
              key: ValueKey('sx-mode-there-${e.id}'),
              label: Text(context.t('sxWasThere')),
              selected: _mode == 'confirmed_unrecorded_stock',
              onSelected: _saving ? null : (_) => setState(() => _mode = 'confirmed_unrecorded_stock'),
            ),
          ]),
          if (_mode == 'assigned_to_lot') ...[
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              key: ValueKey('sx-lot-${e.id}'),
              initialValue: _lotId,
              isExpanded: true,
              decoration: InputDecoration(labelText: context.t('sxChooseLot'), isDense: true),
              items: [
                for (final l in lots)
                  DropdownMenuItem(value: l.id, child: Text('${l.lotCode} · ${feedNumber(l.quantityOnHand)} ${l.unit} · ${feedDate(l.receivedAt)}', overflow: TextOverflow.ellipsis)),
              ],
              onChanged: _saving ? null : (v) => setState(() => _lotId = v),
            ),
          ],
          const SizedBox(height: 8),
          TextField(
            key: ValueKey('sx-note-${e.id}'),
            controller: _note,
            enabled: !_saving,
            maxLength: 300,
            decoration: InputDecoration(labelText: context.t('sxNote'), isDense: true),
          ),
          if (_error != null) NoticeBanner(tone: NoticeTone.danger, text: _error!),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: FilledButton(
              key: ValueKey('sx-save-${e.id}'),
              onPressed: _saving ? null : _save,
              child: _saving ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2)) : Text(context.t('sxSave')),
            ),
          ),
        ]),
      ),
    );
  }
}
