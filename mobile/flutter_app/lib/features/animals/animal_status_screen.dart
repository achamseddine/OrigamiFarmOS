import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/farm_icon_map.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/widgets/app_icon.dart';
import '../../core/widgets/kpi_card.dart';
import '../../core/widgets/photo_slot.dart';
import '../../core/widgets/section_card.dart';
import '../../core/widgets/status_pill.dart';
import '../../domain/entities/access.dart';
import '../../domain/entities/animal.dart';
import '../../providers/access_provider.dart';
import '../../providers/animals_provider.dart';
import '../../providers/livestock_provider.dart';
import '../../sync/sync_controller.dart';
import '../sync/sync_pill.dart';
import 'add_animal_form.dart';
import 'animal_digital_twin_screen.dart';
import '../../core/widgets/ux_blocks.dart';
import 'animal_herd_section.dart' show showAllGroupsSheet;
import 'animal_reproduction_section.dart' show ReproOverviewCard;
import 'animal_quick_entry_screen.dart';
import '../scan/qr_labels.dart';
import '../../core/widgets/hero_band.dart';

class AnimalStatusScreen extends StatefulWidget {
  const AnimalStatusScreen({super.key});

  @override
  State<AnimalStatusScreen> createState() => _AnimalStatusScreenState();
}

/// The registry's status filter. Health, reproduction and withdrawal are
/// all things a person scans the herd for; "left the farm" brings back
/// the animals that were sold or died, whose records are kept.
enum RegistryFilter { all, attention, healthy, observation, treatment, pregnant, inMilk, withdrawal, exited }

/// Whether [a] belongs under [filter] — kept apart from the widget so the
/// rule is tested on its own.
bool registryFilterMatches(RegistryFilter filter, Animal a) => switch (filter) {
      RegistryFilter.all => a.onFarm,
      RegistryFilter.attention => a.onFarm && a.status != AnimalHealthStatus.healthy,
      RegistryFilter.healthy => a.onFarm && a.status == AnimalHealthStatus.healthy,
      RegistryFilter.observation => a.onFarm && a.status == AnimalHealthStatus.underObservation,
      RegistryFilter.treatment => a.onFarm && a.status == AnimalHealthStatus.underTreatment,
      RegistryFilter.pregnant => a.onFarm && a.pregnant,
      RegistryFilter.inMilk => a.onFarm && a.lactating,
      RegistryFilter.withdrawal => a.onFarm && a.isUnderWithdrawal,
      RegistryFilter.exited => !a.onFarm,
    };

/// Name, tag, any identifier the animal ever carried, breed or group.
bool registrySearchMatches(Animal a, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  return a.matches(q) || a.breed.toLowerCase().contains(q) || (a.groupName ?? '').toLowerCase().contains(q);
}

class _AnimalStatusScreenState extends State<AnimalStatusScreen> {
  /// A species *code*; the chips come from the catalog, not an enum.
  String? _speciesFilter;
  RegistryFilter _filter = RegistryFilter.all;
  String _query = '';
  bool _loadingExited = false;

  Future<void> _selectFilter(RegistryFilter f) async {
    setState(() => _filter = f);
    if (f != RegistryFilter.exited) return;
    setState(() => _loadingExited = true);
    try {
      await context.read<AnimalsProvider>().loadExited();
    } catch (_) {
      // Offline with nothing cached: the empty state says there is nothing to show.
    }
    if (mounted) setState(() => _loadingExited = false);
  }

