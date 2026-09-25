import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../domain/entities/access.dart';
import '../../domain/entities/animal.dart';
import '../../domain/entities/livestock.dart';
import '../../providers/access_provider.dart';
import '../../providers/animals_provider.dart';
import '../../providers/livestock_provider.dart';
import 'capability_chips.dart';

/// The Add / Edit Animal record — the start of an animal's digital twin.
///
/// Nothing in this file knows what a cow is. The species come from the
/// catalog (`GET /species`); choosing species → sex → life stage →
/// management profile runs the capability resolver on the device, and
/// the resolved set shapes the rest of the form: which identifier fields
/// appear and which are required (an ear tag for cattle, a microchip for
/// a horse, a leg band for a hen), whether "pregnant" and "lactating" are
/// asked at all, and what the farm calls a female of the species. A
/// species added on the server appears here with no app update — and the
/// rules are cached with the rest of the farm, so this works in a field
/// with no signal.
///
/// Only a name and the species' required identifiers are mandatory: a
/// farmer standing in a barn registers an animal in three fields and
/// fills in the rest later. Financial fields appear only for someone who
/// also holds Finance; the backend drops them for anyone else regardless.
///
/// Editing changes the animal, not its identifiers: those are managed on
/// the Digital Twin (add one, retire one) so a replaced ear tag keeps its
/// history. The one exception is the primary identifier's value, which
/// the server accepts as `tag` and records as a replacement.
void showAnimalForm(BuildContext context, {Animal? animal}) {
  showDialog<void>(context: context, builder: (_) => _AnimalFormDialog(animal: animal));
}

/// Dropdown sentinels: a breed the catalog does not list, no profile.
const _otherBreed = '__other__';
const _noProfile = '__none__';

class _AnimalFormDialog extends StatefulWidget {
  const _AnimalFormDialog({this.animal});
  final Animal? animal;

  @override
  State<_AnimalFormDialog> createState() => _AnimalFormDialogState();
}

class _AnimalFormDialogState extends State<_AnimalFormDialog> {
  late final _name = TextEditingController(text: widget.animal?.name ?? '');
  late final _breed = TextEditingController(text: widget.animal?.breed ?? '');
  late final _primaryId = TextEditingController(text: widget.animal?.primaryId ?? '');
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

  /// One field per identifier type, created the first time the type is
  /// offered and kept if the species changes and comes back — the ear tag
  /// typed before a mis-tap on "horse" is still there after "cow" again.
  final Map<String, TextEditingController> _identifiers = {};

  late String _speciesCode;
  late String _sex;
  String? _lifeStage;
  String? _profile;
  String? _breedId;
  late String _status = widget.animal != null ? animalStatusToApi(widget.animal!.status) : 'healthy';
  late DateTime? _birthDate = widget.animal?.birthDate;
  late bool _birthDateEstimated = widget.animal?.birthDateEstimated ?? false;
  late DateTime? _acquisitionDate = widget.animal?.acquisitionDate;
  late bool _pregnant = widget.animal?.pregnant ?? false;
  late bool _lactating = widget.animal?.lactating ?? false;

  bool _saving = false;
  String? _error;

  bool get _isEdit => widget.animal != null;

  @override
  void initState() {
    super.initState();
    final livestock = context.read<LivestockProvider>();
    final animal = widget.animal;
    _speciesCode = animal?.species ?? (livestock.species.isNotEmpty ? livestock.species.first.code : '');
    _sex = animal == null ? Sex.female : _sexCode(animal.sex);
    _lifeStage = animal?.lifeStage;
    _profile = animal?.managementProfile;
    _breedId = animal?.breedId;
    _fitToSpecies(livestock, fresh: animal == null);
  }

  static String _sexCode(String raw) => switch (raw.trim().toUpperCase()) {
        'F' || 'FEMALE' => Sex.female,
        'M' || 'MALE' => Sex.male,
        _ => Sex.unknown,
      };

