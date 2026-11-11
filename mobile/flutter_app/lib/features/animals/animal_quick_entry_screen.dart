import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/util/number_input.dart';
import '../../domain/entities/access.dart';
import '../../domain/entities/animal.dart';
import '../../domain/entities/feeding.dart';
import '../../domain/entities/livestock.dart';
import '../../providers/access_provider.dart';
import '../../providers/animals_provider.dart';
import '../../providers/feeding_provider.dart';
import '../../providers/livestock_provider.dart';
import '../health/pharmacy_tab.dart' show showAdministerDialog;
import 'animal_quick_actions.dart' show showObserveDialog;
import 'animal_scan.dart';

/// First QR-enabled worker slice: a keyboard-wedge QR reader types the label
/// into the focused field, or the worker enters a tag. The app deliberately
/// does NOT claim camera decoding/QR printing until a reviewed offline scanner
/// and label service are integrated. No new package is introduced here.
class AnimalQuickEntryScreen extends StatefulWidget {
  const AnimalQuickEntryScreen({super.key, this.initialAnimalId});

  final String? initialAnimalId;

  @override
  State<AnimalQuickEntryScreen> createState() => _AnimalQuickEntryScreenState();
}

class _FeedRow {
  String? productId;
  final offered = TextEditingController();
  final refused = TextEditingController();

  void clear() {
    offered.clear();
    refused.clear();
  }

  void dispose() {
    offered.dispose();
    refused.dispose();
  }
}

class _AnimalQuickEntryScreenState extends State<AnimalQuickEntryScreen> {
  final _code = TextEditingController();
  final _milk = TextEditingController();
  final _scanFocus = FocusNode();
  final _feeds = <String, _FeedRow>{
    'concentrate': _FeedRow(),
    'silage': _FeedRow(),
    'straw': _FeedRow(),
  };
  String? _selectedId;
  String _session = milkSessionForHour(DateTime.now().hour);
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _selectedId = widget.initialAnimalId;
    if (_selectedId == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _scanFocus.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _code.dispose();
    _milk.dispose();
    _scanFocus.dispose();
    for (final row in _feeds.values) {
      row.dispose();
    }
    super.dispose();
  }

  Animal? _currentAnimal(List<Animal> animals) {
    for (final animal in animals) {
      if (animal.id == _selectedId) return animal;
    }
    return null;
  }

  bool get _hasDraft =>
      _milk.text.trim().isNotEmpty ||
      _feeds.values.any((row) => row.offered.text.trim().isNotEmpty || row.refused.text.trim().isNotEmpty);

