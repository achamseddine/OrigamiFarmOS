import 'package:flutter/material.dart';

/// The instant a record picked as a calendar day is sent with: now for
/// today (the time it actually happened, as near as the tablet knows), else
/// local midday of that day — never in the future, which the server refuses.
DateTime recordedInstant(DateTime day) {
  final now = DateTime.now();
  if (day.year == now.year && day.month == now.month && day.day == now.day) return now;
  final noon = DateTime(day.year, day.month, day.day, 12);
  return noon.isAfter(now) ? now : noon;
}

String dayLabel(DateTime d) => '${d.day}/${d.month}/${d.year}';

/// True when [d] falls on the device's today.
bool isToday(DateTime d) {
  final now = DateTime.now();
  return d.year == now.year && d.month == now.month && d.day == now.day;
}

/// When a milking on [day] happened, for the record: now for today; on an
/// earlier day — milk noted on paper and entered later — that session's
/// usual hour (morning 07:00, midday 12:00, evening 18:00), so the record
/// falls in the right day and session and is never in the future.
DateTime milkingInstant(DateTime day, String session) {
  final now = DateTime.now();
  if (isToday(day)) return now;
  final hour = switch (session) { 'evening' => 18, 'midday' => 12, _ => 7 };
  final at = DateTime(day.year, day.month, day.day, hour);
  return at.isAfter(now) ? now : at;
}

/// A "when did it happen" button for a record form: shows the chosen day
/// and opens the calendar. Defaults are the caller's (usually today).
class RecordDateButton extends StatelessWidget {
  const RecordDateButton({super.key, required this.label, required this.value, required this.onPicked, this.maxDaysBack = 730});

  final String label;
  final DateTime value;
  final ValueChanged<DateTime> onPicked;
  final int maxDaysBack;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    return OutlinedButton.icon(
      onPressed: () async {
        final picked = await showDatePicker(
          context: context,
          initialDate: value.isAfter(now) ? now : value,
          firstDate: now.subtract(Duration(days: maxDaysBack)),
          lastDate: now,
          helpText: label,
        );
        if (picked != null) onPicked(picked);
      },
      icon: const Icon(Icons.event, size: 18),
      label: Text('$label: ${dayLabel(value)}', overflow: TextOverflow.ellipsis),
    );
  }
}