  @override
  Widget build(BuildContext context) {
    final herd = context.watch<AnimalsProvider>();
    final animals = herd.animals;
    final livestock = context.watch<LivestockProvider>();
    final lang = Localizations.localeOf(context).languageCode;
    final pool = _filter == RegistryFilter.exited ? herd.exited : animals;
    final matching = pool.where((a) {
      final speciesOk = _speciesFilter == null || a.species == _speciesFilter;
      return speciesOk && registryFilterMatches(_filter, a) && registrySearchMatches(a, _query);
    }).toList();
    // Whoever needs looking at comes first — under treatment, then under
    // observation, then everyone else — and within each group the order
    // the farm keeps them in. The grid is titled accordingly: it is not
    // "recent animals", it is the animals to go and see.
    final filtered = [
      for (final status in const [
        AnimalHealthStatus.underTreatment,
        AnimalHealthStatus.underObservation,
        AnimalHealthStatus.healthy,
      ])
        ...matching.where((a) => a.status == status),
    ];
    final onFarmCount = _filter == RegistryFilter.exited ? herd.exited.length : animals.length;

    final total = animals.length;
    final healthyCount = animals.where((a) => a.status == AnimalHealthStatus.healthy).length;
    final observationCount = animals.where((a) => a.status == AnimalHealthStatus.underObservation).length;
    final treatmentCount = animals.where((a) => a.status == AnimalHealthStatus.underTreatment).length;
    final femalesCount = animals.where((a) => a.sex.toUpperCase() == 'F').length;
    final pregnantCount = animals.where((a) => a.pregnant).length;
    final lactatingCount = animals.where((a) => a.lactating).length;
    String pctOf(int part, int whole) => whole == 0 ? '0.0' : (part / whole * 100).toStringAsFixed(1);

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          HeroBand(
            eyebrow: context.t('regEyebrow'),
            title: context.t('animalStatusTitle'),
            subtitle: context.t('animalStatusSubtitle'),
            icon: FarmIcon.cow,
            actions: [
              if ([
                FarmModule.milkProduction, FarmModule.feedNutrition,
                FarmModule.animalHealth, FarmModule.animals,
              ].any(context.watch<AccessProvider>().canCreate))
                HeroAction(
                  icon: FarmIcon.qr,
                  label: context.t('qrScanAnimal'),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const AnimalQuickEntryScreen(startWithCamera: true)),
                  ),
                ),
              // Labels for the animals the registry shows, to print once and
              // tie to each animal's tag.
              if (context.watch<AccessProvider>().canEdit(FarmModule.animals) && filtered.isNotEmpty)
                HeroAction(
                  icon: FarmIcon.qr,
                  label: context.t('qrPrintLabels'),
                  onPressed: () => showQrLabels(context, labels: [
                    for (final a in filtered) QrLabel.forAnimal(a, speciesName: livestock.speciesName(a.species, lang)),
                  ]),
                ),
              // Tech spec §12: the Animals screen must not be read-only for
              // whoever looks after the animals.
              if (context.watch<AccessProvider>().canCreate(FarmModule.animals))
                HeroAction(
                  primary: true,
                  icon: FarmIconMap.add,
                  label: context.t('addAnimal'),
                  onPressed: () => showAnimalForm(context),
                ),
              if (context.watch<AccessProvider>().can(FarmModule.animals, PermissionAction.export))
                HeroAction(
                  icon: FarmIconMap.download,
                  label: context.t('exportReport'),
                  // No report endpoint yet; say so rather than do nothing.
                  onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(context.t('reportsNotYet'))),
                  ),
                ),
            ],
          ),
          const SizedBox(height: FarmSpacing.md),
          LayoutBuilder(builder: (context, c) {
            final perRow = c.maxWidth > 1100 ? 6 : (c.maxWidth > 700 ? 3 : 2);
            final w = (c.maxWidth - FarmSpacing.md * (perRow - 1)) / perRow;
            final cards = [
              KpiCard(icon: FarmIcon.cow, label: context.t('totalAnimals'), value: '$total', caption: context.t('acrossSpecies')),
              KpiCard(icon: FarmIcon.heart, label: context.t('healthy'), value: '$healthyCount', caption: '${pctOf(healthyCount, total)}% ${context.t('ofTotal')}', tint: FarmColors.success),
              KpiCard(icon: FarmIcon.eye, label: context.t('underObservation'), value: '$observationCount', caption: '${pctOf(observationCount, total)}% ${context.t('ofTotal')}', tint: FarmColors.warning),
              KpiCard(icon: FarmIcon.medicine, label: context.t('underTreatment'), value: '$treatmentCount', caption: '${pctOf(treatmentCount, total)}% ${context.t('ofTotal')}', tint: FarmColors.danger),
              KpiCard(icon: FarmIcon.pregnancy, label: context.t('pregnant'), value: '$pregnantCount', caption: '${pctOf(pregnantCount, femalesCount)}% ${context.t('ofFemales')}'),
              KpiCard(icon: FarmIcon.milkBottle, label: context.t('lactating'), value: '$lactatingCount', caption: '${pctOf(lactatingCount, femalesCount)}% ${context.t('ofFemales')}'),
            ];
            return Wrap(
              spacing: FarmSpacing.md,
              runSpacing: FarmSpacing.md,
              children: [for (final card in cards) SizedBox(width: w, child: card)],
            );
          }),
          // Due dates, pregnancy checks waiting, the incubator.
          Padding(
            padding: const EdgeInsets.only(top: FarmSpacing.md),
            child: ReproOverviewCard(
              onOpenAnimal: (id) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => AnimalDigitalTwinScreen(animalId: id))),
            ),
          ),
          const SizedBox(height: FarmSpacing.md),
          LayoutBuilder(builder: (context, c) {
            final wide = c.maxWidth > kTabletBreakpoint;
            final herdGroups = _computeHerdGroups(animals, (code) => livestock.speciesName(code, lang));
            final herdCard = SectionCard(
              title: context.t('herdFlockSummary'),
              child: herdGroups.isEmpty
                  ? Text(context.t('noAnimalsYet'), style: FarmTypography.textTheme.bodySmall)
                  : Column(
                      children: [
                        for (final g in herdGroups) ...[
                          _HerdGroupRow(group: g, icon: FarmIconMap.species(livestock.speciesIcon(g['species'] as String))),
                          const Divider(height: 20, color: FarmColors.border),
                        ],
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton(onPressed: () => showAllGroupsSheet(context), child: Text(context.t('viewAllGroups'))),
                        ),
                      ],
                    ),
            );
            final animalsGrid = SectionCard(
              title: context.t('regTitle'),
              subtitle: context.t('regSubtitle'),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    key: const ValueKey('registry-search'),
                    onChanged: (v) => setState(() => _query = v),
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.search, size: 20),
                      hintText: context.t('regSearchHint'),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: FarmSpacing.sm),
                  _SpeciesFilterRow(
                    options: _speciesOptions(context, livestock, animals, lang),
                    selected: _speciesFilter,
                    onSelected: (s) => setState(() => _speciesFilter = s),
                  ),
                  const SizedBox(height: 8),
                  _StatusFilterRow(selected: _filter, onSelected: _selectFilter),
                  const SizedBox(height: FarmSpacing.sm),
                  Text(
                    '${filtered.length} ${context.t('regOf')} $onFarmCount ${context.t(_filter == RegistryFilter.exited ? 'regLeft' : 'regAnimals')}',
                    style: FarmTypography.textTheme.bodySmall,
                  ),
                  const SizedBox(height: FarmSpacing.sm),
                  if (_loadingExited)
                    const Padding(padding: EdgeInsets.all(FarmSpacing.lg), child: Center(child: CircularProgressIndicator()))
                  else if (filtered.isEmpty)
                    EmptyState(
                      icon: FarmIcon.cow,
                      message: animals.isEmpty ? context.t('noAnimalsYet') : context.t('nothingMatchesFilters'),
                      detail: animals.isEmpty ? null : context.t('regClearHint'),
                    )
                  else
                    EqualGrid(
                      minTileWidth: 300,
                      maxColumns: 3,
                      spacing: FarmSpacing.sm,
                      children: [
                        for (final animal in filtered)
                          RegistryCard(
                            animal: animal,
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute(builder: (_) => AnimalDigitalTwinScreen(animalId: animal.id)),
                            ),
                          ),
                      ],
                    ),
                ],
              ),
            );
            if (!wide) {
              return Column(children: [animalsGrid, const SizedBox(height: FarmSpacing.md), herdCard]);
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 7, child: animalsGrid),
                const SizedBox(width: FarmSpacing.md),
                Expanded(flex: 3, child: herdCard),
              ],
            );
          }),
        ],
      ),
    );
  }
}