  Future<void> _selectAnimal(String id) async {
    if (_selectedId == id) return;
    if (_hasDraft) {
      final discard = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(dialogContext.t('qrDiscardTitle')),
          content: Text(dialogContext.t('qrDiscardBody')),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: Text(dialogContext.t('cancel'))),
            FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: Text(dialogContext.t('qrDiscard'))),
          ],
        ),
      );
      if (!mounted || discard != true) return;
    }
    setState(() {
      _selectedId = id;
      _error = null;
      _milk.clear();
      for (final row in _feeds.values) {
        row.clear();
        row.productId = null;
      }
      _session = milkSessionForHour(DateTime.now().hour);
    });
  }

  Future<void> _resolveCode() async {
    final found = resolveAnimalScan(_code.text, context.read<AnimalsProvider>().animals);
    if (found == null) {
      setState(() => _error = context.t('qrNotFound'));
      return;
    }
    await _selectAnimal(found.id);
    if (mounted && _selectedId == found.id) {
      _code.clear();
      FocusScope.of(context).unfocus();
    }
  }

  Future<void> _submit(Animal animal, {required bool canMilk, required bool canFeed}) async {
    final milkText = _milk.text.trim();
    final milk = milkText.isEmpty ? null : parseLocalizedDouble(milkText);
    if (milkText.isNotEmpty && (!canMilk || milk == null || milk < 0)) {
      setState(() => _error = context.t('qrInvalidQuantity'));
      return;
    }
    final components = <Map<String, dynamic>>[];
    final selectedProducts = <String>{};
    for (final row in _feeds.values) {
      final offeredText = row.offered.text.trim();
      final refusedText = row.refused.text.trim();
      if (offeredText.isEmpty && refusedText.isEmpty) continue;
      final offered = parseLocalizedDouble(offeredText);
      final refused = refusedText.isEmpty ? null : parseLocalizedDouble(refusedText);
      if (!canFeed || offered == null || offered <= 0 ||
          (refusedText.isNotEmpty && (refused == null || refused < 0 || refused > offered))) {
        setState(() => _error = context.t('qrInvalidQuantity'));
        return;
      }
      if (row.productId == null) {
        setState(() => _error = context.t('qrSelectFeed'));
        return;
      }
      if (!selectedProducts.add(row.productId!)) {
        setState(() => _error = context.t('qrDuplicateFeed'));
        return;
      }
      components.add({
        'feed_product_id': row.productId,
        'quantity_offered': offered,
        'unit': 'kg',
        if (refused != null) 'quantity_consumed': offered - refused,
      });
    }
    if (milk == null && components.isEmpty) {
      setState(() => _error = context.t('qrNothingEntered'));
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });
    bool milkSaved = false;
    try {
      // Separate authoritative endpoints: clear only the successful part.
      // If feed fails after milk succeeds, a retry cannot re-send that milk.
      if (milk != null) {
        final result = await context.read<AnimalsProvider>().recordMilk(
          animalId: animal.id,
          session: _session,
          liters: milk,
          destination: animal.isUnderWithdrawal ? 'withheld' : 'stored',
        );
        if (!mounted) return;
        if (!result.success) {
          setState(() => _error = result.error ?? context.t('couldNotSave'));
          return;
        }
        _milk.clear();
        milkSaved = true;
      }
      if (components.isNotEmpty) {
        final result = await context.read<FeedingProvider>().recordFeeding({
          'subject_type': 'animal',
          'subject_id': animal.id,
          'event_type': 'offered',
          'components': components,
        });
        if (!mounted) return;
        if (!result.success) {
          setState(() => _error = milkSaved
              ? '${context.t('qrMilkSavedPartial')} ${result.error ?? context.t('couldNotSave')}'
              : result.error ?? context.t('couldNotSave'));
          return;
        }
        for (final row in _feeds.values) {
          row.clear();
        }
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.t('qrSavedOnDevice'))),
      );
      setState(() {
        _selectedId = null;
        _code.clear();
      });
      _scanFocus.requestFocus();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _recordWeight(Animal animal) async {
    final weight = TextEditingController();
    String method = 'scale';
    String? error;
    bool saving = false;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: Text(dialogContext.t('qrWeight')),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: weight,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(labelText: dialogContext.t('qrWeightKg')),
                ),
                const SizedBox(height: FarmSpacing.sm),
                DropdownButtonFormField<String>(
                  initialValue: method,
                  decoration: InputDecoration(labelText: dialogContext.t('qrWeightMethod')),
                  items: [
                    DropdownMenuItem(value: 'scale', child: Text(dialogContext.t('qrWeightScale'))),
                    DropdownMenuItem(value: 'tape', child: Text(dialogContext.t('qrWeightTape'))),
                  ],
                  onChanged: saving ? null : (value) => setDialogState(() => method = value ?? method),
                ),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: FarmSpacing.sm),
                    child: Text(error!, style: const TextStyle(color: FarmColors.dangerInk)),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: saving ? null : () => Navigator.pop(dialogContext), child: Text(dialogContext.t('cancel'))),
            FilledButton(
              onPressed: saving ? null : () async {
                final value = parseLocalizedDouble(weight.text);
                if (value == null || value <= 0) {
                  setDialogState(() => error = dialogContext.t('qrInvalidQuantity'));
                  return;
                }
                setDialogState(() { saving = true; error = null; });
                final result = await dialogContext.read<AnimalsProvider>().recordWeight(
                  animalId: animal.id, weightKg: value, method: method,
                );
                if (!dialogContext.mounted) return;
                if (result.success) {
                  Navigator.pop(dialogContext);
                  if (mounted) ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(context.t('qrWeightSaved'))),
                  );
                } else {
                  setDialogState(() { saving = false; error = result.error ?? dialogContext.t('couldNotSave'); });
                }
              },
              child: Text(dialogContext.t('save')),
            ),
          ],
        ),
      ),
    );
    weight.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final animals = context.watch<AnimalsProvider>().animals;
    final livestock = context.watch<LivestockProvider>();
    final access = context.watch<AccessProvider>();
    final feeds = context.watch<FeedingProvider>().feedable.where((p) => p.unit == 'kg').toList();
    final animal = _currentAnimal(animals);
    final caps = animal == null ? null : livestock.resolve(
      species: animal.species, sex: animal.sex,
      lifeStage: animal.lifeStage, managementProfile: animal.managementProfile,
    );
    final canMilk = animal != null && caps!.has(Cap.milkProduction) && access.canCreate(FarmModule.milkProduction);
    final canFeed = access.canCreate(FarmModule.feedNutrition);
    final canObserve = access.canCreate(FarmModule.animalHealth) || access.canCreate(FarmModule.animals);
    final canCare = access.canCreate(FarmModule.animalHealth);
    final canWeight = animal != null && caps!.has(Cap.weightTracking) &&
        (access.canEdit(FarmModule.animals) || canCare);
    final lang = Localizations.localeOf(context).languageCode;

    return Scaffold(
      appBar: AppBar(title: Text(context.t('qrQuickEntry'))),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: ListView(
              padding: const EdgeInsets.all(FarmSpacing.md),
              children: [
                Text(context.t('qrScannerHelp')),
                const SizedBox(height: FarmSpacing.sm),
                TextField(
                  controller: _code,
                  focusNode: _scanFocus,
                  enabled: !_saving,
                  onSubmitted: (_) => _resolveCode(),
                  decoration: InputDecoration(
                    labelText: context.t('qrScanOrType'),
                    prefixIcon: const Icon(Icons.qr_code_scanner),
                    suffixIcon: IconButton(
                      tooltip: context.t('qrOpenAnimal'),
                      onPressed: _saving ? null : _resolveCode,
                      icon: const Icon(Icons.arrow_forward),
                    ),
                  ),
                ),
                const SizedBox(height: FarmSpacing.sm),
                DropdownButtonFormField<String>(
                  key: ValueKey(_selectedId),
                  initialValue: animal?.id,
                  isExpanded: true,
                  decoration: InputDecoration(labelText: context.t('qrChooseAnimal')),
                  items: [
                    for (final a in animals)
                      DropdownMenuItem(value: a.id, child: Text('${a.name} · ${a.primaryId}', overflow: TextOverflow.ellipsis)),
                  ],
                  onChanged: _saving ? null : (id) {
                    if (id != null) _selectAnimal(id);
                  },
                ),
                if (_error != null) ...[
                  const SizedBox(height: FarmSpacing.sm),
                  Text(_error!, style: const TextStyle(color: FarmColors.dangerInk)),
                ],
                if (animal != null) ...[
                  const SizedBox(height: FarmSpacing.lg),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(FarmSpacing.md),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(animal.name, style: Theme.of(context).textTheme.headlineSmall),
                          Text('${animal.primaryId} · ${livestock.speciesName(animal.species, lang)} · ${animal.location}'),
                          if (animal.isUnderWithdrawal)
                            Padding(
                              padding: const EdgeInsets.only(top: FarmSpacing.sm),
                              child: Text(context.t('qrWithheldMilk'), style: const TextStyle(color: FarmColors.dangerInk, fontWeight: FontWeight.bold)),
                            ),
                        ],
                      ),
                    ),
                  ),
                  if (canMilk) ...[
                    const SizedBox(height: FarmSpacing.md),
                    Text(context.t('qrMilkTitle'), style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: FarmSpacing.sm),
                    SegmentedButton<String>(
                      segments: [
                        ButtonSegment(value: 'morning', label: Text(context.t('sessionMorning'))),
                        ButtonSegment(value: 'evening', label: Text(context.t('sessionEvening'))),
                      ],
                      selected: {_session},
                      onSelectionChanged: _saving ? null : (values) => setState(() => _session = values.first),
                    ),
                    const SizedBox(height: FarmSpacing.sm),
                    TextField(
                      controller: _milk,
                      enabled: !_saving,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: InputDecoration(labelText: context.t('qrMilkLitres')),
                    ),
                  ],
                  if (canFeed) ...[
                    const SizedBox(height: FarmSpacing.lg),
                    Text(context.t('qrFeedTitle'), style: Theme.of(context).textTheme.titleMedium),
                    Text(context.t('qrFeedOfferedNote')),
                    if (feeds.isEmpty)
                      Text(context.t('qrNoKgFeeds'), style: const TextStyle(color: FarmColors.warningInk)),
                    for (final key in _feeds.keys) _feedEditor(context, key, _feeds[key]!, feeds, lang),
                  ],
                  const SizedBox(height: FarmSpacing.lg),
                  if (canMilk || canFeed)
                    FilledButton.icon(
                      onPressed: _saving ? null : () => _submit(animal, canMilk: canMilk, canFeed: canFeed),
                      icon: const Icon(Icons.check_circle_outline),
                      label: Text(context.t('qrSaveNext')),
                      style: FilledButton.styleFrom(minimumSize: const Size(0, kFarmTouchTarget)),
                    ),
                  const SizedBox(height: FarmSpacing.md),
                  Wrap(
                    spacing: FarmSpacing.sm,
                    runSpacing: FarmSpacing.sm,
                    children: [
                      if (canObserve)
                        OutlinedButton.icon(
                          onPressed: _saving ? null : () => showObserveDialog(context, animal.id),
                          icon: const Icon(Icons.healing),
                          label: Text(context.t('qrReportIssue')),
                        ),
                      if (canWeight)
                        OutlinedButton.icon(
                          onPressed: _saving ? null : () => _recordWeight(animal),
                          icon: const Icon(Icons.monitor_weight_outlined),
                          label: Text(context.t('qrWeight')),
                        ),
                      if (canCare)
                        OutlinedButton.icon(
                          onPressed: _saving ? null : () => showAdministerDialog(context, subjectType: 'animal', subjectId: animal.id),
                          icon: const Icon(Icons.vaccines_outlined),
                          label: Text(context.t('phAdminister')),
                        ),
                    ],
                  ),
                  const SizedBox(height: FarmSpacing.sm),
                  Text(context.t('qrPhotosPending'), style: Theme.of(context).textTheme.bodySmall),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _feedEditor(BuildContext context, String key, _FeedRow row, List<FeedProduct> products, String lang) {
    final label = switch (key) {
      'concentrate' => context.t('qrConcentrate'),
      'silage' => context.t('qrSilage'),
      _ => context.t('qrStraw'),
    };
    final selected = products.any((p) => p.id == row.productId) ? row.productId : null;
    return Padding(
      padding: const EdgeInsets.only(top: FarmSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: FarmSpacing.sm),
          Wrap(
            spacing: FarmSpacing.sm,
            runSpacing: FarmSpacing.sm,
            children: [
              SizedBox(
                width: 240,
                child: DropdownButtonFormField<String>(
                  key: ValueKey('$key-$selected'),
                  initialValue: selected,
                  isExpanded: true,
                  decoration: InputDecoration(labelText: context.t('qrSelectFeed')),
                  items: [for (final p in products) DropdownMenuItem(value: p.id, child: Text(p.label(lang), overflow: TextOverflow.ellipsis))],
                  onChanged: _saving ? null : (id) => setState(() => row.productId = id),
                ),
              ),
              SizedBox(
                width: 155,
                child: TextField(
                  controller: row.offered,
                  enabled: !_saving,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(labelText: context.t('qrOfferedKg')),
                ),
              ),
              SizedBox(
                width: 155,
                child: TextField(
                  controller: row.refused,
                  enabled: !_saving,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(labelText: context.t('qrRefusedKg')),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
