import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../domain/entities/animal.dart';
import '../../domain/entities/observation.dart';
import '../../providers/animals_provider.dart';
import '../../providers/feed_provider.dart';

const _observationTypes = [
  'reduced_appetite',
  'limping',
  'swelling',
  'wound',
  'coughing',
  'nasal_discharge',
  'fever',
  'low_activity',
  'abnormal_milk',
  'abnormal_behavior',
];

String _observationLabel(String key) => key.split('_').map((w) => w[0].toUpperCase() + w.substring(1)).join(' ');

/// Worker-facing capture dialog. Deliberately has no diagnosis field
/// (Constitution: "Workers record observations. Workers do not diagnose.")
Future<void> showObserveDialog(BuildContext context, String animalId) {
  return showDialog(
    context: context,
    builder: (context) => _ObserveDialog(animalId: animalId),
  );
}

class _ObserveDialog extends StatefulWidget {
  const _ObserveDialog({required this.animalId});
  final String animalId;

  @override
  State<_ObserveDialog> createState() => _ObserveDialogState();
}

class _ObserveDialogState extends State<_ObserveDialog> {
  String _type = _observationTypes.first;
  String _severity = 'mild';
  final _notes = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _notes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(context.t('observe')),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(color: FarmColors.mist, borderRadius: BorderRadius.circular(FarmRadii.sm)),
              child: Text(context.t('workerObservationNotice'), style: FarmTypography.textTheme.bodySmall),
            ),
            DropdownButtonFormField<String>(
              value: _type,
              decoration: const InputDecoration(labelText: 'Observation type'),
              items: [for (final t in _observationTypes) DropdownMenuItem(value: t, child: Text(_observationLabel(t)))],
              onChanged: (v) => setState(() => _type = v ?? _type),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: _severity,
              decoration: const InputDecoration(labelText: 'Severity'),
              items: const [
                DropdownMenuItem(value: 'mild', child: Text('Mild')),
                DropdownMenuItem(value: 'moderate', child: Text('Moderate')),
                DropdownMenuItem(value: 'severe', child: Text('Severe')),
              ],
              onChanged: (v) => setState(() => _severity = v ?? _severity),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _notes,
              maxLines: 2,
              decoration: InputDecoration(labelText: context.t('notes')),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: const TextStyle(color: FarmColors.danger, fontSize: 12)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(context.t('cancel'))),
        FilledButton(
          onPressed: _saving ? null : _submit,
          child: _saving ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2)) : Text(context.t('save')),
        ),
      ],
    );
  }

  Future<void> _submit() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    final result = await context.read<AnimalsProvider>().recordObservation(
          animalId: widget.animalId,
          observationType: _type,
          quality: observationQualityToApi(ObservationQuality.humanObserved),
          severity: _severity,
          notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
        );
    if (!mounted) return;
    if (result.success) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.t('saved'))));
    } else {
      setState(() {
        _saving = false;
        _error = result.error;
      });
    }
  }
}

/// Milk-recording dialog. Enforces tech spec §14: "Liters >= 0; destination
/// sale blocked or hard-warned if withdrawal active."
Future<void> showMilkDialog(BuildContext context, Animal animal) {
  return showDialog(context: context, builder: (context) => _MilkDialog(animal: animal));
}

class _MilkDialog extends StatefulWidget {
  const _MilkDialog({required this.animal});
  final Animal animal;

  @override
  State<_MilkDialog> createState() => _MilkDialogState();
}

