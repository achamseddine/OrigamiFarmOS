import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../domain/entities/access.dart';
import '../../domain/entities/animal.dart';
import '../../providers/access_provider.dart';
import '../../providers/animals_provider.dart';

/// The Add / Edit Animal record (tech spec §13) — the start of an animal's
/// digital twin.
///
/// Only ear tag, name and species are required: a farmer standing in a
/// barn can register an animal in three fields and fill in the rest later.
/// The financial section only appears for someone who also holds Finance;
/// the backend drops those fields for anyone else regardless.
void showAnimalForm(BuildContext context, {Animal? animal}) {
  showDialog<void>(context: context, builder: (_) => _AnimalFormDialog(animal: animal));
}

const _species = ['cow', 'goat', 'sheep', 'horse', 'layer_hen', 'duck', 'turkey', 'other'];

class _AnimalFormDialog extends StatefulWidget {
  const _AnimalFormDialog({this.animal});
  final Animal? animal;

  @override
  State<_AnimalFormDialog> createState() => _AnimalFormDialogState();
}

class _AnimalFormDialogState extends State<_AnimalFormDialog> {
  late final _tag = TextEditingController(text: widget.animal?.tag ?? '');
  late final _name = TextEditingController(text: widget.animal?.name ?? '');
  late final _breed = TextEditingController(text: widget.animal?.breed ?? '');
  late final _location = TextEditingController(text: widget.animal?.location ?? '');
  late final _group = TextEditingController(text: widget.animal?.groupName ?? '');
  late final _weight = TextEditingController(text: widget.animal?.weightKg?.toString() ?? '');
  late final _colorMarkings = TextEditingController(text: widget.animal?.colorMarkings ?? '');
  late final _acquisitionSource = TextEditingController(text: widget.animal?.acquisitionSource ?? '');
  late final _sireTag = TextEditingController(text: widget.animal?.sireTag ?? '');
  late final _damTag = TextEditingController(text: widget.animal?.damTag ?? '');
  late final _purchaseCost = TextEditingController(text: widget.animal?.purchaseCost?.toString() ?? '');
  late final _currentValue = TextEditingController(text: widget.animal?.currentValue?.toString() ?? '');
  late final _notes = TextEditingController(text: widget.animal?.notes ?? '');

  late String _speciesValue = widget.animal != null ? animalSpeciesToApi(widget.animal!.species) : 'cow';
  late String _sex = widget.animal?.sex.isNotEmpty == true ? widget.animal!.sex : 'F';
  late String _status = widget.animal != null ? animalStatusToApi(widget.animal!.status) : 'healthy';
  late DateTime? _birthDate = widget.animal?.birthDate;
  late DateTime? _acquisitionDate = widget.animal?.acquisitionDate;
  late bool _pregnant = widget.animal?.pregnant ?? false;
  late bool _lactating = widget.animal?.lactating ?? false;

  bool _saving = false;
  String? _error;

  bool get _isEdit => widget.animal != null;