/// The species chips: the catalog's order, limited to species this farm
/// actually keeps, plus any code the catalog does not know (so no animal
/// is ever unfilterable). No hard-coded "Cows / Goats / Poultry" — a farm
/// that starts keeping camels gets a Camels chip the day the server lists
/// them.
List<(String, String?)> _speciesOptions(BuildContext context, LivestockProvider livestock, List<Animal> animals, String lang) {
  final present = {for (final a in animals) a.species};
  final ordered = [
    for (final s in livestock.species)
      if (present.contains(s.code)) s.code,
    for (final code in present)
      if (livestock.speciesByCode(code) == null) code,
  ];
  return [
    (context.t('allSpecies'), null),
    for (final code in ordered) (livestock.speciesName(code, lang), code),
  ];
}

/// Groups the real herd by [Animal.groupName] (falling back to the species
/// name for animals with no group assigned) — a client-side computation
/// over already-loaded [Animal]s, since the backend has no dedicated
/// herd-group rollup endpoint.
List<Map<String, Object>> _computeHerdGroups(List<Animal> animals, String Function(String code) speciesName) {
  final groups = <String, List<Animal>>{};
  for (final a in animals) {
    groups.putIfAbsent(a.groupName ?? speciesName(a.species), () => []).add(a);
  }
  final result = <Map<String, Object>>[
    for (final entry in groups.entries)
      {
        'name': entry.key,
        'species': entry.value.first.species,
        'speciesLabel': speciesName(entry.value.first.species),
        'count': entry.value.length,
        'healthy': entry.value.where((a) => a.status == AnimalHealthStatus.healthy).length,
        'attention': entry.value.where((a) => a.status != AnimalHealthStatus.healthy).length,
      },
  ];
  result.sort((a, b) => (b['count'] as int).compareTo(a['count'] as int));
  return result;
}

