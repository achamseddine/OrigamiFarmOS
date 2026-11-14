import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/util/record_dates.dart';

import '../../api/api_client.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../domain/entities/animal.dart';
import '../../domain/entities/livestock.dart';
import '../../domain/entities/reproduction.dart';
import '../../providers/access_provider.dart';
import '../../providers/animals_provider.dart';
import '../../providers/herd_records_provider.dart';
import '../../providers/livestock_provider.dart';

/// The forms behind the livestock record: breeding, pregnancy checks,
/// births, losses, milking, exits, group moves, head counts and the
/// incubator. Each one only collects what the person saw; the server
/// decides what it means (which pregnancy a check confirms, what a birth
/// closes) and its refusal is shown in its own words.
///
/// Every `show…` returns true when something was recorded, so the caller
/// can redraw the record it came from.

Future<bool> _recordDialog(
  BuildContext context, {
  required String title,
  required List<Widget> Function(BuildContext context, StateSetter setState) fields,
  required Future<WriteResult> Function(BuildContext context) submit,
  String? saveLabel,
  bool destructive = false,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (_) => _RecordDialog(title: title, fields: fields, submit: submit, saveLabel: saveLabel, destructive: destructive),
  );
  return ok == true;
}

class _RecordDialog extends StatefulWidget {
  const _RecordDialog({required this.title, required this.fields, required this.submit, this.saveLabel, this.destructive = false});

  final String title;
  final List<Widget> Function(BuildContext context, StateSetter setState) fields;
  final Future<WriteResult> Function(BuildContext context) submit;
  final String? saveLabel;
  final bool destructive;

  @override
  State<_RecordDialog> createState() => _RecordDialogState();
}

