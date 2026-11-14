import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../api/api_client.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/farm_icon_map.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/widgets/app_icon.dart';
import '../../core/widgets/section_card.dart';
import '../../core/widgets/status_pill.dart';
import '../../core/widgets/ux_blocks.dart';
import '../../domain/entities/access.dart';
import '../../domain/entities/health_case.dart';
import '../../providers/access_provider.dart';
import '../../providers/animals_provider.dart';
import '../../providers/health_records_provider.dart';
import '../../providers/livestock_provider.dart';
import '../animals/animal_digital_twin_screen.dart';
import '../animals/animal_status_screen.dart' show registrySearchMatches;
import '../feed/feed_workspace_screen.dart' show feedDate;

/// Health cases on the tablet (HEALTH-VETERINARY-SCHEMA): the row a case
/// is listed as, the sheet that shows all of it, and the forms that open,
/// set to monitoring and close one. Diagnoses and treatment plans are the
/// veterinarian's and are only shown here — the server takes them from a
/// diagnostic role, and the AI never writes one.

/// An animal or a group to record against.
typedef HealthSubject = ({String type, String id, String name});

/// What a case or a record is about, by name — the case list carries the
/// name the server knew; a case opened offline a moment ago does not, so
/// the herd list fills it in.
String subjectLabel(BuildContext context, String type, String id, {String? known}) {
  if (known != null && known.isNotEmpty) return known;
  if (type == 'animal') {
    final a = context.read<AnimalsProvider>().find(id);
    if (a != null) return a.primaryId.isEmpty ? a.name : '${a.name} #${a.primaryId}';
  }
  for (final g in context.read<LivestockProvider>().groups) {
    if (g.id == id) return g.name;
  }
  return id;
}

FarmStatusLevel caseStatusLevel(String status) => switch (status) {
      'open' => FarmStatusLevel.alert,
      'monitoring' => FarmStatusLevel.watch,
      _ => FarmStatusLevel.good,
    };

FarmStatusLevel severityLevel(String? s) => switch (s) {
      'critical' || 'high' => FarmStatusLevel.alert,
      'moderate' => FarmStatusLevel.watch,
      'low' => FarmStatusLevel.info,
      _ => FarmStatusLevel.neutral,
    };

/// A searchable list of the farm's animals (and groups, when asked):
/// "who is this about?" before any health record is opened.
Future<HealthSubject?> showSubjectPicker(BuildContext context, {required String title, bool includeGroups = false}) {
  return showDialog<HealthSubject>(context: context, builder: (_) => _SubjectPicker(title: title, includeGroups: includeGroups));
}

class _SubjectPicker extends StatefulWidget {
  const _SubjectPicker({required this.title, required this.includeGroups});
  final String title;
  final bool includeGroups;

  @override
  State<_SubjectPicker> createState() => _SubjectPickerState();
}

class _SubjectPickerState extends State<_SubjectPicker> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final livestock = context.watch<LivestockProvider>();
    final lang = Localizations.localeOf(context).languageCode;
    final animals = [for (final a in context.watch<AnimalsProvider>().animals) if (a.onFarm && registrySearchMatches(a, _query)) a];
    final q = _query.trim().toLowerCase();
    final groups = widget.includeGroups ? [for (final g in livestock.groups) if (q.isEmpty || g.name.toLowerCase().contains(q)) g] : const [];
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 460,
        height: 420,
        child: Column(children: [
          TextField(
            autofocus: true,
            decoration: InputDecoration(prefixIcon: const Icon(Icons.search, size: 20), hintText: context.t('regSearchHint'), isDense: true),
            onChanged: (v) => setState(() => _query = v),
          ),
          const SizedBox(height: FarmSpacing.sm),
          Expanded(
            child: animals.isEmpty && groups.isEmpty
                ? EmptyState(message: context.t('nothingMatchesFilters'), icon: FarmIcon.search, compact: true)
                : ListView(children: [
                    for (final a in animals)
                      ListTile(
                        dense: true,
                        leading: AppIcon(FarmIconMap.species(livestock.speciesIcon(a.species)), size: 18, color: FarmColors.cedar),
                        title: Text(a.primaryId.isEmpty ? a.name : '${a.name} #${a.primaryId}'),
                        subtitle: Text([livestock.speciesName(a.species, lang), if (a.groupName != null) a.groupName!].join(' · ')),
                        onTap: () => Navigator.pop(context, (type: 'animal', id: a.id, name: a.name)),
                      ),
                    for (final g in groups)
                      ListTile(
                        dense: true,
                        leading: const AppIcon(FarmIcon.people, size: 18, color: FarmColors.cedar),
                        title: Text(g.name),
                        subtitle: Text('${livestock.speciesName(g.species, lang)} · ${g.count}'),
                        onTap: () => Navigator.pop(context, (type: 'group', id: g.id, name: g.name)),
                      ),
                  ]),
          ),
        ]),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(context.t('cancel')))],
    );
  }
}

