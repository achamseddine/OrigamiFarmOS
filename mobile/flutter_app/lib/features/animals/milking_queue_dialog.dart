import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/util/number_input.dart';
import '../../core/widgets/status_pill.dart';
import '../../domain/entities/animal.dart';
import '../../domain/entities/livestock.dart';
import '../../providers/animals_provider.dart';
import '../../providers/livestock_provider.dart';
import 'quick_round.dart';

/// The manager gives each cow her number in the milking line (v0.8.2):
/// the order the cows come in. The milking queue, the quick entry and the
/// manual milk entry follow it; a number typed in opens her cow.
///
/// Listed: every animal on the farm that is milked — those in milk, and a
/// dry one still holding a number (she keeps it for her next lactation,
/// and it cannot be given to another cow until it is taken from her).
/// The server checks the numbers again (PUT /animals/milking-queue).
Future<bool> showMilkingQueueDialog(BuildContext context) async {
  final saved = await showDialog<bool>(context: context, builder: (_) => const _MilkingQueueDialog());
  return saved == true;
}

class _MilkingQueueDialog extends StatefulWidget {
  const _MilkingQueueDialog();

  @override
  State<_MilkingQueueDialog> createState() => _MilkingQueueDialogState();
}

class _MilkingQueueDialogState extends State<_MilkingQueueDialog> {
  late final List<Animal> _cows;
  final Map<String, TextEditingController> _fields = {};
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final livestock = context.read<LivestockProvider>();
    bool milked(Animal a) => livestock.resolve(species: a.species, sex: a.sex, lifeStage: a.lifeStage, managementProfile: a.managementProfile).has(Cap.milkProduction);
    _cows = [
      for (final a in context.read<AnimalsProvider>().animals)
        if (a.onFarm && milked(a) && (a.lactating || a.milkingQueueNumber != null)) a,
    ]..sort(milkingQueueOrder);
    for (final a in _cows) {
      _fields[a.id] = TextEditingController(text: a.milkingQueueNumber?.toString() ?? '')..addListener(_changed);
    }
  }

  void _changed() {
    if (mounted) setState(() => _error = null);
  }

  @override
  void dispose() {
    for (final c in _fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  /// Number the cows in milk 1, 2, 3… in the order listed.
  void _numberInOrder() {
    var n = 1;
    for (final a in _cows) {
      _fields[a.id]!.text = a.lactating ? '${n++}' : '';
    }
  }

  void _clearAll() {
    for (final c in _fields.values) {
      c.clear();
    }
  }

  /// The number typed for [id]: null for an empty field, -1 for a wrong one.
  int? _typed(String id) {
    final text = _fields[id]!.text.trim();
    if (text.isEmpty) return null;
    final n = parseLocalizedInt(text);
    return n == null || n < 1 || n > 999 ? -1 : n;
  }

  /// Numbers typed for more than one cow.
  Set<int> get _duplicates {
    final seen = <int>{};
    final twice = <int>{};
    for (final a in _cows) {
      final n = _typed(a.id);
      if (n != null && n > 0 && !seen.add(n)) twice.add(n);
    }
    return twice;
  }

  Future<void> _save() async {
    if (_cows.any((a) => _typed(a.id) == -1)) {
      setState(() => _error = context.t('mqBadNumber'));
      return;
    }
    if (_duplicates.isNotEmpty) {
      setState(() => _error = context.t('mqDuplicate').replaceAll('{n}', _duplicates.join(', ')));
      return;
    }
    final changes = <String, int?>{
      for (final a in _cows)
        if (_typed(a.id) != a.milkingQueueNumber) a.id: _typed(a.id),
    };
    if (changes.isEmpty) {
      Navigator.pop(context, false);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final result = await context.read<AnimalsProvider>().setMilkingQueue(changes);
    if (!mounted) return;
    if (result.success) {
      Navigator.pop(context, true);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.t(result.queued ? 'mqSavedOffline' : 'mqSaved'))));
    } else {
      setState(() {
        _saving = false;
        _error = result.error ?? context.t('couldNotSave');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final duplicates = _duplicates;
    final height = MediaQuery.sizeOf(context).height;
    return AlertDialog(
      title: Text(context.t('mqTitle')),
      content: SizedBox(
        width: 460,
        height: (height * 0.6).clamp(240.0, 560.0),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(context.t('mqIntro'), style: FarmTypography.textTheme.bodySmall),
          const SizedBox(height: FarmSpacing.sm),
          Wrap(spacing: 8, runSpacing: 8, children: [
            OutlinedButton.icon(
              key: const ValueKey('mq-number-in-order'),
              onPressed: _saving || _cows.isEmpty ? null : _numberInOrder,
              icon: const Icon(Icons.format_list_numbered, size: 18),
              label: Text(context.t('mqNumberInOrder')),
            ),
            TextButton(key: const ValueKey('mq-clear'), onPressed: _saving || _cows.isEmpty ? null : _clearAll, child: Text(context.t('mqClear'))),
          ]),
          const SizedBox(height: FarmSpacing.sm),
          const Divider(height: 1, color: FarmColors.border),
          Expanded(
            child: _cows.isEmpty
                ? Center(child: Text(context.t('queueEmptyMilking'), textAlign: TextAlign.center, style: FarmTypography.textTheme.bodySmall))
                : ListView.separated(
                    itemCount: _cows.length,
                    separatorBuilder: (_, __) => const Divider(height: 1, color: FarmColors.border),
                    itemBuilder: (context, i) {
                      final a = _cows[i];
                      final n = _typed(a.id);
                      final wrong = n == -1 || (n != null && duplicates.contains(n));
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Row(children: [
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text([if (a.tag != null && a.tag!.isNotEmpty) a.tag!, a.name].join(' · '), style: FarmTypography.textTheme.titleSmall),
                              if (!a.lactating) ...[
                                const SizedBox(height: 2),
                                StatusPill(label: context.t('mqDry'), level: FarmStatusLevel.neutral, dense: true),
                              ],
                            ]),
                          ),
                          const SizedBox(width: FarmSpacing.sm),
                          SizedBox(
                            width: 92,
                            child: TextField(
                              key: ValueKey('mq-number-${a.id}'),
                              controller: _fields[a.id],
                              enabled: !_saving,
                              keyboardType: TextInputType.number,
                              textAlign: TextAlign.center,
                              decoration: InputDecoration(
                                isDense: true,
                                hintText: '—',
                                prefixText: context.t('mqNo'),
                                errorText: wrong ? '' : null,
                                errorStyle: const TextStyle(height: 0, fontSize: 0),
                              ),
                            ),
                          ),
                        ]),
                      );
                    },
                  ),
          ),
          if (_error != null || duplicates.isNotEmpty) ...[
            const SizedBox(height: FarmSpacing.sm),
            Text(
              _error ?? context.t('mqDuplicate').replaceAll('{n}', duplicates.join(', ')),
              key: const ValueKey('mq-error'),
              style: const TextStyle(color: FarmColors.dangerInk, fontSize: 12.5),
            ),
          ],
        ]),
      ),
      actions: [
        TextButton(onPressed: _saving ? null : () => Navigator.pop(context, false), child: Text(context.t('cancel'))),
        FilledButton(
          key: const ValueKey('mq-save'),
          onPressed: _saving || _cows.isEmpty ? null : _save,
          child: _saving ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2)) : Text(context.t('save')),
        ),
      ],
    );
  }
}
