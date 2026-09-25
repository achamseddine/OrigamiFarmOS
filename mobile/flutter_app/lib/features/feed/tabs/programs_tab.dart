import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/i18n/strings.dart';
import '../../../core/theme/colors.dart';
import '../../../core/theme/spacing.dart';
import '../../../core/theme/typography.dart';
import '../../../core/widgets/section_card.dart';
import '../../../core/widgets/status_pill.dart';
import '../../../domain/entities/access.dart';
import '../../../domain/entities/feeding.dart';
import '../../../providers/access_provider.dart';
import '../../../providers/feeding_provider.dart';
import '../../../providers/livestock_provider.dart';
import '../feed_workspace_screen.dart';

/// Feeding programs (§4, §5, §11, §14): the ration and the rules that say
/// who it is for, and a resolver panel — describe an animal, see which
/// programs its rules match and why. No species in code: the rules are
/// rows and the species list is the catalog's.
class ProgramsTab extends StatelessWidget {
  const ProgramsTab({super.key});

  @override
  Widget build(BuildContext context) {
    final feeding = context.watch<FeedingProvider>();
    final access = context.watch<AccessProvider>();
    final lang = Localizations.localeOf(context).languageCode;
    final canCreate = access.canCreate(FarmModule.feedNutrition);

    return FeedTabScaffold(children: [
      SectionCard(
        title: context.t('programs'),
        subtitle: context.t('programsSubtitle'),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (canCreate)
            FilledButton.icon(onPressed: () => _showProgramDialog(context), icon: const Icon(Icons.add, size: 16), label: Text(context.t('newProgram'))),
          if (feeding.programs.isEmpty) const FeedEmpty('noProgramsYet'),
          for (final p in feeding.programs) ...[const SizedBox(height: 10), _ProgramCard(program: p, lang: lang, canCreate: canCreate)],
        ]),
      ),
      const _ResolverPanel(),
    ]);
  }
}

class _ProgramCard extends StatelessWidget {
  const _ProgramCard({required this.program, required this.lang, required this.canCreate});
  final FeedingProgram program;
  final String lang;
  final bool canCreate;

  @override
  Widget build(BuildContext context) {
    final p = program;
    final v = p.active;
    final livestock = context.watch<LivestockProvider>();
    return Container(
      decoration: BoxDecoration(color: FarmColors.stone, borderRadius: BorderRadius.circular(FarmRadii.md)),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 14),
        childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
        title: Text(p.label(lang), style: FarmTypography.textTheme.titleSmall),
        subtitle: Text(
          [if (p.category != null) p.category!, if (v != null) 'v${v.version} · ${v.feedingsPerDay}× ${context.t('perDay')}', if (p.subjectsAssigned > 0) '${p.subjectsAssigned} ${context.t('subjectsOnProgram')}'].join(' · '),
          style: FarmTypography.textTheme.bodySmall,
        ),
        trailing: v == null ? StatusPill(label: context.t('version_draft'), level: FarmStatusLevel.watch, dense: true) : null,
        children: [
          if (p.description != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(p.description!, style: FarmTypography.textTheme.bodySmall)),
          if (v != null) ...[
            Text(context.t('ration'), style: const TextStyle(fontSize: 11, color: FarmColors.muted, fontWeight: FontWeight.w700, letterSpacing: 0.4)),
            for (final c in v.components)
              FeedKeyValue(c.productName ?? c.feedProductId, '${feedNumber(c.quantityPerHead)} ${c.unit} ${context.t(c.frequency == 'per_feeding' ? 'perFeeding' : 'perHeadPerDay')}${c.frequency == 'per_feeding' ? ' · ${feedNumber(c.dailyPerHead)} ${c.unit}/${context.t('day')}' : ''}'),
            const SizedBox(height: 8),
            Text(context.t('appliesTo'), style: const TextStyle(fontSize: 11, color: FarmColors.muted, fontWeight: FontWeight.w700, letterSpacing: 0.4)),
            if (v.rules.isEmpty) Text(context.t('manualAssignmentOnly'), style: FarmTypography.textTheme.bodySmall),
            for (final r in v.rules)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Wrap(spacing: 6, runSpacing: 4, children: [
                  for (final part in r.parts((code) => livestock.speciesName(code, lang)))
                    StatusPill(label: part, level: FarmStatusLevel.neutral, dense: true),
                  if (r.priority != 0) StatusPill(label: '${context.t('priority')} ${r.priority}', level: FarmStatusLevel.info, dense: true),
                ]),
              ),
          ],
          if (canCreate && v != null) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(onPressed: () => _showProgramDialog(context, program: p), icon: const Icon(Icons.add, size: 16), label: Text(context.t('newVersion'))),
          ],
        ],
      ),
    );
  }
}