/// Open a case: the subject (picked here unless the caller knows it), how
/// serious it looks, the problem in the person's words, and notes. No
/// diagnosis field — that is the veterinarian's.
Future<bool> showOpenCaseForm(BuildContext context, {HealthSubject? subject}) async {
  final chosen = subject ?? await showSubjectPicker(context, title: context.t('hcOpenCase'), includeGroups: true);
  if (chosen == null || !context.mounted) return false;
  final ok = await showDialog<bool>(context: context, builder: (_) => _OpenCaseDialog(subject: chosen));
  return ok == true;
}

class _OpenCaseDialog extends StatefulWidget {
  const _OpenCaseDialog({required this.subject});
  final HealthSubject subject;

  @override
  State<_OpenCaseDialog> createState() => _OpenCaseDialogState();
}

class _OpenCaseDialogState extends State<_OpenCaseDialog> {
  String _severity = 'moderate';
  final _problem = TextEditingController();
  final _notes = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _problem.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    final result = await context.read<HealthRecordsProvider>().openCase(
          subjectType: widget.subject.type,
          subjectId: widget.subject.id,
          severity: _severity,
          problem: _problem.text,
          notes: _notes.text,
        );
    if (!mounted) return;
    _finish(context, result, onError: (e) => setState(() {
          _saving = false;
          _error = e;
        }));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('${context.t('hcOpenCase')} — ${widget.subject.name}'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            NoticeBanner(tone: NoticeTone.info, text: context.t('hcOpenNote')),
            const SizedBox(height: FarmSpacing.sm),
            DropdownButtonFormField<String>(
              isExpanded: true,
              initialValue: _severity,
              decoration: InputDecoration(labelText: context.t('hcSeverity')),
              items: [for (final s in HealthCaseCodes.severities) DropdownMenuItem(value: s, child: Text(context.t('hcSev_$s')))],
              onChanged: (v) => setState(() => _severity = v ?? _severity),
            ),
            const SizedBox(height: FarmSpacing.sm),
            TextField(controller: _problem, decoration: InputDecoration(labelText: context.t('hcProblem'), helperText: context.t('hcProblemHelp'))),
            const SizedBox(height: FarmSpacing.sm),
            TextField(controller: _notes, maxLines: 3, decoration: InputDecoration(labelText: context.t('notes'))),
            if (_error != null) ...[
              const SizedBox(height: FarmSpacing.sm),
              Text(_error!, style: const TextStyle(color: FarmColors.danger, fontSize: 12.5)),
            ],
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: _saving ? null : () => Navigator.pop(context, false), child: Text(context.t('cancel'))),
        FilledButton(onPressed: _saving ? null : _save, child: Text(context.t('hcOpenCase'))),
      ],
    );
  }
}

void _finish(BuildContext context, WriteResult result, {required ValueChanged<String> onError}) {
  if (result.success) {
    final messenger = ScaffoldMessenger.of(context);
    final text = result.queued ? context.t('workingOffline') : context.t('saved');
    Navigator.pop(context, true);
    messenger.showSnackBar(SnackBar(content: Text(text)));
  } else {
    onError(result.error ?? context.t('couldNotSave'));
  }
}

/// Close a case: how it ended is required (the server refuses a blank
/// outcome), resolved or simply closed.
Future<bool> showCloseCaseForm(BuildContext context, HealthCase c) async {
  final ok = await showDialog<bool>(context: context, builder: (_) => _CloseCaseDialog(healthCase: c));
  return ok == true;
}

class _CloseCaseDialog extends StatefulWidget {
  const _CloseCaseDialog({required this.healthCase});
  final HealthCase healthCase;

  @override
  State<_CloseCaseDialog> createState() => _CloseCaseDialogState();
}

