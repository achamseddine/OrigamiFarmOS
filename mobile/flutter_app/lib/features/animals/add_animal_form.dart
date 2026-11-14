import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/util/record_dates.dart';
import '../../api/api_client.dart';
import '../../domain/entities/access.dart';
import '../../domain/entities/animal.dart';
import '../../domain/entities/livestock.dart';
import '../../domain/entities/reproduction.dart';
import '../../providers/access_provider.dart';
import '../../providers/animals_provider.dart';
import '../../providers/herd_records_provider.dart';
import '../../providers/livestock_provider.dart';
import '../scan/qr_labels.dart';
import 'animal_quick_actions.dart';
import 'animal_status_section.dart';
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
/// Only a name is mandatory: a farmer standing in a barn registers an
/// animal in a few fields and fills in the rest later. Nothing has to be
/// scanned — the server gives every new animal the farm's next number, and
/// the tablet shows its QR code to print as soon as it is saved. An ear tag
/// (or a horse's microchip) the species expects can be typed now or added
/// on the Digital Twin when the animal is tagged; until then the twin says
/// it is missing. Financial fields appear only for someone who also holds
/// Finance; the backend drops them for anyone else regardless.
///
/// Pregnancy and milking are asked as two plain questions, on a new animal
/// and on an existing one alike. They are never saved as flags: a new
/// animal arrives with the episodes that say so (one request), and on an
/// edit each changed answer becomes the record the herd keeps — an
/// insemination, a pregnancy check, the start of a lactation, a dry-off.
/// Saying an animal is in milk opens the milk record straight after.
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

  // Pregnancy & milk, as asked (see [AnimalStatusSection]); the initial
  // values are what the herd records said when the form opened.
  late PregnancyChoice _preg = widget.animal?.pregnant == true ? PregnancyChoice.pregnant : PregnancyChoice.open;
  late PregnancyChoice _initialPreg = _preg;
  DateTime? _serviceDate;
  DateTime? _initialServiceDate;
  String _serviceType = kServiceTypes.first;
  late MilkChoice _milk = widget.animal?.lactating == true ? MilkChoice.milking : MilkChoice.dry;
  late MilkChoice _initialMilk = _milk;
  // The calving that started the current lactation (days in milk, the peak
  // and the breeding wait count from it); locked when a recorded birth
  // dates it.
  DateTime? _calving;
  DateTime? _initialCalving;
  bool _calvingLocked = false;
  // Status on the farm: null keeps the animal on the farm; an exit type
  // (sold, dead…) records its exit with the day and the reason.
  String? _exitType;
  DateTime _exitDay = DateTime.now();
  final _exitReason = TextEditingController();
  String? _adjustedNote;
  bool _loadingHistory = false;
  bool _statusTouched = false;
  // Records already written by an edit that then failed part-way, so a
  // second Save does not write them twice.
  final Set<String> _statusDone = {};

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
    if (animal != null && animal.sex.trim().toUpperCase().startsWith('F')) _loadHistory(animal.id);
  }

  /// Reads the animal's reproduction record: an insemination not yet
  /// confirmed, and the date a pregnancy is reckoned from.
  Future<void> _loadHistory(String animalId) async {
    setState(() => _loadingHistory = true);
    ReproSummary? summary;
    try {
      summary = (await context.read<HerdRecordsProvider>().timeline(animalId)).summary;
    } catch (_) {
      summary = null;
    }
    if (!mounted) return;
    setState(() {
      _loadingHistory = false;
      if (summary == null || _statusTouched) return;
      final initial = summary.pregnant
          ? PregnancyChoice.pregnant
          : summary.inseminatedUnconfirmed
              ? PregnancyChoice.inseminated
              : PregnancyChoice.open;
      _preg = _initialPreg = initial;
      final served = summary.pregnancy?.conceivedAt ?? (initial == PregnancyChoice.inseminated ? summary.lastBreeding?.occurredAt : null);
      _serviceDate = _initialServiceDate = served?.toLocal();
      final type = summary.lastBreeding?.eventType;
      if (type != null && kServiceTypes.contains(type)) _serviceType = type;
      _milk = _initialMilk = summary.lactation != null ? MilkChoice.milking : MilkChoice.dry;
      _calving = _initialCalving = summary.lactation?.startedAt?.toLocal();
      _calvingLocked = summary.lactation?.birthEventId != null;
    });
  }

  /// The life stage / profile an answer needs, when the current ones do
  /// not allow it: a "young" female cannot be recorded pregnant, a cow with
  /// no dairy profile cannot be milked. Null when nothing needs to change,
  /// or when nothing would help (a male, a species that is never milked).
  ({String stage, String? profile})? _fixFor(LivestockProvider livestock, String cap) {
    bool grants(String? stage, String? profile) =>
        livestock.resolve(species: _speciesCode, sex: _sex, lifeStage: stage, managementProfile: profile).has(cap);
    if (grants(_lifeStage, _profile)) return null;
    final config = livestock.configurationFor(_speciesCode);
    final profiles = [for (final p in config?.managementProfiles ?? const <ManagementProfile>[]) p.code];
    final stages = [
      if (_lifeStage != null) _lifeStage!,
      for (final s in const [kDefaultLifeStage, 'senior'])
        if (s != _lifeStage && (config?.lifeStages ?? const <LifeStage>[]).any((x) => x.code == s)) s,
    ];
    for (final stage in stages) {
      if (grants(stage, _profile)) return (stage: stage, profile: _profile);
      for (final p in profiles) {
        if (grants(stage, p)) return (stage: stage, profile: p);
      }
    }
    return null;
  }

  bool _speciesCan(LivestockProvider livestock, String cap) =>
      _sex == Sex.female && (_resolve(livestock).has(cap) || _fixFor(livestock, cap) != null);

  /// Moves stage / profile to what [cap] needs, and says so.
  void _ensureCapability(LivestockProvider livestock, String cap) {
    final fix = _fixFor(livestock, cap);
    if (fix == null) return;
    final lang = Localizations.localeOf(context).languageCode;
    final config = livestock.configurationFor(_speciesCode);
    final parts = <String>[];
    if (fix.stage != _lifeStage) {
      final label = (config?.lifeStages ?? const <LifeStage>[]).where((s) => s.code == fix.stage).map((s) => s.label(lang)).firstOrNull ?? fix.stage;
      parts.add('${context.t('lifeStage')}: $label');
      _lifeStage = fix.stage;
    }
    if (fix.profile != _profile) {
      final label =
          (config?.managementProfiles ?? const <ManagementProfile>[]).where((p) => p.code == fix.profile).map((p) => p.label(lang)).firstOrNull ??
              fix.profile ?? context.t('noProfile');
      parts.add('${context.t('managementProfile')}: $label');
      _profile = fix.profile;
    }
    if (parts.isNotEmpty) _adjustedNote = '${context.t('stAdjusted')} ${parts.join(' · ')}';
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
      _acquisitionSource, _sireTag, _damTag, _purchaseCost, _currentValue, _notes, _exitReason,
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

    // Identifiers typed now are optional — the server adds the farm number
    // every animal gets. The ear tag a species expects can come later.
    final identifiers = <Map<String, dynamic>>[];
    if (!_isEdit) {
      var primaryTaken = false;
      for (final type in _identifierTypes(caps)) {
        final value = _identifiers[type]?.text.trim() ?? '';
        if (value.isEmpty) continue;
        identifiers.add({'identifier_type': type, 'identifier_value': value, 'is_primary': !primaryTaken});
        primaryTaken = true;
      }
    }

    final askPregnancy = _sex == Sex.female && caps.has(Cap.pregnancy);
    final askMilk = _sex == Sex.female && caps.has(Cap.lactation);
    final served = askPregnancy && _preg != PregnancyChoice.open;
    if (served && _preg == PregnancyChoice.inseminated && _serviceDate == null) {
      setState(() => _error = context.t('stServiceDateNeeded'));
      return;
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
      // Opening state at registration only: an animal bought in pregnant
      // or in milk arrives with that episode, dated from the insemination
      // when one is given. On an edit the answers become records after the
      // save ([_applyStatus]) — status is a projection (REPRODUCTION-SCHEMA).
      if (!_isEdit) 'pregnant': askPregnancy && _preg == PregnancyChoice.pregnant,
      if (!_isEdit && served && _serviceDate != null) 'service_date': _utcDate(_serviceDate!),
      if (!_isEdit && served && _serviceDate != null) 'service_type': _serviceType,
      if (!_isEdit) 'lactating': askMilk && _milk == MilkChoice.milking,
      if (!_isEdit && askMilk && _milk == MilkChoice.milking && _calving != null) 'lactation_started_at': _utcDate(_calving!),
      'purchase_cost': double.tryParse(_purchaseCost.text),
      'current_value': double.tryParse(_currentValue.text),
      'notes': _blank(_notes.text),
    };

    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final hostContext = navigator.context;
    final speciesName = livestock.speciesName(_speciesCode, Localizations.localeOf(context).languageCode);
    final startMilk = askMilk && _milk == MilkChoice.milking && _initialMilk != MilkChoice.milking;
    final tUpdated = context.t('animalUpdated');
    final tAdded = context.t('animalAdded');
    final tOffline = context.t('stAddedOffline');
    final tQrReady = context.t('stQrReady');
    final tQrNote = context.t('stQrReadyNote');

    // An edit that already saved the animal and part of the records is not
    // sent again: only what is still missing.
    final result = _isEdit
        ? (_statusDone.contains('animal') ? const WriteResult.ok() : await provider.updateAnimal(widget.animal!.id, body))
        : await provider.createAnimal(body);
    if (!mounted) return;
    if (!result.success) {
      setState(() {
        _saving = false;
        _error = result.error;
      });
      return;
    }
    if (_isEdit) {
      _statusDone.add('animal');
      // Leaving the farm is the whole story: the exit closes the pregnancy,
      // the lactation and the group memberships itself.
      final failure = _exitType != null
          ? await _recordExit(widget.animal!)
          : await _applyStatus(widget.animal!, askPregnancy: askPregnancy, askMilk: askMilk);
      if (!mounted) return;
      if (failure != null) {
        setState(() {
          _saving = false;
          _error = failure;
        });
        return;
      }
      await provider.load();
      navigator.pop();
      messenger.showSnackBar(SnackBar(content: Text(tUpdated)));
      final updated = provider.find(widget.animal!.id) ?? widget.animal!;
      if (startMilk && _exitType == null && hostContext.mounted) await showMilkDialog(hostContext, updated, justStarted: true);
      return;
    }

    navigator.pop();
    final id = result.serverId;
    final created = id == null ? null : provider.find(id);
    if (created == null) {
      // Saved in the outbox: the server has not numbered it yet, and a QR
      // label must carry the id the server will know.
      messenger.showSnackBar(SnackBar(content: Text(result.queued ? tOffline : tAdded)));
      return;
    }
    messenger.showSnackBar(SnackBar(content: Text(tAdded)));
    if (!hostContext.mounted) return;
    await showQrLabels(
      hostContext,
      labels: [QrLabel.forAnimal(created, speciesName: speciesName)],
      title: '${created.name} — $tQrReady',
      note: tQrNote,
    );
    if (startMilk && hostContext.mounted) await showMilkDialog(hostContext, created, justStarted: true);
  }

  static String _utcDate(DateTime d) => _noonUtc(d).toIso8601String();

  Future<String?> _recordExit(Animal animal) async {
    if (_statusDone.contains('exit')) return null;
    final r = await context.read<HerdRecordsProvider>().exitAnimal(animal.id, exitType: _exitType!, occurredAt: recordedInstant(_exitDay), reason: _exitReason.text);
    if (!r.success) return r.error;
    _statusDone.add('exit');
    return null;
  }

  /// Turns the changed answers of an edit into the herd's records, in the
  /// order the server needs them: a "not pregnant" check before a new
  /// service, the service before the check that confirms it. Returns the
  /// server's refusal, if any.
  Future<String?> _applyStatus(Animal animal, {required bool askPregnancy, required bool askMilk}) async {
    final herd = context.read<HerdRecordsProvider>();
    final couldNotSave = context.t('couldNotSave');
    Future<String?> step(String key, Future<WriteResult> Function() write) async {
      if (_statusDone.contains(key)) return null;
      final r = await write();
      if (!r.success) return r.error ?? couldNotSave;
      _statusDone.add(key);
      return null;
    }

    if (askPregnancy && (_preg != _initialPreg || !_sameDay(_serviceDate, _initialServiceDate))) {
      final wasPregnant = _initialPreg == PregnancyChoice.pregnant;
      final wasServed = _initialPreg == PregnancyChoice.inseminated;
      final newService = _serviceDate != null && (!_sameDay(_serviceDate, _initialServiceDate) || _initialPreg == PregnancyChoice.open || wasPregnant);
      String? error;
      switch (_preg) {
        case PregnancyChoice.open:
          if (wasPregnant || wasServed) {
            error = await step('negative', () => herd.recordPregnancyCheck(animal.id, assessmentType: 'OBSERVATION', resultCode: 'NEGATIVE'));
          }
        case PregnancyChoice.inseminated:
          if (wasPregnant) {
            error = await step('negative', () => herd.recordPregnancyCheck(animal.id, assessmentType: 'OBSERVATION', resultCode: 'NEGATIVE'));
          }
          if (error == null && newService) {
            error = await step('service', () => herd.recordBreeding(animal.id, eventType: _serviceType, occurredAt: _noonUtc(_serviceDate!)));
          }
        case PregnancyChoice.pregnant:
          if (!wasPregnant) {
            if (newService) {
              error = await step('service', () => herd.recordBreeding(animal.id, eventType: _serviceType, occurredAt: _noonUtc(_serviceDate!)));
            }
            // Dated by the server from the service just recorded (or the
            // one already on record).
            error ??= await step('positive', () => herd.recordPregnancyCheck(animal.id, assessmentType: 'OBSERVATION', resultCode: 'POSITIVE'));
          } else if (_serviceDate != null) {
            // Already pregnant, the insemination date corrected: a check
            // that re-dates the pregnancy from it.
            final days = DateTime.now().difference(_serviceDate!).inDays;
            error = await step('redate', () => herd.recordPregnancyCheck(animal.id, assessmentType: 'OBSERVATION', resultCode: 'POSITIVE', gestationDays: days));
          }
      }
      if (error != null) return error;
    }
    if (askMilk) {
      if (_milk == MilkChoice.milking && _initialMilk != MilkChoice.milking) {
        final error = await step('lactation', () => herd.startLactation(animal.id, at: _calving == null ? null : _noonUtc(_calving!)));
        if (error != null) return error;
      } else if (_milk == MilkChoice.milking && !_calvingLocked && _calving != null && !_sameDay(_calving, _initialCalving)) {
        final error = await step('calving', () => herd.correctLactationStart(animal.id, _noonUtc(_calving!), reason: 'calving date entered on the profile'));
        if (error != null) return error;
      } else if (_milk == MilkChoice.dry && _initialMilk == MilkChoice.milking) {
        final error = await step('dryoff', () => herd.dryOff(animal.id));
        if (error != null) return error;
      }
    }
    return null;
  }

  /// A picked calendar day as an instant: midday UTC, or now when that is
  /// still ahead (the server refuses a service dated in the future).
  static DateTime _noonUtc(DateTime d) {
    final noon = DateTime.utc(d.year, d.month, d.day, 12);
    final now = DateTime.now().toUtc();
    return noon.isAfter(now) ? now : noon;
  }

  static bool _sameDay(DateTime? a, DateTime? b) =>
      (a == null && b == null) || (a != null && b != null && a.year == b.year && a.month == b.month && a.day == b.day);

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
              isExpanded: true,
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
              isExpanded: true,
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
                isExpanded: true,
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
                isExpanded: true,
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
                isExpanded: true,
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
        if (!_isEdit) ...[
          const SizedBox(height: FarmSpacing.md),
          _label(context, 'identification'),
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.qr_code_2, size: 18, color: FarmColors.cedar),
              const SizedBox(width: 8),
              Expanded(child: Text(context.t('stAutoIdNote'), style: FarmTypography.textTheme.bodySmall)),
            ]),
          ),
          if (identifierTypes.isNotEmpty)
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
                        labelText: context.t('id_$type'),
                        hintText: requiredTypes.contains(type) ? context.t('stTagLater') : context.t('optional'),
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
          // A group of this species that exists (LIVESTOCK-SCHEMA §7): the
          // server moves the membership, and refuses a name that is no group.
          Expanded(child: _GroupPicker(speciesCode: _speciesCode, controller: _group, onChanged: () => setState(() {}))),
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
              isExpanded: true,
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
        // Pregnancy & milk: asked of every female whose species has them —
        // a bull, a hen and a gelding never see it. An answer the current
        // stage / profile does not allow moves them, and says so.
        if (_speciesCan(livestock, Cap.pregnancy) || _speciesCan(livestock, Cap.lactation)) ...[
          const SizedBox(height: FarmSpacing.md),
          _label(context, 'stSection'),
          AnimalStatusSection(
            showPregnancy: _speciesCan(livestock, Cap.pregnancy),
            showMilk: _speciesCan(livestock, Cap.lactation),
            pregnancy: _preg,
            serviceDate: _serviceDate,
            serviceType: _serviceType,
            milk: _milk,
            gestationDays: livestock.speciesByCode(_speciesCode)?.gestationDays,
            dryOffDays: context.watch<HerdRecordsProvider>().overview.dryOffDays,
            isEdit: _isEdit,
            wasLactating: _initialMilk == MilkChoice.milking,
            adjustedNote: _adjustedNote,
            loadingHistory: _loadingHistory,
            calvingDate: _calving,
            calvingLocked: _calvingLocked,
            onCalvingDate: _speciesCan(livestock, Cap.lactation) ? (d) => setState(() => _calving = d) : null,
            peakStartDays: context.watch<HerdRecordsProvider>().overview.calendarDays('milk_peak_start_days', 40),
            peakEndDays: context.watch<HerdRecordsProvider>().overview.calendarDays('milk_peak_end_days', 70),
            breedingWaitDays: context.watch<HerdRecordsProvider>().overview.calendarDays('breeding_wait_days', 50),
            onPregnancy: (c) => setState(() {
              _statusTouched = true;
              _preg = c;
              if (c != PregnancyChoice.open) _ensureCapability(livestock, Cap.pregnancy);
            }),
            onServiceDate: (d) => setState(() {
              _statusTouched = true;
              _serviceDate = d;
            }),
            onServiceType: (t) => setState(() => _serviceType = t),
            onMilk: (c) => setState(() {
              _statusTouched = true;
              _milk = c;
              if (c == MilkChoice.milking) _ensureCapability(livestock, Cap.lactation);
            }),
          ),
        ],
        if (_isEdit) ...[
          const SizedBox(height: FarmSpacing.md),
          _label(context, 'stFarmStatus'),
          _farmStatus(context),
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

  /// On the farm, or gone — sold, died, culled, slaughtered, transferred.
  /// Leaving is recorded as the exit it is (date, reason), never by editing
  /// a status field, and the record stays.
  Widget _farmStatus(BuildContext context) {
    final animal = widget.animal!;
    if (!animal.onFarm) {
      return Text(
        '${context.t('exit_${animal.lifecycleStatus}')}${animal.exitedAt != null ? ' · ${dayLabel(animal.exitedAt!.toLocal())}' : ''}',
        style: FarmTypography.textTheme.titleSmall?.copyWith(color: FarmColors.danger),
      );
    }
    final access = context.watch<AccessProvider>();
    final refused = [for (final t in ReproCodes.exitTypes) if (!access.canRecordExit(t)) t];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(spacing: 8, runSpacing: 8, children: [
        ChoiceChip(label: Text(context.t('active')), selected: _exitType == null, onSelected: (_) => setState(() => _exitType = null)),
        for (final t in ReproCodes.exitTypes)
          ChoiceChip(
            label: Text(context.t('exit_$t')),
            selected: _exitType == t,
            // Greyed out rather than refused after the form is filled in.
            onSelected: refused.contains(t) ? null : (_) => setState(() => _exitType = t),
          ),
      ]),
      if (refused.isNotEmpty) ...[
        const SizedBox(height: 6),
        Text(context.t(refused.contains('dead') ? 'exitNeedsEdit' : 'exitNeedsApproval'),
            style: const TextStyle(fontSize: 12, color: FarmColors.muted)),
      ],
      if (_exitType != null) ...[
        const SizedBox(height: 10),
        Wrap(spacing: 12, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
          RecordDateButton(label: context.t('reproDate'), value: _exitDay, onPicked: (d) => setState(() => _exitDay = d)),
          SizedBox(width: 320, child: TextField(controller: _exitReason, decoration: InputDecoration(labelText: context.t('reason')))),
        ]),
        const SizedBox(height: 6),
        Text(context.t('exitWarning'), style: const TextStyle(fontSize: 12.5, color: FarmColors.dangerInk)),
      ],
    ]);
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


/// The herd / group field: the groups of this species, or none. A legacy
/// free-text name that names no group stays selectable, so an edit that
/// does not touch it is not refused.
class _GroupPicker extends StatelessWidget {
  const _GroupPicker({required this.speciesCode, required this.controller, required this.onChanged});

  final String speciesCode;
  final TextEditingController controller;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final names = [
      for (final g in context.watch<LivestockProvider>().groups)
        if (g.species == speciesCode) g.name,
    ];
    final current = controller.text.trim();
    if (current.isNotEmpty && !names.contains(current)) names.add(current);
    return DropdownButtonFormField<String?>(
      key: ValueKey('group-$speciesCode'),
      initialValue: current.isEmpty ? null : current,
      isExpanded: true,
      decoration: InputDecoration(labelText: context.t('herdOrGroup')),
      items: [
        DropdownMenuItem<String?>(value: null, child: Text(context.t('herdNoGroup'))),
        for (final n in names) DropdownMenuItem<String?>(value: n, child: Text(n, overflow: TextOverflow.ellipsis)),
      ],
      onChanged: (v) {
        controller.text = v ?? '';
        onChanged();
      },
    );
  }
}