class _SpeciesFilterRow extends StatelessWidget {
  const _SpeciesFilterRow({required this.options, required this.selected, required this.onSelected});
  final List<(String, String?)> options;
  final String? selected;
  final ValueChanged<String?> onSelected;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final o in options) ...[
            _FilterChip(label: o.$1, selected: selected == o.$2, onTap: () => onSelected(o.$2)),
            const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }
}

class _StatusFilterRow extends StatelessWidget {
  const _StatusFilterRow({required this.selected, required this.onSelected});
  final RegistryFilter selected;
  final ValueChanged<RegistryFilter> onSelected;

  @override
  Widget build(BuildContext context) {
    final options = <(String, RegistryFilter)>[
      (context.t('regAllStatuses'), RegistryFilter.all),
      (context.t('regAttention'), RegistryFilter.attention),
      (context.t('healthy'), RegistryFilter.healthy),
      (context.t('underObservation'), RegistryFilter.observation),
      (context.t('underTreatment'), RegistryFilter.treatment),
      (context.t('pregnant'), RegistryFilter.pregnant),
      (context.t('lactating'), RegistryFilter.inMilk),
      (context.t('regWithdrawal'), RegistryFilter.withdrawal),
      (context.t('exitedBanner'), RegistryFilter.exited),
    ];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final o in options) ...[
            _FilterChip(label: o.$1, selected: selected == o.$2, onTap: () => onSelected(o.$2)),
            const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      // Fill carries selection; the outline is gone.
      color: selected ? FarmColors.cedar : FarmColors.sand,
      borderRadius: BorderRadius.circular(FarmRadii.pill),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(FarmRadii.pill),
        child: Container(
          constraints: const BoxConstraints(minHeight: 40),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              color: selected ? FarmColors.white : FarmColors.ink,
              fontWeight: FontWeight.w600,
              fontSize: 13,
            ),
          ),
        ),
      ),
    );
  }
}

