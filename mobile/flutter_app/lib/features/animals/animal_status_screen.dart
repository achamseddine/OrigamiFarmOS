import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/widgets/app_icon.dart';
import '../../core/widgets/kpi_card.dart';
import '../../core/widgets/photo_slot.dart';
import '../../core/widgets/section_card.dart';
import '../../core/widgets/status_pill.dart';
import '../../data/demo/demo_data.dart';
import '../../domain/entities/animal.dart';
import '../../providers/animals_provider.dart';
import 'animal_digital_twin_screen.dart';

class AnimalStatusScreen extends StatefulWidget {
  const AnimalStatusScreen({super.key});

  @override
  State<AnimalStatusScreen> createState() => _AnimalStatusScreenState();
}

class _AnimalStatusScreenState extends State<AnimalStatusScreen> {
  AnimalSpecies? _speciesFilter;
  AnimalHealthStatus? _healthFilter;

  @override
  Widget build(BuildContext context) {
    final animals = context.watch<AnimalsProvider>().animals;
    final filtered = animals.where((a) {
      final speciesOk = _speciesFilter == null || a.species == _speciesFilter;
      final healthOk = _healthFilter == null || a.status == _healthFilter;
      return speciesOk && healthOk;
    }).toList();

    final summary = DemoData.animalSummary;

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(context.t('animalStatusTitle'), style: FarmTypography.display(size: 28)),
                    const SizedBox(height: 2),
                    Text(context.t('animalStatusSubtitle'), style: FarmTypography.textTheme.bodyMedium),
                  ],
                ),
              ),
              OutlinedButton.icon(
                onPressed: () {},
                icon: const Icon(Icons.file_download_outlined, size: 18),
                label: Text(context.t('exportReport')),
              ),
            ],
          ),
          const SizedBox(height: FarmSpacing.md),
          _SpeciesFilterRow(
            selected: _speciesFilter,
            onSelected: (s) => setState(() => _speciesFilter = s),
          ),
          const SizedBox(height: 8),
          _HealthFilterRow(
            selected: _healthFilter,
            onSelected: (s) => setState(() => _healthFilter = s),
          ),
          const SizedBox(height: FarmSpacing.md),
          LayoutBuilder(builder: (context, c) {
            final perRow = c.maxWidth > 1100 ? 6 : (c.maxWidth > 700 ? 3 : 2);
            final w = (c.maxWidth - FarmSpacing.md * (perRow - 1)) / perRow;
            final cards = [
              KpiCard(icon: FarmIcon.cow, label: context.t('totalAnimals'), value: '${summary['total']}', caption: context.t('acrossSpecies')),
              KpiCard(icon: FarmIcon.heart, label: context.t('healthy'), value: '${summary['healthy']}', caption: '82.4% ${context.t('ofTotal')}', tint: FarmColors.success),
              KpiCard(icon: FarmIcon.eye, label: context.t('underObservation'), value: '${summary['underObservation']}', caption: '8.1% ${context.t('ofTotal')}', tint: FarmColors.warning),
              KpiCard(icon: FarmIcon.medicine, label: context.t('underTreatment'), value: '${summary['underTreatment']}', caption: '4.6% ${context.t('ofTotal')}', tint: FarmColors.danger),
              KpiCard(icon: FarmIcon.pregnancy, label: context.t('pregnant'), value: '${summary['pregnant']}', caption: '12.3% ${context.t('ofFemales')}'),
              KpiCard(icon: FarmIcon.milkBottle, label: context.t('lactating'), value: '${summary['lactating']}', caption: '33.1% ${context.t('ofFemales')}'),
            ];
            return Wrap(
              spacing: FarmSpacing.md,
              runSpacing: FarmSpacing.md,
              children: [for (final card in cards) SizedBox(width: w, child: card)],
            );
          }),
          const SizedBox(height: FarmSpacing.md),
          LayoutBuilder(builder: (context, c) {
            final wide = c.maxWidth > kTabletBreakpoint;
            final herdCard = SectionCard(
              title: context.t('herdFlockSummary'),
              child: Column(
                children: [
                  for (final g in DemoData.herdGroups) ...[
                    _HerdGroupRow(group: g),
                    const Divider(height: 20, color: FarmColors.border),
                  ],
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(onPressed: () {}, child: Text(context.t('viewAllGroups'))),
                  ),
                ],
              ),
            );
            final animalsGrid = SectionCard(
              title: context.t('recentAnimals'),
              child: LayoutBuilder(builder: (context, gridConstraints) {
                final cols = gridConstraints.maxWidth > 760 ? 4 : (gridConstraints.maxWidth > 420 ? 2 : 1);
                final cardW = (gridConstraints.maxWidth - FarmSpacing.sm * (cols - 1)) / cols;
                return Wrap(
                  spacing: FarmSpacing.sm,
                  runSpacing: FarmSpacing.sm,
                  children: [
                    for (final animal in filtered)
                      SizedBox(
                        width: cardW,
                        child: _AnimalCard(
                          animal: animal,
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(builder: (_) => AnimalDigitalTwinScreen(animalId: animal.id)),
                          ),
                        ),
                      ),
                  ],
                );
              }),
            );
            if (!wide) {
              return Column(children: [herdCard, const SizedBox(height: FarmSpacing.md), animalsGrid]);
            }
            return IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(flex: 4, child: herdCard),
                  const SizedBox(width: FarmSpacing.md),
                  Expanded(flex: 7, child: animalsGrid),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }
}

class _SpeciesFilterRow extends StatelessWidget {
  const _SpeciesFilterRow({required this.selected, required this.onSelected});
  final AnimalSpecies? selected;
  final ValueChanged<AnimalSpecies?> onSelected;

