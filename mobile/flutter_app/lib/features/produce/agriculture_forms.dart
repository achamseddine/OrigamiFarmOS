import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../domain/entities/crop.dart';
import '../../domain/entities/field.dart';
import '../../providers/agriculture_provider.dart';
import '../../providers/production_provider.dart';

/// Add Field, Add Crop, Add Planting and Record Daily Harvest — the
/// agriculture employee's whole day (tech spec §14–§17).

// ---------------------------------------------------------------- Field
void showFieldForm(BuildContext context, {Field? field}) {
  showDialog<void>(context: context, builder: (_) => _FieldFormDialog(field: field));
}

class _FieldFormDialog extends StatefulWidget {
  const _FieldFormDialog({this.field});
  final Field? field;

  @override
  State<_FieldFormDialog> createState() => _FieldFormDialogState();
}

class _FieldFormDialogState extends State<_FieldFormDialog> {
  late final _name = TextEditingController(text: widget.field?.name ?? '');
  late final _code = TextEditingController(text: widget.field?.fieldCode ?? '');
  late final _area = TextEditingController(text: widget.field?.areaValue?.toString() ?? '');
  late final _location = TextEditingController(text: widget.field?.locationLabel ?? '');
  late final _soil = TextEditingController(text: widget.field?.soilType ?? '');
  late final _notes = TextEditingController(text: widget.field?.notes ?? '');
  late String _areaUnit = widget.field?.areaUnit ?? 'm2';
  late String? _irrigation = widget.field?.irrigationMethod;
  late String _status = widget.field?.status ?? 'active';
  bool _saving = false;
  String? _error;

  bool get _isEdit => widget.field != null;

  @override
  void dispose() {
    for (final c in [_name, _code, _area, _location, _soil, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    if (_name.text.trim().isEmpty) {
      setState(() => _error = context.t('fieldNameRequired'));
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final agriculture = context.read<AgricultureProvider>();
    final body = {
      'name': _name.text.trim(),
      'field_code': _blank(_code.text),
      'area_value': double.tryParse(_area.text),
      'area_unit': _areaUnit,
      'location_label': _blank(_location.text),
      'soil_type': _blank(_soil.text),
      'irrigation_method': _irrigation,
      'status': _status,
      'notes': _blank(_notes.text),
    };
    final result = _isEdit ? await agriculture.updateField(widget.field!.id, body) : await agriculture.createField(body);
    if (!mounted) return;
    if (result.success) {
      await context.read<ProductionProvider>().load();
      if (!mounted) return;
      Navigator.of(context).pop();
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
    return _FormShell(
      title: _isEdit ? context.t('editField') : context.t('addField'),
      error: _error,
      saving: _saving,
      submitLabel: _isEdit ? context.t('saveChanges') : context.t('addField'),
      onSubmit: _submit,
      children: [
        Row(children: [
          Expanded(flex: 2, child: TextField(controller: _name, decoration: InputDecoration(labelText: context.t('fieldName'), hintText: 'Field 3'))),
          const SizedBox(width: 12),
          Expanded(child: TextField(controller: _code, decoration: InputDecoration(labelText: context.t('fieldCode')))),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: TextField(
              controller: _area,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: context.t('area')),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: DropdownButtonFormField<String>(
              value: _areaUnit,
              decoration: InputDecoration(labelText: context.t('areaUnit')),
              items: [for (final u in kAreaUnits) DropdownMenuItem(value: u, child: Text(context.t('unit_$u')))],
              onChanged: (v) => setState(() => _areaUnit = v ?? _areaUnit),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(child: TextField(controller: _location, decoration: InputDecoration(labelText: context.t('location')))),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: TextField(controller: _soil, decoration: InputDecoration(labelText: context.t('soilType')))),
          const SizedBox(width: 12),
          Expanded(
            child: DropdownButtonFormField<String?>(
              value: _irrigation,
              decoration: InputDecoration(labelText: context.t('irrigationMethod')),
              items: [
                const DropdownMenuItem<String?>(value: null, child: Text('—')),
                for (final m in kIrrigationMethods) DropdownMenuItem<String?>(value: m, child: Text(context.t('irrigation_$m'))),
              ],
              onChanged: (v) => setState(() => _irrigation = v),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: DropdownButtonFormField<String>(
              value: _status,
              decoration: InputDecoration(labelText: context.t('status')),
              items: [for (final s in kFieldStatuses) DropdownMenuItem(value: s, child: Text(context.t('fieldStatus_$s')))],
              onChanged: (v) => setState(() => _status = v ?? _status),
            ),
          ),
        ]),
        const SizedBox(height: 12),
        TextField(controller: _notes, maxLines: 2, decoration: InputDecoration(labelText: context.t('notes'))),
      ],
    );
  }
}

// ----------------------------------------------------------- Crop type
void showCropForm(BuildContext context) {
  showDialog<void>(context: context, builder: (_) => const _CropFormDialog());
}

class _CropFormDialog extends StatefulWidget {
  const _CropFormDialog();

  @override
  State<_CropFormDialog> createState() => _CropFormDialogState();
}

class _CropFormDialogState extends State<_CropFormDialog> {
  final _name = TextEditingController();
  final _cycleDays = TextEditingController();
  String? _category;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _cycleDays.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_name.text.trim().isEmpty) {
      setState(() => _error = context.t('cropNameRequired'));
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final result = await context.read<AgricultureProvider>().createCrop(
          name: _name.text.trim(),
          category: _category,
          defaultCycleDays: int.tryParse(_cycleDays.text),
        );
    if (!mounted) return;
    if (result.success) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _saving = false;
      _error = result.error;
    });
  }

  @override
  Widget build(BuildContext context) {
    return _FormShell(
      title: context.t('addCropType'),
      subtitle: context.t('addCropTypeSubtitle'),
      error: _error,
      saving: _saving,
      submitLabel: context.t('addCropType'),
      onSubmit: _submit,
      children: [
        TextField(
          controller: _name,
          decoration: InputDecoration(labelText: context.t('cropName'), hintText: context.t('cropNameHint')),
        ),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: DropdownButtonFormField<String?>(
              value: _category,
              decoration: InputDecoration(labelText: context.t('category')),
              items: [
                const DropdownMenuItem<String?>(value: null, child: Text('—')),
                for (final c in kCropCategories) DropdownMenuItem<String?>(value: c, child: Text(context.t('cropCategory_$c'))),
              ],
              onChanged: (v) => setState(() => _category = v),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              controller: _cycleDays,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: context.t('growingCycleDays'),
                helperText: context.t('growingCycleHelper'),
              ),
            ),
          ),
        ]),
      ],
    );
  }
}

