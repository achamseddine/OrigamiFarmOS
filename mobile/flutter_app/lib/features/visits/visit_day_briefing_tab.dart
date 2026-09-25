import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/widgets/kpi_card.dart';
import '../../core/widgets/app_icon.dart';
import '../../core/widgets/section_card.dart';
import '../../core/widgets/status_pill.dart';
import '../../domain/entities/visits.dart';
import '../../providers/visits_provider.dart';

/// Visit-Day Briefing (tech spec v0.6 §6, screen 6) — everything staff need
/// to know before a session opens: expected guests vs. capacity, who's
/// rostered, direct costs booked so far, and a place to log an incident
/// the moment it happens (offline-first — incident logging must work
/// without a connection).
class VisitDayBriefingTab extends StatefulWidget {
  const VisitDayBriefingTab({super.key});

  @override
  State<VisitDayBriefingTab> createState() => _VisitDayBriefingTabState();
}

class _VisitDayBriefingTabState extends State<VisitDayBriefingTab> {
  String? _sessionId;

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<VisitsProvider>();
    final sessions = provider.sessions;
    _sessionId ??= sessions.isNotEmpty ? sessions.last.id : null;
    final session = _sessionId == null ? null : provider.sessionById(_sessionId!);

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionCard(
            title: 'Choose a Session',
            child: DropdownButtonFormField<String>(
              value: _sessionId,
              decoration: const InputDecoration(labelText: 'Session'),
              items: [for (final s in sessions) DropdownMenuItem(value: s.id, child: Text('${s.date.day}/${s.date.month}/${s.date.year} · ${s.startTime}–${s.endTime} · ${s.status}'))],
              onChanged: sessions.isEmpty ? null : (v) => setState(() => _sessionId = v),
            ),
          ),
          if (session != null) ...[
            const SizedBox(height: FarmSpacing.md),
            _SessionBriefing(session: session),
          ],
        ],
      ),
    );
  }
}