class _HerdGroupRow extends StatelessWidget {
  const _HerdGroupRow({required this.group, required this.icon});
  final Map<String, Object> group;
  final FarmIcon icon;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 38,
          height: 38,
          decoration: const BoxDecoration(color: FarmColors.mist, shape: BoxShape.circle),
          child: Center(child: AppIcon(icon, size: 17, color: FarmColors.cedar)),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(group['name'] as String, style: FarmTypography.textTheme.titleSmall),
              Row(
                children: [
                  Text('${group['speciesLabel']}', style: FarmTypography.textTheme.bodySmall),
                  const SizedBox(width: 8),
                  Text('${context.t('healthy')} ${group['healthy']}',
                      style: const TextStyle(fontSize: 11, color: FarmColors.success, fontWeight: FontWeight.w700)),
                  const SizedBox(width: 8),
                  Text('${group['attention']}',
                      style: const TextStyle(fontSize: 11, color: FarmColors.warning, fontWeight: FontWeight.w700)),
                ],
              ),
            ],
          ),
        ),
        Text('${group['count']}', style: FarmTypography.textTheme.titleLarge),
      ],
    );
  }
}

/// One animal in the registry, the prototype's way: a photo tile, the tag
/// as an eyebrow, the name, what it is and where it belongs, then the
/// tags a person scans the herd for — health, pregnancy, milk, a
/// withdrawal in force, a record still waiting to sync.
class RegistryCard extends StatelessWidget {
  const RegistryCard({super.key, required this.animal, required this.onTap});
  final Animal animal;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final livestock = context.watch<LivestockProvider>();
    final lang = Localizations.localeOf(context).languageCode;
    final speciesName = livestock.speciesName(animal.species, lang);
    final caps = livestock.resolve(species: animal.species, sex: animal.sex, lifeStage: animal.lifeStage, managementProfile: animal.managementProfile);
    final pending = context.watch<SyncController>().isPending(animal.id);
    final what = [speciesName, if (animal.breed.isNotEmpty) animal.breed].join(' · ');
    final where = [sexLabel(context, animal, caps, lang), animal.groupName ?? animal.location].where((x) => x.isNotEmpty).join(' · ');

    return Material(
      color: FarmColors.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(FarmRadii.sm), side: const BorderSide(color: FarmColors.border)),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(FarmRadii.sm),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 64,
                height: 64,
                child: PhotoSlot(
                  filePath: animal.photoPath,
                  icon: FarmIconMap.species(livestock.speciesIcon(animal.species)),
                  borderRadius: BorderRadius.circular(FarmRadii.xs),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Eyebrow(animal.primaryId.isEmpty ? speciesName : '#${animal.primaryId}'),
                    Text(animal.name, style: FarmTypography.textTheme.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
                    Text(what, style: FarmTypography.textTheme.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                    if (where.isNotEmpty) Text(where, style: FarmTypography.textTheme.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      children: [
                        if (animal.onFarm)
                          StatusPill(label: healthStatusLabel(context, animal.status), level: healthStatusLevel(animal.status), dense: true)
                        else
                          StatusPill(label: context.t('exit_${animal.lifecycleStatus}'), level: FarmStatusLevel.neutral, dense: true),
                        if (animal.pregnant) TagChip(context.t('pregnant'), color: FarmColors.lilac),
                        if (animal.lactating) TagChip(context.t('lactating'), color: FarmColors.milkBlue),
                        if (animal.isUnderWithdrawal) TagChip(context.t('regWithdrawal'), color: FarmColors.danger),
                        if (pending) const PendingChip(),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