class _RecordDialogState extends State<_RecordDialog> {
  bool _saving = false;
  String? _error;

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    final result = await widget.submit(context);
    if (!mounted) return;
    if (result.success) {
      final messenger = ScaffoldMessenger.of(context);
      final text = result.queued ? context.t('workingOffline') : context.t('saved');
      Navigator.pop(context, true);
      messenger.showSnackBar(SnackBar(content: Text(text)));
    } else {
      setState(() {
        _saving = false;
        _error = result.error ?? context.t('couldNotSave');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ...widget.fields(context, setState),
              if (_error != null) ...[
                const SizedBox(height: FarmSpacing.sm),
                Text(_error!, style: const TextStyle(color: FarmColors.danger, fontSize: 12.5)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: _saving ? null : () => Navigator.pop(context, false), child: Text(context.t('cancel'))),
        FilledButton(
          style: widget.destructive ? FilledButton.styleFrom(backgroundColor: FarmColors.danger) : null,
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : Text(widget.saveLabel ?? context.t('save')),
        ),
      ],
    );
  }
}

Widget _gap() => const SizedBox(height: FarmSpacing.sm);

Widget _dropdown(BuildContext context, {required String label, required String value, required List<String> options, required String Function(String) display, required ValueChanged<String> onChanged}) =>
    DropdownButtonFormField<String>(
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(labelText: label),
      items: [for (final o in options) DropdownMenuItem(value: o, child: Text(display(o), overflow: TextOverflow.ellipsis))],
      onChanged: (v) {
        if (v != null) onChanged(v);
      },
    );

bool _arabic(BuildContext context) => Localizations.localeOf(context).languageCode == 'ar';

/// The identifier a newborn of this species must carry to be registered
/// (an ear tag on a calf, a leg band on a chick) — the same resolver the
/// Add Animal form uses, at the newborn stage.
String _identifierTypeFor(BuildContext context, Animal dam, String? sex) {
  final caps = context.read<LivestockProvider>().resolve(species: dam.species, sex: sex, lifeStage: 'newborn', managementProfile: null);
  if (caps.requiredIdentifierTypes.isNotEmpty) return caps.requiredIdentifierTypes.first;
  final allowed = caps.allowedIdentifierTypes.where((t) => t != 'NAME').toList();
  return allowed.isNotEmpty ? allowed.first : 'FARM_NUMBER';
}

// ---------------------------------------------------------------- breeding
Future<bool> showBreedingForm(BuildContext context, Animal female) async {
  var type = 'ARTIFICIAL_INSEMINATION';
  var day = DateTime.now();
  String? maleId;
  final sire = TextEditingController();
  final semen = TextEditingController();
  final notes = TextEditingController();
  final males = context.read<AnimalsProvider>().animals.where((a) => a.species == female.species && a.sex == 'M' && a.id != female.id).toList();
  final ok = await _recordDialog(
    context,
    title: '${context.t('reproActBreeding')} — ${female.name}',
    fields: (context, setState) => [
      _dropdown(context, label: context.t('reproType'), value: type, options: ReproCodes.breedingTypes, display: (c) => context.t('breed_$c'),
          onChanged: (v) => setState(() => type = v)),
      _gap(),
      RecordDateButton(label: context.t('reproDate'), value: day, onPicked: (d) => setState(() => day = d)),
      if (type != 'HEAT_OBSERVED') ...[
        if (males.isNotEmpty) ...[
          _gap(),
          DropdownButtonFormField<String?>(
            initialValue: maleId,
            isExpanded: true,
            decoration: InputDecoration(labelText: context.t('herdSire')),
            items: [
              const DropdownMenuItem<String?>(value: null, child: Text('—')),
              for (final m in males) DropdownMenuItem<String?>(value: m.id, child: Text('${m.name} #${m.primaryId}')),
            ],
            onChanged: (v) => setState(() => maleId = v),
          ),
        ],
        if (maleId == null) ...[_gap(), TextField(controller: sire, decoration: InputDecoration(labelText: context.t('reproSire')))],
        if (type == 'ARTIFICIAL_INSEMINATION' || type == 'EMBRYO_TRANSFER') ...[
          _gap(),
          TextField(controller: semen, decoration: InputDecoration(labelText: context.t('reproSemen'))),
        ],
      ],
      _gap(),
      TextField(controller: notes, decoration: InputDecoration(labelText: context.t('notes'))),
    ],
    submit: (context) => context.read<HerdRecordsProvider>().recordBreeding(
          female.id,
          eventType: type,
          occurredAt: recordedInstant(day),
          maleAnimalId: type == 'HEAT_OBSERVED' ? null : maleId,
          sireReference: type == 'HEAT_OBSERVED' || maleId != null ? null : sire.text,
          semenBatch: semen.text,
          notes: notes.text,
        ),
  );
  for (final c in [sire, semen, notes]) {
    c.dispose();
  }
  return ok;
}

// ---------------------------------------------------------------- pregnancy
Future<bool> showPregnancyCheckForm(BuildContext context, Animal animal) async {
  var method = 'ULTRASOUND';
  var result = 'POSITIVE';
  var day = DateTime.now();
  final days = TextEditingController();
  final notes = TextEditingController();
  final ok = await _recordDialog(
    context,
    title: '${context.t('reproActCheck')} — ${animal.name}',
    fields: (context, setState) => [
      _dropdown(context, label: context.t('reproMethod'), value: method, options: ReproCodes.assessmentTypes, display: (c) => context.t('check_$c'),
          onChanged: (v) => setState(() => method = v)),
      _gap(),
      RecordDateButton(label: context.t('reproDate'), value: day, onPicked: (d) => setState(() => day = d)),
      _gap(),
      SegmentedButton<String>(
        segments: [for (final r in ReproCodes.results) ButtonSegment(value: r, label: Text(context.t('result_$r')))],
        selected: {result},
        onSelectionChanged: (s) => setState(() => result = s.first),
      ),
      if (result == 'POSITIVE') ...[
        _gap(),
        TextField(controller: days, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: context.t('reproGestationDays'))),
      ],
      _gap(),
      TextField(controller: notes, decoration: InputDecoration(labelText: context.t('notes'))),
    ],
    submit: (context) {
      final gestation = days.text.trim().isEmpty ? null : int.tryParse(days.text.trim());
      if (days.text.trim().isNotEmpty && (gestation == null || gestation < 0)) {
        return Future.value(WriteResult.fail(context.t('valueMustBePositive')));
      }
      return context.read<HerdRecordsProvider>().recordPregnancyCheck(animal.id,
          assessmentType: method, resultCode: result, assessedAt: recordedInstant(day), gestationDays: result == 'POSITIVE' ? gestation : null, notes: notes.text);
    },
  );
  days.dispose();
  notes.dispose();
  return ok;
}

