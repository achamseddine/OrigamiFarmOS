import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/typography.dart';
import '../../core/util/number_input.dart';
import '../../core/widgets/ux_blocks.dart';
import '../../domain/entities/access.dart';
import '../../domain/entities/feeding.dart';
import '../../providers/access_provider.dart';
import '../../providers/feeding_provider.dart';

/// One feed line being entered: a product and how much. A line that comes
/// from one of the standard rows carries its [slot] (concentrate, corn
/// silage, wheat straw) so it keeps its label even with no product picked.
class FeedingLine {
  FeedingLine({this.productId, double? quantity, this.slot})
      : quantity = TextEditingController(text: quantity == null ? '' : _trim(quantity));
  String? productId;
  final TextEditingController quantity;
  final StandardFeedSlot? slot;

  static String _trim(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);
}

/// Records a feeding event (generic feed architecture §2.6): what was put
/// in front of an animal or a group, from which feeds.
///
/// It opens with the three standard rows — concentrate, corn silage, wheat
/// straw (docs/QR-ANIMAL-QUICK-ENTRY.md) — each already pointing at the
/// farm's feed for it; the worker fills the amounts that were given and
/// leaves the rest blank, and adds another feed when there was one. A blank
/// row records nothing. A plan's amounts ([initialLines]) are written into
/// the matching rows to check and correct.
///
/// The server issues the stock FIFO from usable, unreserved lots and
/// refuses — with the reason — anything the feed's usage policy or a
/// restriction forbids. Feeding more than the stock the farm has entered is
/// refused too, unless the worker says so here explicitly ("stock not
/// entered yet"): the shortfall is then recorded against no lot, visible in
/// the ledger until a delivery is entered.
Future<bool> showFeedingEventDialog(
  BuildContext context, {
  required String subjectType,
  required String subjectId,
  required String subjectName,
  int? headCount,
  List<FeedingLine>? initialLines,
}) async {
  final saved = await showDialog<bool>(
    context: context,
    builder: (_) => _FeedingEventDialog(
      subjectType: subjectType, subjectId: subjectId, subjectName: subjectName, headCount: headCount, initialLines: initialLines,
    ),
  );
  return saved ?? false;
}

/// The rows the dialog opens with: the standard three, a plan's amounts
/// filled into the row of the same feed, and any other planned feed as an
/// extra row after them.
List<FeedingLine> feedingRowsFor(List<StandardFeedSlot> slots, List<FeedingLine>? initial) {
  final planned = [...?initial];
  final rows = <FeedingLine>[];
  for (final slot in slots) {
    final match = planned.where((l) => l.productId != null && l.productId == slot.feedProductId).toList();
    final qty = match.isEmpty ? null : parseLocalizedDouble(match.first.quantity.text);
    if (match.isNotEmpty) planned.remove(match.first);
    rows.add(FeedingLine(productId: slot.feedProductId, quantity: qty, slot: slot));
  }
  for (final extra in planned) {
    rows.add(FeedingLine(productId: extra.productId, quantity: parseLocalizedDouble(extra.quantity.text)));
  }
  for (final l in [...?initial]) {
    l.quantity.dispose();
  }
  return rows;
}

class _FeedingEventDialog extends StatefulWidget {
  const _FeedingEventDialog({required this.subjectType, required this.subjectId, required this.subjectName, this.headCount, this.initialLines});
  final String subjectType;
  final String subjectId;
  final String subjectName;
  final int? headCount;
  final List<FeedingLine>? initialLines;

  @override
  State<_FeedingEventDialog> createState() => _FeedingEventDialogState();
}

class _FeedingEventDialogState extends State<_FeedingEventDialog> {
  late final List<FeedingLine> _lines = feedingRowsFor(context.read<FeedingProvider>().feedSlots, widget.initialLines);
  late final _head = TextEditingController(text: widget.headCount?.toString() ?? '');
  final _notes = TextEditingController();
  // What was put in front of an animal is "offered"; a pen's round is a
  // "delivery". Both issue the stock.
  late String _eventType = widget.subjectType == 'group' ? 'delivered' : 'offered';
  bool _saving = false;
  bool _settingUp = false;
  bool _overrideStock = false;
  bool _serverShortfall = false;
  String? _error;

  static const _types = ['delivered', 'offered', 'consumed_estimate', 'refusal'];

  @override
  void dispose() {
    for (final l in _lines) {
      l.quantity.dispose();
    }
    _head.dispose();
    _notes.dispose();
    super.dispose();
  }

  bool get _movesStock => _eventType == 'offered' || _eventType == 'delivered';

