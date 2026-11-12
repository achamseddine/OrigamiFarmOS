import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/widgets/section_card.dart';
import '../../domain/entities/access.dart';
import '../../domain/entities/animal.dart';
import '../../domain/entities/livestock.dart';
import '../../domain/entities/reproduction.dart';
import '../../providers/access_provider.dart';
import '../../providers/herd_records_provider.dart';
import '../../providers/livestock_provider.dart';
import '../feed/feed_workspace_screen.dart' show feedDate;
import '../navigation/entity_router.dart';
import 'reproduction_forms.dart';

/// Herd & family on the animal's profile (LIVESTOCK-SCHEMA §5, §7, §10):
/// the groups it is in now, its recorded dam, sire and offspring, and its
/// effective-dated history — status, stage, profile and location. An
/// animal that left the farm says so at the top; its record stays.
class AnimalHerdSection extends StatelessWidget {
  const AnimalHerdSection({super.key, required this.animal, required this.twin, required this.loading, this.onChanged});

  final Animal animal;
  final Map<String, dynamic>? twin;
  final bool loading;
  final VoidCallback? onChanged;

  @override
  Widget build(BuildContext context) {
    final t = twin;
    final memberships = [for (final m in t?['groups'] as List<dynamic>? ?? const []) if (m is Map) GroupMembership.fromJson(m.cast<String, dynamic>())];
    final parentage = t?['relationships'] is Map ? Parentage.fromJson((t!['relationships'] as Map).cast<String, dynamic>()) : const Parentage();
    final history = [for (final h in t?['recent_history'] as List<dynamic>? ?? const []) if (h is Map) StateChange.fromJson(h.cast<String, dynamic>())];
    final access = context.watch<AccessProvider>();
    final canEdit = animal.onFarm && access.canEdit(FarmModule.animals);
    final groups = context.watch<LivestockProvider>().groups;

    return SectionCard(
      title: context.t('herdTitle'),
      child: loading
          ? const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Center(child: SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))),
            )
          : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (!animal.onFarm)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(bottom: FarmSpacing.sm),
                  padding: const EdgeInsets.all(FarmSpacing.sm),
                  decoration: BoxDecoration(color: FarmColors.tint(FarmColors.danger, 0.12), borderRadius: BorderRadius.circular(FarmRadii.sm)),
                  child: Text(
                    '${context.t('exitedBanner')} · ${context.t('exit_${animal.lifecycleStatus}')}${animal.exitedAt != null ? ' · ${feedDate(animal.exitedAt!)}' : ''}',
                    style: const TextStyle(color: FarmColors.danger, fontWeight: FontWeight.w700, fontSize: 12.5),
                  ),
                ),
              _label(context.t('herdGroups')),
              if (memberships.isEmpty)
                Text(context.t('herdNoGroup'), style: FarmTypography.textTheme.bodySmall?.copyWith(color: FarmColors.muted))
              else
                Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final m in memberships)
                    ActionChip(
                      avatar: const Icon(Icons.groups_outlined, size: 16),
                      label: Text('${m.groupName ?? ''}${m.validFrom != null ? ' · ${context.t('herdSince')} ${feedDate(m.validFrom!)}' : ''}'),
                      onPressed: () {
                        final group = groups.where((g) => g.id == m.groupId).firstOrNull;
                        if (group != null) showGroupSheet(context, group);
                      },
                    ),
                ]),
              if (canEdit)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Wrap(spacing: 8, children: [
                    TextButton.icon(
                      onPressed: () async {
                        if (await showMoveToGroupForm(context, animal)) onChanged?.call();
                      },
                      icon: const Icon(Icons.swap_horiz, size: 18),
                      label: Text(context.t('herdMove')),
                    ),
                    for (final m in memberships)
                      TextButton.icon(
                        onPressed: () async {
                          final result = await context.read<HerdRecordsProvider>().removeFromGroup(m.groupId, animal.id);
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                              content: Text(result.success ? (result.queued ? context.t('workingOffline') : context.t('saved')) : (result.error ?? context.t('couldNotSave')))));
                          if (result.success) {
                            await context.read<LivestockProvider>().load();
                            onChanged?.call();
                          }
                        },
                        icon: const Icon(Icons.logout, size: 18),
                        label: Text('${context.t('herdLeave')} · ${m.groupName ?? ''}'),
                      ),
                  ]),
                ),
              if (!parentage.isEmpty) ...[
                const SizedBox(height: FarmSpacing.sm),
                if (parentage.dam != null) _relative(context, context.t('herdDam'), parentage.dam!),
                if (parentage.sire != null) _relative(context, context.t('herdSire'), parentage.sire!),
                if (parentage.offspring.isNotEmpty) ...[
                  _label(context.t('herdOffspring')),
                  for (final o in parentage.offspring) _relative(context, '', o),
                ],
              ],
              if (history.isNotEmpty) ...[
                const SizedBox(height: FarmSpacing.sm),
                _label(context.t('herdHistory')),
                for (final h in history.take(8))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Text(
                      '${h.effectiveFrom != null ? feedDate(h.effectiveFrom!) : '—'} · ${context.t('state_${h.stateType}')}: ${_stateValue(context, h)}',
                      style: TextStyle(fontSize: 12, color: h.current ? FarmColors.ink : FarmColors.muted),
                    ),
                  ),
              ],
            ]),
    );
  }

  String _stateValue(BuildContext context, StateChange h) {
    final v = h.value;
    if (v == null) return '—';
    if (h.stateType == 'STATUS') return v == 'active' ? '✓' : context.t('exit_$v');
    return v.replaceAll('_', ' ');
  }

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Text(text.toUpperCase(), style: const TextStyle(fontSize: 11, color: FarmColors.muted, fontWeight: FontWeight.w700, letterSpacing: 0.4)),
      );

  Widget _relative(BuildContext context, String role, Relative r) => InkWell(
        onTap: () => EntityRouter.openEntityOrExplain(context, 'animal', r.animalId),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(children: [
            if (role.isNotEmpty) SizedBox(width: 60, child: Text(role, style: const TextStyle(fontSize: 12, color: FarmColors.muted, fontWeight: FontWeight.w600))),
            Expanded(
              child: Text('${r.name}${r.tag != null ? ' #${r.tag}' : ''}${r.active ? '' : ' · ${context.t('exitedBanner')}'}',
                  style: const TextStyle(fontSize: 12.5, color: FarmColors.cedar, fontWeight: FontWeight.w600)),
            ),
            const Icon(Icons.chevron_right, size: 16, color: FarmColors.muted),
          ]),
        ),
      );
}