  /// Keeps stage, profile and breed valid for the chosen species. A fresh
  /// record takes the species' defaults; an existing one keeps what it
  /// has unless the species no longer offers it.
  void _fitToSpecies(LivestockProvider livestock, {required bool fresh}) {
    final config = livestock.configurationFor(_speciesCode);
    final stages = config?.lifeStages ?? const <LifeStage>[];
    if (_lifeStage == null || !stages.any((s) => s.code == _lifeStage)) {
      _lifeStage = stages.any((s) => s.code == kDefaultLifeStage)
          ? kDefaultLifeStage
          : (stages.isNotEmpty ? stages.first.code : kDefaultLifeStage);
    }
    final profiles = config?.managementProfiles ?? const <ManagementProfile>[];
    if (_profile != null && !profiles.any((p) => p.code == _profile)) _profile = null;
    if (_profile == null && fresh && profiles.isNotEmpty) _profile = profiles.first.code;
    final breeds = config?.breeds ?? const <Breed>[];
    if (_breedId != null && !breeds.any((b) => b.id == _breedId)) _breedId = null;
  }

  void _changeSpecies(String code) {
    setState(() {
      _speciesCode = code;
      _fitToSpecies(context.read<LivestockProvider>(), fresh: true);
    });
  }

  TextEditingController _identifierField(String type) => _identifiers.putIfAbsent(type, TextEditingController.new);

