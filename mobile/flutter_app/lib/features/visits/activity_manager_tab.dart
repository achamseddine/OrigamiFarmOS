import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/widgets/data_table_card.dart';
import '../../core/widgets/section_card.dart';
import '../../domain/entities/visits.dart';
import '../../providers/visits_provider.dart';

/// Activity Manager (tech spec v0.6 §6, screen 4). RULE-VIS-010: "Horse
/// Ride" is only ever demo data — any activity is created here the same
/// way. RULE-VIS-004/005: capacity, duration, price, an optional required
/// staff role and an optional animal-welfare daily limit are just fields
/// on the form below.
class ActivityManagerTab extends StatefulWidget {
  const ActivityManagerTab({super.key});

  @override
  State<ActivityManagerTab> createState() => _ActivityManagerTabState();
}

class _ActivityManagerTabState extends State<ActivityManagerTab> {
  final _name = TextEditingController();
  final _price = TextEditingController(text: '0');
  final _capacity = TextEditingController(text: '1');
  final _duration = TextEditingController();
  final _staffRole = TextEditingController();
  final _animalId = TextEditingController();
  final _maxUsesPerDay = TextEditingController();
  String _type = 'other';
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _price.dispose();
    _capacity.dispose();
    _duration.dispose();
    _staffRole.dispose();
    _animalId.dispose();
    _maxUsesPerDay.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    final result = await context.read<VisitsProvider>().createActivity(
          name: _name.text.trim(),
          activityType: _type,
          price: double.tryParse(_price.text) ?? 0,
          capacityPerSlot: int.tryParse(_capacity.text) ?? 1,
          durationMinutes: int.tryParse(_duration.text),
          requiresStaffRole: _staffRole.text.trim().isEmpty ? null : _staffRole.text.trim(),
          requiresAnimalId: _animalId.text.trim().isEmpty ? null : _animalId.text.trim(),
          maxUsesPerDay: int.tryParse(_maxUsesPerDay.text),
        );
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (result.success) {
        _name.clear();
        _price.text = '0';
        _capacity.text = '1';
        _duration.clear();
        _staffRole.clear();
        _animalId.clear();
        _maxUsesPerDay.clear();
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Activity created.')));
      } else {
        _error = result.error;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final activities = context.watch<VisitsProvider>().activities;

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionCard(
            title: 'New Activity',
            subtitle: 'A required staff role or a daily-use limit are optional — set them for a ride/animal-interaction activity, leave blank otherwise.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Expanded(flex: 2, child: TextField(controller: _name, decoration: const InputDecoration(labelText: 'Activity name'))),
                  const SizedBox(width: 12),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      value: _type,
                      decoration: const InputDecoration(labelText: 'Type'),
                      items: [for (final t in kVisitActivityTypes) DropdownMenuItem(value: t, child: Text(t))],
                      onChanged: (v) => setState(() => _type = v ?? _type),
                    ),
                  ),
                ]),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(child: TextField(controller: _price, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Price per guest (\$)'))),
                  const SizedBox(width: 12),
                  Expanded(child: TextField(controller: _capacity, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Capacity per slot'))),
                  const SizedBox(width: 12),
                  Expanded(child: TextField(controller: _duration, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Duration (min)'))),
                ]),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(child: TextField(controller: _staffRole, decoration: const InputDecoration(labelText: 'Requires staff role (optional)'))),
                  const SizedBox(width: 12),
                  Expanded(child: TextField(controller: _animalId, decoration: const InputDecoration(labelText: 'Requires animal ID (optional)'))),
                  const SizedBox(width: 12),
                  Expanded(child: TextField(controller: _maxUsesPerDay, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Welfare limit: max uses/day (optional)'))),
                ]),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton(
                    onPressed: _saving ? null : _submit,
                    child: _saving ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Create Activity'),
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
            title: 'Activities',
            child: activities.isEmpty
                ? Text('No activities yet.', style: FarmTypography.textTheme.bodySmall)
                : FarmDataTable(
                    columns: const ['Name', 'Type', 'Price', 'Capacity/slot', 'Requires'],
                    columnFlex: const [2, 1, 1, 1, 2],
                    rows: [
                      for (final a in activities)
                        [
                          Text(a.name, style: FarmTypography.textTheme.titleSmall),
                          Text(a.activityType),
                          Text('\$${a.price.toStringAsFixed(2)}'),
                          Text('${a.capacityPerSlot}'),
                          Text([if (a.requiresStaffRole != null) 'staff: ${a.requiresStaffRole}', if (a.maxUsesPerDay != null) 'max ${a.maxUsesPerDay}/day'].join(' · ').ifEmpty('—')),
                        ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

extension _IfEmpty on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}
