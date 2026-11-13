import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/farm_icon_map.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/widgets/app_icon.dart';
import '../../core/widgets/directional_icon.dart';
import '../../core/widgets/kpi_card.dart';
import '../../core/widgets/photo_slot.dart';
import '../../core/widgets/section_card.dart';
import '../../core/widgets/status_pill.dart';
import '../../core/widgets/top_bar.dart';
import '../../core/widgets/ux_blocks.dart';
import '../../domain/entities/access.dart';
import '../../domain/entities/animal.dart';
import '../../domain/entities/livestock.dart';
import '../../domain/entities/production_records.dart';
import '../../domain/entities/reproduction.dart';
import '../../providers/access_provider.dart';
import '../../providers/animals_provider.dart';
import '../../providers/livestock_provider.dart';
import '../../providers/production_provider.dart';
import '../../sync/sync_controller.dart';
import '../feed/feed_workspace_screen.dart' show feedDate;
import '../health/emergency_tab.dart' show showAssessDialog;
import '../health/health_cases.dart' show CaseRow, showOpenCaseForm;
import '../../providers/health_records_provider.dart';
import '../health/pharmacy_tab.dart' show showAdministerDialog;
import '../sync/sync_pill.dart' show PendingChip;
import 'add_animal_form.dart' show showAnimalForm;
import 'animal_care_section.dart';
import 'animal_herd_section.dart';
import 'animal_identifier_dialog.dart';
import 'animal_quick_actions.dart';
import 'animal_quick_entry_screen.dart';
import '../scan/qr_labels.dart';
import 'animal_twin_tabs.dart';
import 'capability_chips.dart';
import 'reproduction_forms.dart';

/// Screen 4 — the Animal Digital Twin, laid out the way the V3 farm-wide
/// prototype settled it (`prototypes/origami-farmos-v3.html`):
///
///   1. a header card — photo, "SPECIES · TAG" eyebrow, name, the tags that
///      say what the animal is right now, and the two things a person
///      came to do: edit the profile, or record something;
///   2. four figures — milk, weight, pregnancy, activity — each saying
///      what it is measured from;
///   3. tabs, one per part of the record: Overview, Milk, Feed, Weight,
///      Reproduction, Health & medicines, Timeline.
///
/// Which tabs exist is decided by the resolved capabilities and the
/// signed-in person's modules, never by the species: a hen has no Milk or
/// Reproduction tab because her capabilities say so, a worker without the
/// health module has no Health tab because the server would refuse it.
///
/// It is still a pushed route (no bottom bar), with the farm-wide [TopBar]
/// beside the way back.
class AnimalDigitalTwinScreen extends StatefulWidget {
  const AnimalDigitalTwinScreen({super.key, required this.animalId, this.initialTab = TwinTab.overview});

  final String animalId;
  final TwinTab initialTab;

  @override
  State<AnimalDigitalTwinScreen> createState() => _AnimalDigitalTwinScreenState();
}

/// The parts of the record, in tab order.
enum TwinTab { overview, milk, feed, weight, reproduction, health, timeline }

String twinTabLabel(BuildContext context, TwinTab tab) => context.t(switch (tab) {
      TwinTab.overview => 'twTabOverview',
      TwinTab.milk => 'twTabMilk',
      TwinTab.feed => 'twTabFeed',
      TwinTab.weight => 'twTabWeight',
      TwinTab.reproduction => 'twTabRepro',
      TwinTab.health => 'twTabHealth',
      TwinTab.timeline => 'twTabTimeline',
    });

/// The tabs this animal has, for this person.
List<TwinTab> twinTabsFor({required CapabilitySet caps, required AccessProvider access, required ReproSummary? repro}) => [
      TwinTab.overview,
      if (caps.has(Cap.milkProduction)) TwinTab.milk,
      if (access.isModuleAvailable(FarmModule.feedNutrition)) TwinTab.feed,
      TwinTab.weight,
      // Until the twin arrives, the resolved capabilities say whether a
      // reproduction record can exist; once it is here, the server's own
      // summary does.
      if (repro != null ? repro.applies.any : (caps.has(Cap.breeding) || caps.has(Cap.pregnancy) || caps.has(Cap.lactation))) TwinTab.reproduction,
      if (access.isModuleAvailable(FarmModule.animalHealth)) TwinTab.health,
      TwinTab.timeline,
    ];

class _AnimalDigitalTwinScreenState extends State<AnimalDigitalTwinScreen> {
  Map<String, dynamic>? _twin;
  bool _twinLoading = true;
  String? _twinError;
  late TwinTab _tab = widget.initialTab;

  /// Bumped whenever something is recorded, so tabs that fetch their own
  /// lists (weights, history) fetch again.
  int _revision = 0;

  @override
  void initState() {
    super.initState();
    _loadTwin();
  }

