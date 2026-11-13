import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../domain/entities/employee.dart';
import '../../domain/entities/responsibility.dart';
import '../../providers/animals_provider.dart';
import '../../providers/employees_provider.dart';
import '../../providers/livestock_provider.dart';
import '../../providers/production_provider.dart';

/// Settings > Employees > *Animals & duties*: what this person looks after
/// — a group (the Dairy Herd), one animal, every animal of a species, or a
/// field — and what they do there: milking and the milk record, feeding and
/// the feeding record, observations, health care, egg collection, crop care,
/// harvest. Saving one gives them the module access the duties need (shown
/// on their card as usual); ending one keeps it in their history.
Future<void> showResponsibilitiesDialog(BuildContext context, Employee employee) =>
    showDialog<void>(context: context, builder: (_) => _ResponsibilitiesDialog(employee: employee));

class _ResponsibilitiesDialog extends StatefulWidget {
  const _ResponsibilitiesDialog({required this.employee});
  final Employee employee;

  @override
  State<_ResponsibilitiesDialog> createState() => _ResponsibilitiesDialogState();
}

class _ResponsibilitiesDialogState extends State<_ResponsibilitiesDialog> {
  List<WorkResponsibility>? _current;
  String _scopeType = 'group';
  String? _scopeId;
  final Set<String> _duties = {'milking', 'feeding', 'observation'};
  final _notes = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _notes.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    try {
      final rows = await context.read<EmployeesProvider>().responsibilitiesOf(widget.employee.id);
      if (mounted) setState(() => _current = [for (final r in rows) if (r.active) r]);
    } catch (e) {
      if (mounted) setState(() => _current = const []);
    }
  }

  List<(String, String)> _scopeOptions(BuildContext context) {
    final lang = Localizations.localeOf(context).languageCode;
    return switch (_scopeType) {
      'group' => [for (final g in context.read<LivestockProvider>().groups) (g.id, g.name)],
      'animal' => [
          for (final a in context.read<AnimalsProvider>().animals)
            if (a.onFarm) (a.id, '${a.name}${a.primaryId.isNotEmpty ? ' #${a.primaryId}' : ''}'),
        ],
      'species' => [for (final s in context.read<LivestockProvider>().species) (s.code, s.name(lang))],
      _ => [for (final f in context.read<ProductionProvider>().fields) (f.id, f.name)],
    };
  }

  List<String> get _allowedDuties => _scopeType == 'field' ? kFieldDuties : kAnimalDuties;

  Future<void> _add() async {
    final duties = [for (final d in _allowedDuties) if (_duties.contains(d)) d];
    if (_scopeId == null || duties.isEmpty) {
      setState(() => _error = context.t('wrNeedScopeDuty'));
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final result = await context.read<EmployeesProvider>().assignResponsibility(widget.employee.id,
        scopeType: _scopeType, scopeId: _scopeId!, duties: duties, notes: _notes.text);
    if (!mounted) return;
    setState(() {
      _saving = false;
      _error = result.error;
    });
    if (result.success) {
      _scopeId = null;
      _notes.clear();
      await _reload();
    }
  }

  Future<void> _end(WorkResponsibility r) async {
    final result = await context.read<EmployeesProvider>().endResponsibility(widget.employee.id, r.id);
    if (!mounted) return;
    if (!result.success) {
      setState(() => _error = result.error);
      return;
    }
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final options = _scopeOptions(context);
    return AlertDialog(
      title: Text(context.t('wrTitle').replaceAll('{name}', widget.employee.name)),
      content: SizedBox(
        width: 620,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(context.t('wrSubtitle'), style: FarmTypography.textTheme.bodySmall),
            const SizedBox(height: FarmSpacing.md),
            if (_current == null)
              const Center(child: SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2)))
            else if (_current!.isEmpty)
              Text(context.t('wrNone'), style: FarmTypography.textTheme.bodySmall)
            else
              for (final r in _current!)
                Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.all(FarmSpacing.sm),
                  decoration: BoxDecoration(color: FarmColors.surfaceSoft, borderRadius: BorderRadius.circular(FarmRadii.sm)),
                  child: Row(children: [
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('${context.t('wrScope_${r.scopeType}')}: ${r.scopeName}', style: FarmTypography.textTheme.titleSmall),
                        Text([for (final d in r.duties) context.t('wrDuty_$d')].join(' · '), style: FarmTypography.textTheme.bodySmall),
                      ]),
                    ),
                    TextButton(onPressed: () => _end(r), child: Text(context.t('wrEnd'))),
                  ]),
                ),
            const Divider(height: 24, color: FarmColors.border),
            Text(context.t('wrAdd'), style: FarmTypography.textTheme.titleSmall),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final t in const ['group', 'animal', 'species', 'field'])
                ChoiceChip(
                  label: Text(context.t('wrScope_$t')),
                  selected: _scopeType == t,
                  onSelected: (_) => setState(() {
                    _scopeType = t;
                    _scopeId = null;
                    _duties
                      ..clear()
                      ..addAll(t == 'field' ? const ['crop_care'] : const ['milking', 'feeding', 'observation']);
                  }),
                ),
            ]),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              key: ValueKey('scope-$_scopeType'),
              initialValue: options.any((o) => o.$1 == _scopeId) ? _scopeId : null,
              isExpanded: true,
              decoration: InputDecoration(labelText: context.t('wrScope_$_scopeType')),
              items: [for (final (id, label) in options) DropdownMenuItem(value: id, child: Text(label, overflow: TextOverflow.ellipsis))],
              onChanged: (v) => setState(() => _scopeId = v),
            ),
            const SizedBox(height: 10),
            Text(context.t('wrDuties'), style: FarmTypography.textTheme.bodySmall),
            const SizedBox(height: 6),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final d in _allowedDuties)
                FilterChip(
                  label: Text(context.t('wrDuty_$d')),
                  selected: _duties.contains(d),
                  onSelected: (on) => setState(() => on ? _duties.add(d) : _duties.remove(d)),
                ),
            ]),
            const SizedBox(height: 10),
            TextField(controller: _notes, decoration: InputDecoration(labelText: context.t('notes'), hintText: context.t('optional'))),
            const SizedBox(height: 6),
            Text(context.t('wrAccessNote'), style: const TextStyle(fontSize: 12, color: FarmColors.muted)),
            if (_error != null) ...[const SizedBox(height: 8), Text(_error!, style: const TextStyle(color: FarmColors.danger, fontSize: 12.5))],
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(context.t('close'))),
        FilledButton(
          onPressed: _saving ? null : _add,
          child: _saving ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2)) : Text(context.t('wrSave')),
        ),
      ],
    );
  }
}
