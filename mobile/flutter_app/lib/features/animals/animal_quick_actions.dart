import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/i18n/strings.dart';
import '../../core/util/number_input.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../domain/entities/animal.dart';
import '../../domain/entities/observation.dart';
import '../../providers/animals_provider.dart';
import '../feed/feeding_event_dialog.dart';

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
              decoration: InputDecoration(labelText: context.t('observationType')),
              items: [for (final t in _observationTypes) DropdownMenuItem(value: t, child: Text(_observationLabel(t)))],
              onChanged: (v) => setState(() => _type = v ?? _type),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: _severity,
              decoration: InputDecoration(labelText: context.t('severity')),
              items: [
                DropdownMenuItem(value: 'mild', child: Text(context.t('sevMild'))),
                DropdownMenuItem(value: 'moderate', child: Text(context.t('sevModerate'))),
                DropdownMenuItem(value: 'severe', child: Text(context.t('sevSevere'))),
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
      title: Text('${context.t('milk')} — ${widget.animal.name} #${widget.animal.primaryId}'),
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
              decoration: InputDecoration(labelText: context.t('session')),
              items: [
                DropdownMenuItem(value: 'morning', child: Text(context.t('sessionMorning'))),
                DropdownMenuItem(value: 'evening', child: Text(context.t('sessionEvening'))),
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
            if (isUnderWithdrawal)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: FarmSpacing.sm),
                child: Text(context.t('qrWithheldMilk'), style: const TextStyle(color: FarmColors.dangerInk)),
              )
            else DropdownButtonFormField<String>(
              value: _destination,
              decoration: InputDecoration(labelText: context.t('destination')),
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
    final liters = parseLocalizedDouble(_liters.text);
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
          destination: widget.animal.isUnderWithdrawal ? 'withheld' : _destination,
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
      title: Text('${context.t('move')} — ${widget.animal.name} #${widget.animal.primaryId}'),
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

/// The Feed quick action opens the generic feeding dialog (generic feed
/// architecture §2.6). The server issues the stock from the feed's lots
/// and applies its usage policy, so the tablet no longer picks a raw
/// inventory item and writes a bare movement against it.
Future<void> showFeedDialog(BuildContext context, Animal animal) =>
    showFeedingEventDialog(context, subjectType: 'animal', subjectId: animal.id, subjectName: animal.name);