  @override
  void didUpdateWidget(covariant AnimalDigitalTwinScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animalId != widget.animalId) _loadTwin();
  }

  Future<void> _loadTwin() async {
    setState(() {
      _twinLoading = true;
      _twinError = null;
    });
    try {
      final twin = await context.read<AnimalsProvider>().fetchDigitalTwin(widget.animalId);
      if (!mounted) return;
      setState(() {
        _twin = twin;
        _twinLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _twinError = context.t('twinLoadFailed');
        _twinLoading = false;
      });
    }
  }

  /// Refreshes the farm-wide list (the header) and the twin (everything
  /// under it) after something was recorded here.
  Future<void> _refreshRecord() async {
    await context.read<AnimalsProvider>().load();
    if (!mounted) return;
    setState(() => _revision++);
    await _loadTwin();
  }

  /// What this animal can do. The server's answer travels with the twin;
  /// until it arrives — or for an animal registered offline a moment ago,
  /// which the server has never seen — the device resolves it from the
  /// same cached rules, and the two are proven to agree.
  CapabilitySet _capabilities(BuildContext context, Animal animal) {
    final fromTwin = _twin?['capabilities'];
    if (fromTwin is Map<String, dynamic> && (fromTwin['capabilities'] as List<dynamic>? ?? const []).isNotEmpty) {
      return CapabilitySet.fromJson(fromTwin);
    }
    return context.watch<LivestockProvider>().resolve(
          species: animal.species,
          sex: animal.sex,
          lifeStage: animal.lifeStage,
          managementProfile: animal.managementProfile,
        );
  }

  @override
  Widget build(BuildContext context) {
    final herd = context.watch<AnimalsProvider>();
    final found = herd.find(widget.animalId);
    // Opened from a notification before the herd has loaded, or for an
    // animal no longer on this farm's list: say so rather than show
    // somebody else's record.
    if (found == null) return _Missing(loading: herd.loading || herd.animals.isEmpty);
    final animal = found;
    final caps = _capabilities(context, animal);
    final access = context.watch<AccessProvider>();
    final rawRepro = _twin?['reproduction'];
    final repro = rawRepro is Map ? ReproSummary.fromJson(rawRepro.cast<String, dynamic>()) : null;
    final tabs = twinTabsFor(caps: caps, access: access, repro: repro);
    final tab = tabs.contains(_tab) ? _tab : TwinTab.overview;
    final actions = animalRecordActions(context, animal: animal, caps: caps, repro: repro, onChanged: _refreshRecord);
    final canEdit = animal.onFarm && access.canEdit(FarmModule.animals);
    final compact = MediaQuery.sizeOf(context).width < kTabletBreakpoint;

    return Scaffold(
      backgroundColor: FarmColors.stone,
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: compact ? FarmSpacing.md : FarmSpacing.xl, vertical: FarmSpacing.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  TextButton.icon(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const BackChevron(),
                    label: Text(context.t('backToHerd')),
                  ),
                  const Expanded(child: TopBar()),
                ],
              ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.only(bottom: FarmSpacing.xl),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TwinHeaderCard(
                        animal: animal,
                        caps: caps,
                        onEdit: canEdit ? () => showAnimalForm(context, animal: animal) : null,
                        onRecord: actions.isEmpty ? null : () => showAnimalRecordSheet(context, animal: animal, actions: actions),
                      ),
                      if (!animal.onFarm) ...[
                        const SizedBox(height: FarmSpacing.sm),
                        NoticeBanner(
                          tone: NoticeTone.info,
                          title: '${context.t('exitedBanner')} · ${context.t('exit_${animal.lifecycleStatus}')}${animal.exitedAt != null ? ' · ${feedDate(animal.exitedAt!)}' : ''}',
                          text: context.t('twLeftFarmNotice'),
                        ),
                      ],
                      const SizedBox(height: FarmSpacing.md),
                      TwinKpiRow(animal: animal, caps: caps, twin: _twin, repro: repro),
                      const SizedBox(height: FarmSpacing.md),
                      UnderlineTabs(
                        labels: [for (final t in tabs) twinTabLabel(context, t)],
                        selected: tabs.indexOf(tab),
                        onSelect: (i) => setState(() => _tab = tabs[i]),
                      ),
                      const SizedBox(height: FarmSpacing.md),
                      KeyedSubtree(key: ValueKey('${tab.name}-$_revision'), child: _body(context, tab, animal, caps, repro, actions)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context, TwinTab tab, Animal animal, CapabilitySet caps, ReproSummary? repro, List<RecordAction> actions) {
    switch (tab) {
      case TwinTab.overview:
        return _OverviewTab(
          animal: animal,
          caps: caps,
          twin: _twin,
          loading: _twinLoading,
          error: _twinError,
          actions: actions,
          onRecordChanged: _refreshRecord,
          onOpenTimeline: () => setState(() => _tab = TwinTab.timeline),
        );
      case TwinTab.milk:
        return TwinMilkTab(animal: animal, onRecord: _action(actions, 'milk'));
      case TwinTab.feed:
        return TwinFeedTab(animal: animal, caps: caps, twin: _twin, repro: repro);
      case TwinTab.weight:
        return TwinWeightTab(animal: animal, caps: caps, onRecord: _action(actions, 'weight'));
      case TwinTab.reproduction:
        return TwinReproductionTab(animal: animal, twin: _twin, loading: _twinLoading, onChanged: _refreshRecord);
      case TwinTab.health:
        return _HealthTab(animal: animal, twin: _twin, loading: _twinLoading, error: _twinError, actions: actions);
      case TwinTab.timeline:
        return TwinTimelineTab(animal: animal, twin: _twin, loading: _twinLoading, error: _twinError);
    }
  }

  VoidCallback? _action(List<RecordAction> actions, String id) {
    for (final a in actions) {
      if (a.id == id) return a.run;
    }
    return null;
  }
}

class _Missing extends StatelessWidget {
  const _Missing({required this.loading});
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: FarmColors.stone,
      appBar: AppBar(backgroundColor: FarmColors.stone, leading: const BackButton()),
      body: Center(
        child: loading
            ? const CircularProgressIndicator()
            : Padding(
                padding: const EdgeInsets.all(FarmSpacing.lg),
                child: EmptyState(message: context.t('twNotFound'), icon: FarmIcon.cow),
              ),
      ),
    );
  }
}

// ---------------------------------------------------------------- record actions