  /// Filled lines whose amount is more than the stock this tablet last saw.
  List<(FeedProduct, double)> _shortfalls(FeedingProvider feeding) {
    if (!_movesStock) return const [];
    final wanted = <String, double>{};
    for (final line in _lines) {
      final qty = parseLocalizedDouble(line.quantity.text);
      if (line.productId == null || qty == null || qty <= 0) continue;
      wanted[line.productId!] = (wanted[line.productId!] ?? 0) + qty;
    }
    return [
      for (final e in wanted.entries)
        if (feeding.productById(e.key) case final p? when e.value > p.availability.available + 0.0005) (p, e.value),
    ];
  }

  Future<void> _submit() async {
    final feeding = context.read<FeedingProvider>();
    final components = <Map<String, dynamic>>[];
    for (final line in _lines) {
      final raw = line.quantity.text.trim();
      if (raw.isEmpty) continue;
      final qty = parseLocalizedDouble(raw);
      if (qty == null || qty <= 0) {
        setState(() => _error = context.t('valueMustBePositive'));
        return;
      }
      if (line.productId == null) {
        setState(() => _error = '${context.t('feedChooseProductFor')} ${line.slot?.label(Localizations.localeOf(context).languageCode) ?? ''}'.trim());
        return;
      }
      components.add({'feed_product_id': line.productId, 'quantity_offered': qty});
    }
    if (components.isEmpty) {
      setState(() => _error = context.t('feedEnterAmount'));
      return;
    }
    if (_shortfalls(feeding).isNotEmpty && !_overrideStock) {
      final canOverride = context.read<AccessProvider>().canOverrideFeedStock;
      setState(() => _error = context.t(canOverride ? 'feedStockShortConfirm' : 'feedOverrideNeedsApproval'));
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final result = await feeding.recordFeeding({
      'subject_type': widget.subjectType,
      'subject_id': widget.subjectId,
      'event_type': _eventType,
      if (_head.text.trim().isNotEmpty) 'head_count': parseLocalizedInt(_head.text),
      if (_notes.text.trim().isNotEmpty) 'notes': _notes.text.trim(),
      if (_overrideStock) 'allow_negative': true,
      'components': components,
    });
    if (!mounted) return;
    if (result.success) {
      Navigator.of(context).pop(true);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.t('feedingRecorded'))));
      return;
    }
    final message = result.error ?? '';
    final short = message.startsWith('Not enough');
    setState(() {
      _saving = false;
      _serverShortfall = _serverShortfall || short;
      // The server's sentence, without the developer's hint at its end.
      _error = short ? message.replaceAll(RegExp(r'\s*Pass allow_negative=true to override\.?'), '') : message;
    });
  }

  Future<void> _setUpStandardFeeds() async {
    setState(() => _settingUp = true);
    final feeding = context.read<FeedingProvider>();
    final result = await feeding.ensureStandardFeeds();
    if (!mounted) return;
    setState(() {
      _settingUp = false;
      if (!result.success) {
        _error = result.error;
        return;
      }
      for (final slot in feeding.feedSlots) {
        for (final line in _lines) {
          if (line.slot?.slot == slot.slot && line.productId == null) line.productId = slot.feedProductId;
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final feeding = context.watch<FeedingProvider>();
    final canSetUp = context.watch<AccessProvider>().canCreate(FarmModule.feedNutrition);
    final lang = Localizations.localeOf(context).languageCode;
    final feeds = feeding.feedable;
    final shortfalls = _shortfalls(feeding);
    final missingSlot = _lines.any((l) => l.slot != null && l.productId == null);
    return AlertDialog(
      title: Text('${context.t('recordFeeding')} — ${widget.subjectName}'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: _eventType,
                    decoration: InputDecoration(labelText: context.t('eventType')),
                    items: [for (final t in _types) DropdownMenuItem(value: t, child: Text(context.t('event_$t')))],
                    onChanged: (v) => setState(() => _eventType = v ?? _eventType),
                  ),
                ),
                if (widget.subjectType == 'group') ...[
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 110,
                    child: TextField(
                      controller: _head,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(labelText: context.t('headCount')),
                    ),
                  ),
                ],
              ]),
              const SizedBox(height: 6),
              Text(context.t('feedRowsHint'), style: FarmTypography.textTheme.bodySmall),
              const SizedBox(height: 10),
              for (var i = 0; i < _lines.length; i++) ...[
                _FeedRow(
                  key: ObjectKey(_lines[i]),
                  line: _lines[i],
                  feeds: feeds,
                  lang: lang,
                  onChanged: () => setState(() {}),
                  onRemove: _lines[i].slot == null ? () => setState(() => _lines.removeAt(i).quantity.dispose()) : null,
                ),
                const SizedBox(height: 10),
              ],
              Wrap(spacing: 8, runSpacing: 4, children: [
                TextButton.icon(
                  onPressed: feeds.isEmpty ? null : () => setState(() => _lines.add(FeedingLine())),
                  icon: const Icon(Icons.add, size: 16),
                  label: Text(context.t('addFeedLine')),
                ),
                if (missingSlot && canSetUp)
                  TextButton.icon(
                    onPressed: _settingUp ? null : _setUpStandardFeeds,
                    icon: _settingUp
                        ? const SizedBox(height: 14, width: 14, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.playlist_add, size: 16),
                    label: Text(context.t('feedSetUpStandard')),
                  ),
              ]),
              if (missingSlot && !canSetUp)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(context.t('feedAskManagerStandard'), style: FarmTypography.textTheme.bodySmall),
                ),
              TextField(controller: _notes, decoration: InputDecoration(labelText: context.t('notes'))),
              if (shortfalls.isNotEmpty || _serverShortfall) ...[
                const SizedBox(height: 12),
                NoticeBanner(
                  title: context.t('feedStockShortTitle'),
                  text: [
                    for (final (p, qty) in shortfalls)
                      '${p.label(lang)}: ${_fmt(p.availability.available)} ${p.unit} ${context.t('feedInStock')}, ${_fmt(qty)} ${p.unit} ${context.t('feedEntered')}',
                    context.t('feedStockShortBody'),
                  ].join('\n'),
                ),
                // Only Feed or Inventory approval records past the ledger.
                if (context.watch<AccessProvider>().canOverrideFeedStock)
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
                  )
                else
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(context.t('feedOverrideNeedsApproval'), style: const TextStyle(fontSize: 12.5, color: FarmColors.warningInk)),
                  ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(_error!, style: const TextStyle(color: FarmColors.danger, fontSize: 12.5)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(context.t('cancel'))),
        FilledButton(
          onPressed: _saving ? null : _submit,
          child: _saving ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2)) : Text(context.t('save')),
        ),
      ],
    );
  }

  static String _fmt(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
}