  @override
  void dispose() {
    for (final c in [
      _tag, _name, _breed, _location, _group, _weight, _colorMarkings,
      _acquisitionSource, _sireTag, _damTag, _purchaseCost, _currentValue, _notes,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    if (_tag.text.trim().isEmpty || _name.text.trim().isEmpty) {
      setState(() => _error = context.t('tagAndNameRequired'));
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });

    final provider = context.read<AnimalsProvider>();
    final body = <String, dynamic>{
      'tag': _tag.text.trim(),
      'name': _name.text.trim(),
      'species': _speciesValue,
      'breed': _blank(_breed.text),
      'sex': _sex,
      'birth_date': _birthDate?.toIso8601String(),
      'acquisition_date': _acquisitionDate?.toIso8601String(),
      'acquisition_source': _blank(_acquisitionSource.text),
      'sire_tag': _blank(_sireTag.text),
      'dam_tag': _blank(_damTag.text),
      'location_label': _blank(_location.text),
      'group_name': _blank(_group.text),
      'weight_kg': double.tryParse(_weight.text),
      'color_markings': _blank(_colorMarkings.text),
      'status': _status,
      'pregnant': _pregnant,
      'lactating': _lactating,
      'purchase_cost': double.tryParse(_purchaseCost.text),
      'current_value': double.tryParse(_currentValue.text),
      'notes': _blank(_notes.text),
    };

    final result = _isEdit ? await provider.updateAnimal(widget.animal!.id, body) : await provider.createAnimal(body);
    if (!mounted) return;
    if (result.success) {
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_isEdit ? context.t('animalUpdated') : context.t('animalAdded'))),
      );
      return;
    }
    setState(() {
      _saving = false;
      _error = result.error;
    });
  }

  String? _blank(String v) => v.trim().isEmpty ? null : v.trim();

  @override
  Widget build(BuildContext context) {
    final access = context.watch<AccessProvider>();
    final showFinance = access.canView(FarmModule.finance);

    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760, maxHeight: 760),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(FarmSpacing.lg, FarmSpacing.lg, FarmSpacing.sm, 0),
              child: Row(children: [
                Expanded(
                  child: Text(_isEdit ? context.t('editAnimal') : context.t('addAnimal'),
                      style: FarmTypography.display(size: 22)),
                ),
                IconButton(onPressed: () => Navigator.of(context).pop(), icon: const Icon(Icons.close)),
              ]),
            ),
            const Divider(height: 20, color: FarmColors.border),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: FarmSpacing.lg),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _label(context, 'identity'),
                    Row(children: [
                      Expanded(child: TextField(controller: _tag, decoration: InputDecoration(labelText: context.t('earTag')))),
                      const SizedBox(width: 12),
                      Expanded(child: TextField(controller: _name, decoration: InputDecoration(labelText: context.t('animalName')))),
                    ]),
                    const SizedBox(height: 12),
                    Row(children: [
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          value: _speciesValue,
                          decoration: InputDecoration(labelText: context.t('species')),
                          items: [
                            for (final s in _species) DropdownMenuItem(value: s, child: Text(context.t('species_$s'))),
                          ],
                          onChanged: (v) => setState(() => _speciesValue = v ?? _speciesValue),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(child: TextField(controller: _breed, decoration: InputDecoration(labelText: context.t('breed')))),
                      const SizedBox(width: 12),
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          value: _sex,
                          decoration: InputDecoration(labelText: context.t('sex')),
                          items: [
                            DropdownMenuItem(value: 'F', child: Text(context.t('female'))),
                            DropdownMenuItem(value: 'M', child: Text(context.t('male'))),
                          ],
                          onChanged: (v) => setState(() => _sex = v ?? _sex),
                        ),
                      ),
                    ]),
                    const SizedBox(height: 12),
                    Row(children: [
                      Expanded(child: _dateButton(context, context.t('dateOfBirth'), _birthDate, (d) => setState(() => _birthDate = d))),
                      const SizedBox(width: 12),
                      Expanded(child: _dateButton(context, context.t('acquisitionDate'), _acquisitionDate, (d) => setState(() => _acquisitionDate = d))),
                      const SizedBox(width: 12),
                      Expanded(child: TextField(controller: _acquisitionSource, decoration: InputDecoration(labelText: context.t('acquisitionSource')))),
                    ]),
                    const SizedBox(height: 12),
                    Row(children: [
                      Expanded(child: TextField(controller: _sireTag, decoration: InputDecoration(labelText: context.t('sireTag')))),
                      const SizedBox(width: 12),
                      Expanded(child: TextField(controller: _damTag, decoration: InputDecoration(labelText: context.t('damTag')))),
                    ]),
                    const SizedBox(height: FarmSpacing.md),
                    _label(context, 'locationSection'),
                    Row(children: [
                      Expanded(child: TextField(controller: _location, decoration: InputDecoration(labelText: context.t('barnPenPasture')))),
                      const SizedBox(width: 12),
                      Expanded(child: TextField(controller: _group, decoration: InputDecoration(labelText: context.t('herdOrGroup')))),
                    ]),
                    const SizedBox(height: FarmSpacing.md),
                    _label(context, 'physicalAndHealth'),
                    Row(children: [
                      Expanded(
                        child: TextField(
                          controller: _weight,
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(labelText: context.t('weightKg')),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(child: TextField(controller: _colorMarkings, decoration: InputDecoration(labelText: context.t('colorMarkings')))),
                      const SizedBox(width: 12),
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          value: _status,
                          decoration: InputDecoration(labelText: context.t('healthStatus')),
                          items: [
                            DropdownMenuItem(value: 'healthy', child: Text(context.t('healthy'))),
                            DropdownMenuItem(value: 'under_observation', child: Text(context.t('underObservation'))),
                            DropdownMenuItem(value: 'under_treatment', child: Text(context.t('underTreatment'))),
                          ],
                          onChanged: (v) => setState(() => _status = v ?? _status),
                        ),
                      ),
                    ]),
                    const SizedBox(height: 6),
                    Row(children: [
                      Expanded(
                        child: CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          controlAffinity: ListTileControlAffinity.leading,
                          value: _pregnant,
                          title: Text(context.t('pregnant')),
                          onChanged: (v) => setState(() => _pregnant = v ?? false),
                        ),
                      ),
                      Expanded(
                        child: CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          controlAffinity: ListTileControlAffinity.leading,
                          value: _lactating,
                          title: Text(context.t('lactating')),
                          onChanged: (v) => setState(() => _lactating = v ?? false),
                        ),
                      ),
                    ]),
                    if (showFinance) ...[
                      const SizedBox(height: FarmSpacing.md),
                      _label(context, 'financial'),
                      Row(children: [
                        Expanded(
                          child: TextField(
                            controller: _purchaseCost,
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(labelText: context.t('purchaseCost')),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: TextField(
                            controller: _currentValue,
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(labelText: context.t('estimatedValue')),
                          ),
                        ),
                      ]),
                    ],
                    const SizedBox(height: 12),
                    TextField(controller: _notes, maxLines: 2, decoration: InputDecoration(labelText: context.t('notes'))),
                    const SizedBox(height: FarmSpacing.md),
                  ],
                ),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: FarmSpacing.lg),
                child: Text(_error!, style: const TextStyle(color: FarmColors.danger, fontSize: 12.5)),
              ),
            const Divider(height: 20, color: FarmColors.border),
            Padding(
              padding: const EdgeInsets.fromLTRB(FarmSpacing.lg, 0, FarmSpacing.lg, FarmSpacing.lg),
              child: Row(children: [
                const Spacer(),
                TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(context.t('cancel'))),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _saving ? null : _submit,
                  child: _saving
                      ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : Text(_isEdit ? context.t('saveChanges') : context.t('addAnimal')),
                ),
              ]),
            ),
          ],
        ),
      ),
    );
  }

  Widget _dateButton(BuildContext context, String label, DateTime? value, ValueChanged<DateTime> onPicked) {
    return OutlinedButton(
      onPressed: () async {
        final picked = await showDatePicker(
          context: context,
          initialDate: value ?? DateTime.now(),
          firstDate: DateTime(1990),
          lastDate: DateTime.now(),
        );
        if (picked != null) onPicked(picked);
      },
      child: Text(value == null ? label : '${value.day}/${value.month}/${value.year}', overflow: TextOverflow.ellipsis),
    );
  }

  Widget _label(BuildContext context, String key) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(
          context.t(key),
          style: const TextStyle(fontSize: 11, color: FarmColors.muted, fontWeight: FontWeight.w700, letterSpacing: 0.4),
        ),
      );
}