class _CloseCaseDialogState extends State<_CloseCaseDialog> {
  final _outcome = TextEditingController();
  String _status = 'resolved';
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _outcome.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_outcome.text.trim().isEmpty) {
      setState(() => _error = context.t('hcOutcomeRequired'));
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final result = await context.read<HealthRecordsProvider>().closeCase(widget.healthCase.id, outcome: _outcome.text, status: _status);
    if (!mounted) return;
    _finish(context, result, onError: (e) => setState(() {
          _saving = false;
          _error = e;
        }));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('${context.t('hcCloseCase')} — ${widget.healthCase.caseCode}'),
      content: SizedBox(
        width: 420,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          TextField(controller: _outcome, autofocus: true, maxLines: 2, decoration: InputDecoration(labelText: context.t('hcOutcome'))),
          const SizedBox(height: FarmSpacing.sm),
          DropdownButtonFormField<String>(
            isExpanded: true,
            initialValue: _status,
            decoration: InputDecoration(labelText: context.t('hcStatus')),
            items: [for (final s in const ['resolved', 'closed']) DropdownMenuItem(value: s, child: Text(context.t('hcSt_$s')))],
            onChanged: (v) => setState(() => _status = v ?? _status),
          ),
          if (_error != null) ...[
            const SizedBox(height: FarmSpacing.sm),
            Text(_error!, style: const TextStyle(color: FarmColors.danger, fontSize: 12.5)),
          ],
        ]),
      ),
      actions: [
        TextButton(onPressed: _saving ? null : () => Navigator.pop(context, false), child: Text(context.t('cancel'))),
        FilledButton(onPressed: _saving ? null : _save, child: Text(context.t('hcCloseCase'))),
      ],
    );
  }
}

/// One case in a list: its number, who it is about, the problem, how
/// serious, where it stands, and when it was opened.
class CaseRow extends StatelessWidget {
  const CaseRow({super.key, required this.healthCase, this.showSubject = true});
  final HealthCase healthCase;
  final bool showSubject;

  @override
  Widget build(BuildContext context) {
    final c = healthCase;
    final title = [
      if (showSubject) subjectLabel(context, c.subjectType, c.subjectId, known: c.subjectName),
      problemLabel(context, c),
    ].join(' · ');
    final detail = [
      c.caseCode,
      if (c.openedAt != null) '${context.t('hcOpened')} ${feedDate(c.openedAt!)}',
      if (c.closedAt != null) '${context.t('hcClosed')} ${feedDate(c.closedAt!)}',
      if (c.responsibleName != null) c.responsibleName!,
    ].join(' · ');
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => showCaseSheet(context, c),
        borderRadius: BorderRadius.circular(FarmRadii.sm),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
          decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: FarmColors.border))),
          child: Row(children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(color: FarmColors.tint(c.isOpen ? FarmColors.danger : FarmColors.success, 0.14), shape: BoxShape.circle),
              child: const Center(child: AppIcon(FarmIcon.stethoscope, size: 16, color: FarmColors.ink)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: FarmTypography.textTheme.titleSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                Text(detail, style: FarmTypography.textTheme.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
              ]),
            ),
            const SizedBox(width: 8),
            Wrap(spacing: 4, children: [
              if (c.severity != null) StatusPill(label: context.t('hcSev_${c.severity}'), level: severityLevel(c.severity), dense: true),
              StatusPill(label: context.t('hcSt_${c.status}'), level: caseStatusLevel(c.status), dense: true),
            ]),
          ]),
        ),
      ),
    );
  }
}

/// The problem a case is about: the vet's active diagnosis when there is
/// one, otherwise the problem as it was reported.
String problemLabel(BuildContext context, HealthCase c) {
  if (c.activeDiagnoses.isNotEmpty) return c.activeDiagnoses.first.replaceAll('_', ' ');
  if (c.problem != null && c.problem!.isNotEmpty) return c.problem!.replaceAll('_', ' ');
  // A case the emergency engine opened says so rather than "not stated".
  if (c.sourceType != null && c.sourceType != 'manual') return context.t('hcSrc_${c.sourceType}');
  return context.t('hcProblemUnstated');
}

Future<void> showCaseSheet(BuildContext context, HealthCase c) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      constraints: const BoxConstraints(maxWidth: kFarmModalMaxWidth),
      builder: (_) => FractionallySizedBox(heightFactor: 0.88, child: _CaseSheet(summary: c)),
    );

class _CaseSheet extends StatefulWidget {
  const _CaseSheet({required this.summary});
  final HealthCase summary;

  @override
  State<_CaseSheet> createState() => _CaseSheetState();
}

class _CaseSheetState extends State<_CaseSheet> {
  late Future<HealthCase> _detail = _fetch();

  Future<HealthCase> _fetch() => context.read<HealthRecordsProvider>().detail(widget.summary.id).catchError((_) => widget.summary);