/// One row: what the row is for (a standard row's label), which feed, how
/// much. The amount is the only thing a worker normally touches.
class _FeedRow extends StatelessWidget {
  const _FeedRow({super.key, required this.line, required this.feeds, required this.lang, required this.onChanged, this.onRemove});
  final FeedingLine line;
  final List<FeedProduct> feeds;
  final String lang;
  final VoidCallback onChanged;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final product = feeds.where((p) => p.id == line.productId).firstOrNull;
    final slot = line.slot;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (slot != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text(slot.label(lang), style: FarmTypography.textTheme.titleSmall),
        ),
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          flex: 3,
          child: DropdownButtonFormField<String>(
            value: product?.id,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: context.t('feedItem'),
              helperText: product == null ? null : '${_fmt(product.availability.available)} ${product.unit} ${context.t('feedInStock')}',
            ),
            hint: Text(slot != null && feeds.isEmpty ? context.t('feedNotSetUp') : context.t('feedChooseProduct'), overflow: TextOverflow.ellipsis),
            items: [
              for (final p in feeds) DropdownMenuItem(value: p.id, child: Text(p.label(lang), overflow: TextOverflow.ellipsis)),
            ],
            onChanged: feeds.isEmpty
                ? null
                : (v) {
                    line.productId = v;
                    onChanged();
                  },
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          flex: 2,
          child: TextField(
            controller: line.quantity,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onChanged: (_) => onChanged(),
            decoration: InputDecoration(
              labelText: context.t('quantity'),
              suffixText: product?.unit ?? slot?.unit ?? 'kg',
              hintText: context.t('optional'),
            ),
          ),
        ),
        if (onRemove != null)
          IconButton(
            onPressed: onRemove,
            tooltip: context.t('remove'),
            icon: const Icon(Icons.remove_circle_outline, size: 18, color: FarmColors.muted),
          )
        else
          const SizedBox(width: 48),
      ]),
    ]);
  }

  static String _fmt(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
}

/// Lines pre-filled from a plan's daily targets (the daily feeding list's
/// "record delivery"), so the worker confirms rather than types.
List<FeedingLine> linesFromTargets(Iterable<DailyTarget> targets, {double fraction = 1}) => [
      for (final t in targets) FeedingLine(productId: t.feedProductId, quantity: t.dailyTotal * fraction),
    ];