// ------------------------------------------------------------ resolver
class _ResolverPanel extends StatefulWidget {
  const _ResolverPanel();
  @override
  State<_ResolverPanel> createState() => _ResolverPanelState();
}

class _ResolverPanelState extends State<_ResolverPanel> {
  String? _species;
  String _sex = 'F';
  String _stage = 'adult';
  String? _profile;
  String? _lactation;
  String? _reproduction;
  final _milk = TextEditingController();
  Map<String, dynamic>? _result;
  bool _busy = false;

  @override
  void dispose() {
    _milk.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    if (_species == null) return;
    setState(() => _busy = true);
    final milk = double.tryParse(_milk.text);
    final result = await context.read<FeedingProvider>().resolve({
      'species_code': _species, 'sex': _sex, 'life_stage': _stage, 'management_profile': _profile,
      'lactation_state': _lactation, 'reproductive_state': _reproduction,
      if (milk != null) 'production': {'milk_l_per_day': milk},
    });
    if (!mounted) return;
    setState(() {
      _result = result;
      _busy = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final livestock = context.watch<LivestockProvider>();
    final lang = Localizations.localeOf(context).languageCode;
    final config = _species == null ? null : livestock.configurationFor(_species!);
    final best = _result?['best'] as Map<String, dynamic>?;
    final eligible = (_result?['eligible'] as List<dynamic>? ?? const []).cast<Map<String, dynamic>>();
    final warnings = (_result?['warnings'] as List<dynamic>? ?? const []).cast<String>();
    return SectionCard(
      title: context.t('tryResolver'),
      subtitle: context.t('resolverIntro'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: 10, runSpacing: 10, children: [
          SizedBox(
            width: 170,
            child: DropdownButtonFormField<String>(
              value: _species,
              decoration: InputDecoration(labelText: context.t('species')),
              items: [for (final s in livestock.species) DropdownMenuItem(value: s.code, child: Text(s.name(lang)))],
              onChanged: (v) => setState(() {
                _species = v;
                _profile = null;
                _result = null;
              }),
            ),
          ),
          SizedBox(
            width: 130,
            child: DropdownButtonFormField<String>(
              value: _sex,
              decoration: InputDecoration(labelText: context.t('sex')),
              items: [DropdownMenuItem(value: 'F', child: Text(context.t('female'))), DropdownMenuItem(value: 'M', child: Text(context.t('male')))],
              onChanged: (v) => setState(() => _sex = v ?? _sex),
            ),
          ),
          if (config != null && config.lifeStages.isNotEmpty)
            SizedBox(
              width: 150,
              child: DropdownButtonFormField<String>(
                value: config.lifeStages.any((s) => s.code == _stage) ? _stage : config.lifeStages.first.code,
                decoration: InputDecoration(labelText: context.t('lifeStage')),
                items: [for (final s in config.lifeStages) DropdownMenuItem(value: s.code, child: Text(s.label(lang)))],
                onChanged: (v) => setState(() => _stage = v ?? _stage),
              ),
            ),
          if (config != null && config.managementProfiles.isNotEmpty)
            SizedBox(
              width: 160,
              child: DropdownButtonFormField<String?>(
                value: _profile,
                decoration: InputDecoration(labelText: context.t('managementProfile')),
                items: [const DropdownMenuItem<String?>(value: null, child: Text('—')), for (final p in config.managementProfiles) DropdownMenuItem<String?>(value: p.code, child: Text(p.label(lang)))],
                onChanged: (v) => setState(() => _profile = v),
              ),
            ),
          if (_sex == 'F') ...[
            SizedBox(
              width: 150,
              child: DropdownButtonFormField<String?>(
                value: _lactation,
                decoration: InputDecoration(labelText: context.t('lactationState')),
                items: [const DropdownMenuItem<String?>(value: null, child: Text('—')), DropdownMenuItem<String?>(value: 'lactating', child: Text(context.t('lactating'))), DropdownMenuItem<String?>(value: 'dry', child: Text(context.t('dry')))],
                onChanged: (v) => setState(() => _lactation = v),
              ),
            ),
            SizedBox(
              width: 150,
              child: DropdownButtonFormField<String?>(
                value: _reproduction,
                decoration: InputDecoration(labelText: context.t('reproductiveState')),
                items: [const DropdownMenuItem<String?>(value: null, child: Text('—')), DropdownMenuItem<String?>(value: 'pregnant', child: Text(context.t('pregnant'))), DropdownMenuItem<String?>(value: 'open', child: Text(context.t('openNotPregnant')))],
                onChanged: (v) => setState(() => _reproduction = v),
              ),
            ),
            SizedBox(width: 130, child: TextField(controller: _milk, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: context.t('milkPerDay')))),
          ],
          FilledButton(onPressed: _busy || _species == null ? null : _run, child: Text(context.t('resolve'))),
        ]),
        if (_result != null) ...[
          const SizedBox(height: FarmSpacing.md),
          if (best == null)
            Text(context.t('noProgramMatches'), style: FarmTypography.textTheme.bodyMedium)
          else ...[
            Text('${context.t('bestMatch')}: ${(lang == 'ar' ? best['program_name_ar'] : null) ?? best['program_name']}', style: FarmTypography.textTheme.titleSmall),
            Text(((best['reasons'] as List<dynamic>?) ?? const []).join(' · '), style: FarmTypography.textTheme.bodySmall),
          ],
          if (eligible.length > 1) ...[
            const SizedBox(height: 8),
            Text(context.t('eligiblePrograms'), style: const TextStyle(fontSize: 11, color: FarmColors.muted, fontWeight: FontWeight.w700, letterSpacing: 0.4)),
            for (final e in eligible.skip(1)) FeedKeyValue(e['program_name'] as String? ?? '', ((e['reasons'] as List<dynamic>?) ?? const []).join(' · ')),
          ],
          for (final w in warnings) Padding(padding: const EdgeInsets.only(top: 4), child: Text(w, style: const TextStyle(fontSize: 12, color: FarmColors.warningInk))),
        ],
      ]),
    );
  }
}

