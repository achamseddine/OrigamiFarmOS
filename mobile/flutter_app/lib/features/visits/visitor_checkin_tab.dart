import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/widgets/section_card.dart';
import '../../core/widgets/status_pill.dart';
import '../../providers/visits_provider.dart';

/// Visitor Check-in (tech spec v0.6 §6, screen 7) plus feedback capture —
/// the tech spec's UI table also lists a "Feedback & Follow-up" screen;
/// since a visitor gives feedback right after their visit, it lives here
/// rather than as an 11th tab. Must work fully offline (RULE-VIS-009 —
/// walk-ins and check-ins sync later with conflict handling).
class VisitorCheckinTab extends StatelessWidget {
  const VisitorCheckinTab({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<VisitsProvider>();
    final readyToCheckIn = [...provider.bookings.where((b) => b.status == 'confirmed')]..sort((a, b) => (provider.sessionById(a.sessionId)?.date ?? DateTime(9999)).compareTo(provider.sessionById(b.sessionId)?.date ?? DateTime(9999)));
    final awaitingFeedback = provider.bookings.where((b) => b.status == 'completed' && provider.feedbackForBooking(b.id) == null).toList();
    final checkedInToday = provider.bookings.where((b) => b.status == 'checked_in').toList();

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionCard(
            title: 'Ready to Check In',
            subtitle: 'Confirmed bookings, earliest session first',
            child: readyToCheckIn.isEmpty
                ? Text('No confirmed bookings waiting to check in.', style: FarmTypography.textTheme.bodySmall)
                : Column(children: [for (final b in readyToCheckIn) _CheckinRow(bookingId: b.id)]),
          ),
          const SizedBox(height: FarmSpacing.md),
          SectionCard(
            title: 'Checked In',
            child: checkedInToday.isEmpty
                ? Text('No one checked in yet.', style: FarmTypography.textTheme.bodySmall)
                : Column(
                    children: [
                      for (final b in checkedInToday)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Row(children: [
                            Expanded(child: Text('${provider.visitorById(b.visitorId)?.fullName ?? b.visitorId} · ${b.guestCount} guests', style: FarmTypography.textTheme.bodyMedium)),
                            StatusPill(label: 'checked in', level: FarmStatusLevel.good, dense: true),
                          ]),
                        ),
                    ],
                  ),
          ),
          const SizedBox(height: FarmSpacing.md),
          SectionCard(
            title: 'Feedback & Follow-up',
            subtitle: 'Capture a rating right after a completed visit',
            child: awaitingFeedback.isEmpty
                ? Text('No completed visits awaiting feedback.', style: FarmTypography.textTheme.bodySmall)
                : Column(children: [for (final b in awaitingFeedback) _FeedbackForm(bookingId: b.id)]),
          ),
        ],
      ),
    );
  }
}

class _CheckinRow extends StatelessWidget {
  const _CheckinRow({required this.bookingId});
  final String bookingId;

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<VisitsProvider>();
    final booking = provider.bookingById(bookingId);
    if (booking == null) return const SizedBox.shrink();
    final visitor = provider.visitorById(booking.visitorId);
    final session = provider.sessionById(booking.sessionId);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(visitor?.fullName ?? booking.visitorId, style: FarmTypography.textTheme.titleSmall),
                Text(
                  session == null ? '${booking.guestCount} guests' : '${session.date.day}/${session.date.month} · ${session.startTime} · ${booking.guestCount} guests',
                  style: FarmTypography.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          FilledButton(
            onPressed: () async {
              final result = await provider.checkInBooking(bookingId);
              if (!context.mounted) return;
              if (!result.success) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(result.error ?? 'Could not check in.')));
              }
            },
            child: const Text('Check In'),
          ),
        ],
      ),
    );
  }
}

class _FeedbackForm extends StatefulWidget {
  const _FeedbackForm({required this.bookingId});
  final String bookingId;

  @override
  State<_FeedbackForm> createState() => _FeedbackFormState();
}

class _FeedbackFormState extends State<_FeedbackForm> {
  int _rating = 5;
  bool? _wouldReturn = true;
  final _comments = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _comments.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() => _saving = true);
    final result = await context.read<VisitsProvider>().addFeedback(bookingId: widget.bookingId, rating: _rating, comments: _comments.text.trim().isEmpty ? null : _comments.text.trim(), wouldReturn: _wouldReturn);
    if (!mounted) return;
    setState(() => _saving = false);
    if (result.success) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Feedback recorded.')));
    } else if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(result.error ?? 'Could not save feedback.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<VisitsProvider>();
    final booking = provider.bookingById(widget.bookingId);
    final visitor = booking == null ? null : provider.visitorById(booking.visitorId);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(border: Border.all(color: FarmColors.border), borderRadius: BorderRadius.circular(FarmRadii.sm)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(visitor?.fullName ?? widget.bookingId, style: FarmTypography.textTheme.titleSmall),
          const SizedBox(height: 8),
          Row(children: [
            for (var star = 1; star <= 5; star++)
              IconButton(
                onPressed: () => setState(() => _rating = star),
                icon: Icon(star <= _rating ? Icons.star : Icons.star_border, color: FarmColors.gold),
                iconSize: 22,
              ),
            const SizedBox(width: 12),
            const Text('Would return?'),
            Switch(value: _wouldReturn ?? false, onChanged: (v) => setState(() => _wouldReturn = v)),
          ]),
          TextField(controller: _comments, decoration: const InputDecoration(labelText: 'Comments (optional)')),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
              onPressed: _saving ? null : _submit,
              child: _saving ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Save Feedback'),
            ),
          ),
        ],
      ),
    );
  }
}