/// One thing that can be recorded against this animal from its profile.
class RecordAction {
  const RecordAction(this.id, this.icon, this.label, this.run, {this.accent = FarmColors.cedar, this.group = RecordGroup.daily});
  final String id;
  final FarmIcon icon;
  final String label;
  final VoidCallback run;
  final Color accent;
  final RecordGroup group;
}

enum RecordGroup { daily, health, breeding, herd }

/// Everything this person may record for this animal, in the order a
/// worker reaches for them. The capabilities decide what exists ("Milk"
/// only for an animal that is milked, "Breeding" only where breeding
/// applies), the person's modules decide what they may do — the server
/// would refuse the rest anyway, and a button that can only fail is worse
/// than none. An animal that has left the farm takes no new records.
List<RecordAction> animalRecordActions(
  BuildContext context, {
  required Animal animal,
  required CapabilitySet caps,
  required ReproSummary? repro,
  required Future<void> Function() onChanged,
}) {
  if (!animal.onFarm) return const [];
  final access = context.watch<AccessProvider>();
  final health = access.isModuleAvailable(FarmModule.animalHealth);
  final canCare = health && access.canCreate(FarmModule.animalHealth);
  final canWeigh = access.canEdit(FarmModule.animals) || access.canCreate(FarmModule.animalHealth);
  final canRepro = access.canCreate(FarmModule.animals) || access.canCreate(FarmModule.animalHealth);
  final canHerd = access.canEdit(FarmModule.animals);
  // The QR workflow's gating (docs/QR-ANIMAL-QUICK-ENTRY.md): an action is
  // offered only to someone the server would let record it.
  final canObserve = access.canCreate(FarmModule.animalHealth) || access.canCreate(FarmModule.animals);
  final canFeed = access.canCreate(FarmModule.feedNutrition);
  final canMilk = caps.has(Cap.milkProduction) && access.canCreate(FarmModule.milkProduction);
  final arabic = Localizations.localeOf(context).languageCode == 'ar';

  Future<void> then(Future<Object?> work) async {
    await work;
    await onChanged();
  }

  return [
    // Milk, feed and the rest of a visit in one sheet — the scan-first
    // worker screen, opened on this animal.
    if (canMilk || canFeed || canObserve || canCare)
      RecordAction('quick', FarmIcon.qr, context.t('qrQuickEntry'), () => then(Navigator.of(context).push<void>(
            MaterialPageRoute<void>(builder: (_) => AnimalQuickEntryScreen(initialAnimalId: animal.id)),
          ))),
    if (canMilk)
      RecordAction('milk', FarmIcon.milkBottle, context.t('twRecordMilk'), accent: FarmColors.milkBlue, () async {
        await showMilkDialog(context, animal);
        if (context.mounted) await context.read<ProductionProvider>().load();
        await onChanged();
      }),
    if (canFeed) RecordAction('feed', FarmIcon.feedBag, context.t('twRecordFeeding'), () => then(showFeedDialog(context, animal))),
    if (canWeigh) RecordAction('weight', FarmIcon.scale, context.t('twRecordWeight'), () => then(showWeightForm(context, animal))),
    if (canObserve) RecordAction('observe', FarmIcon.eye, context.t('twRecordObservation'), () => then(showObserveDialog(context, animal.id))),
    // Medicine is given through the pharmacy — lot, route and withdrawal
    // from the record — never as free text.
    if (canCare)
      RecordAction('administer', FarmIcon.syringe, context.t('phAdminister'), accent: FarmColors.lilac, group: RecordGroup.health,
          () => then(showAdministerDialog(context, subjectType: 'animal', subjectId: animal.id))),
    if (canCare)
      RecordAction('assess', FarmIcon.bell, context.t('emAssess'), accent: FarmColors.danger, group: RecordGroup.health,
          () => then(showAssessDialog(context, subjectType: 'animal', subjectId: animal.id))),
    if (canRepro && repro != null && repro.applies.breeding && !repro.pregnant)
      RecordAction('breeding', FarmIcon.heart, context.t('reproActBreeding'), group: RecordGroup.breeding, () => then(showBreedingForm(context, animal))),
    if (canRepro && repro != null && repro.applies.pregnancy)
      RecordAction('check', FarmIcon.pregnancy, context.t('reproActCheck'), group: RecordGroup.breeding, () => then(showPregnancyCheckForm(context, animal))),
    if (canRepro && repro != null && repro.applies.liveBirth && repro.pregnant)
      RecordAction('birth', FarmIcon.pregnancy, repro.birthTerm(arabic), group: RecordGroup.breeding, () => then(showBirthForm(context, animal, repro))),
    if (canHerd) RecordAction('move', FarmIcon.location, context.t('twMoveLocation'), group: RecordGroup.herd, () => then(showMoveDialog(context, animal))),
    if (canHerd) RecordAction('group', FarmIcon.people, context.t('herdMove'), group: RecordGroup.herd, () => then(showMoveToGroupForm(context, animal))),
    // The label to tie to this animal's tag, for the scan-first round.
    RecordAction('label', FarmIcon.qr, context.t('qrLabel'), group: RecordGroup.herd, () => showQrLabels(context, labels: [
          QrLabel.forAnimal(animal, speciesName: context.read<LivestockProvider>().speciesName(animal.species, Localizations.localeOf(context).languageCode)),
        ])),
    if (canHerd) RecordAction('exit', FarmIcon.logout, context.t('exitAction'), accent: FarmColors.danger, group: RecordGroup.herd, () => then(showExitForm(context, animal))),
  ];
}

