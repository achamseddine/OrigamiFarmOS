import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/widgets/section_card.dart';
import '../../core/widgets/status_pill.dart';
import '../../domain/entities/visits.dart';
import '../../providers/visits_provider.dart';

class _ActivityLineDraft {
  _ActivityLineDraft({this.activityId, this.quantity = 1, this.time = '10:00'});
  String? activityId;
  int quantity;
  String time;
}

/// Booking Form + Visit Session Management (tech spec v0.6 §6, screen 5).
/// Session creation is folded into this screen rather than a separate tab
/// — a session is picked here the moment before a booking needs one.
class BookingFormTab extends StatefulWidget {
  const BookingFormTab({super.key});

  @override
  State<BookingFormTab> createState() => _BookingFormTabState();
}

class _BookingFormTabState extends State<BookingFormTab> {
  String? _sessionId;
  String? _packageId;
  String? _visitorId;
  bool _walkIn = false;
  final _newVisitorName = TextEditingController();
  final _newVisitorPhone = TextEditingController();
  final _adults = TextEditingController(text: '1');
  final _children = TextEditingController(text: '0');
  final _notes = TextEditingController();
  String _source = 'manual';
  final List<_ActivityLineDraft> _activityLines = [];
  bool _saving = false;
  String? _error;

  // New-session mini form.
  DateTime? _newSessionDate;
  final _newSessionStart = TextEditingController(text: '10:00');
  final _newSessionEnd = TextEditingController(text: '13:00');
  final _newSessionCapacity = TextEditingController();
  bool _sessionSaving = false;
  String? _sessionError;

  @override
  void dispose() {
    _newVisitorName.dispose();
    _newVisitorPhone.dispose();
    _adults.dispose();
    _children.dispose();
    _notes.dispose();
    _newSessionStart.dispose();
    _newSessionEnd.dispose();
    _newSessionCapacity.dispose();
    super.dispose();
  }

  Future<void> _createSession() async {
    if (_newSessionDate == null) {
      setState(() => _sessionError = 'Pick a date.');
      return;
    }
    setState(() {
      _sessionSaving = true;
      _sessionError = null;
    });
    final result = await context.read<VisitsProvider>().createSession(
          date: _newSessionDate!,
          startTime: _newSessionStart.text,
          endTime: _newSessionEnd.text,
          capacity: int.tryParse(_newSessionCapacity.text),
        );
    if (!mounted) return;
    setState(() {
      _sessionSaving = false;
      if (!result.success) _sessionError = result.error;
    });
  }

  Future<void> _submitBooking() async {
    if (_sessionId == null || _packageId == null) {
      setState(() => _error = 'Pick a session and a package.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final provider = context.read<VisitsProvider>();
    final result = await provider.createBooking(
      visitorId: _walkIn ? null : _visitorId,
      newVisitorFullName: _walkIn ? _newVisitorName.text.trim() : null,
      newVisitorPhone: _walkIn && _newVisitorPhone.text.trim().isNotEmpty ? _newVisitorPhone.text.trim() : null,
      sessionId: _sessionId!,
      packageId: _packageId!,
      adults: int.tryParse(_adults.text) ?? 1,
      children: int.tryParse(_children.text) ?? 0,
      source: _source,
      notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
      activitySelections: [
        for (final line in _activityLines)
          if (line.activityId != null)
            (activityId: line.activityId!, scheduledAt: _combineSessionDate(line.time), quantity: line.quantity),
      ],
    );
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (result.success) {
        _visitorId = null;
        _newVisitorName.clear();
        _newVisitorPhone.clear();
        _adults.text = '1';
        _children.text = '0';
        _notes.clear();
        _activityLines.clear();
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Booking created as a draft.')));
      } else {
        _error = result.error;
      }
    });
  }

