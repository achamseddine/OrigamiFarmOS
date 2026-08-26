import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/widgets/section_card.dart';
import '../../providers/visits_provider.dart';

const List<String> _kWeekdayNames = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];

/// Opening Calendar (tech spec v0.6 §6, screen 2). RULE-VIS-003: opening
/// days are configurable per farm and never hard-coded — every one of the
/// 7 weekdays below is the same editable row; a Lebanese farm's Friday /
/// Saturday / Sunday default (see `data/demo/visits_demo_data.dart`) is
/// only this farm's own choice, not a rule baked into the code.
class OpeningCalendarTab extends StatelessWidget {
  const OpeningCalendarTab({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<VisitsProvider>();
    final calendar = provider.calendar;

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionCard(
            title: 'Weekly Opening Calendar',
            subtitle: 'Toggle any day open or closed, and set its default visiting hours & capacity.',
            child: Column(children: [for (final day in calendar) _CalendarDayRow(day: day)]),
          ),
        ],
      ),
    );
  }
}

class _CalendarDayRow extends StatefulWidget {
  const _CalendarDayRow({required this.day});
  final VisitOpeningCalendarDay day;

  @override
  State<_CalendarDayRow> createState() => _CalendarDayRowState();
}

class _CalendarDayRowState extends State<_CalendarDayRow> {
  late TextEditingController _open;
  late TextEditingController _close;
  late TextEditingController _capacity;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _open = TextEditingController(text: widget.day.openTime ?? '09:00');
    _close = TextEditingController(text: widget.day.closeTime ?? '17:00');
    _capacity = TextEditingController(text: widget.day.defaultCapacity > 0 ? '${widget.day.defaultCapacity}' : '40');
  }

  @override
  void dispose() {
    _open.dispose();
    _close.dispose();
    _capacity.dispose();
    super.dispose();
  }

  Future<void> _toggle(bool isOpen) async {
    setState(() {
      _saving = true;
      _error = null;
    });
    final result = await context.read<VisitsProvider>().upsertCalendarDay(
          weekday: widget.day.weekday,
          isOpen: isOpen,
          openTime: isOpen ? _open.text : null,
          closeTime: isOpen ? _close.text : null,
          defaultCapacity: int.tryParse(_capacity.text) ?? 0,
          notes: widget.day.notes,
        );
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (!result.success) _error = result.error;
    });
  }

  Future<void> _saveDetails() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    final result = await context.read<VisitsProvider>().upsertCalendarDay(
          weekday: widget.day.weekday,
          isOpen: widget.day.isOpen,
          openTime: _open.text,
          closeTime: _close.text,
          defaultCapacity: int.tryParse(_capacity.text) ?? 0,
          notes: widget.day.notes,
        );
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (!result.success) _error = result.error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final isOpen = widget.day.isOpen;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: FarmColors.border),
        borderRadius: BorderRadius.circular(FarmRadii.sm),
        color: isOpen ? FarmColors.tint(FarmColors.success, 0.06) : FarmColors.card,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(_kWeekdayNames[widget.day.weekday], style: FarmTypography.textTheme.titleSmall)),
              if (_saving) const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2)),
              Switch(value: isOpen, onChanged: _saving ? null : _toggle),
            ],
          ),
          if (isOpen) ...[
            const SizedBox(height: 8),
            Row(children: [
              Expanded(child: TextField(controller: _open, decoration: const InputDecoration(labelText: 'Open (HH:MM)'))),
              const SizedBox(width: 12),
              Expanded(child: TextField(controller: _close, decoration: const InputDecoration(labelText: 'Close (HH:MM)'))),
              const SizedBox(width: 12),
              Expanded(child: TextField(controller: _capacity, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Default capacity'))),
              const SizedBox(width: 12),
              OutlinedButton(onPressed: _saving ? null : _saveDetails, child: const Text('Save')),
            ]),
          ],
          if (_error != null) ...[
            const SizedBox(height: 6),
            Text(_error!, style: const TextStyle(color: FarmColors.danger, fontSize: 12.5)),
          ],
        ],
      ),
    );
  }
}