/// "Record for Bella": every action, grouped, as big tiles.
Future<void> showAnimalRecordSheet(BuildContext context, {required Animal animal, required List<RecordAction> actions}) {
  final groups = <RecordGroup, String>{
    RecordGroup.daily: context.t('twRecordDaily'),
    RecordGroup.health: context.t('twRecordHealth'),
    RecordGroup.breeding: context.t('twRecordBreeding'),
    RecordGroup.herd: context.t('twRecordHerd'),
  };
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    constraints: const BoxConstraints(maxWidth: kFarmModalMaxWidth),
    builder: (sheet) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(FarmSpacing.lg, 0, FarmSpacing.lg, FarmSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SectionHeading(eyebrow: animal.primaryId.isEmpty ? null : '#${animal.primaryId}', title: '${context.t('twRecordFor')} ${animal.name}'),
            for (final entry in groups.entries)
              if (actions.any((a) => a.group == entry.key)) ...[
                const SizedBox(height: FarmSpacing.md),
                Eyebrow(entry.value, color: FarmColors.muted),
                const SizedBox(height: FarmSpacing.sm),
                EqualGrid(
                  minTileWidth: 150,
                  spacing: FarmSpacing.sm,
                  children: [
                    for (final a in actions.where((a) => a.group == entry.key))
                      RecordTile(
                        icon: a.icon,
                        label: a.label,
                        accent: a.accent,
                        onTap: () {
                          Navigator.of(sheet).pop();
                          a.run();
                        },
                      ),
                  ],
                ),
              ],
          ],
        ),
      ),
    ),
  );
}

// ---------------------------------------------------------------- header

/// Photo, "SPECIES · TAG · PROFILE", the name, what the animal is now,
/// and the way to edit it or record something against it.
class TwinHeaderCard extends StatelessWidget {
  const TwinHeaderCard({super.key, required this.animal, required this.caps, this.onEdit, this.onRecord});
  final Animal animal;
  final CapabilitySet caps;
  final VoidCallback? onEdit;
  final VoidCallback? onRecord;

  @override
  Widget build(BuildContext context) {
    final livestock = context.watch<LivestockProvider>();
    final lang = Localizations.localeOf(context).languageCode;
    final speciesName = livestock.speciesName(animal.species, lang);
    final profile = livestock.profileLabel(animal.species, animal.managementProfile, lang);
    final pending = context.watch<SyncController>().isPending(animal.id);
    final eyebrow = [speciesName, if (animal.primaryId.isNotEmpty) '#${animal.primaryId}', if (profile.isNotEmpty) profile].join(' · ');
    final born = '${context.t('twBorn')} ${feedDate(animal.birthDate)}${animal.birthDateEstimated ? ' ~' : ''} (${animal.ageLabel})';
    final line = [if (animal.breed.isNotEmpty) animal.breed, born, if (animal.location.isNotEmpty) animal.location].join(' · ');

    final tags = Wrap(
      spacing: 6,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        animal.onFarm
            ? StatusPill(label: context.t('active'), level: FarmStatusLevel.good, dense: true)
            : StatusPill(label: context.t('exit_${animal.lifecycleStatus}'), level: FarmStatusLevel.neutral, dense: true),
        if (animal.onFarm) StatusPill(label: healthStatusLabel(context, animal.status), level: healthStatusLevel(animal.status), dense: true),
        TagChip(sexLabel(context, animal, caps, lang)),
        if (animal.groupName != null && animal.groupName!.isNotEmpty) TagChip(animal.groupName!),
        if (caps.has(Cap.pregnancy) && animal.pregnant)
          TagChip('${context.t('reproPregnantDay')} ${animal.pregnancyDays ?? '–'}', color: FarmColors.lilac),
        if (caps.has(Cap.lactation) && animal.lactating)
          TagChip('${context.t('reproInMilk')} ${animal.lactationCycle ?? 1}', color: FarmColors.milkBlue),
        if (animal.isUnderWithdrawal)
          StatusPill(label: '${context.t('twWithdrawalUntil')} ${feedDate(animal.underWithdrawalUntil!)}', level: FarmStatusLevel.alert, dense: true),
        if (pending) const PendingChip(),
      ],
    );

    final buttons = Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        if (onEdit != null)
          OutlinedButton.icon(onPressed: onEdit, icon: const Icon(Icons.edit_outlined, size: 18), label: Text(context.t('twEditProfile'))),
        if (onRecord != null)
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: FarmColors.cedarDark),
            onPressed: onRecord,
            icon: const Icon(Icons.add, size: 18),
            label: Text(context.t('twRecord')),
          ),
      ],
    );

    return Container(
      padding: const EdgeInsets.all(FarmSpacing.lg),
      decoration: BoxDecoration(color: FarmColors.card, borderRadius: FarmRadii.card, boxShadow: FarmShadows.card),
      child: LayoutBuilder(builder: (context, c) {
        final wide = c.maxWidth >= 640;
        final photoSize = wide ? 124.0 : 84.0;
        final photo = SizedBox(
          width: photoSize,
          height: photoSize,
          child: PhotoSlot(
            filePath: animal.photoPath,
            icon: FarmIconMap.species(livestock.speciesIcon(animal.species)),
            borderRadius: BorderRadius.circular(FarmRadii.sm),
          ),
        );
        final info = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Eyebrow(eyebrow),
            const SizedBox(height: 4),
            Text(animal.name, style: FarmTypography.display(size: wide ? 32 : 26), maxLines: 1, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 8),
            tags,
            const SizedBox(height: 8),
            Text(line, style: FarmTypography.textTheme.bodySmall),
          ],
        );
        if (wide) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              photo,
              const SizedBox(width: FarmSpacing.lg),
              Expanded(child: info),
              const SizedBox(width: FarmSpacing.md),
              buttons,
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [photo, const SizedBox(width: FarmSpacing.md), Expanded(child: info)]),
            const SizedBox(height: FarmSpacing.md),
            buttons,
          ],
        );
      }),
    );
  }
}