  DateTime _combineSessionDate(String hhmm) {
    final session = context.read<VisitsProvider>().sessionById(_sessionId!);
    final day = session?.date ?? DateTime.now();
    final parts = hhmm.split(':');
    return DateTime(day.year, day.month, day.day, int.tryParse(parts[0]) ?? 10, parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0);
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<VisitsProvider>();
    final sessions = provider.upcomingSessions;

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionCard(
            title: 'Add a Session',
            subtitle: 'Only dates on a configured open weekday should be scheduled — see Opening Calendar.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () async {
                        final picked = await showDatePicker(context: context, initialDate: DateTime.now().add(const Duration(days: 1)), firstDate: DateTime.now(), lastDate: DateTime.now().add(const Duration(days: 365)));
                        if (picked != null) setState(() => _newSessionDate = picked);
                      },
                      child: Text(_newSessionDate == null ? 'Pick a date' : '${_newSessionDate!.day}/${_newSessionDate!.month}/${_newSessionDate!.year}'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: TextField(controller: _newSessionStart, decoration: const InputDecoration(labelText: 'Start (HH:MM)'))),
                  const SizedBox(width: 12),
                  Expanded(child: TextField(controller: _newSessionEnd, decoration: const InputDecoration(labelText: 'End (HH:MM)'))),
                  const SizedBox(width: 12),
                  Expanded(child: TextField(controller: _newSessionCapacity, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Capacity (blank = calendar default)'))),
                  const SizedBox(width: 12),
                  FilledButton(
                    onPressed: _sessionSaving ? null : _createSession,
                    child: _sessionSaving ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Add Session'),
                  ),
                ]),
                if (_sessionError != null) ...[
                  const SizedBox(height: 8),
                  Text(_sessionError!, style: const TextStyle(color: FarmColors.danger, fontSize: 12.5)),
                ],
              ],
            ),
          ),
          const SizedBox(height: FarmSpacing.md),
          SectionCard(
            title: 'New Booking',
            subtitle: 'Every booking starts as a draft — confirm it once the deposit / guest count is settled.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      value: _sessionId,
                      decoration: const InputDecoration(labelText: 'Session'),
                      items: [for (final s in sessions) DropdownMenuItem(value: s.id, child: Text('${s.date.day}/${s.date.month} · ${s.startTime}–${s.endTime}'))],
                      onChanged: (v) => setState(() => _sessionId = v),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      value: _packageId,
                      decoration: const InputDecoration(labelText: 'Package'),
                      items: [for (final p in provider.packages) DropdownMenuItem(value: p.id, child: Text(p.name))],
                      onChanged: (v) => setState(() => _packageId = v),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      value: _source,
                      decoration: const InputDecoration(labelText: 'Source'),
                      items: [for (final s in kVisitBookingSources) DropdownMenuItem(value: s, child: Text(s))],
                      onChanged: (v) => setState(() => _source = v ?? _source),
                    ),
                  ),
                ]),
                const SizedBox(height: 12),
                Row(children: [
                  ChoiceChip(label: const Text('Existing visitor'), selected: !_walkIn, onSelected: (_) => setState(() => _walkIn = false)),
                  const SizedBox(width: 8),
                  ChoiceChip(label: const Text('Walk-in guest'), selected: _walkIn, onSelected: (_) => setState(() => _walkIn = true)),
                ]),
                const SizedBox(height: 12),
                if (!_walkIn)
                  DropdownButtonFormField<String>(
                    value: _visitorId,
                    decoration: const InputDecoration(labelText: 'Visitor'),
                    items: [for (final v in provider.visitors) DropdownMenuItem(value: v.id, child: Text(v.fullName))],
                    onChanged: (v) => setState(() => _visitorId = v),
                  )
                else
                  Row(children: [
                    Expanded(child: TextField(controller: _newVisitorName, decoration: const InputDecoration(labelText: 'Walk-in guest name'))),
                    const SizedBox(width: 12),
                    Expanded(child: TextField(controller: _newVisitorPhone, decoration: const InputDecoration(labelText: 'Phone (optional)'))),
                  ]),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(child: TextField(controller: _adults, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Adults'))),
                  const SizedBox(width: 12),
                  Expanded(child: TextField(controller: _children, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Children'))),
                  const SizedBox(width: 12),
                  Expanded(flex: 2, child: TextField(controller: _notes, decoration: const InputDecoration(labelText: 'Notes (optional)'))),
                ]),
                const SizedBox(height: FarmSpacing.md),
                Row(children: [
                  Text('Activity add-ons', style: FarmTypography.textTheme.titleSmall),
                  const Spacer(),
                  TextButton.icon(onPressed: () => setState(() => _activityLines.add(_ActivityLineDraft())), icon: const Icon(Icons.add, size: 16), label: const Text('Add activity')),
                ]),
                for (var i = 0; i < _activityLines.length; i++)
                  _ActivityLineRow(key: ValueKey(_activityLines[i]), line: _activityLines[i], onRemove: () => setState(() => _activityLines.removeAt(i))),
                const SizedBox(height: FarmSpacing.md),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton(
                    onPressed: _saving ? null : _submitBooking,
                    child: _saving ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Create Booking'),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(_error!, style: const TextStyle(color: FarmColors.danger, fontSize: 12.5)),
                ],
              ],
            ),
          ),
          const SizedBox(height: FarmSpacing.md),
          SectionCard(
            title: 'Bookings',
            child: provider.bookings.isEmpty ? Text('No bookings yet.', style: FarmTypography.textTheme.bodySmall) : Column(children: [for (final b in provider.bookings) _BookingRow(bookingId: b.id)]),
          ),
        ],
      ),
    );
  }
}