/// A group's own record (LIVESTOCK-SCHEMA §6–§9): who is in it, its head-
/// count ledger and — for a poultry flock — the incubator.
Future<void> showGroupSheet(BuildContext context, AnimalGroup group) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => FractionallySizedBox(heightFactor: 0.85, child: GroupSheet(group: group)),
    );

class GroupSheet extends StatefulWidget {
  const GroupSheet({super.key, required this.group});
  final AnimalGroup group;

  @override
  State<GroupSheet> createState() => _GroupSheetState();
}

class _GroupSheetState extends State<GroupSheet> {
  late Future<(List<GroupMembership>, List<QuantityEvent>, List<IncubationBatch>)> _future = _load();

  Future<(List<GroupMembership>, List<QuantityEvent>, List<IncubationBatch>)> _load() async {
    final herd = context.read<HerdRecordsProvider>();
    final members = await herd.members(widget.group.id);
    final ledger = widget.group.countsMembers ? <QuantityEvent>[] : await herd.quantityEvents(widget.group.id);
    final incubations = _poultry ? (await herd.incubations()).where((b) => b.speciesCode == widget.group.species).toList() : <IncubationBatch>[];
    return (members, ledger, incubations);
  }

  bool get _poultry {
    final species = context.read<LivestockProvider>().species.where((s) => s.code == widget.group.species).firstOrNull;
    return species?.reproductionMode == 'oviparous';
  }

  void _reload() => setState(() => _future = _load());