class _SessionBriefing extends StatelessWidget {
  const _SessionBriefing({required this.session});
  final VisitSession session;

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<VisitsProvider>();
    final bookings = provider.bookingsForSession(session.id);
    final confirmedGuests = bookings.where((b) => b.status == 'confirmed' || b.status == 'checked_in' || b.status == 'completed').fold<int>(0, (sum, b) => sum + b.guestCount);
    final checkedInGuests = bookings.where((b) => b.status == 'checked_in' || b.status == 'completed').fold<int>(0, (sum, b) => sum + b.guestCount);
    final staff = provider.staffForSession(session.id);
    final costs = provider.costsForSession(session.id);
    final totalCosts = staff.fold<double>(0, (sum, r) => sum + r.totalCost) + costs.fold<double>(0, (sum, c) => sum + c.amount);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LayoutBuilder(builder: (context, c) {
          final perRow = c.maxWidth > 700 ? 4 : 2;
          final w = (c.maxWidth - FarmSpacing.md * (perRow - 1)) / perRow;
          final cards = [
            KpiCard(icon: FarmIcon.calendar, label: 'Capacity', value: '${session.capacity}'),
            KpiCard(icon: FarmIcon.check, label: 'Guests Confirmed', value: '$confirmedGuests', tint: confirmedGuests > session.capacity ? FarmColors.danger : null),
            KpiCard(icon: FarmIcon.eye, label: 'Checked In', value: '$checkedInGuests'),
            KpiCard(icon: FarmIcon.money, label: 'Direct Costs Booked', value: '\$${totalCosts.toStringAsFixed(0)}'),
          ];
          return Wrap(spacing: FarmSpacing.md, runSpacing: FarmSpacing.md, children: [for (final c2 in cards) SizedBox(width: w, child: c2)]);
        }),
        const SizedBox(height: FarmSpacing.md),
        SectionCard(
          title: 'Session Status',
          child: Row(children: [
            Expanded(child: Text('Currently "${session.status}" — closing or cancelling stops new bookings against it.', style: FarmTypography.textTheme.bodySmall)),
            const SizedBox(width: 12),
            DropdownButton<String>(
              value: session.status,
              items: [for (final s in kVisitSessionStatuses) DropdownMenuItem(value: s, child: Text(s))],
              onChanged: (v) {
                if (v != null && v != session.status) provider.updateSession(id: session.id, status: v);
              },
            ),
          ]),
        ),
        const SizedBox(height: FarmSpacing.md),
        SectionCard(
          title: "Today's Bookings",
          child: bookings.isEmpty
              ? Text('No bookings on this session.', style: FarmTypography.textTheme.bodySmall)
              : Column(
                  children: [
                    for (final b in bookings)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Row(children: [
                          Expanded(child: Text('${provider.visitorById(b.visitorId)?.fullName ?? b.visitorId} · ${b.guestCount} guests', style: FarmTypography.textTheme.bodyMedium)),
                          StatusPill(label: b.status.replaceAll('_', ' '), level: b.status == 'checked_in' || b.status == 'completed' ? FarmStatusLevel.good : FarmStatusLevel.neutral, dense: true),
                        ]),
                      ),
                  ],
                ),
        ),
        const SizedBox(height: FarmSpacing.md),
        SectionCard(
          title: 'Staff Rostered',
          child: staff.isEmpty
              ? Text('No staff rostered for this session yet — add some on Staff Roster & Costs.', style: FarmTypography.textTheme.bodySmall)
              : Column(children: [for (final r in staff) Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Text('${r.workerName} — ${r.role} (${r.startTime}–${r.endTime})', style: FarmTypography.textTheme.bodyMedium))]),
        ),
        const SizedBox(height: FarmSpacing.md),
        _IncidentLogger(sessionId: session.id),
        const SizedBox(height: FarmSpacing.md),
        SectionCard(
          title: 'Incidents Logged',
          child: provider.incidentsForSession(session.id).isEmpty
              ? Text('No incidents logged for this session.', style: FarmTypography.textTheme.bodySmall)
              : Column(
                  children: [
                    for (final i in provider.incidentsForSession(session.id))
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          StatusPill(label: i.severity, level: i.severity == 'high' ? FarmStatusLevel.alert : (i.severity == 'medium' ? FarmStatusLevel.watch : FarmStatusLevel.neutral), dense: true),
                          const SizedBox(width: 8),
                          Expanded(child: Text('${i.incidentType}: ${i.description}', style: FarmTypography.textTheme.bodySmall)),
                        ]),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

class _IncidentLogger extends StatefulWidget {
  const _IncidentLogger({required this.sessionId});
  final String sessionId;

  @override
  State<_IncidentLogger> createState() => _IncidentLoggerState();
}

class _IncidentLoggerState extends State<_IncidentLogger> {
  String _type = 'other';
  String _severity = 'low';
  final _description = TextEditingController();
  final _actionTaken = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _description.dispose();
    _actionTaken.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    final result = await context.read<VisitsProvider>().addIncident(
          sessionId: widget.sessionId,
          incidentType: _type,
          severity: _severity,
          description: _description.text.trim(),
          actionTaken: _actionTaken.text.trim().isEmpty ? null : _actionTaken.text.trim(),
        );
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (result.success) {
        _description.clear();
        _actionTaken.clear();
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Incident logged.')));
      } else {
        _error = result.error;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: 'Log an Incident',
      subtitle: 'Safety, animal, weather, payment or complaint — logged offline, synced later.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                value: _type,
                decoration: const InputDecoration(labelText: 'Type'),
                items: [for (final t in kVisitIncidentTypes) DropdownMenuItem(value: t, child: Text(t))],
                onChanged: (v) => setState(() => _type = v ?? _type),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: DropdownButtonFormField<String>(
                value: _severity,
                decoration: const InputDecoration(labelText: 'Severity'),
                items: [for (final s in kVisitIncidentSeverities) DropdownMenuItem(value: s, child: Text(s))],
                onChanged: (v) => setState(() => _severity = v ?? _severity),
              ),
            ),
          ]),
          const SizedBox(height: 12),
          TextField(controller: _description, decoration: const InputDecoration(labelText: 'What happened'), maxLines: 2),
          const SizedBox(height: 12),
          TextField(controller: _actionTaken, decoration: const InputDecoration(labelText: 'Action taken (optional)')),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton(
              onPressed: _saving ? null : _submit,
              child: _saving ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Log Incident'),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: const TextStyle(color: FarmColors.danger, fontSize: 12.5)),
          ],
        ],
      ),
    );
  }
}