class _ActivityLineRow extends StatefulWidget {
  const _ActivityLineRow({super.key, required this.line, required this.onRemove});
  final _ActivityLineDraft line;
  final VoidCallback onRemove;

  @override
  State<_ActivityLineRow> createState() => _ActivityLineRowState();
}

class _ActivityLineRowState extends State<_ActivityLineRow> {
  late final TextEditingController _time = TextEditingController(text: widget.line.time);
  late final TextEditingController _quantity = TextEditingController(text: '${widget.line.quantity}');

  @override
  void dispose() {
    _time.dispose();
    _quantity.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final activities = context.watch<VisitsProvider>().activities;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        Expanded(
          flex: 2,
          child: DropdownButtonFormField<String>(
            value: widget.line.activityId,
            decoration: const InputDecoration(labelText: 'Activity'),
            items: [for (final a in activities) DropdownMenuItem(value: a.id, child: Text('${a.name} (\$${a.price.toStringAsFixed(2)})'))],
            onChanged: (v) => setState(() => widget.line.activityId = v),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(child: TextField(controller: _time, decoration: const InputDecoration(labelText: 'Time (HH:MM)'), onChanged: (v) => widget.line.time = v)),
        const SizedBox(width: 12),
        Expanded(child: TextField(controller: _quantity, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Qty'), onChanged: (v) => widget.line.quantity = int.tryParse(v) ?? 1)),
        IconButton(onPressed: widget.onRemove, icon: const Icon(Icons.close, size: 18)),
      ]),
    );
  }
}

class _BookingRow extends StatelessWidget {
  const _BookingRow({required this.bookingId});
  final String bookingId;

  StatusPill _pill(String status) {
    final level = switch (status) {
      'confirmed' || 'checked_in' || 'completed' => FarmStatusLevel.good,
      'cancelled' || 'no_show' => FarmStatusLevel.alert,
      'refunded' => FarmStatusLevel.neutral,
      _ => FarmStatusLevel.watch,
    };
    return StatusPill(label: status.replaceAll('_', ' '), level: level, dense: true);
  }

  Future<void> _run(BuildContext context, Future<dynamic> Function() action) async {
    final result = await action();
    if (!context.mounted) return;
    if (result != null && result.success != true) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(result.error ?? 'Could not update this booking.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<VisitsProvider>();
    final booking = provider.bookingById(bookingId);
    if (booking == null) return const SizedBox.shrink();
    final visitor = provider.visitorById(booking.visitorId);
    final session = provider.sessionById(booking.sessionId);
    final pkg = provider.packageById(booking.packageId);

    final actions = <Widget>[];
    switch (booking.status) {
      case 'draft':
        actions.add(OutlinedButton(onPressed: () => _run(context, () => provider.confirmBooking(bookingId)), child: const Text('Confirm')));
        actions.add(TextButton(onPressed: () => _run(context, () => provider.cancelBooking(bookingId)), child: const Text('Cancel')));
      case 'confirmed':
        actions.add(OutlinedButton(onPressed: () => _run(context, () => provider.checkInBooking(bookingId)), child: const Text('Check In')));
        actions.add(TextButton(onPressed: () => _run(context, () => provider.noShowBooking(bookingId)), child: const Text('No-show')));
        actions.add(TextButton(onPressed: () => _run(context, () => provider.cancelBooking(bookingId)), child: const Text('Cancel')));
      case 'checked_in':
        actions.add(OutlinedButton(onPressed: () => _run(context, () => provider.completeBooking(bookingId)), child: const Text('Complete')));
        actions.add(TextButton(onPressed: () => _run(context, () => provider.cancelBooking(bookingId)), child: const Text('Cancel')));
      case 'completed':
      case 'cancelled':
      case 'no_show':
        actions.add(TextButton(onPressed: () => _run(context, () => provider.refundBooking(bookingId)), child: const Text('Refund')));
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${visitor?.fullName ?? booking.visitorId} · ${pkg?.name ?? booking.packageId}', style: FarmTypography.textTheme.titleSmall),
                  Text(
                    session == null ? '${booking.guestCount} guests' : '${session.date.day}/${session.date.month} · ${session.startTime} · ${booking.guestCount} guests · \$${booking.totalAmount.toStringAsFixed(2)}',
                    style: FarmTypography.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            _pill(booking.status),
          ]),
          if (actions.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: Wrap(spacing: 8, children: actions)),
          const Divider(height: 16, color: FarmColors.border),
        ],
      ),
    );
  }
}