// --------------------------------------------------------------- dialog
Future<void> _showProgramDialog(BuildContext context, {FeedingProgram? program}) => showDialog<void>(context: context, builder: (_) => _ProgramDialog(program: program));

class _RationLine {
  _RationLine({this.productId, double? quantity, this.frequency = 'per_day'}) : quantity = TextEditingController(text: quantity == null ? '' : feedNumber(quantity));
  String? productId;
  final TextEditingController quantity;
  String frequency;
}

class _RuleLine {
  _RuleLine({this.species, this.sex, this.stage, this.profile, this.lactation, this.reproduction, double? milkMin, double? milkMax, int priority = 0})
      : milkMin = TextEditingController(text: milkMin == null ? '' : feedNumber(milkMin)),
        milkMax = TextEditingController(text: milkMax == null ? '' : feedNumber(milkMax)),
        priority = TextEditingController(text: '$priority');
  String? species;
  String? sex;
  String? stage;
  String? profile;
  String? lactation;
  String? reproduction;
  final TextEditingController milkMin;
  final TextEditingController milkMax;
  final TextEditingController priority;
}

class _ProgramDialog extends StatefulWidget {
  const _ProgramDialog({this.program});
  final FeedingProgram? program;
  @override
  State<_ProgramDialog> createState() => _ProgramDialogState();
}