  @override
  Widget build(BuildContext context) {
    final access = context.watch<AccessProvider>();
    final canCount = access.canCreate(FarmModule.animals) || access.canCreate(FarmModule.eggProduction);
    final group = context.watch<LivestockProvider>().groups.where((g) => g.id == widget.group.id).firstOrNull ?? widget.group;
    return FutureBuilder(
      future: _future,
      builder: (context, snap) {
        final data = snap.data;
        return ListView(padding: const EdgeInsets.fromLTRB(FarmSpacing.lg, 0, FarmSpacing.lg, FarmSpacing.lg), children: [
          Text('${group.name} · ${group.count}', style: FarmTypography.textTheme.titleMedium),
          Text(group.countsMembers ? context.t('groupCountsMembers') : context.t('groupLedger'), style: const TextStyle(color: FarmColors.muted, fontSize: 12.5)),
          const SizedBox(height: FarmSpacing.sm),
          if (snap.connectionState != ConnectionState.done)
            const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
          else if (data == null)
            Text(context.t('couldNotSave'))
          else ...[
            if (!group.countsMembers) ...[
              Row(children: [
                Expanded(child: Text(context.t('groupLedger'), style: const TextStyle(fontWeight: FontWeight.w700))),
                if (canCount)
                  FilledButton.tonalIcon(
                    onPressed: () async {
                      if (await showQuantityForm(context, group)) _reload();
                    },
                    icon: const Icon(Icons.exposure, size: 18),
                    label: Text(context.t('groupRecordCount')),
                  ),
              ]),
              for (final e in data.$2.take(12))
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text('${context.t('qty_${e.eventType}')} ${e.delta > 0 ? '+' : ''}${e.delta} → ${e.resulting}'),
                  subtitle: Text('${e.occurredAt != null ? feedDate(e.occurredAt!) : ''}${e.reason != null ? ' · ${e.reason}' : ''}'),
                ),
              const Divider(),
            ],
            Text(context.t('groupMembers'), style: const TextStyle(fontWeight: FontWeight.w700)),
            if (data.$1.isEmpty) Text(context.t('groupNoMembers'), style: const TextStyle(color: FarmColors.muted)),
            for (final m in data.$1)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text('${m.animalName ?? ''}${m.animalTag != null ? ' #${m.animalTag}' : ''}'),
                subtitle: m.validFrom != null ? Text('${context.t('herdSince')} ${feedDate(m.validFrom!)}') : null,
                trailing: const Icon(Icons.chevron_right),
                onTap: () => EntityRouter.openEntityOrExplain(context, 'animal', m.animalId),
              ),
            if (_poultry) ...[
              const Divider(),
              Row(children: [
                Expanded(child: Text(context.t('incubTitle'), style: const TextStyle(fontWeight: FontWeight.w700))),
                if (canCount)
                  TextButton.icon(
                    onPressed: () async {
                      if (await showStartIncubationForm(context, group)) _reload();
                    },
                    icon: const Icon(Icons.egg_outlined, size: 18),
                    label: Text(context.t('incubStart')),
                  ),
              ]),
              if (data.$3.isEmpty) Text(context.t('incubNone'), style: const TextStyle(color: FarmColors.muted)),
              for (final b in data.$3)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text('${b.code} · ${b.eggsSet} ${context.t('incubEggs').toLowerCase()}'),
                  subtitle: Text(b.incubating
                      ? '${context.t('incubHatchIn')} ${b.daysToHatch ?? '–'} ${context.t('incubDays')}'
                      : '${context.t('incubHatched')}: ${b.hatchedLive ?? 0}${b.hatchRate != null ? ' (${b.hatchRate}%)' : ''}'),
                  trailing: b.incubating && canCount
                      ? TextButton(
                          onPressed: () async {
                            if (await showHatchForm(context, b)) _reload();
                          },
                          child: Text(context.t('incubRecordHatch')),
                        )
                      : null,
                ),
            ],
          ],
        ]);
      },
    );
  }
}

/// Every group on the farm (or of one species), each opening its own sheet.
Future<void> showAllGroupsSheet(BuildContext context, {String? species}) => showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        final groups = [
          for (final g in context.watch<LivestockProvider>().groups)
            if (species == null || g.species == species) g,
        ];
        return ListView(padding: const EdgeInsets.fromLTRB(FarmSpacing.lg, 0, FarmSpacing.lg, FarmSpacing.lg), children: [
          Text(context.t('herdGroups'), style: FarmTypography.textTheme.titleMedium),
          if (groups.isEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Text(context.t('herdNoGroupsForSpecies'))),
          for (final g in groups)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.groups_outlined),
              title: Text(g.name),
              subtitle: Text(g.countsMembers ? context.t('groupCountsMembers') : context.t('groupLedger')),
              trailing: Text('${g.count}', style: FarmTypography.textTheme.titleMedium),
              onTap: () => showGroupSheet(context, g),
            ),
        ]);
      },
    );