class _MilkDialogState extends State<_MilkDialog> {
  String _session = 'morning';
  String _destination = 'stored';
  final _liters = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _liters.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isUnderWithdrawal = widget.animal.isUnderWithdrawal;
    return AlertDialog(
      title: Text('${context.t('milk')} — ${widget.animal.name} #${widget.animal.tag}'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (isUnderWithdrawal)
              Container(
                padding: const EdgeInsets.all(10),
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(color: FarmColors.tint(FarmColors.danger, 0.14), borderRadius: BorderRadius.circular(FarmRadii.sm)),
                child: Row(
                  children: [
                    const Icon(Icons.error, color: FarmColors.danger, size: 18),
                    const SizedBox(width: 8),
                    Expanded(child: Text(context.t('cannotBeSoldToday'), style: const TextStyle(color: FarmColors.danger, fontSize: 12.5))),
                  ],
                ),
              ),
            DropdownButtonFormField<String>(
              value: _session,
              decoration: const InputDecoration(labelText: 'Session'),
              items: const [
                DropdownMenuItem(value: 'morning', child: Text('Morning')),
                DropdownMenuItem(value: 'evening', child: Text('Evening')),
              ],
              onChanged: (v) => setState(() => _session = v ?? _session),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _liters,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(labelText: '${context.t('quantity')} (${context.t('liters')})'),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: _destination,
              decoration: const InputDecoration(labelText: 'Destination'),
              items: [
                DropdownMenuItem(value: 'stored', child: Text(context.t('stored'))),
                DropdownMenuItem(
                  value: 'sold',
                  enabled: !isUnderWithdrawal,
                  child: Text(context.t('sold'), style: isUnderWithdrawal ? const TextStyle(color: FarmColors.muted) : null),
                ),
                DropdownMenuItem(value: 'processed', child: Text(context.t('processed'))),
                DropdownMenuItem(value: 'consumed', child: Text(context.t('consumed'))),
              ],
              onChanged: (v) => setState(() => _destination = v ?? _destination),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: const TextStyle(color: FarmColors.danger, fontSize: 12)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(context.t('cancel'))),
        FilledButton(
          onPressed: _saving ? null : _submit,
          child: _saving ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2)) : Text(context.t('save')),
        ),
      ],
    );
  }

  Future<void> _submit() async {
    final liters = double.tryParse(_liters.text.trim());
    if (liters == null || liters < 0) {
      setState(() => _error = context.t('valueMustBePositive'));
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final result = await context.read<AnimalsProvider>().recordMilk(
          animalId: widget.animal.id,
          session: _session,
          liters: liters,
          destination: _destination,
        );
    if (!mounted) return;
    if (result.success) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.t('saved'))));
    } else {
      setState(() {
        _saving = false;
        _error = result.error;
      });
    }
  }
}

/// Manager/veterinarian-gated treatment dialog (Constitution: "Veterinarians
/// diagnose and prescribe"). Tech spec §14: "Medication, dose, route, start
/// date, responsible user, and withdrawal period are required where
/// applicable."
Future<void> showTreatDialog(BuildContext context, Animal animal) {
  return showDialog(context: context, builder: (context) => _TreatDialog(animal: animal));
}

class _TreatDialog extends StatefulWidget {
  const _TreatDialog({required this.animal});
  final Animal animal;

  @override
  State<_TreatDialog> createState() => _TreatDialogState();
}

class _TreatDialogState extends State<_TreatDialog> {
  final _diagnosis = TextEditingController();
  final _medication = TextEditingController();
  final _dose = TextEditingController();
  final _route = TextEditingController(text: 'Intramuscular');
  int _withdrawalDays = 3;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _diagnosis.dispose();
    _medication.dispose();
    _dose.dispose();
    _route.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('${context.t('treat')} — ${widget.animal.name} #${widget.animal.tag}'),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(color: FarmColors.tint(FarmColors.gold, 0.18), borderRadius: BorderRadius.circular(FarmRadii.sm)),
              child: Text(context.t('diagnosisLocked'), style: FarmTypography.textTheme.bodySmall),
            ),
            TextField(controller: _diagnosis, decoration: const InputDecoration(labelText: 'Diagnosis')),
            const SizedBox(height: 10),
            TextField(controller: _medication, decoration: const InputDecoration(labelText: 'Medication *')),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(child: TextField(controller: _dose, decoration: const InputDecoration(labelText: 'Dose *'))),
                const SizedBox(width: 10),
                Expanded(child: TextField(controller: _route, decoration: const InputDecoration(labelText: 'Route *'))),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                const Text('Withdrawal (days):'),
                Expanded(
                  child: Slider(
                    value: _withdrawalDays.toDouble(),
                    min: 0,
                    max: 21,
                    divisions: 21,
                    label: '$_withdrawalDays',
                    onChanged: (v) => setState(() => _withdrawalDays = v.round()),
                  ),
                ),
                Text('$_withdrawalDays'),
              ],
            ),
            if (_error != null) Text(_error!, style: const TextStyle(color: FarmColors.danger, fontSize: 12)),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(context.t('cancel'))),
        FilledButton(
          onPressed: _saving ? null : _submit,
          child: _saving ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2)) : Text(context.t('save')),
        ),
      ],
    );
  }

  Future<void> _submit() async {
    if (_medication.text.trim().isEmpty || _dose.text.trim().isEmpty || _route.text.trim().isEmpty) {
      setState(() => _error = 'Medication, dose and route are required.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final result = await context.read<AnimalsProvider>().recordTreatment(
          animalId: widget.animal.id,
          medication: _medication.text.trim(),
          dose: _dose.text.trim(),
          route: _route.text.trim(),
          diagnosis: _diagnosis.text.trim().isEmpty ? null : _diagnosis.text.trim(),
          withdrawalUntil: _withdrawalDays > 0 ? DateTime.now().add(Duration(days: _withdrawalDays)) : null,
        );
    if (!mounted) return;
    if (result.success) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.t('saved'))));
    } else {
      setState(() {
        _saving = false;
        _error = result.error;
      });
    }
  }
}