class _ProgramDialogState extends State<_ProgramDialog> {
  late final _name = TextEditingController(text: widget.program?.name ?? '');
  late final _nameAr = TextEditingController(text: widget.program?.nameAr ?? '');
  late final _category = TextEditingController(text: widget.program?.category ?? '');
  late final _feedings = TextEditingController(text: '${widget.program?.active?.feedingsPerDay ?? 2}');
  final _notes = TextEditingController();
  late final List<_RationLine> _ration = [
    for (final c in widget.program?.active?.components ?? const <ProgramComponent>[]) _RationLine(productId: c.feedProductId, quantity: c.quantityPerHead, frequency: c.frequency),
    if (widget.program == null) _RationLine(),
  ];
  late final List<_RuleLine> _rules = [
    for (final r in widget.program?.active?.rules ?? const <ProgramRule>[])
      _RuleLine(species: r.speciesCode, sex: r.sex, stage: r.lifeStage, profile: r.managementProfile, lactation: r.lactationState, reproduction: r.reproductiveState, milkMin: r.productionMin, milkMax: r.productionMax, priority: r.priority),
    if (widget.program == null) _RuleLine(),
  ];
  bool _saving = false;
  String? _error;

  bool get _isVersion => widget.program != null;

  @override
  void dispose() {
    for (final c in [_name, _nameAr, _category, _feedings, _notes]) {
      c.dispose();
    }
    for (final l in _ration) {
      l.quantity.dispose();
    }
    for (final r in _rules) {
      r.milkMin.dispose();
      r.milkMax.dispose();
      r.priority.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    final components = [
      for (final l in _ration)
        if (l.productId != null && (double.tryParse(l.quantity.text) ?? 0) > 0)
          {'feed_product_id': l.productId, 'quantity_per_head': double.parse(l.quantity.text), 'frequency': l.frequency},
    ];
    if (components.isEmpty || (!_isVersion && _name.text.trim().isEmpty)) {
      setState(() => _error = context.t('programIncomplete'));
      return;
    }
    final rules = [
      for (final r in _rules)
        if (r.species != null || r.profile != null || r.lactation != null || r.stage != null || r.sex != null)
          {
            'species_code': r.species, 'sex': r.sex, 'life_stage': r.stage, 'management_profile': r.profile, 'lactation_state': r.lactation,
            'reproductive_state': r.reproduction, 'production_min': double.tryParse(r.milkMin.text), 'production_max': double.tryParse(r.milkMax.text),
            if (double.tryParse(r.milkMin.text) != null || double.tryParse(r.milkMax.text) != null) 'production_metric': 'milk_l_per_day',
            'priority': int.tryParse(r.priority.text) ?? 0,
          },
    ];
    setState(() {
      _saving = true;
      _error = null;
    });
    final feeding = context.read<FeedingProvider>();
    final body = {
      'feedings_per_day': int.tryParse(_feedings.text) ?? 2, 'components': components, 'rules': rules,
      if (_notes.text.trim().isNotEmpty) 'notes': _notes.text.trim(),
    };
    final result = _isVersion
        ? await feeding.addProgramVersion(widget.program!.id, body)
        : await feeding.createProgram({
            ...body, 'name': _name.text.trim(), if (_nameAr.text.trim().isNotEmpty) 'name_ar': _nameAr.text.trim(),
            if (_category.text.trim().isNotEmpty) 'category': _category.text.trim(),
          });
    if (!mounted) return;
    if (result.success) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.t(_isVersion ? 'versionCreated' : 'programCreated'))));
      return;
    }
    setState(() {
      _saving = false;
      _error = result.error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final feeding = context.watch<FeedingProvider>();
    final livestock = context.watch<LivestockProvider>();
    final lang = Localizations.localeOf(context).languageCode;
    final feeds = feeding.feedable;
    return AlertDialog(
      title: Text(_isVersion ? '${context.t('newVersion')} — ${widget.program!.name}' : context.t('newProgram')),
      content: SizedBox(
        width: 600,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (!_isVersion) ...[
              Row(children: [
                Expanded(child: TextField(controller: _name, autofocus: true, decoration: InputDecoration(labelText: context.t('feedingProgram')))),
                const SizedBox(width: 10),
                Expanded(child: TextField(controller: _nameAr, decoration: InputDecoration(labelText: '${context.t('feedingProgram')} (AR)'))),
              ]),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(child: TextField(controller: _category, decoration: InputDecoration(labelText: context.t('category')))),
                const SizedBox(width: 10),
                SizedBox(width: 140, child: TextField(controller: _feedings, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: context.t('feedingsPerDay')))),
              ]),
            ] else
              SizedBox(width: 160, child: TextField(controller: _feedings, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: context.t('feedingsPerDay')))),
            const SizedBox(height: 12),
            Text(context.t('ration'), style: const TextStyle(fontSize: 11, color: FarmColors.muted, fontWeight: FontWeight.w700, letterSpacing: 0.4)),
            for (var i = 0; i < _ration.length; i++)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(children: [
                  Expanded(
                    flex: 3,
                    child: DropdownButtonFormField<String>(
                      value: feeds.any((p) => p.id == _ration[i].productId) ? _ration[i].productId : null,
                      isExpanded: true,
                      decoration: InputDecoration(labelText: context.t('feedItem')),
                      items: [for (final p in feeds) DropdownMenuItem(value: p.id, child: Text(p.label(lang), overflow: TextOverflow.ellipsis))],
                      onChanged: (v) => setState(() => _ration[i].productId = v),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(flex: 2, child: TextField(controller: _ration[i].quantity, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: '${context.t('quantity')} / ${context.t('headCount').toLowerCase()}'))),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 2,
                    child: DropdownButtonFormField<String>(
                      value: _ration[i].frequency,
                      decoration: const InputDecoration(labelText: ' '),
                      items: [DropdownMenuItem(value: 'per_day', child: Text(context.t('perHeadPerDay'))), DropdownMenuItem(value: 'per_feeding', child: Text(context.t('perFeeding')))],
                      onChanged: (v) => setState(() => _ration[i].frequency = v ?? 'per_day'),
                    ),
                  ),
                  IconButton(onPressed: _ration.length == 1 ? null : () => setState(() => _ration.removeAt(i).quantity.dispose()), icon: const Icon(Icons.remove_circle_outline, size: 18, color: FarmColors.muted)),
                ]),
              ),
            TextButton.icon(onPressed: () => setState(() => _ration.add(_RationLine())), icon: const Icon(Icons.add, size: 16), label: Text(context.t('addFeedLine'))),
            const SizedBox(height: 6),
            Text(context.t('appliesTo'), style: const TextStyle(fontSize: 11, color: FarmColors.muted, fontWeight: FontWeight.w700, letterSpacing: 0.4)),
            for (var i = 0; i < _rules.length; i++) _ruleRow(context, i, livestock, lang),
            TextButton.icon(onPressed: () => setState(() => _rules.add(_RuleLine())), icon: const Icon(Icons.add, size: 16), label: Text(context.t('addRule'))),
            TextField(controller: _notes, decoration: InputDecoration(labelText: context.t('notes'))),
            if (_error != null) ...[const SizedBox(height: 8), Text(_error!, style: const TextStyle(color: FarmColors.danger, fontSize: 12.5))],
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(context.t('cancel'))),
        FilledButton(onPressed: _saving ? null : _submit, child: Text(context.t('save'))),
      ],
    );
  }

  Widget _ruleRow(BuildContext context, int i, LivestockProvider livestock, String lang) {
    final r = _rules[i];
    final config = r.species == null ? null : livestock.configurationFor(r.species!);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        SizedBox(
          width: 140,
          child: DropdownButtonFormField<String?>(
            value: r.species,
            decoration: InputDecoration(labelText: context.t('species')),
            items: [DropdownMenuItem<String?>(value: null, child: Text(context.t('anySpecies'))), for (final s in livestock.species) DropdownMenuItem<String?>(value: s.code, child: Text(s.name(lang)))],
            onChanged: (v) => setState(() {
              r.species = v;
              r.profile = null;
              r.stage = null;
            }),
          ),
        ),
        SizedBox(
          width: 100,
          child: DropdownButtonFormField<String?>(
            value: r.sex,
            decoration: InputDecoration(labelText: context.t('sex')),
            items: [const DropdownMenuItem<String?>(value: null, child: Text('—')), DropdownMenuItem<String?>(value: 'F', child: Text(context.t('female'))), DropdownMenuItem<String?>(value: 'M', child: Text(context.t('male')))],
            onChanged: (v) => setState(() => r.sex = v),
          ),
        ),
        SizedBox(
          width: 130,
          child: DropdownButtonFormField<String?>(
            value: config?.lifeStages.any((s) => s.code == r.stage) == true ? r.stage : null,
            decoration: InputDecoration(labelText: context.t('lifeStage')),
            items: [const DropdownMenuItem<String?>(value: null, child: Text('—')), for (final s in config?.lifeStages ?? const []) DropdownMenuItem<String?>(value: s.code, child: Text(s.label(lang)))],
            onChanged: (v) => setState(() => r.stage = v),
          ),
        ),
        SizedBox(
          width: 140,
          child: DropdownButtonFormField<String?>(
            value: config?.managementProfiles.any((p) => p.code == r.profile) == true ? r.profile : null,
            decoration: InputDecoration(labelText: context.t('managementProfile')),
            items: [const DropdownMenuItem<String?>(value: null, child: Text('—')), for (final p in config?.managementProfiles ?? const []) DropdownMenuItem<String?>(value: p.code, child: Text(p.label(lang)))],
            onChanged: (v) => setState(() => r.profile = v),
          ),
        ),
        SizedBox(
          width: 130,
          child: DropdownButtonFormField<String?>(
            value: r.lactation,
            decoration: InputDecoration(labelText: context.t('lactationState')),
            items: [const DropdownMenuItem<String?>(value: null, child: Text('—')), DropdownMenuItem<String?>(value: 'lactating', child: Text(context.t('lactating'))), DropdownMenuItem<String?>(value: 'dry', child: Text(context.t('dry')))],
            onChanged: (v) => setState(() => r.lactation = v),
          ),
        ),
        SizedBox(
          width: 130,
          child: DropdownButtonFormField<String?>(
            value: r.reproduction,
            decoration: InputDecoration(labelText: context.t('reproductiveState')),
            items: [const DropdownMenuItem<String?>(value: null, child: Text('—')), DropdownMenuItem<String?>(value: 'pregnant', child: Text(context.t('pregnant'))), DropdownMenuItem<String?>(value: 'open', child: Text(context.t('openNotPregnant')))],
            onChanged: (v) => setState(() => r.reproduction = v),
          ),
        ),
        SizedBox(width: 90, child: TextField(controller: r.milkMin, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: '${context.t('milkPerDay')} ≥'))),
        SizedBox(width: 90, child: TextField(controller: r.milkMax, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: '${context.t('milkPerDay')} ≤'))),
        SizedBox(width: 80, child: TextField(controller: r.priority, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: context.t('priority')))),
        IconButton(
          onPressed: _rules.length == 1 ? null : () => setState(() => _rules.removeAt(i)),
          icon: const Icon(Icons.remove_circle_outline, size: 18, color: FarmColors.muted),
        ),
      ]),
    );
  }
}