Future<bool> showPregnancyLossForm(BuildContext context, Animal animal) async {
  var outcome = 'LOSS';
  var day = DateTime.now();
  final notes = TextEditingController();
  final ok = await _recordDialog(
    context,
    title: '${context.t('reproActLoss')} — ${animal.name}',
    destructive: true,
    fields: (context, setState) => [
      _dropdown(context, label: context.t('reproType'), value: outcome, options: ReproCodes.lossOutcomes, display: (c) => context.t('loss_$c'),
          onChanged: (v) => setState(() => outcome = v)),
      _gap(),
      RecordDateButton(label: context.t('reproDate'), value: day, onPicked: (d) => setState(() => day = d)),
      _gap(),
      TextField(controller: notes, decoration: InputDecoration(labelText: context.t('notes'))),
    ],
    submit: (context) => context.read<HerdRecordsProvider>().recordPregnancyLoss(animal.id, outcomeCode: outcome, occurredAt: recordedInstant(day), notes: notes.text),
  );
  notes.dispose();
  return ok;
}

// ---------------------------------------------------------------- birth
class _NewbornDraft {
  String outcome = 'LIVE';
  String? sex;
  bool register = false;
  final weight = TextEditingController();
  final name = TextEditingController();
  final tag = TextEditingController();

  void dispose() {
    weight.dispose();
    name.dispose();
    tag.dispose();
  }
}

Future<bool> showBirthForm(BuildContext context, Animal dam, ReproSummary summary) async {
  final term = summary.birthTerm(_arabic(context));
  var assistance = 'NONE';
  var day = DateTime.now();
  var startLactation = summary.applies.lactation;
  final newborns = [_NewbornDraft()];
  final notes = TextEditingController();
  final ok = await _recordDialog(
    context,
    title: '$term — ${dam.name}',
    fields: (context, setState) => [
      RecordDateButton(label: context.t('reproDate'), value: day, onPicked: (d) => setState(() => day = d)),
      _gap(),
      _dropdown(context, label: context.t('reproAssistance'), value: assistance, options: ReproCodes.assistance, display: (c) => context.t('assist_$c'),
          onChanged: (v) => setState(() => assistance = v)),
      _gap(),
      Text(context.t('reproNewborns'), style: const TextStyle(fontWeight: FontWeight.w700, color: FarmColors.ink)),
      for (var i = 0; i < newborns.length; i++) _NewbornFields(index: i, draft: newborns[i], onChanged: () => setState(() {}),
          onRemove: newborns.length > 1 ? () => setState(() => newborns.removeAt(i).dispose()) : null),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: TextButton.icon(onPressed: () => setState(() => newborns.add(_NewbornDraft())), icon: const Icon(Icons.add, size: 18), label: Text(context.t('reproAddNewborn'))),
      ),
      if (summary.applies.lactation)
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: startLactation,
          title: Text(context.t('reproStartLactation')),
          onChanged: (v) => setState(() => startLactation = v),
        ),
      TextField(controller: notes, decoration: InputDecoration(labelText: context.t('notes'))),
    ],
    submit: (context) {
      final rows = <Map<String, dynamic>>[];
      for (final n in newborns) {
        final weight = n.weight.text.trim().isEmpty ? null : double.tryParse(n.weight.text.trim());
        if (n.weight.text.trim().isNotEmpty && (weight == null || weight < 0)) return Future.value(WriteResult.fail(context.t('valueMustBePositive')));
        final register = n.register && n.outcome == 'LIVE';
        // A name is enough to register a newborn: the server gives it the
        // farm's next number; a tag typed now becomes its primary identifier.
        if (register && n.name.text.trim().isEmpty) {
          return Future.value(WriteResult.fail(context.t('reproNewbornNeedsTag')));
        }
        rows.add({
          'outcome_code': n.outcome,
          if (n.sex != null) 'sex': n.sex,
          'birth_weight_kg': ?weight,
          if (register) ...{
            'register_now': true,
            'name': n.name.text.trim(),
            'identifiers': [
              if (n.tag.text.trim().isNotEmpty)
                {'identifier_type': _identifierTypeFor(context, dam, n.sex), 'identifier_value': n.tag.text.trim(), 'is_primary': true},
            ],
          },
        });
      }
      return context.read<HerdRecordsProvider>().recordBirth(dam.id,
          offspring: rows, assistanceCode: assistance, occurredAt: recordedInstant(day), startLactation: startLactation, notes: notes.text);
    },
  );
  for (final n in newborns) {
    n.dispose();
  }
  notes.dispose();
  if (ok && context.mounted) await context.read<AnimalsProvider>().load();
  return ok;
}

class _NewbornFields extends StatelessWidget {
  const _NewbornFields({required this.index, required this.draft, required this.onChanged, this.onRemove});

