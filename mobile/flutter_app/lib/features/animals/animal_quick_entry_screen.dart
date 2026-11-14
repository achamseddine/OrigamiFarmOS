import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/farm_icon_map.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/util/number_input.dart';
import '../../core/widgets/app_icon.dart';
import '../../core/widgets/photo_slot.dart';
import '../../core/widgets/section_card.dart';
import '../../core/widgets/status_pill.dart';
import '../../core/widgets/ux_blocks.dart';
import '../../domain/entities/access.dart';
import '../../domain/entities/animal.dart';
import '../../domain/entities/feeding.dart';
import '../../domain/entities/livestock.dart';
import '../../providers/access_provider.dart';
import '../../providers/animals_provider.dart';
import '../../providers/feeding_provider.dart';
import '../../providers/livestock_provider.dart';
import '../../providers/production_provider.dart';
import '../feed/feed_workspace_screen.dart' show feedDate, feedNumber;
import '../feed/feeding_event_dialog.dart';
import '../health/health_cases.dart' show showSubjectPicker;
import '../health/pharmacy_tab.dart' show showAdministerDialog;
import '../scan/qr_labels.dart';
import '../scan/qr_scanner_page.dart';
import 'animal_digital_twin_screen.dart';
import 'animal_herd_section.dart' show showGroupSheet;
import 'animal_quick_actions.dart' show showObserveDialog;
import 'animal_scan.dart';
import 'quick_round.dart';
import 'reproduction_forms.dart' show confirmLactationChange, showWeightForm;

/// The worker's screen at the animal (docs/QR-ANIMAL-QUICK-ENTRY.md):
/// scan the label — with the tablet's camera, a keyboard-wedge reader, or
/// by typing the tag — confirm it is the right animal, record what was
/// measured, save, and scan the next one.
///
/// What it adds to PR #11's first slice, from the workflow analysis:
///   - the camera reads the label on the device (ADR-003);
///   - a pen or flock label opens the group: its feeding round, its
///     members — never "whichever animal stood there";
///   - what is **already recorded today** for the animal is on screen, and
///     a second milking in the same session needs a deliberate yes;
///   - feed rows come from the animal's own program, product named and the
///     planned amount per feeding shown as a hint; "Fill planned amounts"
///     writes them in for the worker to check — nothing is saved that the
///     worker did not see and confirm;
///   - a **round** (the 06:00 milking, the individual feeding) shows who
///     is done and who is left, opened from the day's routine.
class AnimalQuickEntryScreen extends StatefulWidget {
  const AnimalQuickEntryScreen({super.key, this.initialAnimalId, this.initialGroupId, this.round, this.startWithCamera = false});

  final String? initialAnimalId;
  final String? initialGroupId;
  final QuickRound? round;

  /// Open the camera as soon as the screen appears.
  final bool startWithCamera;

  @override
  State<AnimalQuickEntryScreen> createState() => _AnimalQuickEntryScreenState();
}

class _FeedRow {
  _FeedRow({this.productId, this.productName, this.unit = 'kg', this.planned, this.fromPlan = false, this.slotKey});
  String? productId;
  String? productName;
  String unit;
  double? planned;

  /// The product is the program's; the worker only fills the amounts.
  final bool fromPlan;

  /// concentrate | silage | straw — PR #11's labelled slots, used when the
  /// animal is on no program.
  final String? slotKey;
  final offered = TextEditingController();
  final refused = TextEditingController();

  bool get hasValues => offered.text.trim().isNotEmpty || refused.text.trim().isNotEmpty;

  void dispose() {
    offered.dispose();
    refused.dispose();
  }
}