String healthStatusLabel(BuildContext context, AnimalHealthStatus status) => context.t(switch (status) {
      AnimalHealthStatus.healthy => 'healthy',
      AnimalHealthStatus.underObservation => 'underObservation',
      AnimalHealthStatus.underTreatment => 'underTreatment',
    });

FarmStatusLevel healthStatusLevel(AnimalHealthStatus status) => switch (status) {
      AnimalHealthStatus.healthy => FarmStatusLevel.good,
      AnimalHealthStatus.underObservation => FarmStatusLevel.watch,
      AnimalHealthStatus.underTreatment => FarmStatusLevel.alert,
    };

/// "Female · Cow", "Male · Stallion": the generic word, then what this
/// farm calls one of this species.
String sexLabel(BuildContext context, Animal animal, CapabilitySet caps, String lang) {
  final code = animal.sex.trim().toUpperCase();
  final base = switch (code) {
    'F' || 'FEMALE' => context.t('female'),
    'M' || 'MALE' => context.t('male'),
    _ => context.t('unknownSex'),
  };
  final term = switch (code) {
    'F' || 'FEMALE' => caps.term('female', lang),
    'M' || 'MALE' => caps.term('male', lang),
    _ => '',
  };
  return term.isEmpty || term.toLowerCase() == base.toLowerCase() ? base : '$base · $term';
}

// ---------------------------------------------------------------- KPIs

/// Milk, weight, pregnancy and activity — each with the line that says
/// what it is measured from. An animal that is not milked shows its health
/// score in the first slot; one that cannot be pregnant shows its stage.
class TwinKpiRow extends StatelessWidget {
  const TwinKpiRow({super.key, required this.animal, required this.caps, required this.twin, required this.repro});
  final Animal animal;
  final CapabilitySet caps;
  final Map<String, dynamic>? twin;
  final ReproSummary? repro;

  @override
  Widget build(BuildContext context) {
    final lang = Localizations.localeOf(context).languageCode;
    final milk = context.watch<ProductionProvider>().milkRecords.where((r) => r.animalId == animal.id);
    final weekAgo = DateTime.now().subtract(const Duration(days: 7));
    final milk7 = milk.where((r) => r.recordedAt.isAfter(weekAgo)).fold<double>(0, (s, r) => s + r.liters);

    final latest = twin?['latest_weight'];
    final latestKg = latest is Map ? (latest['weight_kg'] as num?)?.toDouble() : animal.weightKg;
    final latestAt = latest is Map ? DateTime.tryParse(latest['measured_at'] as String? ?? '') : null;

    final events = (twin?['recent_events'] as List<dynamic>? ?? const []).whereType<Map<String, dynamic>>();
    final monthAgo = DateTime.now().subtract(const Duration(days: 30));
    final recent = events.where((e) => (DateTime.tryParse(e['created_at'] as String? ?? '') ?? DateTime(2000)).isAfter(monthAgo)).length;
    // The twin carries the latest 20 events; a full page means "at least".
    final activity = recent >= 20 ? '20+' : '$recent';

    final stage = context.watch<LivestockProvider>().lifeStageLabel(animal.species, animal.lifeStage, lang);

    return EqualGrid(
      minTileWidth: 190,
      children: [
        if (caps.has(Cap.milkProduction))
          KpiCard(icon: FarmIcon.milkBottle, accent: FarmColors.milkBlue, label: context.t('twKpiMilk7'), value: milk7.toStringAsFixed(1), unit: 'L', caption: context.t('twKpiMilk7Cap'))
        else
          KpiCard(icon: FarmIcon.heart, label: context.t('healthScore'), value: '${animal.healthScore}', unit: '/ 100', caption: healthStatusLabel(context, animal.status)),
        KpiCard(
          icon: FarmIcon.scale,
          label: context.t('twKpiWeight'),
          value: latestKg == null ? '—' : _kg(latestKg),
          unit: latestKg == null ? null : 'kg',
          caption: latestKg == null ? context.t('twNotWeighed') : (latestAt != null ? feedDate(latestAt) : context.t('twFromProfile')),
        ),
        if (caps.has(Cap.pregnancy)) _pregnancyKpi(context) else KpiCard(icon: FarmIcon.calendar, label: context.t('lifeStage'), value: stage.isEmpty ? '—' : stage, caption: animal.ageLabel),
        KpiCard(icon: FarmIcon.chartLine, label: context.t('twKpiActivity'), value: twin == null ? '…' : activity, caption: context.t('twKpiActivityCap')),
      ],
    );
  }

  Widget _pregnancyKpi(BuildContext context) {
    final s = repro;
    final p = s?.pregnancy;
    if (s != null && s.pregnant && p != null) {
      return KpiCard(
        icon: FarmIcon.pregnancy,
        accent: FarmColors.lilac,
        label: context.t('twKpiPregnancy'),
        value: '${context.t('twDay')} ${p.daysPregnant ?? '–'}',
        caption: p.expectedDueDate == null ? context.t('reproPregnantDay').split('·').first.trim() : '${context.t('reproDue')} ${feedDate(p.expectedDueDate!)}${p.overdue ? ' · ${context.t('reproOverdue')}' : ''}',
        tint: p.overdue ? FarmColors.danger : null,
      );
    }
    final value = s == null
        ? (animal.pregnant ? '${context.t('twDay')} ${animal.pregnancyDays ?? '–'}' : '…')
        : s.awaitingCheck
            ? context.t('twKpiCheckDue')
            : context.t('reproOpen');
    final served = s?.lastBreeding?.occurredAt;
    return KpiCard(
      icon: FarmIcon.pregnancy,
      accent: FarmColors.lilac,
      label: context.t('twKpiPregnancy'),
      value: value,
      caption: s != null && s.awaitingCheck && served != null ? '${context.t('reproLastService')} ${feedDate(served)}' : context.t('twKpiPregnancyCap'),
    );
  }
}