Future<void> showMoveDialog(BuildContext context, Animal animal) {
  return showDialog(context: context, builder: (context) => _MoveDialog(animal: animal));
}

class _MoveDialog extends StatefulWidget {
  const _MoveDialog({required this.animal});
  final Animal animal;

  @override
  State<_MoveDialog> createState() => _MoveDialogState();
}

class _MoveDialogState extends State<_MoveDialog> {
  late final _location = TextEditingController(text: widget.animal.location);
  bool _saving = false;

  @override
  void dispose() {
    _location.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('${context.t('move')} — ${widget.animal.name} #${widget.animal.tag}'),
      content: SizedBox(
        width: 360,
        child: TextField(controller: _location, decoration: const InputDecoration(labelText: 'New location')),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(context.t('cancel'))),
        FilledButton(
          onPressed: _saving
              ? null
              : () async {
                  setState(() => _saving = true);
                  await context.read<AnimalsProvider>().moveAnimal(animalId: widget.animal.id, newLocation: _location.text.trim());
                  if (!context.mounted) return;
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.t('saved'))));
                },
          child: Text(context.t('save')),
        ),
      ],
    );
  }
}

Future<void> showFeedDialog(BuildContext context, Animal animal) {
  return showDialog(context: context, builder: (context) => _FeedDialog(animal: animal));
}

class _FeedDialog extends StatefulWidget {
  const _FeedDialog({required this.animal});
  final Animal animal;

  @override
  State<_FeedDialog> createState() => _FeedDialogState();
}

class _FeedDialogState extends State<_FeedDialog> {
  String? _itemId;
  final _qty = TextEditingController(text: '2');
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _qty.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final items = context.watch<FeedProvider>().items;
    _itemId ??= items.isNotEmpty ? items.first.id : null;
    return AlertDialog(
      title: Text('${context.t('feed')} — ${widget.animal.name} #${widget.animal.tag}'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DropdownButtonFormField<String>(
              value: _itemId,
              decoration: const InputDecoration(labelText: 'Feed item'),
              items: [for (final i in items) DropdownMenuItem(value: i.id, child: Text('${i.name} (${i.currentQty.toStringAsFixed(0)} ${i.unit})'))],
              onChanged: (v) => setState(() => _itemId = v),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _qty,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Quantity (kg)'),
            ),
            if (_error != null) Text(_error!, style: const TextStyle(color: FarmColors.danger, fontSize: 12)),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(context.t('cancel'))),
        FilledButton(
          onPressed: _saving ? null : _submit,
          child: _saving ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2)) : Text(context.t('save')),
        ),
      ],
    );
  }

  Future<void> _submit() async {
    final qty = double.tryParse(_qty.text.trim());
    if (qty == null || qty <= 0 || _itemId == null) {
      setState(() => _error = context.t('valueMustBePositive'));
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final result = await context.read<FeedProvider>().recordDistribution(
          itemId: _itemId!,
          quantityKg: qty,
          reason: 'supplemental_feeding',
          linkedEntityType: 'animal',
          linkedEntityId: widget.animal.id,
        );
    if (!mounted) return;
    if (result.success) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.t('saved'))));
    } else {
      setState(() {
        _saving = false;
        _error = result.error;
      });
    }
  }
}
