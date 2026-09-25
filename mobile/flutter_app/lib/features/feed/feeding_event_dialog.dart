import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/typography.dart';
import '../../domain/entities/feeding.dart';
import '../../providers/feeding_provider.dart';

/// One feed line being entered: a product and how much.
class FeedingLine {
  FeedingLine({this.productId, double? quantity}) : quantity = TextEditingController(text: quantity == null ? '' : _trim(quantity));
  String? productId;
  final TextEditingController quantity;

  static String _trim(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);
}

/// Records a feeding event (generic feed architecture §2.6): what was put
/// in front of an animal or a group, from which feeds. The server issues
/// the stock FIFO from usable, unreserved lots and refuses — with the
/// reason — anything the feed's usage policy or a restriction forbids;
/// that sentence is shown here as it came.
///
/// Opened from the Digital Twin's Feed action, and from the daily feeding
/// list with the line's planned quantities filled in.
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
  late final List<FeedingLine> _lines = widget.initialLines?.isNotEmpty == true ? widget.initialLines! : [FeedingLine()];
  late final _head = TextEditingController(text: widget.headCount?.toString() ?? '');
  final _notes = TextEditingController();
  String _eventType = 'delivered';
  bool _saving = false;
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

  Future<void> _submit() async {
    final components = <Map<String, dynamic>>[];
    for (final line in _lines) {
      final qty = double.tryParse(line.quantity.text.trim());
      if (line.productId == null || qty == null || qty <= 0) continue;
      components.add({'feed_product_id': line.productId, 'quantity_offered': qty});
    }
    if (components.isEmpty) {
      setState(() => _error = context.t('valueMustBePositive'));
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final result = await context.read<FeedingProvider>().recordFeeding({
      'subject_type': widget.subjectType,
      'subject_id': widget.subjectId,
      'event_type': _eventType,
      if (_head.text.trim().isNotEmpty) 'head_count': int.tryParse(_head.text.trim()),
      if (_notes.text.trim().isNotEmpty) 'notes': _notes.text.trim(),
      'components': components,
    });
    if (!mounted) return;
    if (result.success) {
      Navigator.of(context).pop(true);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.t('feedingRecorded'))));
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
    final feeds = feeding.feedable;
    return AlertDialog(
      title: Text('${context.t('recordFeeding')} — ${widget.subjectName}'),
      content: SizedBox(
        width: 460,
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
              const SizedBox(height: 12),
              if (feeds.isEmpty)
                Text(context.t('noFeedItems'), style: FarmTypography.textTheme.bodySmall)
              else
                for (var i = 0; i < _lines.length; i++) ...[
                  Row(children: [
                    Expanded(
                      flex: 3,
                      child: DropdownButtonFormField<String>(
                        value: feeds.any((p) => p.id == _lines[i].productId) ? _lines[i].productId : null,
                        isExpanded: true,
                        decoration: InputDecoration(labelText: context.t('feedItem')),
                        items: [
                          for (final p in feeds)
                            DropdownMenuItem(
                              value: p.id,
                              child: Text('${p.label(lang)} — ${p.availability.available.toStringAsFixed(0)} ${p.unit}', overflow: TextOverflow.ellipsis),
                            ),
                        ],
                        onChanged: (v) => setState(() => _lines[i].productId = v),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 2,
                      child: TextField(
                        controller: _lines[i].quantity,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: InputDecoration(labelText: context.t('quantity')),
                      ),
                    ),
                    if (_lines.length > 1)
                      IconButton(
                        onPressed: () => setState(() => _lines.removeAt(i).quantity.dispose()),
                        icon: const Icon(Icons.remove_circle_outline, size: 18, color: FarmColors.muted),
                      ),
                  ]),
                  const SizedBox(height: 8),
                ],
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  onPressed: () => setState(() => _lines.add(FeedingLine())),
                  icon: const Icon(Icons.add, size: 16),
                  label: Text(context.t('addFeedLine')),
                ),
              ),
              TextField(controller: _notes, decoration: InputDecoration(labelText: context.t('notes'))),
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
}

/// Lines pre-filled from a plan's daily targets (the daily feeding list's
/// "record delivery"), so the worker confirms rather than types.
List<FeedingLine> linesFromTargets(Iterable<DailyTarget> targets, {double fraction = 1}) => [
      for (final t in targets) FeedingLine(productId: t.feedProductId, quantity: t.dailyTotal * fraction),
    ];