String _kg(double kg) => kg >= 100 ? kg.toStringAsFixed(0) : kg.toStringAsFixed(1);

// ---------------------------------------------------------------- overview tab

class _OverviewTab extends StatelessWidget {
  const _OverviewTab({
    required this.animal,
    required this.caps,
    required this.twin,
    required this.loading,
    required this.error,
    required this.actions,
    required this.onRecordChanged,
    required this.onOpenTimeline,
  });
  final Animal animal;
  final CapabilitySet caps;
  final Map<String, dynamic>? twin;
  final bool loading;
  final String? error;
  final List<RecordAction> actions;
  final Future<void> Function() onRecordChanged;
  final VoidCallback onOpenTimeline;

  @override
  Widget build(BuildContext context) {
    // The four the prototype keeps under a thumb: milk, feeding, weight,
    // an observation — whichever of them this animal and person have.
    const quick = ['quick', 'milk', 'feed', 'weight', 'observe', 'administer'];
    final quickActions = [
      for (final id in quick)
        for (final a in actions)
          if (a.id == id) a,
    ].take(4).toList();

    final identity = _IdentityCard(animal: animal, caps: caps, onRecordChanged: onRecordChanged);
    final side = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _RecentEventsCard(twin: twin, loading: loading, error: error, onOpenTimeline: onOpenTimeline),
        const SizedBox(height: FarmSpacing.md),
        _RecommendationCard(twin: twin, loading: loading),
      ],
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(builder: (context, c) {
          if (c.maxWidth < 760) return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [identity, const SizedBox(height: FarmSpacing.md), side]);
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 5, child: identity),
              const SizedBox(width: FarmSpacing.md),
              Expanded(flex: 4, child: side),
            ],
          );
        }),
        if (quickActions.isNotEmpty) ...[
          const SizedBox(height: FarmSpacing.md),
          SectionCard(
            title: context.t('twQuickRecord'),
            child: EqualGrid(
              minTileWidth: 150,
              spacing: FarmSpacing.sm,
              children: [for (final a in quickActions) RecordTile(icon: a.icon, label: a.label, accent: a.accent, onTap: a.run)],
            ),
          ),
        ],
        const SizedBox(height: FarmSpacing.md),
        AnimalHerdSection(animal: animal, twin: twin, loading: loading, onChanged: onRecordChanged),
        if (caps.capabilities.isNotEmpty) ...[
          const SizedBox(height: FarmSpacing.md),
          SectionCard(title: context.t('tracked'), subtitle: context.t('twTrackedSub'), child: CapabilityChips(caps: caps)),
        ],
      ],
    );
  }
}

/// The identity table: who the animal is, where it is, how it came, and
/// every identifier it carries — the catalog names each, so this draws a
/// mare and a hen with the same code it draws a cow.
class _IdentityCard extends StatelessWidget {
  const _IdentityCard({required this.animal, required this.caps, required this.onRecordChanged});
  final Animal animal;
  final CapabilitySet caps;
  final Future<void> Function() onRecordChanged;