class _AnimalQuickEntryScreenState extends State<AnimalQuickEntryScreen> {
  final _code = TextEditingController();
  final _milk = TextEditingController();
  final _scanFocus = FocusNode();
  List<_FeedRow> _feeds = [];
  String? _animalId;
  String? _groupId;
  String _session = milkSessionForHour(DateTime.now().hour);
  bool _secondMilking = false;
  // The server refused a feed for lack of entered stock; the worker may say
  // the stock was simply never entered and record it anyway.
  bool _feedStockShort = false;
  bool _feedStockOverride = false;
  bool _loadingPlan = false;
  bool _saving = false;
  bool _autoScan = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _animalId = widget.initialAnimalId;
    _groupId = widget.initialGroupId;
    if (widget.round?.session != null) _session = widget.round!.session!;
    _autoScan = widget.startWithCamera;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_animalId != null) {
        _loadFeedRows(_animalId!);
      } else if (widget.startWithCamera) {
        _scanWithCamera();
      } else {
        _scanFocus.requestFocus();
      }
    });
  }

  @override
  void dispose() {
    _code.dispose();
    _milk.dispose();
    _scanFocus.dispose();
    for (final row in _feeds) {
      row.dispose();
    }
    super.dispose();
  }

  bool get _hasDraft => _milk.text.trim().isNotEmpty || _feeds.any((r) => r.hasValues);

  Future<bool> _confirmDiscard() async {
    if (!_hasDraft) return true;
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
    return discard == true;
  }

  Future<void> _selectAnimal(String id) async {
    if (_animalId == id && _groupId == null) return;
    if (!await _confirmDiscard() || !mounted) return;
    setState(() {
      _animalId = id;
      _groupId = null;
      _error = null;
      _milk.clear();
      _secondMilking = false;
      if (widget.round?.session == null) _session = milkSessionForHour(DateTime.now().hour);
    });
    await _loadFeedRows(id);
  }

  Future<void> _selectGroup(String id) async {
    if (!await _confirmDiscard() || !mounted) return;
    setState(() {
      _groupId = id;
      _animalId = null;
      _error = null;
      _milk.clear();
      _replaceFeeds(const []);
    });
  }

  void _replaceFeeds(List<_FeedRow> rows) {
    for (final r in _feeds) {
      r.dispose();
    }
    _feeds = rows;
  }

  /// The animal's program names its feeds; with no program, PR #11's three
  /// labelled rows ask the worker for the product.
  Future<void> _loadFeedRows(String animalId) async {
    // Prepared whatever the person's modules; the feed section itself is
    // shown only to someone who may record feeding.
    setState(() => _loadingPlan = true);
    FeedingPlan? plan;
    try {
      plan = await context.read<FeedingProvider>().planFor(animalId);
    } catch (_) {
      plan = null;
    }
    if (!mounted || _animalId != animalId) return;
    final seeds = feedRowsFromPlan(plan);
    // With no program, the farm's three standard feeds, each row already
    // pointing at the farm's product for it (the worker can change it).
    final slots = context.read<FeedingProvider>().feedSlots;
    const keys = {'concentrate': 'concentrate', 'corn_silage': 'silage', 'wheat_straw': 'straw'};
    setState(() {
      _loadingPlan = false;
      _replaceFeeds(seeds.isEmpty
          ? [for (final s in slots) _FeedRow(slotKey: keys[s.slot] ?? s.slot, productId: s.feedProductId, unit: s.unit)]
          : [for (final s in seeds) _FeedRow(productId: s.productId, productName: s.productName, unit: s.unit, planned: s.plannedPerFeeding, fromPlan: true)]);
    });
  }

  Future<void> _resolve(String raw) async {
    final target = resolveScan(
      raw,
      animals: context.read<AnimalsProvider>().animals,
      groups: context.read<LivestockProvider>().groups,
    );
    switch (target) {
      case AnimalScanTarget(:final animal):
        await _selectAnimal(animal.id);
        if (mounted && _animalId == animal.id) _code.clear();
      case GroupScanTarget(:final group):
        await _selectGroup(group.id);
        if (mounted && _groupId == group.id) _code.clear();
      case NoScanTarget(:final reason):
        setState(() => _error = context.t(switch (reason) {
              ScanMiss.notOurs => 'qrMissNotOurs',
              ScanMiss.ambiguous => 'qrMissAmbiguous',
              ScanMiss.unknown => 'qrMissUnknown',
            }));
    }
  }

  Future<void> _scanWithCamera() async {
    final raw = await QrScan.source.scan(context);
    if (!mounted || raw == null) return;
    _code.text = raw;
    await _resolve(raw);
  }

  Future<void> _find() async {
    final subject = await showSubjectPicker(context, title: context.t('qrFindTitle'), includeGroups: true);
    if (subject == null || !mounted) return;
    if (subject.type == 'group') {
      await _selectGroup(subject.id);
    } else {
      await _selectAnimal(subject.id);
    }
  }

  void _fillPlanned() {
    setState(() {
      for (final row in _feeds) {
        final p = row.planned;
        if (p != null && row.offered.text.trim().isEmpty) row.offered.text = feedNumber(p);
      }
    });
  }

  Future<void> _submit(Animal animal, {required bool canMilk, required bool canFeed}) async {
    final milkText = _milk.text.trim();
    final milk = milkText.isEmpty ? null : parseLocalizedDouble(milkText);
    if (milkText.isNotEmpty && (!canMilk || milk == null || milk < 0)) {
      setState(() => _error = context.t('qrInvalidQuantity'));
      return;
    }
    final production = context.read<ProductionProvider>();
    if (milk != null && sameSessionToday(animal.id, _session, production.milkRecords) != null && !_secondMilking) {
      setState(() => _error = context.t('qrConfirmSecondMilking'));
      return;
    }
    final components = <Map<String, dynamic>>[];
    final products = <String>{};
    for (final row in _feeds) {
      final offeredText = row.offered.text.trim();
      final refusedText = row.refused.text.trim();
      if (offeredText.isEmpty && refusedText.isEmpty) continue;
      final offered = parseLocalizedDouble(offeredText);
      final refused = refusedText.isEmpty ? null : parseLocalizedDouble(refusedText);
      if (!canFeed || offered == null || offered <= 0 || (refusedText.isNotEmpty && (refused == null || refused < 0 || refused > offered))) {
        setState(() => _error = context.t('qrInvalidQuantity'));
        return;
      }
      if (row.productId == null) {
        setState(() => _error = context.t('qrSelectFeed'));
        return;
      }
      if (!products.add(row.productId!)) {
        setState(() => _error = context.t('qrDuplicateFeed'));
        return;
      }
      components.add({
        'feed_product_id': row.productId,
        'quantity_offered': offered,
        'unit': row.unit,
        // Consumed only when the refusal was weighed — never assumed.
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
    var milkSaved = false;
    try {
      // Separate authoritative endpoints: clear only what succeeded, so a
      // retry after a feed failure cannot send the milk twice.
      if (milk != null) {
        final result = await context.read<AnimalsProvider>().recordMilk(
              animalId: animal.id,
              session: _session,
              liters: milk,
              destination: animal.isUnderWithdrawal ? 'withheld' : 'stored',
              confirmDuplicate: _secondMilking,
            );
        if (!mounted) return;
        if (!result.success) {
          setState(() => _error = result.error ?? context.t('couldNotSave'));
          return;
        }
        _milk.clear();
        _secondMilking = false;
        milkSaved = true;
        // The duplicate check and the round read this list.
        await production.load();
        if (!mounted) return;
      }
      if (components.isNotEmpty) {
        final result = await context.read<FeedingProvider>().recordFeeding({
          'subject_type': 'animal',
          'subject_id': animal.id,
          'event_type': 'offered',
          if (_feedStockOverride) 'allow_negative': true,
          'components': components,
        });
        if (!mounted) return;
        if (!result.success) {
          final message = result.error ?? context.t('couldNotSave');
          final short = message.startsWith('Not enough');
          final shown = short ? message.replaceAll(RegExp(r'\s*Pass allow_negative=true to override\.?'), '') : message;
          setState(() {
            _feedStockShort = _feedStockShort || short;
            _error = milkSaved ? '${context.t('qrMilkSavedPartial')} $shown' : shown;
          });
          return;
        }
        _feedStockOverride = false;
        for (final row in _feeds) {
          row.offered.clear();
          row.refused.clear();
        }
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${animal.name} — ${context.t('qrSavedOnDevice')}')));
      setState(() {
        _animalId = null;
        _code.clear();
        _replaceFeeds(const []);
      });
      if (_autoScan) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _scanWithCamera();
        });
      } else {
        _scanFocus.requestFocus();
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final animals = context.watch<AnimalsProvider>().animals;
    final livestock = context.watch<LivestockProvider>();
    final production = context.watch<ProductionProvider>();
    final feeding = context.watch<FeedingProvider>();
    Animal? animal;
    for (final a in animals) {
      if (a.id == _animalId) animal = a;
    }
    AnimalGroup? group;
    for (final g in livestock.groups) {
      if (g.id == _groupId) group = g;
    }
    final round = widget.round;
    final status = round == null
        ? null
        : roundStatus(
            round,
            animals: animals,
            milked: (a) => livestock.resolve(species: a.species, sex: a.sex, lifeStage: a.lifeStage, managementProfile: a.managementProfile).has(Cap.milkProduction),
            milk: production.milkRecords,
            plan: feeding.dailyPlan,
            fedToday: feeding.fedToday,
          );

    return Scaffold(
      backgroundColor: FarmColors.stone,
      appBar: AppBar(
        backgroundColor: FarmColors.stone,
        title: Text(round == null ? context.t('qrQuickEntry') : _roundTitle(context, round)),
        actions: [
          Row(children: [
            Text(context.t('qrAutoScan'), style: FarmTypography.textTheme.labelMedium),
            Switch(value: _autoScan, onChanged: (v) => setState(() => _autoScan = v)),
          ]),
          const SizedBox(width: FarmSpacing.sm),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 820),
            child: ListView(
              padding: const EdgeInsets.all(FarmSpacing.md),
              children: [
                _scanBar(context),
                if (_error != null) ...[
                  const SizedBox(height: FarmSpacing.sm),
                  NoticeBanner(tone: NoticeTone.danger, text: _error!),
                ],
                if (status != null) ...[
                  const SizedBox(height: FarmSpacing.md),
                  _RoundPanel(status: status, current: _animalId, onSelect: _selectAnimal),
                ],
                const SizedBox(height: FarmSpacing.md),
                if (animal != null)
                  ..._animalEntry(context, animal, livestock, production, feeding, status)
                else if (group != null)
                  _GroupEntry(group: group, onSelectAnimal: _selectAnimal)
                else
                  SectionCard(child: EmptyState(icon: FarmIcon.qr, message: context.t('qrScanToStart'), detail: context.t('qrScanToStartDetail'))),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _roundTitle(BuildContext context, QuickRound round) => switch (round.kind) {
        RoundKind.milking => round.session == 'evening' ? context.t('routineMilkEvening') : context.t('routineMilkMorning'),
        RoundKind.feeding => '${context.t('routineFeeding')} · ${context.t('routineIndividual')}',
      };

  Widget _scanBar(BuildContext context) {
    return SectionCard(
      padding: const EdgeInsets.all(FarmSpacing.md),
      child: LayoutBuilder(builder: (context, c) {
        final camera = FilledButton.icon(
          style: FilledButton.styleFrom(minimumSize: const Size(0, kFarmPrimaryTarget), backgroundColor: FarmColors.cedarDark),
          onPressed: _saving ? null : _scanWithCamera,
          icon: const Icon(Icons.qr_code_scanner),
          label: Text(context.t('qrScanLabel')),
        );
        final field = TextField(
          key: const ValueKey('qr-code-field'),
          controller: _code,
          focusNode: _scanFocus,
          enabled: !_saving,
          textInputAction: TextInputAction.go,
          onSubmitted: (v) => _resolve(v),
          decoration: InputDecoration(
            labelText: context.t('qrScanOrType'),
            isDense: true,
            prefixIcon: const Icon(Icons.keyboard_outlined, size: 20),
            suffixIcon: IconButton(tooltip: context.t('qrOpenAnimal'), onPressed: _saving ? null : () => _resolve(_code.text), icon: const Icon(Icons.arrow_forward)),
          ),
        );
        final find = OutlinedButton.icon(onPressed: _saving ? null : _find, icon: const Icon(Icons.search, size: 18), label: Text(context.t('qrFind')));
        if (c.maxWidth < 600) {
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [camera, const SizedBox(height: 8), field, const SizedBox(height: 8), find]);
        }
        return Row(children: [camera, const SizedBox(width: 12), Expanded(child: field), const SizedBox(width: 12), find]);
      }),
    );
  }

  List<Widget> _animalEntry(BuildContext context, Animal animal, LivestockProvider livestock, ProductionProvider production, FeedingProvider feeding, RoundStatus? status) {
    final access = context.watch<AccessProvider>();
    final lang = Localizations.localeOf(context).languageCode;
    final caps = livestock.resolve(species: animal.species, sex: animal.sex, lifeStage: animal.lifeStage, managementProfile: animal.managementProfile);
    final canMilk = caps.has(Cap.milkProduction) && access.canCreate(FarmModule.milkProduction);
    final canFeed = access.canCreate(FarmModule.feedNutrition);
    final canObserve = access.canCreate(FarmModule.animalHealth) || access.canCreate(FarmModule.animals);
    final canCare = access.canCreate(FarmModule.animalHealth);
    final canWeigh = caps.has(Cap.weightTracking) && (access.canEdit(FarmModule.animals) || canCare);
    final milked = milkToday(animal.id, production.milkRecords);
    final duplicate = sameSessionToday(animal.id, _session, production.milkRecords);
    final fedCount = feedingsToday(animal.id, feeding.recentEvents);
    final rounds = feeding.cachedPlan(animal.id)?.program?.feedingsPerDay;
    final outsideRound = status != null && !status.contains(animal.id);

    return [
      // Who this is — the worker checks it before anything is recorded.
      SectionCard(
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
            width: 72,
            height: 72,
            child: PhotoSlot(filePath: animal.photoPath, icon: FarmIconMap.species(livestock.speciesIcon(animal.species)), borderRadius: BorderRadius.circular(FarmRadii.sm)),
          ),
          const SizedBox(width: FarmSpacing.md),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Eyebrow([livestock.speciesName(animal.species, lang), if (animal.primaryId.isNotEmpty) '#${animal.primaryId}'].join(' · ')),
              Text(animal.name, style: FarmTypography.display(size: 26)),
              Text([animal.location, if (animal.groupName != null) animal.groupName!].where((s) => s.isNotEmpty).join(' · '), style: FarmTypography.textTheme.bodySmall),
              const SizedBox(height: 6),
              Wrap(spacing: 6, runSpacing: 6, children: [
                if (animal.isUnderWithdrawal) StatusPill(label: '${context.t('twWithdrawalUntil')} ${feedDate(animal.underWithdrawalUntil!)}', level: FarmStatusLevel.alert, dense: true),
                if (animal.pregnant) TagChip(context.t('pregnant'), color: FarmColors.lilac),
                if (animal.lactating) TagChip(context.t('lactating'), color: FarmColors.milkBlue),
              ]),
            ]),
          ),
          IconButton(
            tooltip: context.t('hcOpenAnimal'),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => AnimalDigitalTwinScreen(animalId: animal.id))),
            icon: const Icon(Icons.open_in_new),
          ),
        ]),
      ),
      if (outsideRound) ...[
        const SizedBox(height: FarmSpacing.sm),
        NoticeBanner(text: context.t('qrNotInRound')),
      ],
      const SizedBox(height: FarmSpacing.md),
      // What is already recorded today: the duplicate check starts here.
      SectionCard(
        title: context.t('qrToday'),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (caps.has(Cap.milkProduction))
            FactRow(
              label: context.t('qrMilkToday'),
              value: milked.isEmpty
                  ? context.t('qrNoneYet')
                  : [for (final r in milked) '${r.session == 'morning' ? context.t('sessionMorning') : context.t('sessionEvening')} ${r.liters.toStringAsFixed(1)} L'].join(' · '),
            ),
          FactRow(
            label: context.t('qrFeedToday'),
            value: rounds == null ? '$fedCount' : '$fedCount / $rounds ${context.t('routineRounds')}',
            last: true,
          ),
        ]),
      ),
      if (canMilk) ...[
        const SizedBox(height: FarmSpacing.md),
        SectionCard(
          title: context.t('qrMilkTitle'),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            // Milk belongs to an animal in milk: one not yet marked as being
            // milked is started first (calving date), then the field opens.
            if (!animal.lactating) ...[
              NoticeBanner(text: context.t('milkNotInMilk').replaceAll('{name}', animal.name)),
              const SizedBox(height: FarmSpacing.sm),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: OutlinedButton.icon(
                  key: const ValueKey('qr-start-milking'),
                  onPressed: _saving
                      ? null
                      : () async {
                          final animals = context.read<AnimalsProvider>();
                          final started = await confirmLactationChange(context, animal, start: true);
                          if (started) await animals.load();
                        },
                  icon: const Icon(Icons.play_arrow, size: 18),
                  label: Text(context.t('reproActStartMilking')),
                ),
              ),
            ] else ...[
            SegmentedButton<String>(
              segments: [
                ButtonSegment(value: 'morning', label: Text(context.t('sessionMorning'))),
                ButtonSegment(value: 'evening', label: Text(context.t('sessionEvening'))),
              ],
              selected: {_session},
              onSelectionChanged: _saving ? null : (v) => setState(() {
                _session = v.first;
                _secondMilking = false;
              }),
            ),
            const SizedBox(height: FarmSpacing.sm),
            TextField(
              key: const ValueKey('qr-milk-field'),
              controller: _milk,
              enabled: !_saving,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
              decoration: InputDecoration(labelText: context.t('qrMilkLitres'), suffixText: 'L'),
            ),
            if (animal.isUnderWithdrawal) ...[
              const SizedBox(height: FarmSpacing.sm),
              NoticeBanner(tone: NoticeTone.danger, text: context.t('qrWithheldMilk')),
            ],
            if (duplicate != null) ...[
              const SizedBox(height: FarmSpacing.sm),
              NoticeBanner(
                text: '${context.t('qrAlreadyMilked')} ${duplicate.liters.toStringAsFixed(1)} L · ${TimeOfDay.fromDateTime(duplicate.recordedAt.toLocal()).format(context)}',
              ),
              Material(
                type: MaterialType.transparency,
                child: CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _secondMilking,
                  onChanged: _saving ? null : (v) => setState(() => _secondMilking = v ?? false),
                  title: Text(context.t('qrSecondMilking')),
                  controlAffinity: ListTileControlAffinity.leading,
                ),
              ),
            ],
            ],
          ]),
        ),
      ],
      if (canFeed) ...[
        const SizedBox(height: FarmSpacing.md),
        SectionCard(
          title: context.t('qrFeedTitle'),
          subtitle: context.t('qrFeedOfferedNote'),
          trailing: _feeds.any((r) => r.planned != null) ? context.t('qrFillPlanned') : null,
          onTrailingTap: _feeds.any((r) => r.planned != null) ? _fillPlanned : null,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (rounds != null && fedCount >= rounds) ...[
              NoticeBanner(text: context.t('qrAllRoundsFed')),
              const SizedBox(height: FarmSpacing.sm),
            ],
            if (_loadingPlan)
              const Padding(padding: EdgeInsets.all(FarmSpacing.md), child: Center(child: CircularProgressIndicator()))
            else
              for (final row in _feeds) _feedEditor(context, row, feeding, lang),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                onPressed: _saving ? null : () => setState(() => _feeds = [..._feeds, _FeedRow()]),
                icon: const Icon(Icons.add, size: 16),
                label: Text(context.t('qrAddFeed')),
              ),
            ),
            if (_feedStockShort) ...[
              NoticeBanner(title: context.t('feedStockShortTitle'), text: context.t('feedStockShortBody')),
              if (context.watch<AccessProvider>().canOverrideFeedStock)
                Material(
                  type: MaterialType.transparency,
                  child: CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    dense: true,
                    value: _feedStockOverride,
                    title: Text(context.t('feedRecordAnyway')),
                    onChanged: _saving ? null : (v) => setState(() => _feedStockOverride = v ?? false),
                  ),
                )
              else
                Text(context.t('feedOverrideNeedsApproval'), style: const TextStyle(fontSize: 12.5, color: FarmColors.warningInk)),
            ],
          ]),
        ),
      ],
      const SizedBox(height: FarmSpacing.md),
      if (canMilk || canFeed)
        FilledButton.icon(
          key: const ValueKey('qr-save'),
          onPressed: _saving ? null : () => _submit(animal, canMilk: canMilk, canFeed: canFeed),
          icon: _saving ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.check_circle_outline),
          label: Text(context.t('qrSaveNext')),
          style: FilledButton.styleFrom(minimumSize: const Size(0, kFarmPrimaryTarget), backgroundColor: FarmColors.cedarDark),
        ),
      const SizedBox(height: FarmSpacing.md),
      Wrap(spacing: FarmSpacing.sm, runSpacing: FarmSpacing.sm, children: [
        if (canObserve)
          OutlinedButton.icon(
            onPressed: _saving ? null : () => showObserveDialog(context, animal.id),
            icon: const AppIcon(FarmIcon.eye, size: 16, color: FarmColors.cedar),
            label: Text(context.t('qrReportIssue')),
          ),
        if (canWeigh)
          OutlinedButton.icon(
            onPressed: _saving ? null : () => showWeightForm(context, animal),
            icon: const AppIcon(FarmIcon.scale, size: 16, color: FarmColors.cedar),
            label: Text(context.t('qrWeight')),
          ),
        if (canCare)
          OutlinedButton.icon(
            onPressed: _saving ? null : () => showAdministerDialog(context, subjectType: 'animal', subjectId: animal.id),
            icon: const AppIcon(FarmIcon.syringe, size: 16, color: FarmColors.lilac),
            label: Text(context.t('phAdminister')),
          ),
        OutlinedButton.icon(
          onPressed: () => showQrLabels(context, labels: [QrLabel.forAnimal(animal, speciesName: livestock.speciesName(animal.species, lang))]),
          icon: const Icon(Icons.qr_code_2, size: 18),
          label: Text(context.t('qrLabel')),
        ),
      ]),
    ];
  }

  Widget _feedEditor(BuildContext context, _FeedRow row, FeedingProvider feeding, String lang) {
    final label = row.fromPlan
        ? (row.productName ?? row.productId ?? '')
        : switch (row.slotKey) {
            'concentrate' => context.t('qrConcentrate'),
            'silage' => context.t('qrSilage'),
            'straw' => context.t('qrStraw'),
            _ => context.t('qrOtherFeed'),
          };
    final products = [for (final p in feeding.feedable) if (p.unit == row.unit || !row.fromPlan) p];
    return Padding(
      padding: const EdgeInsets.only(bottom: FarmSpacing.md),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(label, style: FarmTypography.textTheme.titleSmall)),
          if (row.planned != null)
            Text('${context.t('qrPlanned')} ${feedNumber(row.planned!)} ${row.unit}', style: FarmTypography.textTheme.bodySmall),
        ]),
        const SizedBox(height: 6),
        Wrap(spacing: FarmSpacing.sm, runSpacing: FarmSpacing.sm, children: [
          if (!row.fromPlan)
            SizedBox(
              width: 240,
              child: DropdownButtonFormField<String>(
                initialValue: products.any((p) => p.id == row.productId) ? row.productId : null,
                isExpanded: true,
                decoration: InputDecoration(labelText: context.t('qrSelectFeed'), isDense: true),
                items: [for (final p in products) DropdownMenuItem(value: p.id, child: Text(p.label(lang), overflow: TextOverflow.ellipsis))],
                onChanged: _saving
                    ? null
                    : (id) => setState(() {
                          row.productId = id;
                          for (final p in products) {
                            if (p.id == id) row.unit = p.unit;
                          }
                        }),
              ),
            ),
          SizedBox(
            width: 150,
            child: TextField(
              controller: row.offered,
              enabled: !_saving,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(labelText: '${context.t('qrOffered')} (${row.unit})', isDense: true),
            ),
          ),
          SizedBox(
            width: 150,
            child: TextField(
              controller: row.refused,
              enabled: !_saving,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(labelText: '${context.t('qrRefused')} (${row.unit})', isDense: true),
            ),
          ),
        ]),
      ]),
    );
  }
}

