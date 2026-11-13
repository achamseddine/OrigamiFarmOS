import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/typography.dart';
import '../../providers/livestock_provider.dart';

/// The membership rules a group can follow instead of being filled by hand
/// (flocks.membership_rule): its members follow the herd records.
const kMembershipRules = ['PREGNANT', 'NOT_PREGNANT', 'IN_MILK', 'DRY'];

/// A new group (LIVESTOCK-SCHEMA §7): a herd or pen the animals are moved
/// into by hand, or a group whose members follow the records — the
/// pregnant cows, the open (not pregnant) cows, the cows in milk, the dry
/// cows. A rule group overlaps the herd and the pen: a cow confirmed
/// pregnant joins "Pregnant cows" and stays in the Dairy Herd.
Future<bool> showNewGroupForm(BuildContext context, {String? species}) async =>
    await showDialog<bool>(context: context, builder: (_) => _NewGroupDialog(species: species)) ?? false;

/// Creates the farm's "Pregnant …" and "Open …" groups for a species in one
/// go; each starts with whoever already matches.
Future<String?> createPregnancyGroups(BuildContext context, String species) async {
  final livestock = context.read<LivestockProvider>();
  final lang = Localizations.localeOf(context).languageCode;
  final name = livestock.speciesName(species, lang);
  final pregnant = context.t('grpPregnantName').replaceAll('{species}', name);
  final open = context.t('grpOpenName').replaceAll('{species}', name);
  for (final (n, rule) in [(pregnant, 'PREGNANT'), (open, 'NOT_PREGNANT')]) {
    if (livestock.groups.any((g) => g.species == species && g.membershipRule == rule)) continue;
    final r = await livestock.createGroup({'name': n, 'species': species, 'group_type': 'cohort', 'membership_rule': rule});
    if (!r.success) return r.error;
  }
  return null;
}

class _NewGroupDialog extends StatefulWidget {
  const _NewGroupDialog({this.species});
  final String? species;

  @override
  State<_NewGroupDialog> createState() => _NewGroupDialogState();
}

class _NewGroupDialogState extends State<_NewGroupDialog> {
  final _name = TextEditingController();
  late String? _species = widget.species;
  String _type = 'herd';
  String? _rule;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_species == null || _name.text.trim().isEmpty) {
      setState(() => _error = context.t('grpNeedNameSpecies'));
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final result = await context.read<LivestockProvider>().createGroup({
      'name': _name.text.trim(),
      'species': _species,
      'group_type': _rule != null ? 'cohort' : _type,
      'membership_rule': ?_rule,
    });
    if (!mounted) return;
    if (result.success) {
      Navigator.pop(context, true);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(result.queued ? context.t('workingOffline') : context.t('grpCreated'))));
      return;
    }
    setState(() {
      _saving = false;
      _error = result.error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final livestock = context.watch<LivestockProvider>();
    final lang = Localizations.localeOf(context).languageCode;
    return AlertDialog(
      title: Text(context.t('grpNew')),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            TextField(controller: _name, autofocus: true, decoration: InputDecoration(labelText: context.t('grpName'))),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              initialValue: _species,
              isExpanded: true,
              decoration: InputDecoration(labelText: context.t('species')),
              items: [for (final s in livestock.species) DropdownMenuItem(value: s.code, child: Text(s.name(lang)))],
              onChanged: (v) => setState(() => _species = v),
            ),
            const SizedBox(height: 12),
            Text(context.t('grpMembers'), style: FarmTypography.textTheme.titleSmall),
            const SizedBox(height: 6),
            Wrap(spacing: 8, runSpacing: 8, children: [
              ChoiceChip(label: Text(context.t('grpByHand')), selected: _rule == null, onSelected: (_) => setState(() => _rule = null)),
              for (final r in kMembershipRules)
                ChoiceChip(label: Text(context.t('grpRule_$r')), selected: _rule == r, onSelected: (_) => setState(() => _rule = r)),
            ]),
            const SizedBox(height: 6),
            Text(context.t(_rule == null ? 'grpByHandHint' : 'grpRuleHint'), style: FarmTypography.textTheme.bodySmall),
            if (_rule == null) ...[
              const SizedBox(height: 10),
              Wrap(spacing: 8, children: [
                for (final t in const ['herd', 'pen', 'cohort'])
                  ChoiceChip(label: Text(context.t('grpType_$t')), selected: _type == t, onSelected: (_) => setState(() => _type = t)),
              ]),
            ],
            if (_error != null) ...[const SizedBox(height: 8), Text(_error!, style: const TextStyle(color: FarmColors.danger, fontSize: 12.5))],
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text(context.t('cancel'))),
        FilledButton(onPressed: _saving ? null : _submit, child: Text(context.t('grpCreate'))),
      ],
    );
  }
}