  final int index;
  final _NewbornDraft draft;
  final VoidCallback onChanged;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: FarmSpacing.sm),
      padding: const EdgeInsets.all(FarmSpacing.sm),
      decoration: BoxDecoration(border: Border.all(color: FarmColors.border), borderRadius: BorderRadius.circular(FarmRadii.sm)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text('#${index + 1}', style: const TextStyle(fontWeight: FontWeight.w700)),
          const Spacer(),
          if (onRemove != null) IconButton(onPressed: onRemove, icon: const Icon(Icons.close, size: 18), tooltip: context.t('cancel')),
        ]),
        Row(children: [
          Expanded(
            child: _dropdown(context, label: context.t('reproResult'), value: draft.outcome, options: ReproCodes.newbornOutcomes, display: (c) => context.t('nb_$c'),
                onChanged: (v) {
                  draft.outcome = v;
                  onChanged();
                }),
          ),
          const SizedBox(width: FarmSpacing.sm),
          Expanded(
            child: DropdownButtonFormField<String?>(
              initialValue: draft.sex,
              decoration: InputDecoration(labelText: context.t('sex')),
              items: [
                const DropdownMenuItem<String?>(value: null, child: Text('—')),
                DropdownMenuItem<String?>(value: 'F', child: Text(context.t('female'))),
                DropdownMenuItem<String?>(value: 'M', child: Text(context.t('male'))),
              ],
              onChanged: (v) {
                draft.sex = v;
                onChanged();
              },
            ),
          ),
        ]),
        TextField(controller: draft.weight, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: context.t('reproWeightKg'))),
        if (draft.outcome == 'LIVE')
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: draft.register,
            title: Text(context.t('reproRegisterNow')),
            onChanged: (v) {
              draft.register = v;
              onChanged();
            },
          ),
        if (draft.outcome == 'LIVE' && draft.register)
          Row(children: [
            Expanded(child: TextField(controller: draft.name, decoration: InputDecoration(labelText: context.t('name')))),
            const SizedBox(width: FarmSpacing.sm),
            Expanded(child: TextField(controller: draft.tag, decoration: InputDecoration(labelText: context.t('reproNewbornTag')))),
          ]),
      ]),
    );
  }
}

Future<bool> showRegisterNewbornForm(BuildContext context, {required Animal dam, required String birthId, required Newborn newborn}) async {
  final name = TextEditingController();
  final tag = TextEditingController();
  final ok = await _recordDialog(
    context,
    title: context.t('reproRegisterTitle'),
    saveLabel: context.t('reproRegister'),
    fields: (context, setState) => [
      TextField(controller: name, decoration: InputDecoration(labelText: context.t('name'))),
      _gap(),
      TextField(controller: tag, decoration: InputDecoration(labelText: context.t('reproNewbornTag'))),
    ],
    submit: (context) {
      if (name.text.trim().isEmpty) return Future.value(WriteResult.fail(context.t('reproNewbornNeedsTag')));
      return context.read<HerdRecordsProvider>().registerOffspring(birthId, newborn.sequenceNo,
          name: name.text.trim(), identifierType: _identifierTypeFor(context, dam, newborn.sex), identifierValue: tag.text.trim(), sex: newborn.sex);
    },
  );
  name.dispose();
  tag.dispose();
  if (ok && context.mounted) await context.read<AnimalsProvider>().load();
  return ok;
}

// ---------------------------------------------------------------- lactation
Future<bool> confirmLactationChange(BuildContext context, Animal animal, {required bool start}) {
  var day = DateTime.now();
  return _recordDialog(
    context,
    title: '${context.t(start ? 'reproActStartMilking' : 'reproActDryOff')} — ${animal.name}',
    fields: (context, setState) => [
      Text(context.t(start ? 'reproStartMilkingConfirm' : 'reproDryOffConfirm')),
      _gap(),
      RecordDateButton(
        label: context.t(start ? 'calvingDate' : 'reproDate'),
        value: day,
        onPicked: (d) => setState(() => day = d),
      ),
    ],
    submit: (context) {
      final herd = context.read<HerdRecordsProvider>();
      return start ? herd.startLactation(animal.id, at: recordedInstant(day)) : herd.dryOff(animal.id, at: recordedInstant(day));
    },
  );
}