  @override
  void dispose() {
    for (final c in [
      _name, _breed, _primaryId, _location, _group, _weight, _colorMarkings,
      _acquisitionSource, _sireTag, _damTag, _purchaseCost, _currentValue, _notes,
      ..._identifiers.values,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  CapabilitySet _resolve(LivestockProvider livestock) =>
      livestock.resolve(species: _speciesCode, sex: _sex, lifeStage: _lifeStage, managementProfile: _profile);

  /// The identifier fields to show for this animal, required ones first.
  List<String> _identifierTypes(CapabilitySet caps) {
    final allowed = caps.allowedIdentifierTypes.toSet();
    final required = caps.requiredIdentifierTypes.toSet();
    return [
      for (final t in IdentifierType.fieldOrder)
        if (allowed.contains(t) && required.contains(t)) t,
      for (final t in IdentifierType.fieldOrder)
        if (allowed.contains(t) && !required.contains(t)) t,
    ];
  }

  Future<void> _submit() async {
    final livestock = context.read<LivestockProvider>();
    final caps = _resolve(livestock);
    if (_name.text.trim().isEmpty) {
      setState(() => _error = context.t('nameRequired'));
      return;
    }

    // The same rules the server applies (§12), checked here first so the
    // farmer hears "this species needs an ear tag" before the round trip
    // — and hears it offline, where there is no round trip.
    final identifiers = <Map<String, dynamic>>[];
    if (!_isEdit) {
      for (final type in caps.requiredIdentifierTypes) {
        if ((_identifiers[type]?.text.trim() ?? '').isEmpty) {
          setState(() => _error = '${context.t('requiredIdentifierMissing')} ${context.t('id_$type')}');
          return;
        }
      }
      var primaryTaken = false;
      for (final type in _identifierTypes(caps)) {
        final value = _identifiers[type]?.text.trim() ?? '';
        if (value.isEmpty) continue;
        identifiers.add({'identifier_type': type, 'identifier_value': value, 'is_primary': !primaryTaken});
        primaryTaken = true;
      }
    }

    setState(() {
      _saving = true;
      _error = null;
    });

    String? breedName;
    for (final b in livestock.configurationFor(_speciesCode)?.breeds ?? const <Breed>[]) {
      if (b.id == _breedId) breedName = b.name;
    }

    final provider = context.read<AnimalsProvider>();
    final body = <String, dynamic>{
      'name': _name.text.trim(),
      'species': _speciesCode,
      'breed': breedName ?? _blank(_breed.text),
      'breed_id': _breedId,
      'sex': _sex,
      'life_stage': _lifeStage,
      'management_profile': _profile,
      'birth_date': _birthDate?.toIso8601String(),
      'birth_date_estimated': _birthDateEstimated,
      if (!_isEdit) 'identifiers': identifiers,
      if (_isEdit && _primaryId.text.trim().isNotEmpty) 'tag': _primaryId.text.trim(),
      'acquisition_date': _acquisitionDate?.toIso8601String(),
      'acquisition_source': _blank(_acquisitionSource.text),
      'sire_tag': _blank(_sireTag.text),
      'dam_tag': _blank(_damTag.text),
      'location_label': _blank(_location.text),
      'group_name': _blank(_group.text),
      'weight_kg': double.tryParse(_weight.text),
      'color_markings': _blank(_colorMarkings.text),
      'status': _status,
      // A switch the resolver hid is sent off, whatever it was before: a
      // cow moved to the meat profile stops being flagged as lactating.
      'pregnant': caps.has(Cap.pregnancy) && _pregnant,
      'lactating': caps.has(Cap.lactation) && _lactating,
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
    final livestock = context.watch<LivestockProvider>();
    final showFinance = access.canView(FarmModule.finance);
    final lang = Localizations.localeOf(context).languageCode;
    final species = livestock.species;

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
              child: species.isEmpty
                  ? _CatalogMissing(loading: livestock.loading, onRetry: () => livestock.load())
                  : SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(horizontal: FarmSpacing.lg),
                      child: _fields(context, livestock, lang, showFinance),
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
                  onPressed: _saving || species.isEmpty ? null : _submit,
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

  Widget _fields(BuildContext context, LivestockProvider livestock, String lang, bool showFinance) {
    final species = livestock.species;
    final config = livestock.configurationFor(_speciesCode);
    final caps = _resolve(livestock);
    final stages = config?.lifeStages ?? const <LifeStage>[];
    final profiles = config?.managementProfiles ?? const <ManagementProfile>[];
    final breeds = config?.breeds ?? const <Breed>[];
    final identifierTypes = _identifierTypes(caps);
    final requiredTypes = caps.requiredIdentifierTypes.toSet();
    final primaryType = widget.animal?.primaryIdentifier?.type;

    // Every dropdown's value is checked against its items: the catalog
    // can finish loading while this dialog is open, and a value no longer
    // in the list would otherwise take the whole form down.
    final speciesValue = species.any((s) => s.code == _speciesCode) ? _speciesCode : null;
    final stageValue = stages.any((s) => s.code == _lifeStage) ? _lifeStage : null;
    final profileValue = _profile == null ? _noProfile : (profiles.any((p) => p.code == _profile) ? _profile : _noProfile);
    final breedValue = breeds.any((b) => b.id == _breedId) ? _breedId! : _otherBreed;
    final showWeight = caps.capabilities.isEmpty || caps.has(Cap.weightTracking) || caps.has(Cap.growthTracking);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _label(context, 'identity'),
        Row(children: [
          Expanded(flex: 2, child: TextField(controller: _name, decoration: InputDecoration(labelText: context.t('animalName')))),
          if (_isEdit) ...[
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _primaryId,
                decoration: InputDecoration(labelText: primaryType != null ? context.t('id_$primaryType') : context.t('primaryIdentifier')),
              ),
            ),
          ],
        ]),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: DropdownButtonFormField<String>(
              value: speciesValue,
              decoration: InputDecoration(labelText: context.t('species')),
              items: [for (final s in species) DropdownMenuItem(value: s.code, child: Text(s.name(lang)))],
              onChanged: (v) {
                if (v != null) _changeSpecies(v);
              },
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: DropdownButtonFormField<String>(
              value: _sex,
              decoration: InputDecoration(labelText: context.t('sex')),
              items: [
                for (final code in const [Sex.female, Sex.male, Sex.unknown])
                  DropdownMenuItem(value: code, child: Text(_sexLabel(context, livestock, code, lang), overflow: TextOverflow.ellipsis)),
              ],
              onChanged: (v) => setState(() => _sex = v ?? _sex),
            ),
          ),
          if (stages.isNotEmpty) ...[
            const SizedBox(width: 12),
            Expanded(
              child: DropdownButtonFormField<String>(
                value: stageValue,
                decoration: InputDecoration(labelText: context.t('lifeStage')),
                items: [for (final s in stages) DropdownMenuItem(value: s.code, child: Text(s.label(lang)))],
                onChanged: (v) => setState(() => _lifeStage = v ?? _lifeStage),
              ),
            ),
          ],
        ]),
        const SizedBox(height: 12),
        Row(children: [
          if (breeds.isNotEmpty) ...[
            Expanded(
              child: DropdownButtonFormField<String>(
                value: breedValue,
                decoration: InputDecoration(labelText: context.t('breed')),
                items: [
                  for (final b in breeds) DropdownMenuItem(value: b.id, child: Text(b.label(lang))),
                  DropdownMenuItem(value: _otherBreed, child: Text(context.t('otherBreed'))),
                ],
                onChanged: (v) => setState(() => _breedId = v == _otherBreed ? null : v),
              ),
            ),
            const SizedBox(width: 12),
          ],
          if (breeds.isEmpty || _breedId == null) ...[
            Expanded(child: TextField(controller: _breed, decoration: InputDecoration(labelText: context.t('breed')))),
            const SizedBox(width: 12),
          ],
          if (profiles.isNotEmpty)
            Expanded(
              child: DropdownButtonFormField<String>(
                value: profileValue,
                decoration: InputDecoration(labelText: context.t('managementProfile')),
                items: [
                  for (final p in profiles) DropdownMenuItem(value: p.code, child: Text(p.label(lang))),
                  DropdownMenuItem(value: _noProfile, child: Text(context.t('noProfile'))),
                ],
                onChanged: (v) => setState(() => _profile = v == _noProfile ? null : v),
              ),
            )
          else
            const Spacer(),
        ]),
        if (!_isEdit && identifierTypes.isNotEmpty) ...[
          const SizedBox(height: FarmSpacing.md),
          _label(context, 'identification'),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final type in identifierTypes)
                SizedBox(
                  width: 220,
                  child: TextField(
                    controller: _identifierField(type),
                    decoration: InputDecoration(
                      labelText: requiredTypes.contains(type) ? '${context.t('id_$type')} *' : context.t('id_$type'),
                    ),
                  ),
                ),
            ],
          ),
        ],
        const SizedBox(height: FarmSpacing.md),
        _label(context, 'whatWillBeTracked'),
        CapabilityChips(caps: caps),
        const SizedBox(height: FarmSpacing.md),
        Row(children: [
          Expanded(child: _dateButton(context, context.t('dateOfBirth'), _birthDate, (d) => setState(() => _birthDate = d))),
          const SizedBox(width: 12),
          Expanded(child: _dateButton(context, context.t('acquisitionDate'), _acquisitionDate, (d) => setState(() => _acquisitionDate = d))),
          const SizedBox(width: 12),
          Expanded(child: TextField(controller: _acquisitionSource, decoration: InputDecoration(labelText: context.t('acquisitionSource')))),
        ]),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          dense: true,
          value: _birthDateEstimated,
          title: Text(context.t('birthDateEstimated')),
          onChanged: (v) => setState(() => _birthDateEstimated = v ?? false),
        ),
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
          if (showWeight) ...[
            Expanded(
              child: TextField(
                controller: _weight,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(labelText: context.t('weightKg')),
              ),
            ),
            const SizedBox(width: 12),
          ],
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
        // Reproduction and lactation switches exist only for an animal
        // that can be pregnant or lactating: a bull, a hen and a horse
        // kept for meat never see them.
        if (caps.has(Cap.pregnancy) || caps.has(Cap.lactation)) ...[
          const SizedBox(height: 6),
          Row(children: [
            if (caps.has(Cap.pregnancy))
              Expanded(
                child: CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: _pregnant,
                  title: Text(context.t('pregnant')),
                  onChanged: (v) => setState(() => _pregnant = v ?? false),
                ),
              ),
            if (caps.has(Cap.lactation))
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
        ],
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
    );
  }

  /// "Female · Cow", "Male · Bull": the generic word, then what this farm
  /// calls one of this species.
  String _sexLabel(BuildContext context, LivestockProvider livestock, String code, String lang) {
    final base = switch (code) {
      Sex.female => context.t('female'),
      Sex.male => context.t('male'),
      _ => context.t('unknownSex'),
    };
    final term = switch (code) {
      Sex.female => livestock.term(_speciesCode, 'female', lang),
      Sex.male => livestock.term(_speciesCode, 'male', lang),
      _ => '',
    };
    return term.isEmpty ? base : '$base · $term';
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

/// The form cannot be built without the catalog — there is nothing to
/// pick a species from. This happens once: a tablet that has never been
/// online since install. Say so, and offer to fetch it.
class _CatalogMissing extends StatelessWidget {
  const _CatalogMissing({required this.loading, required this.onRetry});
  final bool loading;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(FarmSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(context.t('speciesCatalogUnavailable'), style: FarmTypography.textTheme.bodyMedium),
          const SizedBox(height: FarmSpacing.md),
          OutlinedButton.icon(
            onPressed: loading ? null : onRetry,
            icon: loading
                ? const SizedBox(height: 14, width: 14, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh, size: 18),
            label: Text(context.t('retry')),
          ),
        ],
      ),
    );
  }
}