/// Who in the round is done and who is left; tap a name to record it.
class _RoundPanel extends StatelessWidget {
  const _RoundPanel({required this.status, required this.current, required this.onSelect});
  final RoundStatus status;
  final String? current;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: '${status.done} ${context.t('regOf')} ${status.total} ${context.t('routineDone')}',
      subtitle: status.complete ? context.t('qrRoundComplete') : context.t('qrRoundHint'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(FarmRadii.pill),
          child: LinearProgressIndicator(value: status.total == 0 ? 0 : status.done / status.total, minHeight: 8, backgroundColor: FarmColors.sand, color: FarmColors.cedar),
        ),
        const SizedBox(height: FarmSpacing.sm),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final e in status.entries)
            ChoiceChip(
              avatar: Icon(e.done ? Icons.check_circle : Icons.radio_button_unchecked, size: 16, color: e.done ? FarmColors.success : FarmColors.muted),
              label: Text(e.animal.primaryId.isEmpty ? e.animal.name : '${e.animal.name} #${e.animal.primaryId}'),
              selected: e.animal.id == current,
              onSelected: (_) => onSelect(e.animal.id),
            ),
        ]),
      ]),
    );
  }
}

/// A pen, herd or flock label: the group's feeding round today, its
/// members to pick from, and its own record.
class _GroupEntry extends StatelessWidget {
  const _GroupEntry({required this.group, required this.onSelectAnimal});
  final AnimalGroup group;
  final ValueChanged<String> onSelectAnimal;