// ---------------------------------------------------------------- exit
Future<bool> showExitForm(BuildContext context, Animal animal) async {
  // Only the exits this person may record: a death needs Animals edit, a
  // sale / cull / slaughter / transfer needs Animals approve.
  final access = context.read<AccessProvider>();
  final allowed = [for (final t in ReproCodes.exitTypes) if (access.canRecordExit(t)) t];
  if (allowed.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.t('exitNeedsEdit'))));
    return false;
  }
  var type = allowed.first;
  var day = DateTime.now();
  final reason = TextEditingController();
  final ok = await _recordDialog(
    context,
    title: '${context.t('exitTitle')} — ${animal.name}',
    destructive: true,
    fields: (context, setState) => [
      _dropdown(context, label: context.t('exitType'), value: type, options: allowed, display: (c) => context.t('exit_$c'),
          onChanged: (v) => setState(() => type = v)),
      if (allowed.length < ReproCodes.exitTypes.length) ...[
        const SizedBox(height: 4),
        Text(context.t('exitNeedsApproval'), style: const TextStyle(fontSize: 12, color: FarmColors.muted)),
      ],
      _gap(),
      RecordDateButton(label: context.t('reproDate'), value: day, onPicked: (d) => setState(() => day = d)),
      _gap(),
      TextField(controller: reason, decoration: InputDecoration(labelText: context.t('reason'))),
      _gap(),
      Text(context.t('exitWarning'), style: const TextStyle(fontSize: 12.5, color: FarmColors.muted)),
    ],
    submit: (context) => context.read<HerdRecordsProvider>().exitAnimal(animal.id, exitType: type, occurredAt: recordedInstant(day), reason: reason.text),
  );
  reason.dispose();
  if (ok && context.mounted) await context.read<AnimalsProvider>().load();
  return ok;
}

// ---------------------------------------------------------------- weight
/// The methods a person can choose; `point_of_care` and `legacy` are set
/// by the system (a weight taken during an emergency protocol, a figure
/// carried over from the old profile field), never picked here.
const weightMethods = ['scale', 'tape', 'visual_estimate'];

Future<bool> showWeightForm(BuildContext context, Animal animal) async {
  var method = 'scale';
  final kg = TextEditingController();
  final notes = TextEditingController();
  final ok = await _recordDialog(
    context,
    title: '${context.t('twRecordWeight')} — ${animal.name}',
    fields: (context, setState) => [
      TextField(
        controller: kg,
        autofocus: true,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(labelText: context.t('weightKg'), suffixText: 'kg'),
      ),
      _gap(),
      _dropdown(context, label: context.t('weightMethod'), value: method, options: weightMethods, display: (m) => context.t('wm_$m'),
          onChanged: (v) => setState(() => method = v)),
      _gap(),
      TextField(controller: notes, decoration: InputDecoration(labelText: context.t('notes'))),
    ],
    submit: (context) {
      final value = double.tryParse(kg.text.trim().replaceAll(',', '.'));
      if (value == null || value <= 0) return Future.value(WriteResult.fail(context.t('weightInvalid')));
      return context.read<AnimalsProvider>().recordWeight(
            animalId: animal.id,
            weightKg: value,
            method: method,
            notes: notes.text.trim().isEmpty ? null : notes.text.trim(),
          );
    },
  );
  kg.dispose();
  notes.dispose();
  return ok;
}

// ---------------------------------------------------------------- groups
Future<bool> showMoveToGroupForm(BuildContext context, Animal animal) async {
  final groups = context.read<LivestockProvider>().groups.where((g) => g.species == animal.species && g.name != animal.groupName).toList();
  String? groupId = groups.isEmpty ? null : groups.first.id;
  final ok = await _recordDialog(
    context,
    title: '${context.t('herdMove')} — ${animal.name}',
    fields: (context, setState) => [
      if (groups.isEmpty)
        Text(context.t('herdNoGroupsForSpecies'))
      else
        DropdownButtonFormField<String>(
          initialValue: groupId,
          isExpanded: true,
          decoration: InputDecoration(labelText: context.t('herdChooseGroup')),
          items: [for (final g in groups) DropdownMenuItem(value: g.id, child: Text('${g.name} · ${g.count}'))],
          onChanged: (v) => setState(() => groupId = v),
        ),
    ],
    submit: (context) {
      final id = groupId;
      if (id == null) return Future.value(WriteResult.fail(context.t('herdNoGroupsForSpecies')));
      final group = groups.firstWhere((g) => g.id == id);
      return context.read<HerdRecordsProvider>().addToGroup(id, animal.id, groupName: group.name);
    },
  );
  if (ok && context.mounted) {
    await Future.wait([context.read<AnimalsProvider>().load(), context.read<LivestockProvider>().load()]);
  }
  return ok;
}

