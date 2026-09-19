import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../auth/session_controller.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/widgets/app_icon.dart';
import '../../domain/entities/access.dart';
import '../../domain/entities/animal.dart';
import '../../providers/access_provider.dart';
import '../../providers/animals_provider.dart';
import '../../providers/feed_provider.dart';
import '../../providers/production_provider.dart';
import '../../providers/tasks_provider.dart';
import '../animals/add_animal_form.dart';
import '../animals/animal_quick_actions.dart';
import '../produce/agriculture_forms.dart';
import '../../core/widgets/directional_icon.dart';

/// What the centre button on the bottom bar opens: "what do you want to
/// record?".
///
/// The alternative was sending it straight to one form — milking, say —
/// but that only serves whoever milks. A farm has a handful of things
/// worth writing down in the moment, they differ by who is holding the
/// tablet, and the button sits on every screen. So it asks, and the list
/// it asks with is built from this person's own modules: someone who only
/// looks after animals sees three choices, not eight, and someone with
/// view-only rights never sees the button at all.
///
/// Every entry here writes through an endpoint that already exists. None
/// of them is a placeholder.
class RecordAction {
  const RecordAction({
    required this.icon,
    required this.labelKey,
    required this.accent,
    required this.modules,
    required this.open,
  });

  final FarmIcon icon;
  final String labelKey;

  /// Tints the roundel behind the icon. The colour is the thing being
  /// recorded, not its urgency — milk is the pale blue it is everywhere
  /// else in the app, a treatment is the red of the medicine cabinet —
  /// so the grid can be read by shape and colour before the labels are.
  final Color accent;

  /// Holding *any* of these, with permission to create in it, shows the
  /// tile. The server re-checks on the write either way.
  final List<String> modules;

  final Future<void> Function(BuildContext context) open;
}

final List<RecordAction> _actions = [
  RecordAction(
    icon: FarmIcon.milkBottle,
    labelKey: 'milk',
    accent: FarmColors.milkBlue,
    modules: [FarmModule.milkProduction],
    open: _recordMilk,
  ),
  RecordAction(
    icon: FarmIcon.egg,
    labelKey: 'eggs',
    accent: FarmColors.gold,
    modules: [FarmModule.eggProduction],
    open: _recordEggs,
  ),
  RecordAction(
    icon: FarmIcon.harvestBasket,
    labelKey: 'harvest',
    accent: FarmColors.olive,
    modules: [FarmModule.produceHarvest, FarmModule.agriculture],
    open: (context) async => showHarvestForm(context),
  ),
  RecordAction(
    icon: FarmIcon.feedBag,
    labelKey: 'feed',
    accent: FarmColors.cedar2,
    modules: [FarmModule.feedNutrition, FarmModule.inventory],
    open: _recordFeed,
  ),
  RecordAction(
    icon: FarmIcon.eye,
    labelKey: 'observe',
    accent: FarmColors.muted,
    modules: [FarmModule.animalHealth, FarmModule.animals],
    open: _recordObservation,
  ),
  RecordAction(
    icon: FarmIcon.syringe,
    labelKey: 'treat',
    accent: FarmColors.danger,
    modules: [FarmModule.animalHealth],
    open: _recordTreatment,
  ),
  RecordAction(
    icon: FarmIcon.task,
    labelKey: 'newTask',
    accent: FarmColors.cedar,
    modules: [FarmModule.tasks],
    open: _newTask,
  ),
  RecordAction(
    icon: FarmIcon.cow,
    labelKey: 'addAnimal',
    accent: FarmColors.gold,
    modules: [FarmModule.animals],
    open: (context) async => showAnimalForm(context),
  ),
];

/// The tiles this person gets. Empty means the button should not be on
/// the bar in the first place — see [recordActionsFor].
List<RecordAction> recordActionsFor(AccessProvider access) => [
      for (final action in _actions)
        if (action.modules.any(access.canCreate)) action,
    ];

Future<void> showRecordSheet(BuildContext context) async {
  final actions = recordActionsFor(context.read<AccessProvider>());
  if (actions.isEmpty) return;

  final picked = await showModalBottomSheet<RecordAction>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (sheetContext) => _RecordSheet(actions: actions),
  );
  if (picked == null || !context.mounted) return;
  await picked.open(context);
}

