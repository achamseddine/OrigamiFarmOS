import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/widgets/data_table_card.dart';
import '../../core/widgets/section_card.dart';
import '../../domain/entities/visits.dart';
import '../../providers/visits_provider.dart';

/// Staff Roster & Costs (tech spec v0.6 §6, screen 9) — who's working a
/// session and what it costs, plus every other direct cost (cleaning,
/// utilities, safety, marketing) that feeds the Profitability Report.
class StaffRosterCostsTab extends StatefulWidget {
  const StaffRosterCostsTab({super.key});

  @override
  State<StaffRosterCostsTab> createState() => _StaffRosterCostsTabState();
}

class _StaffRosterCostsTabState extends State<StaffRosterCostsTab> {
  String? _sessionId;

  // Roster form.
  final _workerName = TextEditingController();
  final _role = TextEditingController();
  final _startTime = TextEditingController(text: '09:30');
  final _endTime = TextEditingController(text: '13:30');
  final _hourlyRate = TextEditingController(text: '8');
  bool _rosterSaving = false;
  String? _rosterError;

  // Cost form.
  String _category = 'cleaning';
  final _costDescription = TextEditingController();
  final _costAmount = TextEditingController();
  String _allocationMethod = 'per_session';
  bool _costSaving = false;
  String? _costError;

  @override
  void dispose() {
    _workerName.dispose();
    _role.dispose();
    _startTime.dispose();
    _endTime.dispose();
    _hourlyRate.dispose();
    _costDescription.dispose();
    _costAmount.dispose();
    super.dispose();
  }

  Future<void> _addStaff() async {
    if (_sessionId == null) {
      setState(() => _rosterError = 'Pick a session first.');
      return;
    }
    setState(() {
      _rosterSaving = true;
      _rosterError = null;
    });
    final result = await context.read<VisitsProvider>().addStaffRoster(
          sessionId: _sessionId!,
          workerId: _workerName.text.trim().toLowerCase().replaceAll(' ', '-'),
          workerName: _workerName.text.trim(),
          role: _role.text.trim().isEmpty ? 'guide' : _role.text.trim(),
          startTime: _startTime.text,
          endTime: _endTime.text,
          hourlyRate: double.tryParse(_hourlyRate.text) ?? 0,
        );
    if (!mounted) return;
    setState(() {
      _rosterSaving = false;
      if (result.success) {
        _workerName.clear();
        _role.clear();
      } else {
        _rosterError = result.error;
      }
    });
  }