  @override
  Widget build(BuildContext context) {
    final access = context.watch<AccessProvider>();
    final canEdit = access.canEdit(FarmModule.animalHealth);
    return FutureBuilder<HealthCase>(
      future: _detail,
      builder: (context, snap) {
        final c = snap.data ?? widget.summary;
        final subject = subjectLabel(context, c.subjectType, c.subjectId, known: c.subjectName);
        return ListView(padding: const EdgeInsets.fromLTRB(FarmSpacing.lg, 0, FarmSpacing.lg, FarmSpacing.lg), children: [
          SectionHeading(
            eyebrow: '${context.t('hcCase')} ${c.caseCode}',
            title: '$subject · ${problemLabel(context, c)}',
            actions: [
              if (c.subjectType == 'animal')
                OutlinedButton.icon(
                  onPressed: () {
                    Navigator.pop(context);
                    Navigator.of(context).push(MaterialPageRoute(builder: (_) => AnimalDigitalTwinScreen(animalId: c.subjectId, initialTab: TwinTab.health)));
                  },
                  icon: const Icon(Icons.open_in_new, size: 16),
                  label: Text(context.t('hcOpenAnimal')),
                ),
              if (canEdit && c.status == 'open')
                FilledButton.tonal(
                  onPressed: () async {
                    final result = await context.read<HealthRecordsProvider>().setStatus(c.id, 'monitoring');
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(result.success ? context.t('saved') : (result.error ?? context.t('couldNotSave')))));
                    setState(() => _detail = _fetch());
                  },
                  child: Text(context.t('hcSetMonitoring')),
                ),
              if (canEdit && c.isOpen)
                FilledButton(
                  onPressed: () async {
                    if (await showCloseCaseForm(context, c) && mounted) setState(() => _detail = _fetch());
                  },
                  child: Text(context.t('hcCloseCase')),
                ),
            ],
          ),
          const SizedBox(height: FarmSpacing.sm),
          Wrap(spacing: 6, runSpacing: 6, children: [
            StatusPill(label: context.t('hcSt_${c.status}'), level: caseStatusLevel(c.status)),
            if (c.severity != null) StatusPill(label: context.t('hcSev_${c.severity}'), level: severityLevel(c.severity)),
            if (c.pending) const TagChip('…'),
          ]),
          const SizedBox(height: FarmSpacing.md),
          SectionCard(
            child: Column(children: [
              FactRow(label: context.t('hcOpened'), value: c.openedAt == null ? '' : feedDate(c.openedAt!)),
              if (c.closedAt != null) FactRow(label: context.t('hcClosed'), value: feedDate(c.closedAt!)),
              FactRow(label: context.t('hcSource'), value: context.t('hcSrc_${c.sourceType ?? 'manual'}')),
              FactRow(label: context.t('hcResponsible'), value: c.responsibleName ?? ''),
              if (c.notes != null && c.notes!.isNotEmpty) FactRow(label: context.t('notes'), value: c.notes!),
              if (c.outcome != null) FactRow(label: context.t('hcOutcome'), value: c.outcome!, last: true),
            ]),
          ),
          const SizedBox(height: FarmSpacing.md),
          SectionCard(
            title: context.t('hcDiagnoses'),
            subtitle: context.t('hcDiagnosesSub'),
            child: snap.connectionState != ConnectionState.done
                ? const Padding(padding: EdgeInsets.all(FarmSpacing.md), child: Center(child: CircularProgressIndicator()))
                : c.diagnoses.isEmpty
                    ? EmptyState(message: context.t('hcNoDiagnosis'), icon: FarmIcon.stethoscope, compact: true)
                    : Column(children: [
                        for (final d in c.diagnoses)
                          FactRow(
                            label: [context.t('hcCert_${d.certainty}'), if (d.diagnosedByName != null) d.diagnosedByName!, if (d.diagnosedAt != null) feedDate(d.diagnosedAt!)].join(' · '),
                            value: d.status == 'superseded' ? '${d.label} (${context.t('hcSuperseded')})' : d.label,
                          ),
                      ]),
          ),
          const SizedBox(height: FarmSpacing.md),
          SectionCard(
            title: context.t('hcPlans'),
            child: c.plans.isEmpty
                ? EmptyState(message: context.t('hcNoPlan'), icon: FarmIcon.medicine, compact: true)
                : Column(children: [
                    for (final p in c.plans)
                      FactRow(
                        label: [context.t('hcPlan_${p.status}'), if (p.prescribedByName != null) p.prescribedByName!, if (p.prescribedAt != null) feedDate(p.prescribedAt!)].join(' · '),
                        value: p.instructions ?? '',
                      ),
                  ]),
          ),
          if (c.treatments.isNotEmpty) ...[
            const SizedBox(height: FarmSpacing.md),
            SectionCard(
              title: context.t('hcTreatments'),
              child: Column(children: [
                for (final t in c.treatments)
                  FactRow(
                    label: [
                      if (t['start_at'] is String) feedDate(DateTime.parse(t['start_at'] as String)),
                      if (t['route'] != null) '${t['route']}',
                    ].join(' · '),
                    value: [t['medication'], t['dose']].whereType<String>().join(' · '),
                  ),
              ]),
            ),
          ],
          const SizedBox(height: FarmSpacing.md),
          NoticeBanner(text: context.t('hcVetOnlyNote')),
        ]);
      },
    );
  }
}