  @override
  Widget build(BuildContext context) {
    final feeding = context.watch<FeedingProvider>();
    final access = context.watch<AccessProvider>();
    final livestock = context.watch<LivestockProvider>();
    final lang = Localizations.localeOf(context).languageCode;
    final members = [for (final a in context.watch<AnimalsProvider>().animals) if (a.onFarm && a.groupName == group.name) a];
    DailyPlanLine? line;
    for (final l in feeding.dailyPlan.lines) {
      if (l.subjectId == group.id) line = l;
    }
    final rounds = line?.program?.feedingsPerDay;
    final fed = feedingsToday(group.id, feeding.recentEvents);
    final canFeed = access.canCreate(FarmModule.feedNutrition);

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionCard(
        child: Row(children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(color: FarmColors.mist, borderRadius: BorderRadius.circular(FarmRadii.sm)),
            child: Center(child: AppIcon(FarmIconMap.species(livestock.speciesIcon(group.species)), size: 26, color: FarmColors.cedar)),
          ),
          const SizedBox(width: FarmSpacing.md),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Eyebrow('${context.t('qrGroupLabel')} · ${livestock.speciesName(group.species, lang)}'),
              Text(group.name, style: FarmTypography.display(size: 24)),
              Text('${group.count} ${context.t('qrHead')}', style: FarmTypography.textTheme.bodySmall),
            ]),
          ),
          TextButton(onPressed: () => showGroupSheet(context, group), child: Text(context.t('qrOpenGroup'))),
        ]),
      ),
      const SizedBox(height: FarmSpacing.md),
      SectionCard(
        title: context.t('qrGroupFeeding'),
        subtitle: context.t('qrGroupFeedingSub'),
        child: line == null
            ? EmptyState(message: context.t('qrNoGroupPlan'), icon: FarmIcon.feedBag, compact: true)
            : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                FactRow(label: context.t('qrFeedToday'), value: '$fed / ${rounds ?? 1} ${context.t('routineRounds')}'),
                for (final t in line.dailyTargets)
                  FactRow(label: t.productName ?? t.feedProductId, value: '${feedNumber(t.dailyTotal / ((rounds ?? 1) < 1 ? 1 : (rounds ?? 1)))} ${t.unit} ${context.t('qrPerFeeding')}'),
                const SizedBox(height: FarmSpacing.sm),
                if (canFeed)
                  FilledButton.icon(
                    style: FilledButton.styleFrom(minimumSize: const Size(0, kFarmPrimaryTarget), backgroundColor: FarmColors.cedarDark),
                    onPressed: () => showFeedingEventDialog(
                      context,
                      subjectType: 'group',
                      subjectId: group.id,
                      subjectName: group.name,
                      headCount: line!.headCount,
                      initialLines: linesFromTargets(line.dailyTargets, fraction: (rounds ?? 1) <= 1 ? 1 : 1 / rounds!),
                    ),
                    icon: const Icon(Icons.check_circle_outline),
                    label: Text(context.t('qrRecordGroupRound')),
                  ),
              ]),
      ),
      if (members.isNotEmpty) ...[
        const SizedBox(height: FarmSpacing.md),
        SectionCard(
          title: context.t('qrGroupMembers'),
          subtitle: context.t('qrGroupMembersSub'),
          child: Wrap(spacing: 6, runSpacing: 6, children: [
            for (final a in members) ActionChip(label: Text(a.primaryId.isEmpty ? a.name : '${a.name} #${a.primaryId}'), onPressed: () => onSelectAnimal(a.id)),
          ]),
        ),
      ],
      const SizedBox(height: FarmSpacing.md),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: OutlinedButton.icon(
          onPressed: () => showQrLabels(context, labels: [QrLabel.forGroup(group, speciesName: livestock.speciesName(group.species, lang))]),
          icon: const Icon(Icons.qr_code_2, size: 18),
          label: Text(context.t('qrLabel')),
        ),
      ),
    ]);
  }
}