  @override
  Widget build(BuildContext context) {
    final options = <(String, AnimalSpecies?)>[
      (context.t('allSpecies'), null),
      (context.t('cows'), AnimalSpecies.cow),
      (context.t('goats'), AnimalSpecies.goat),
      (context.t('sheep'), AnimalSpecies.sheep),
      (context.t('horses'), AnimalSpecies.horse),
      (context.t('poultry'), AnimalSpecies.layerHen),
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

class _HealthFilterRow extends StatelessWidget {
  const _HealthFilterRow({required this.selected, required this.onSelected});
  final AnimalHealthStatus? selected;
  final ValueChanged<AnimalHealthStatus?> onSelected;

  @override
  Widget build(BuildContext context) {
    final options = <(String, AnimalHealthStatus?)>[
      (context.t('allHealth'), null),
      (context.t('healthy'), AnimalHealthStatus.healthy),
      (context.t('underObservation'), AnimalHealthStatus.underObservation),
      (context.t('underTreatment'), AnimalHealthStatus.underTreatment),
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
      color: selected ? FarmColors.cedar : FarmColors.card,
      borderRadius: BorderRadius.circular(FarmRadii.pill),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(FarmRadii.pill),
        child: Container(
          constraints: const BoxConstraints(minHeight: 40),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(FarmRadii.pill),
            border: Border.all(color: selected ? FarmColors.cedar : FarmColors.border),
          ),
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
  const _HerdGroupRow({required this.group});
  final Map<String, Object> group;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 38,
          height: 38,
          decoration: const BoxDecoration(color: FarmColors.mist, shape: BoxShape.circle),
          child: Center(child: AppIcon(_iconForSpecies(group['species'] as String), size: 17, color: FarmColors.cedar)),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(group['name'] as String, style: FarmTypography.textTheme.titleSmall),
              Row(
                children: [
                  Text('${group['species']}', style: FarmTypography.textTheme.bodySmall),
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

  FarmIcon _iconForSpecies(String s) {
    switch (s) {
      case 'Cow':
        return FarmIcon.cow;
      case 'Sheep':
        return FarmIcon.sheep;
      case 'Goat':
        return FarmIcon.goat;
      default:
        return FarmIcon.poultry;
    }
  }
}

class _AnimalCard extends StatelessWidget {
  const _AnimalCard({required this.animal, required this.onTap});
  final Animal animal;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final level = switch (animal.status) {
      AnimalHealthStatus.healthy => FarmStatusLevel.good,
      AnimalHealthStatus.underObservation => FarmStatusLevel.watch,
      AnimalHealthStatus.underTreatment => FarmStatusLevel.alert,
    };
    final statusLabel = switch (animal.status) {
      AnimalHealthStatus.healthy => context.t('healthy'),
      AnimalHealthStatus.underObservation => context.t('underObservation'),
      AnimalHealthStatus.underTreatment => context.t('underTreatment'),
    };
    return Material(
      color: FarmColors.card,
      borderRadius: FarmRadii.card,
      child: InkWell(
        onTap: onTap,
        borderRadius: FarmRadii.card,
        child: Container(
          decoration: BoxDecoration(borderRadius: FarmRadii.card, border: Border.all(color: FarmColors.border)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AspectRatio(
                aspectRatio: 1.5,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: PhotoSlot(
                        filePath: animal.photoPath,
                        icon: _iconForSpecies(animal.species),
                        borderRadius: const BorderRadius.vertical(top: Radius.circular(FarmRadii.md - 1)),
                      ),
                    ),
                    Positioned(
                      top: 8,
                      right: 8,
                      child: Container(
                        width: 30,
                        height: 30,
                        decoration: BoxDecoration(
                          color: FarmColors.tint(_scoreColor(animal.healthScore), 0.85),
                          shape: BoxShape.circle,
                          border: Border.all(color: FarmColors.card, width: 2),
                        ),
                        child: Center(
                          child: Text(
                            '${animal.healthScore}',
                            style: const TextStyle(color: FarmColors.white, fontWeight: FontWeight.w700, fontSize: 11),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${animal.name}  #${animal.tag}', style: FarmTypography.textTheme.titleSmall, overflow: TextOverflow.ellipsis),
                    Text('${animal.species.label} • ${animal.groupName ?? animal.location}',
                        style: FarmTypography.textTheme.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 4),
                    if (animal.milkTodayL != null)
                      Text('${animal.milkTodayL!.toStringAsFixed(1)} ${context.t('liters')}  ${context.t('milkToday')}',
                          style: const TextStyle(fontSize: 11, color: FarmColors.muted)),
                    if (animal.weightKg != null && animal.milkTodayL == null)
                      Text('${animal.weightKg!.toStringAsFixed(0)} kg', style: const TextStyle(fontSize: 11, color: FarmColors.muted)),
                    const SizedBox(height: 6),
                    StatusPill(label: statusLabel, level: level, dense: true),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Color _scoreColor(int score) {
    if (score >= 80) return FarmColors.success;
    if (score >= 60) return FarmColors.warning;
    return FarmColors.danger;
  }

  FarmIcon _iconForSpecies(AnimalSpecies s) {
    switch (s) {
      case AnimalSpecies.cow:
        return FarmIcon.cow;
      case AnimalSpecies.goat:
        return FarmIcon.goat;
      case AnimalSpecies.sheep:
        return FarmIcon.sheep;
      case AnimalSpecies.horse:
        return FarmIcon.horse;
      case AnimalSpecies.layerHen:
      case AnimalSpecies.turkey:
        return FarmIcon.poultry;
      case AnimalSpecies.duck:
        return FarmIcon.duck;
    }
  }
}