class _RecordSheet extends StatelessWidget {
  const _RecordSheet({required this.actions});

  final List<RecordAction> actions;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final columns = width > kTabletBreakpoint ? 4 : 2;

    return SafeArea(
      top: false,
      child: Container(
        margin: const EdgeInsets.all(FarmSpacing.md),
        padding: const EdgeInsets.fromLTRB(
            FarmSpacing.md, FarmSpacing.sm, FarmSpacing.md, FarmSpacing.lg),
        decoration: BoxDecoration(
          color: FarmColors.card,
          borderRadius: BorderRadius.circular(FarmRadii.lg),
          boxShadow: FarmShadows.elevated,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 44,
                height: 4,
                margin: const EdgeInsets.only(bottom: FarmSpacing.md),
                decoration: BoxDecoration(
                  color: FarmColors.border,
                  borderRadius: BorderRadius.circular(FarmRadii.pill),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsetsDirectional.only(start: 4, bottom: FarmSpacing.md),
              child: Text(context.t('recordWhat'), style: FarmTypography.display(size: 24)),
            ),
            GridView.count(
              crossAxisCount: columns,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: FarmSpacing.md,
              crossAxisSpacing: FarmSpacing.md,
              childAspectRatio: 1.05,
              children: [
                for (final action in actions)
                  _RecordTile(
                    action: action,
                    onTap: () => Navigator.of(context).pop(action),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _RecordTile extends StatelessWidget {
  const _RecordTile({required this.action, required this.onTap});

  final RecordAction action;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: FarmColors.stone,
      borderRadius: BorderRadius.circular(FarmRadii.sm),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(FarmRadii.sm),
        child: Padding(
          padding: const EdgeInsets.all(FarmSpacing.sm),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 58,
                height: 58,
                decoration: BoxDecoration(
                  color: FarmColors.tint(action.accent, 0.16),
                  shape: BoxShape.circle,
                ),
                child: Center(child: AppIcon(action.icon, size: 28, color: action.accent)),
              ),
              const SizedBox(height: 12),
              Text(
                context.t(action.labelKey),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700, color: FarmColors.ink),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// The three actions that need an animal first. Each reuses the dialog the
// animal screen already opens, so a milking recorded from the bottom bar
// and one recorded from the herd list are the same write.
// ---------------------------------------------------------------------------

Future<void> _recordMilk(BuildContext context) async {
  final animal = await _pickAnimal(context);
  if (animal == null || !context.mounted) return;
  await showMilkDialog(context, animal);
}

Future<void> _recordObservation(BuildContext context) async {
  final animal = await _pickAnimal(context);
  if (animal == null || !context.mounted) return;
  await showObserveDialog(context, animal.id);
}

Future<void> _recordTreatment(BuildContext context) async {
  final animal = await _pickAnimal(context);
  if (animal == null || !context.mounted) return;
  await showTreatDialog(context, animal);
}

Future<Animal?> _pickAnimal(BuildContext context) {
  return showDialog<Animal>(
    context: context,
    builder: (context) => const _AnimalPickerDialog(),
  );
}

class _AnimalPickerDialog extends StatefulWidget {
  const _AnimalPickerDialog();

  @override
  State<_AnimalPickerDialog> createState() => _AnimalPickerDialogState();
}

class _AnimalPickerDialogState extends State<_AnimalPickerDialog> {
  final _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final all = context.watch<AnimalsProvider>().animals;
    final needle = _query.text.trim().toLowerCase();
    final matches = needle.isEmpty
        ? all
        : all
            .where((a) =>
                a.name.toLowerCase().contains(needle) || a.tag.toLowerCase().contains(needle))
            .toList();

    return AlertDialog(
      title: Text(context.t('chooseAnimal')),
      content: SizedBox(
        width: 420,
        height: 420,
        child: Column(
          children: [
            TextField(
              controller: _query,
              autofocus: true,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: context.t('searchNameOrTag'),
                prefixIcon: const Icon(Icons.search, size: 20),
              ),
            ),
            const SizedBox(height: FarmSpacing.sm),
            Expanded(
              child: matches.isEmpty
                  ? Center(
                      child: Text(
                        all.isEmpty ? context.t('noAnimalsYet') : context.t('noMatches'),
                        style: FarmTypography.textTheme.bodySmall,
                      ),
                    )
                  : ListView.separated(
                      itemCount: matches.length,
                      separatorBuilder: (_, __) => const Divider(height: 1, color: FarmColors.border),
                      itemBuilder: (context, i) {
                        final animal = matches[i];
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text('${animal.name}  #${animal.tag}',
                              style: FarmTypography.textTheme.titleSmall),
                          subtitle: Text(
                            '${animal.species.label} • ${animal.groupName ?? animal.location}',
                            style: FarmTypography.textTheme.bodySmall,
                          ),
                          trailing: const ForwardChevron(size: 18, color: FarmColors.muted),
                          onTap: () => Navigator.pop(context, animal),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(context.t('cancel'))),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Eggs, feed and tasks: no standalone form existed for these, only a screen
// you had to be on. They do now.
// ---------------------------------------------------------------------------

Future<void> _recordEggs(BuildContext context) {
  return showDialog<void>(context: context, builder: (_) => const _EggDialog());
}

class _EggDialog extends StatefulWidget {
  const _EggDialog();

  @override
  State<_EggDialog> createState() => _EggDialogState();
}

class _EggDialogState extends State<_EggDialog> {
  final _flock = TextEditingController();
  final _total = TextEditingController();
  final _sellable = TextEditingController();
  final _broken = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _flock.dispose();
    _total.dispose();
    _sellable.dispose();
    _broken.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // `flock_id` is free text on the server, not a record you pick from a
    // list — so the field is a text field, and whatever flocks this farm
    // has used before are offered as chips rather than guessed at.
    final known = <String>{
      for (final record in context.watch<ProductionProvider>().eggRecords) record.flockId,
    }.toList()
      ..sort();

    return AlertDialog(
      title: Text(context.t('eggs')),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _flock,
              decoration: InputDecoration(labelText: context.t('flock')),
            ),
            if (known.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final flock in known)
                    ActionChip(
                      label: Text(flock),
                      onPressed: () => setState(() => _flock.text = flock),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 12),
            TextField(
              controller: _total,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: context.t('totalEggs')),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _sellable,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(labelText: context.t('sellable')),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _broken,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(labelText: context.t('brokenEggs')),
                  ),
                ),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: const TextStyle(color: FarmColors.danger, fontSize: 12)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(context.t('cancel'))),
        FilledButton(
          onPressed: _saving ? null : _submit,
          child: _saving
              ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : Text(context.t('save')),
        ),
      ],
    );
  }

  Future<void> _submit() async {
    final flock = _flock.text.trim();
    final total = int.tryParse(_total.text.trim());
    if (flock.isEmpty) {
      setState(() => _error = context.t('flockRequired'));
      return;
    }
    if (total == null || total < 0) {
      setState(() => _error = context.t('valueMustBePositive'));
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final result = await context.read<ProductionProvider>().recordEggs(
          flockId: flock,
          totalEggs: total,
          sellableEggs: int.tryParse(_sellable.text.trim()) ?? 0,
          brokenEggs: int.tryParse(_broken.text.trim()) ?? 0,
        );
    if (!mounted) return;
    if (result.success) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.t('saved'))));
    } else {
      setState(() {
        _saving = false;
        _error = result.error;
      });
    }
  }
}

Future<void> _recordFeed(BuildContext context) {
  return showDialog<void>(context: context, builder: (_) => const _FeedOutDialog());
}

class _FeedOutDialog extends StatefulWidget {
  const _FeedOutDialog();

  @override
  State<_FeedOutDialog> createState() => _FeedOutDialogState();
}

class _FeedOutDialogState extends State<_FeedOutDialog> {
  String? _itemId;
  String _reason = 'feeding';
  final _quantity = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _quantity.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final items = context.watch<FeedProvider>().items;
    if (items.isEmpty) {
      return AlertDialog(
        title: Text(context.t('feed')),
        content: Text(context.t('noFeedItems'), style: FarmTypography.textTheme.bodyMedium),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(context.t('close'))),
        ],
      );
    }
    final selected = _itemId ?? items.first.id;

    return AlertDialog(
      title: Text(context.t('feed')),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DropdownButtonFormField<String>(
              value: selected,
              decoration: InputDecoration(labelText: context.t('feedItem')),
              items: [
                for (final item in items)
                  DropdownMenuItem(
                    value: item.id,
                    child: Text('${item.name} — ${item.currentQty.toStringAsFixed(0)} ${item.unit}'),
                  ),
              ],
              onChanged: (v) => setState(() => _itemId = v ?? selected),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _quantity,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(labelText: '${context.t('quantity')} (kg)'),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: _reason,
              decoration: InputDecoration(labelText: context.t('reason')),
              items: [
                DropdownMenuItem(value: 'feeding', child: Text(context.t('reasonFeeding'))),
                DropdownMenuItem(value: 'waste', child: Text(context.t('reasonWaste'))),
                DropdownMenuItem(value: 'transfer', child: Text(context.t('reasonTransfer'))),
              ],
              onChanged: (v) => setState(() => _reason = v ?? _reason),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: const TextStyle(color: FarmColors.danger, fontSize: 12)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(context.t('cancel'))),
        FilledButton(
          onPressed: _saving ? null : () => _submit(selected),
          child: _saving
              ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : Text(context.t('save')),
        ),
      ],
    );
  }

  Future<void> _submit(String itemId) async {
    final quantity = double.tryParse(_quantity.text.trim());
    if (quantity == null || quantity <= 0) {
      setState(() => _error = context.t('valueMustBePositive'));
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final result = await context.read<FeedProvider>().recordDistribution(
          itemId: itemId,
          quantityKg: quantity,
          reason: _reason,
        );
    if (!mounted) return;
    if (result.success) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.t('saved'))));
    } else {
      setState(() {
        _saving = false;
        _error = result.error;
      });
    }
  }
}