// ------------------------------------------------------------ Planting
void showPlantingForm(BuildContext context, {String? fieldId}) {
  showDialog<void>(context: context, builder: (_) => _PlantingFormDialog(fieldId: fieldId));
}

class _PlantingFormDialog extends StatefulWidget {
  const _PlantingFormDialog({this.fieldId});
  final String? fieldId;

  @override
  State<_PlantingFormDialog> createState() => _PlantingFormDialogState();
}

class _PlantingFormDialogState extends State<_PlantingFormDialog> {
  final _variety = TextEditingController();
  final _area = TextEditingController();
  final _expectedYield = TextEditingController();
  final _notes = TextEditingController();
  late String? _fieldId = widget.fieldId;
  String? _cropId;
  DateTime _plantedDate = DateTime.now();
  DateTime? _expectedHarvest;
  String _stage = 'planted';
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_variety, _area, _expectedYield, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    if (_fieldId == null || _cropId == null) {
      setState(() => _error = context.t('pickFieldAndCrop'));
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final result = await context.read<AgricultureProvider>().createPlanting({
      'field_id': _fieldId,
      'crop_id': _cropId,
      'variety': _variety.text.trim().isEmpty ? null : _variety.text.trim(),
      'planted_area': double.tryParse(_area.text),
      'planted_date': _plantedDate.toIso8601String(),
      'expected_harvest_date': _expectedHarvest?.toIso8601String(),
      'expected_yield_kg': double.tryParse(_expectedYield.text),
      'stage': _stage,
      'notes': _notes.text.trim().isEmpty ? null : _notes.text.trim(),
    });
    if (!mounted) return;
    if (result.success) {
      await context.read<ProductionProvider>().load();
      if (!mounted) return;
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _saving = false;
      _error = result.error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final agriculture = context.watch<AgricultureProvider>();
    final fields = context.watch<ProductionProvider>().fields;

    return _FormShell(
      title: context.t('recordPlanting'),
      error: _error,
      saving: _saving,
      submitLabel: context.t('recordPlanting'),
      onSubmit: _submit,
      children: [
        if (fields.isEmpty)
          Text(context.t('addAFieldFirst'), style: const TextStyle(color: FarmColors.warning))
        else if (agriculture.crops.isEmpty)
          Text(context.t('addACropTypeFirst'), style: const TextStyle(color: FarmColors.warning)),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: DropdownButtonFormField<String>(
              value: _fieldId,
              decoration: InputDecoration(labelText: context.t('field')),
              items: [for (final f in fields) DropdownMenuItem(value: f.id, child: Text(f.name))],
              onChanged: fields.isEmpty ? null : (v) => setState(() => _fieldId = v),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: DropdownButtonFormField<String>(
              value: _cropId,
              decoration: InputDecoration(labelText: context.t('crop')),
              items: [for (final c in agriculture.crops) DropdownMenuItem(value: c.id, child: Text(c.name))],
              onChanged: agriculture.crops.isEmpty ? null : (v) => setState(() => _cropId = v),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(child: TextField(controller: _variety, decoration: InputDecoration(labelText: context.t('variety')))),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: OutlinedButton(
              onPressed: () async {
                final picked = await showDatePicker(
                  context: context,
                  initialDate: _plantedDate,
                  firstDate: DateTime.now().subtract(const Duration(days: 730)),
                  lastDate: DateTime.now().add(const Duration(days: 30)),
                );
                if (picked != null) setState(() => _plantedDate = picked);
              },
              child: Text('${context.t('plantedOn')}: ${_plantedDate.day}/${_plantedDate.month}/${_plantedDate.year}'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: OutlinedButton(
              onPressed: () async {
                final picked = await showDatePicker(
                  context: context,
                  initialDate: _expectedHarvest ?? DateTime.now().add(const Duration(days: 60)),
                  firstDate: DateTime.now().subtract(const Duration(days: 30)),
                  lastDate: DateTime.now().add(const Duration(days: 1095)),
                );
                if (picked != null) setState(() => _expectedHarvest = picked);
              },
              child: Text(
                _expectedHarvest == null
                    ? context.t('expectedHarvestAuto')
                    : '${context.t('expectedHarvest')}: ${_expectedHarvest!.day}/${_expectedHarvest!.month}',
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: TextField(
              controller: _area,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: context.t('plantedArea')),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              controller: _expectedYield,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: context.t('expectedYieldKg')),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: DropdownButtonFormField<String>(
              value: _stage,
              decoration: InputDecoration(labelText: context.t('cropStage')),
              items: [for (final s in kPlantingStages) DropdownMenuItem(value: s, child: Text(context.t('stage_$s')))],
              onChanged: (v) => setState(() => _stage = v ?? _stage),
            ),
          ),
        ]),
        const SizedBox(height: 12),
        TextField(controller: _notes, maxLines: 2, decoration: InputDecoration(labelText: context.t('notes'))),
      ],
    );
  }
}

// ------------------------------------------------------------- Harvest
void showHarvestForm(BuildContext context, {String? fieldId}) {
  showDialog<void>(context: context, builder: (_) => _HarvestFormDialog(fieldId: fieldId));
}

class _HarvestFormDialog extends StatefulWidget {
  const _HarvestFormDialog({this.fieldId});
  final String? fieldId;

  @override
  State<_HarvestFormDialog> createState() => _HarvestFormDialogState();
}

class _HarvestFormDialogState extends State<_HarvestFormDialog> {
  final _total = TextEditingController();
  final _sellable = TextEditingController();
  final _waste = TextEditingController(text: '0');
  final _notes = TextEditingController();
  late String? _fieldId = widget.fieldId;
  String? _cropId;
  String _unit = 'kg';
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_total, _sellable, _waste, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  /// Keeps the sellable figure honest as the farmer types: entering total
  /// and waste fills sellable in, so the split always adds up.
  void _recalculateSellable() {
    final total = double.tryParse(_total.text);
    final waste = double.tryParse(_waste.text) ?? 0;
    if (total == null) return;
    _sellable.text = (total - waste).clamp(0, total).toStringAsFixed(
          (total - waste) % 1 == 0 ? 0 : 1,
        );
    setState(() {});
  }

  Future<void> _submit() async {
    final total = double.tryParse(_total.text);
    if (_fieldId == null) {
      setState(() => _error = context.t('pickAField'));
      return;
    }
    if (total == null || total <= 0) {
      setState(() => _error = context.t('enterHarvestedAmount'));
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final result = await context.read<AgricultureProvider>().recordHarvest(
          fieldId: _fieldId!,
          cropId: _cropId,
          totalQuantity: total,
          sellableQuantity: double.tryParse(_sellable.text),
          wasteQuantity: double.tryParse(_waste.text) ?? 0,
          unit: _unit,
          notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
        );
    if (!mounted) return;
    if (result.success) {
      // The sellable part became inventory, so both screens are now stale.
      await context.read<ProductionProvider>().load();
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.t('harvestRecorded'))));
      return;
    }
    setState(() {
      _saving = false;
      _error = result.error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final agriculture = context.watch<AgricultureProvider>();
    final fields = context.watch<ProductionProvider>().fields;

    return _FormShell(
      title: context.t('recordHarvest'),
      subtitle: context.t('recordHarvestSubtitle'),
      error: _error,
      saving: _saving,
      submitLabel: context.t('recordHarvest'),
      onSubmit: _submit,
      children: [
        if (fields.isEmpty) Text(context.t('addAFieldFirst'), style: const TextStyle(color: FarmColors.warning)),
        Row(children: [
          Expanded(
            child: DropdownButtonFormField<String>(
              value: _fieldId,
              decoration: InputDecoration(labelText: context.t('field')),
              items: [for (final f in fields) DropdownMenuItem(value: f.id, child: Text(f.name))],
              onChanged: fields.isEmpty ? null : (v) => setState(() => _fieldId = v),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: DropdownButtonFormField<String?>(
              value: _cropId,
              decoration: InputDecoration(
                labelText: context.t('crop'),
                helperText: context.t('cropOptionalHelper'),
              ),
              items: [
                const DropdownMenuItem<String?>(value: null, child: Text('—')),
                for (final c in agriculture.crops) DropdownMenuItem<String?>(value: c.id, child: Text(c.name)),
              ],
              onChanged: (v) => setState(() => _cropId = v),
            ),
          ),
        ]),
        const SizedBox(height: FarmSpacing.md),
        Row(children: [
          Expanded(
            child: TextField(
              controller: _total,
              keyboardType: TextInputType.number,
              onChanged: (_) => _recalculateSellable(),
              decoration: InputDecoration(labelText: context.t('totalHarvested')),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              controller: _waste,
              keyboardType: TextInputType.number,
              onChanged: (_) => _recalculateSellable(),
              decoration: InputDecoration(labelText: context.t('damagedWaste')),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              controller: _sellable,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: context.t('sellable'),
                helperText: context.t('sellableHelper'),
              ),
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 90,
            child: DropdownButtonFormField<String>(
              value: _unit,
              decoration: InputDecoration(labelText: context.t('unit')),
              items: const [
                DropdownMenuItem(value: 'kg', child: Text('kg')),
                DropdownMenuItem(value: 'crate', child: Text('crate')),
                DropdownMenuItem(value: 'piece', child: Text('piece')),
              ],
              onChanged: (v) => setState(() => _unit = v ?? _unit),
            ),
          ),
        ]),
        const SizedBox(height: 12),
        TextField(controller: _notes, maxLines: 2, decoration: InputDecoration(labelText: context.t('notes'))),
      ],
    );
  }
}

// -------------------------------------------------------------- Shell
/// The shared dialog frame for these four forms — same header, error line
/// and action row, so they read as one family rather than four one-offs.
class _FormShell extends StatelessWidget {
  const _FormShell({
    required this.title,
    this.subtitle,
    required this.children,
    required this.onSubmit,
    required this.submitLabel,
    required this.saving,
    this.error,
  });

  final String title;
  final String? subtitle;
  final List<Widget> children;
  final Future<void> Function() onSubmit;
  final String submitLabel;
  final bool saving;
  final String? error;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760, maxHeight: 640),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(FarmSpacing.lg, FarmSpacing.lg, FarmSpacing.sm, 0),
              child: Row(children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: FarmTypography.display(size: 22)),
                      if (subtitle != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(subtitle!, style: FarmTypography.textTheme.bodySmall),
                        ),
                    ],
                  ),
                ),
                IconButton(onPressed: () => Navigator.of(context).pop(), icon: const Icon(Icons.close)),
              ]),
            ),
            const Divider(height: 20, color: FarmColors.border),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: FarmSpacing.lg),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
              ),
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: FarmSpacing.lg),
                child: Text(error!, style: const TextStyle(color: FarmColors.danger, fontSize: 12.5)),
              ),
            const Divider(height: 20, color: FarmColors.border),
            Padding(
              padding: const EdgeInsets.fromLTRB(FarmSpacing.lg, 0, FarmSpacing.lg, FarmSpacing.lg),
              child: Row(children: [
                const Spacer(),
                TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(context.t('cancel'))),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: saving ? null : onSubmit,
                  child: saving
                      ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : Text(submitLabel),
                ),
              ]),
            ),
          ],
        ),
      ),
    );
  }
}