Future<bool> showQuantityForm(BuildContext context, AnimalGroup group) async {
  var type = 'DEATH';
  final howMany = TextEditingController();
  final reason = TextEditingController();
  final ok = await _recordDialog(
    context,
    title: '${context.t('groupRecordCount')} — ${group.name}',
    fields: (context, setState) => [
      _dropdown(context, label: context.t('reproType'), value: type, options: ReproCodes.quantityEvents, display: (c) => context.t('qty_$c'),
          onChanged: (v) => setState(() => type = v)),
      _gap(),
      TextField(
        controller: howMany,
        keyboardType: const TextInputType.numberWithOptions(signed: true),
        decoration: InputDecoration(labelText: type == 'COUNT_ADJUSTMENT' ? '${context.t('groupHowMany')} (±)' : context.t('groupHowMany')),
      ),
      _gap(),
      TextField(controller: reason, decoration: InputDecoration(labelText: context.t('reason'))),
    ],
    submit: (context) {
      final n = int.tryParse(howMany.text.trim());
      if (n == null || n == 0) return Future.value(WriteResult.fail(context.t('valueMustBePositive')));
      final sign = ReproCodes.sign(type);
      final delta = sign == 0 ? n : sign * n.abs();
      return context.read<HerdRecordsProvider>().recordQuantity(group.id, eventType: type, delta: delta, reason: reason.text);
    },
  );
  howMany.dispose();
  reason.dispose();
  if (ok && context.mounted) await context.read<LivestockProvider>().load();
  return ok;
}

// ---------------------------------------------------------------- incubation
Future<bool> showStartIncubationForm(BuildContext context, AnimalGroup flock) async {
  final eggs = TextEditingController();
  final notes = TextEditingController();
  final ok = await _recordDialog(
    context,
    title: '${context.t('incubStart')} — ${flock.name}',
    fields: (context, setState) => [
      TextField(controller: eggs, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: context.t('incubEggs'))),
      _gap(),
      TextField(controller: notes, decoration: InputDecoration(labelText: context.t('notes'))),
    ],
    submit: (context) {
      final n = int.tryParse(eggs.text.trim());
      if (n == null || n <= 0) return Future.value(WriteResult.fail(context.t('valueMustBePositive')));
      // Eggs from the flock itself only when it is kept for breeding — a
      // laying flock's eggs go to sale, and the server would refuse it.
      return context.read<HerdRecordsProvider>().startIncubation(
          speciesCode: flock.species, eggsSet: n, sourceGroupId: flock.managementProfile == 'breeding' ? flock.id : null, notes: notes.text);
    },
  );
  eggs.dispose();
  notes.dispose();
  return ok;
}

Future<bool> showHatchForm(BuildContext context, IncubationBatch batch) async {
  final groups = context.read<LivestockProvider>().groups.where((g) => g.species == batch.speciesCode && !g.countsMembers).toList();
  String? destination = groups.isEmpty ? null : groups.first.id;
  final live = TextEditingController();
  final unhatched = TextEditingController();
  final ok = await _recordDialog(
    context,
    title: '${context.t('incubRecordHatch')} — ${batch.code}',
    fields: (context, setState) => [
      TextField(controller: live, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: context.t('incubHatchedLive'))),
      _gap(),
      TextField(controller: unhatched, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: context.t('incubUnhatched'))),
      if (groups.isNotEmpty) ...[
        _gap(),
        DropdownButtonFormField<String?>(
          initialValue: destination,
          isExpanded: true,
          decoration: InputDecoration(labelText: context.t('incubIntoFlock')),
          items: [
            const DropdownMenuItem<String?>(value: null, child: Text('—')),
            for (final g in groups) DropdownMenuItem<String?>(value: g.id, child: Text('${g.name} · ${g.count}')),
          ],
          onChanged: (v) => setState(() => destination = v),
        ),
      ],
    ],
    submit: (context) {
      final hatched = int.tryParse(live.text.trim());
      final notHatched = unhatched.text.trim().isEmpty ? null : int.tryParse(unhatched.text.trim());
      if (hatched == null || hatched < 0 || (unhatched.text.trim().isNotEmpty && (notHatched == null || notHatched < 0))) {
        return Future.value(WriteResult.fail(context.t('valueMustBePositive')));
      }
      return context.read<HerdRecordsProvider>().recordHatch(batch.id, hatchedLive: hatched, unhatched: notHatched, destinationGroupId: destination);
    },
  );
  live.dispose();
  unhatched.dispose();
  if (ok && context.mounted) await context.read<LivestockProvider>().load();
  return ok;
}