  @override
  Widget build(BuildContext context) {
    final livestock = context.watch<LivestockProvider>();
    final lang = Localizations.localeOf(context).languageCode;
    final canEdit = animal.onFarm && context.watch<AccessProvider>().can(FarmModule.animals, PermissionAction.edit);
    final stage = livestock.lifeStageLabel(animal.species, animal.lifeStage, lang);
    final profile = livestock.profileLabel(animal.species, animal.managementProfile, lang);
    final identifiers = animal.activeIdentifiers;
    final acquired = [
      if (animal.acquisitionDate != null) feedDate(animal.acquisitionDate!),
      if (animal.acquisitionSource != null && animal.acquisitionSource!.isNotEmpty) animal.acquisitionSource!,
    ].join(' · ');

    return SectionCard(
      title: context.t('twIdentityTitle'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FactRow(label: context.t('species'), value: livestock.speciesName(animal.species, lang)),
          if (animal.breed.isNotEmpty) FactRow(label: context.t('breed'), value: animal.breed),
          FactRow(label: context.t('sex'), value: sexLabel(context, animal, caps, lang)),
          FactRow(label: context.t('twBirthDate'), value: '${feedDate(animal.birthDate)}${animal.birthDateEstimated ? ' (${context.t('twEstimated')})' : ''} · ${animal.ageLabel}'),
          if (stage.isNotEmpty) FactRow(label: context.t('lifeStage'), value: stage),
          if (profile.isNotEmpty) FactRow(label: context.t('managementProfile'), value: profile),
          FactRow(label: context.t('twGroup'), value: animal.groupName ?? ''),
          FactRow(label: context.t('location'), value: animal.location),
          FactRow(
            label: context.t('twLifecycle'),
            value: animal.onFarm
                ? context.t('active')
                : '${context.t('exit_${animal.lifecycleStatus}')}${animal.exitedAt != null ? ' · ${feedDate(animal.exitedAt!)}' : ''}',
          ),
          if (acquired.isNotEmpty) FactRow(label: context.t('twAcquired'), value: acquired),
          if (animal.damTag != null && animal.damTag!.isNotEmpty) FactRow(label: context.t('herdDam'), value: animal.damTag!),
          if (animal.sireTag != null && animal.sireTag!.isNotEmpty) FactRow(label: context.t('herdSire'), value: animal.sireTag!),
          FactRow(label: context.t('healthScore'), value: '${animal.healthScore} / 100', valueColor: _scoreColor(animal.healthScore)),
          const SizedBox(height: FarmSpacing.md),
          Row(children: [
            Expanded(child: Eyebrow(context.t('identification'), color: FarmColors.muted)),
            if (canEdit)
              TextButton.icon(
                onPressed: () async {
                  final added = await showAddIdentifierDialog(context, animal: animal, caps: caps);
                  if (added) await onRecordChanged();
                },
                icon: const Icon(Icons.add, size: 16),
                label: Text(context.t('addIdentifier')),
              ),
          ]),
          if (identifiers.isEmpty) FactRow(label: context.t('noIdentifiers'), value: '—'),
          for (final i in identifiers)
            FactRow(
              label: i.isPrimary ? '${context.t('id_${i.type}')} ★' : context.t('id_${i.type}'),
              value: i.issuingAuthority == null || i.issuingAuthority!.isEmpty ? i.value : '${i.value} · ${i.issuingAuthority}',
              trailing: canEdit && !i.isPrimary
                  ? InkWell(
                      onTap: () => _retire(context, i),
                      child: Tooltip(message: context.t('retireIdentifier'), child: const Icon(Icons.remove_circle_outline, size: 16, color: FarmColors.muted)),
                    )
                  : null,
            ),
          FactRow(label: context.t('internalId'), value: animal.id, last: true),
        ],
      ),
    );
  }

  /// Retiring keeps the row (§4: "retire, never delete") — a replaced ear
  /// tag still finds the animal it was on.
  Future<void> _retire(BuildContext context, AnimalIdentifier identifier) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ctx.t('retireIdentifier')),
        content: Text('${ctx.t('id_${identifier.type}')} ${identifier.value}\n\n${ctx.t('retireIdentifierBody')}'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: Text(ctx.t('cancel'))),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: Text(ctx.t('retire'))),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final result = await context.read<LivestockProvider>().retireIdentifier(animal.id, identifier.id);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(result.success ? context.t('identifierRetired') : (result.error ?? context.t('couldNotSave')))),
    );
    if (result.success) await onRecordChanged();
  }
}

Color _scoreColor(int score) {
  if (score >= 80) return FarmColors.success;
  if (score >= 60) return FarmColors.warning;
  return FarmColors.danger;
}

class _RecentEventsCard extends StatelessWidget {
  const _RecentEventsCard({required this.twin, required this.loading, required this.error, required this.onOpenTimeline});
  final Map<String, dynamic>? twin;
  final bool loading;
  final String? error;
  final VoidCallback onOpenTimeline;

  @override
  Widget build(BuildContext context) {
    final events = (twin?['recent_events'] as List<dynamic>? ?? const []).whereType<Map<String, dynamic>>().take(5).toList();
    return SectionCard(
      title: context.t('twRecentEvents'),
      trailing: events.isEmpty ? null : context.t('twOpenTimeline'),
      onTrailingTap: events.isEmpty ? null : onOpenTimeline,
      child: twinLoadState(context, loading: loading, error: error) ??
          (events.isEmpty
              ? EmptyState(message: context.t('twNoEvents'), icon: FarmIcon.calendar, compact: true)
              : Column(children: [for (final e in events) TimelineRow(entry: TimelineEntry.fromEvent(context, e))])),
    );
  }
}

/// The open recommendation, with the line that keeps it what it is:
/// decision support, never a diagnosis or a prescription.
class _RecommendationCard extends StatelessWidget {
  const _RecommendationCard({required this.twin, required this.loading});
  final Map<String, dynamic>? twin;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final recs = (twin?['open_recommendations'] as List<dynamic>? ?? const []).whereType<Map<String, dynamic>>().toList();
    return SectionCard(
      title: context.t('aiRecommendation'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          twinLoadState(context, loading: loading, error: null) ??
              (recs.isEmpty
                  ? Text(context.t('twNoRecommendations'), style: FarmTypography.textTheme.bodySmall)
                  : Column(children: [for (final r in recs.take(3)) _RecommendationLine(rec: r)])),
          const SizedBox(height: FarmSpacing.sm),
          NoticeBanner(text: context.t('twAiCaveat')),
        ],
      ),
    );
  }
}

class _RecommendationLine extends StatelessWidget {
  const _RecommendationLine({required this.rec});
  final Map<String, dynamic> rec;

  @override
  Widget build(BuildContext context) {
    final confidence = ((rec['confidence'] as num?)?.toDouble() ?? 0) * 100;
    final priority = (rec['priority'] as String?) ?? 'medium';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text((rec['title'] as String?) ?? '', style: FarmTypography.textTheme.titleSmall),
            Text('${context.t('twPriority')}: ${context.t('priority_$priority')}', style: FarmTypography.textTheme.bodySmall),
          ]),
        ),
        StatusPill(label: '${confidence.round()}%', level: FarmStatusLevel.info, dense: true),
      ]),
    );
  }
}

/// Shared loading/error handling for the parts backed by the twin fetch;
/// null when the data is there to draw.
Widget? twinLoadState(BuildContext context, {required bool loading, required String? error}) {
  if (loading) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 16),
      child: Center(child: SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))),
    );
  }
  if (error != null) return NoticeBanner(text: error, tone: NoticeTone.danger);
  return null;
}

// ---------------------------------------------------------------- health tab

class _HealthTab extends StatelessWidget {
  const _HealthTab({required this.animal, required this.twin, required this.loading, required this.error, required this.actions});
  final Animal animal;
  final Map<String, dynamic>? twin;
  final bool loading;
  final String? error;
  final List<RecordAction> actions;