  Future<void> _addCost() async {
    if (_sessionId == null) {
      setState(() => _costError = 'Pick a session first.');
      return;
    }
    setState(() {
      _costSaving = true;
      _costError = null;
    });
    final result = await context.read<VisitsProvider>().addCost(
          sessionId: _sessionId!,
          category: _category,
          description: _costDescription.text.trim().isEmpty ? null : _costDescription.text.trim(),
          amount: double.tryParse(_costAmount.text) ?? 0,
          allocationMethod: _allocationMethod,
        );
    if (!mounted) return;
    setState(() {
      _costSaving = false;
      if (result.success) {
        _costDescription.clear();
        _costAmount.clear();
      } else {
        _costError = result.error;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<VisitsProvider>();
    final sessions = provider.sessions;
    _sessionId ??= sessions.isNotEmpty ? sessions.last.id : null;
    final staff = _sessionId == null ? const <VisitStaffRosterEntry>[] : provider.staffForSession(_sessionId!);
    final costs = _sessionId == null ? const <VisitCost>[] : provider.costsForSession(_sessionId!);

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionCard(
            title: 'Session',
            child: DropdownButtonFormField<String>(
              value: _sessionId,
              decoration: const InputDecoration(labelText: 'Session'),
              items: [for (final s in sessions) DropdownMenuItem(value: s.id, child: Text('${s.date.day}/${s.date.month}/${s.date.year} · ${s.startTime}–${s.endTime}'))],
              onChanged: sessions.isEmpty ? null : (v) => setState(() => _sessionId = v),
            ),
          ),
          const SizedBox(height: FarmSpacing.md),
          SectionCard(
            title: 'Assign Staff',
            subtitle: 'Total cost = hours worked × hourly rate — used directly by the Profitability Report.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Expanded(child: TextField(controller: _workerName, decoration: const InputDecoration(labelText: 'Worker name'))),
                  const SizedBox(width: 12),
                  Expanded(child: TextField(controller: _role, decoration: const InputDecoration(labelText: 'Role (e.g. guide, horse_handler)'))),
                  const SizedBox(width: 12),
                  Expanded(child: TextField(controller: _startTime, decoration: const InputDecoration(labelText: 'Start (HH:MM)'))),
                  const SizedBox(width: 12),
                  Expanded(child: TextField(controller: _endTime, decoration: const InputDecoration(labelText: 'End (HH:MM)'))),
                  const SizedBox(width: 12),
                  Expanded(child: TextField(controller: _hourlyRate, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Hourly rate (\$)'))),
                  const SizedBox(width: 12),
                  FilledButton(
                    onPressed: _rosterSaving ? null : _addStaff,
                    child: _rosterSaving ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Add'),
                  ),
                ]),
                if (_rosterError != null) ...[
                  const SizedBox(height: 8),
                  Text(_rosterError!, style: const TextStyle(color: FarmColors.danger, fontSize: 12.5)),
                ],
                const SizedBox(height: FarmSpacing.md),
                staff.isEmpty
                    ? Text('No staff rostered for this session.', style: FarmTypography.textTheme.bodySmall)
                    : FarmDataTable(
                        columns: const ['Worker', 'Role', 'Hours', 'Rate', 'Total cost'],
                        rows: [
                          for (final r in staff)
                            [
                              Text(r.workerName),
                              Text(r.role),
                              Text('${r.startTime}–${r.endTime}'),
                              Text('\$${r.hourlyRate.toStringAsFixed(2)}/hr'),
                              Text('\$${r.totalCost.toStringAsFixed(2)}', style: const TextStyle(fontWeight: FontWeight.w700)),
                            ],
                        ],
                      ),
              ],
            ),
          ),
          const SizedBox(height: FarmSpacing.md),
          SectionCard(
            title: 'Direct Costs',
            subtitle: 'Cleaning, utilities, safety, marketing, maintenance or any other visit-day cost.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      value: _category,
                      decoration: const InputDecoration(labelText: 'Category'),
                      items: [for (final c in kVisitCostCategories) DropdownMenuItem(value: c, child: Text(c))],
                      onChanged: (v) => setState(() => _category = v ?? _category),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(flex: 2, child: TextField(controller: _costDescription, decoration: const InputDecoration(labelText: 'Description'))),
                  const SizedBox(width: 12),
                  Expanded(child: TextField(controller: _costAmount, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Amount (\$)'))),
                  const SizedBox(width: 12),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      value: _allocationMethod,
                      decoration: const InputDecoration(labelText: 'Allocation'),
                      items: [for (final m in kVisitCostAllocationMethods) DropdownMenuItem(value: m, child: Text(m))],
                      onChanged: (v) => setState(() => _allocationMethod = v ?? _allocationMethod),
                    ),
                  ),
                  const SizedBox(width: 12),
                  FilledButton(
                    onPressed: _costSaving ? null : _addCost,
                    child: _costSaving ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Add'),
                  ),
                ]),
                if (_costError != null) ...[
                  const SizedBox(height: 8),
                  Text(_costError!, style: const TextStyle(color: FarmColors.danger, fontSize: 12.5)),
                ],
                const SizedBox(height: FarmSpacing.md),
                costs.isEmpty
                    ? Text('No direct costs recorded for this session.', style: FarmTypography.textTheme.bodySmall)
                    : FarmDataTable(
                        columns: const ['Category', 'Description', 'Allocation', 'Amount'],
                        rows: [
                          for (final c in costs)
                            [
                              Text(c.category),
                              Text(c.description ?? '—'),
                              Text(c.allocationMethod),
                              Text('\$${c.amount.toStringAsFixed(2)}', style: const TextStyle(fontWeight: FontWeight.w700)),
                            ],
                        ],
                      ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