Future<void> _newTask(BuildContext context) {
  return showDialog<void>(context: context, builder: (_) => const _TaskDialog());
}

class _TaskDialog extends StatefulWidget {
  const _TaskDialog();

  @override
  State<_TaskDialog> createState() => _TaskDialogState();
}

class _TaskDialogState extends State<_TaskDialog> {
  final _title = TextEditingController();
  final _description = TextEditingController();
  String _priority = 'medium';
  DateTime? _dueAt;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(context.t('newTask')),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _title,
              autofocus: true,
              decoration: InputDecoration(labelText: context.t('taskTitle')),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _description,
              maxLines: 2,
              decoration: InputDecoration(labelText: context.t('notes')),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: _priority,
              decoration: InputDecoration(labelText: context.t('priority')),
              items: [
                DropdownMenuItem(value: 'high', child: Text(context.t('high'))),
                DropdownMenuItem(value: 'medium', child: Text(context.t('medium'))),
                DropdownMenuItem(value: 'low', child: Text(context.t('low'))),
              ],
              onChanged: (v) => setState(() => _priority = v ?? _priority),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Text(
                    _dueAt == null
                        ? context.t('noDueDate')
                        : '${_dueAt!.year}-${_dueAt!.month.toString().padLeft(2, '0')}-${_dueAt!.day.toString().padLeft(2, '0')}',
                    style: FarmTypography.textTheme.bodySmall,
                  ),
                ),
                TextButton(onPressed: _pickDue, child: Text(context.t('dueDate'))),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: const TextStyle(color: FarmColors.danger, fontSize: 12)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(context.t('cancel'))),
        FilledButton(
          onPressed: _saving ? null : _submit,
          child: _saving
              ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : Text(context.t('save')),
        ),
      ],
    );
  }

  Future<void> _pickDue() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _dueAt ?? now,
      firstDate: now.subtract(const Duration(days: 1)),
      lastDate: now.add(const Duration(days: 365)),
    );
    if (picked != null) setState(() => _dueAt = picked);
  }

  Future<void> _submit() async {
    final title = _title.text.trim();
    if (title.isEmpty) {
      setState(() => _error = context.t('taskTitleRequired'));
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    // A worker's task is their own; a manager creating one from here does
    // not get an assignee picker, because the moment this button is for is
    // "remember this", not "staff the week" — the Tasks screen assigns.
    final user = context.read<SessionController>().user;
    final result = await context.read<TasksProvider>().createTask(
          title: title,
          description: _description.text.trim().isEmpty ? null : _description.text.trim(),
          assignedTo: user?.isManager == true ? null : user?.id,
          dueAt: _dueAt,
          priority: _priority,
        );
    if (!mounted) return;
    if (result.success) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.t('saved'))));
    } else {
      setState(() {
        _saving = false;
        _error = result.error;
      });
    }
  }
}