  @override
  Widget build(BuildContext context) {
    final healthActions = [for (final a in actions) if (a.id == 'observe' || a.group == RecordGroup.health) a];
    final treatments = context.watch<AnimalsProvider>().treatmentsFor(animal.id);
    final cases = context.watch<HealthRecordsProvider>().casesFor(animal.id)
      ..sort((a, b) => (b.openedAt ?? DateTime(2000)).compareTo(a.openedAt ?? DateTime(2000)));
    final canOpenCase = animal.onFarm && context.watch<AccessProvider>().canCreate(FarmModule.animalHealth);
    final observations = (twin?['recent_observations'] as List<dynamic>? ?? const []).whereType<Map<String, dynamic>>().toList();

    final treatmentsCard = SectionCard(
      title: context.t('healthHistory'),
      child: treatments.isEmpty
          ? EmptyState(message: context.t('twNoTreatments'), icon: FarmIcon.stethoscope, compact: true)
          : Column(children: [for (final t in treatments) _TreatmentLine(treatment: t)]),
    );
    final observationsCard = SectionCard(
      title: context.t('twObservations'),
      child: twinLoadState(context, loading: loading, error: error) ??
          (observations.isEmpty
              ? EmptyState(message: context.t('twNoObservations'), icon: FarmIcon.eye, compact: true)
              : Column(children: [for (final o in observations.take(8)) _ObservationLine(obs: o)])),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeading(
          eyebrow: context.t('twTabHealth'),
          title: context.t('twHealthTitle'),
          subtitle: context.t('twHealthSub'),
          actions: [
            for (final a in healthActions)
              a.id == 'observe'
                  ? FilledButton.tonalIcon(onPressed: a.run, icon: AppIcon(a.icon, size: 16, color: FarmColors.cedarDark), label: Text(a.label))
                  : OutlinedButton.icon(onPressed: a.run, icon: AppIcon(a.icon, size: 16, color: a.accent), label: Text(a.label)),
          ],
        ),
        const SizedBox(height: FarmSpacing.md),
        // Doses and their lots, the withdrawal in force, standing
        // conditions, the latest weight, the open case, a live emergency.
        AnimalCareSection(twin: twin, loading: loading),
        const SizedBox(height: FarmSpacing.md),
        // Every case this animal has had, open first by date.
        SectionCard(
          title: context.t('hlTabCases'),
          trailing: canOpenCase ? context.t('hcOpenCase') : null,
          onTrailingTap: canOpenCase ? () => showOpenCaseForm(context, subject: (type: 'animal', id: animal.id, name: animal.name)) : null,
          child: cases.isEmpty
              ? EmptyState(message: context.t('hcNoCasesAnimal'), icon: FarmIcon.stethoscope, compact: true)
              : Column(children: [for (final c in cases) CaseRow(healthCase: c, showSubject: false)]),
        ),
        const SizedBox(height: FarmSpacing.md),
        LayoutBuilder(builder: (context, c) {
          if (c.maxWidth < 700) return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [treatmentsCard, const SizedBox(height: FarmSpacing.md), observationsCard]);
          return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: treatmentsCard),
            const SizedBox(width: FarmSpacing.md),
            Expanded(child: observationsCard),
          ]);
        }),
        const SizedBox(height: FarmSpacing.md),
        NoticeBanner(text: context.t('twWithdrawalCaveat')),
      ],
    );
  }
}

class _TreatmentLine extends StatelessWidget {
  const _TreatmentLine({required this.treatment});
  final TreatmentRecord treatment;

  @override
  Widget build(BuildContext context) {
    final resolved = treatment.status.toLowerCase() != 'active';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(resolved ? Icons.check_circle : Icons.radio_button_unchecked, size: 15, color: resolved ? FarmColors.success : FarmColors.warning),
          const SizedBox(width: 8),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(treatment.diagnosis ?? treatment.medication, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700), overflow: TextOverflow.ellipsis),
              if (treatment.diagnosis != null) Text(treatment.medication, style: FarmTypography.textTheme.bodySmall, overflow: TextOverflow.ellipsis),
            ]),
          ),
          StatusPill(label: context.t(resolved ? 'twTreatmentDone' : 'twTreatmentActive'), level: resolved ? FarmStatusLevel.good : FarmStatusLevel.watch, dense: true),
          const SizedBox(width: 8),
          Text(feedDate(treatment.startAt), style: const TextStyle(fontSize: 11, color: FarmColors.muted)),
        ],
      ),
    );
  }
}

class _ObservationLine extends StatelessWidget {
  const _ObservationLine({required this.obs});
  final Map<String, dynamic> obs;

  @override
  Widget build(BuildContext context) {
    final type = (obs['observation_type'] as String?) ?? 'observation';
    final severity = obs['severity'] as String?;
    final observedAt = DateTime.tryParse(obs['observed_at'] as String? ?? '');
    final color = switch (severity) {
      'severe' => FarmColors.danger,
      'moderate' => FarmColors.warning,
      _ => FarmColors.muted,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(Icons.circle, size: 8, color: color),
          const SizedBox(width: 8),
          Expanded(child: Text(observationLabel(context, type), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700), overflow: TextOverflow.ellipsis)),
          if (severity != null) ...[
            Text(context.t('sev${severity[0].toUpperCase()}${severity.substring(1)}'), style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w700)),
            const SizedBox(width: 8),
          ],
          Text(observedAt == null ? '—' : feedDate(observedAt), style: const TextStyle(fontSize: 11, color: FarmColors.muted)),
        ],
      ),
    );
  }
}
