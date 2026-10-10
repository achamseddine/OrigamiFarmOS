import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/widgets/app_icon.dart';
import '../../core/widgets/kpi_card.dart';
import '../../core/widgets/section_card.dart';
import '../../core/widgets/status_pill.dart';
import '../../domain/entities/access.dart';
import '../../domain/entities/emergency.dart';
import '../../providers/access_provider.dart';
import '../../providers/animals_provider.dart';
import '../../providers/emergency_provider.dart';
import '../../providers/livestock_provider.dart';
import '../feed/feed_workspace_screen.dart' show FeedEmpty, feedDate, feedNumber;
import 'pharmacy_tab.dart' show askReason;

/// Emergency triage and veterinarian-approved protocols at the point of
/// care (database/CLINICAL-DECISION-SUPPORT-EMERGENCY-PROTOCOLS.md). The
/// person reports signs; the server matches current approved protocols,
/// checks the animal's facts, calculates the approved dose from the
/// approved rule, checks eligible stock and schedules reassessment — or
/// escalates. Every drug on this screen is shown next to the protocol
/// version and approval it came from, and the person confirms every
/// action. When the engine escalates, the screen says so in red.
class EmergencyTab extends StatelessWidget {
  const EmergencyTab({super.key});

  @override
  Widget build(BuildContext context) {
    final emergency = context.watch<EmergencyProvider>();
    final access = context.watch<AccessProvider>();
    final canAct = access.canCreate(FarmModule.animalHealth);
    final s = emergency.summary;

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      LayoutBuilder(builder: (context, c) {
        final perRow = c.maxWidth > 700 ? 4 : 2;
        final w = (c.maxWidth - FarmSpacing.md * (perRow - 1)) / perRow;
        final cards = [
          KpiCard(icon: FarmIcon.bell, label: context.t('emEscalated'), value: '${s.escalated}', accent: s.escalated > 0 ? FarmColors.danger : FarmColors.olive),
          KpiCard(icon: FarmIcon.check, label: context.t('emAwaitingConfirmation'), value: '${s.openAssessments}', accent: FarmColors.warningInk),
          KpiCard(icon: FarmIcon.heart, label: context.t('emRunsInProgress'), value: '${s.runsInProgress + s.awaitingReassessment}',
              caption: s.reassessmentsOverdue == 0 ? null : '${s.reassessmentsOverdue} ${context.t('emReassessmentOverdue').toLowerCase()}', accent: FarmColors.cedar2),
          KpiCard(icon: FarmIcon.medicine, label: context.t('emApprovedProtocols'), value: '${s.activeProtocols}', caption: '${s.protocols} ${context.t('emProtocols').toLowerCase()}', accent: FarmColors.gold),
        ];
        return Wrap(spacing: FarmSpacing.md, runSpacing: FarmSpacing.md, children: [for (final k in cards) SizedBox(width: w, child: k)]);
      }),
      const SizedBox(height: FarmSpacing.md),
      if (canAct)
        Wrap(spacing: 8, runSpacing: 8, children: [
          FilledButton.icon(onPressed: () => showAssessDialog(context), icon: const Icon(Icons.emergency_outlined, size: 18), label: Text(context.t('emAssess'))),
        ]),
      const SizedBox(height: FarmSpacing.md),
      SectionCard(
        title: context.t('emCasesTitle'),
        subtitle: context.t('emCasesSubtitle'),
        child: emergency.activeCases.isEmpty
            ? const FeedEmpty('emNoCases')
            : Column(children: [for (final a in emergency.activeCases) _CaseCard(assessment: a, run: emergency.runById(a.runId), canAct: canAct)]),
      ),
      const SizedBox(height: FarmSpacing.md),
      SectionCard(
        title: context.t('emProtocolsTitle'),
        subtitle: context.t('emProtocolsSubtitle'),
        child: emergency.protocols.isEmpty
            ? const FeedEmpty('emNoProtocols')
            : Column(children: [for (final p in emergency.protocols) _ProtocolRow(p)]),
      ),
    ]);
  }
}

FarmStatusLevel _triageLevel(String triage) => switch (triage) {
      'CRITICAL' || 'HIGH' => FarmStatusLevel.alert,
      'MODERATE' => FarmStatusLevel.watch,
      _ => FarmStatusLevel.neutral,
    };

void _toast(BuildContext context, ScaffoldMessengerState messenger, dynamic result, String done) {
  final text = result.success ? (result.queued ? context.t('workingOffline') : done) : (result.error ?? context.t('couldNotSave'));
  messenger.showSnackBar(SnackBar(content: Text(text)));
}

String _pct(double? v) => v == null ? '—' : '${(v * 100).round()}%';

/// One live case: the triage, the explanation, the matched protocol with
/// its evidence and warnings — or the escalation banner — and the run.
class _CaseCard extends StatelessWidget {
  const _CaseCard({required this.assessment, required this.run, required this.canAct});
  final EmergencyAssessment assessment;
  final EmergencyRun? run;
  final bool canAct;

  @override
  Widget build(BuildContext context) {
    final a = assessment;
    final match = a.selectedMatch;
    return Container(
      margin: const EdgeInsets.only(bottom: FarmSpacing.sm),
      padding: const EdgeInsets.all(FarmSpacing.md),
      decoration: BoxDecoration(
        color: a.isEscalated ? const Color(0xFFFDECEC) : FarmColors.white,
        borderRadius: BorderRadius.circular(FarmRadii.md),
        border: Border.all(color: a.isEscalated ? FarmColors.danger : FarmColors.mist, width: a.isEscalated ? 1.5 : 1),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(a.subjectName ?? a.subjectId, style: FarmTypography.textTheme.titleMedium)),
          StatusPill(label: context.t('emTriage_${a.triageLevel}'), level: _triageLevel(a.triageLevel), dense: true),
          const SizedBox(width: 6),
          StatusPill(label: context.t('emStatus_${a.status}'), level: a.isEscalated ? FarmStatusLevel.alert : (a.status == 'open' ? FarmStatusLevel.watch : FarmStatusLevel.info), dense: true),
        ]),
        const SizedBox(height: 2),
        Text(
          [
            if (a.startedAt != null) feedDate(a.startedAt!),
            context.t('emSource_${a.source}'),
            if (a.createdByName != null) a.createdByName!,
            if (a.confidence != null) '${context.t('perfConfidence')} ${_pct(a.confidence)}',
            ...a.observedSigns.where((s) => s['present'] != false).map((s) => s['value_numeric'] != null ? '${s['code']} ${s['value_numeric']}' : (s['value_text'] != null ? '${s['code']} ${s['value_text']}' : '${s['code']}')),
          ].join(' · '),
          style: FarmTypography.textTheme.bodySmall?.copyWith(color: FarmColors.muted),
        ),
        if (a.isEscalated) ...[
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(FarmSpacing.sm),
            decoration: BoxDecoration(color: FarmColors.danger, borderRadius: BorderRadius.circular(FarmRadii.sm)),
            child: Row(children: [
              const Icon(Icons.phone_in_talk, color: Colors.white, size: 20),
              const SizedBox(width: 8),
              Expanded(child: Text(context.t('emCallVet'), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700))),
            ]),
          ),
          const SizedBox(height: 6),
          for (final r in a.escalationReasons) Text('• $r', style: FarmTypography.textTheme.bodySmall),
        ],
        const SizedBox(height: 8),
        Text(a.explanation, style: FarmTypography.textTheme.bodySmall),
        if (match != null && !a.isEscalated) ...[
          const SizedBox(height: 8),
          _MatchBox(match: match),
        ],
        if (run != null) ...[const SizedBox(height: 8), _RunBox(run: run!, canAct: canAct)],
        if (canAct) ...[
          const SizedBox(height: 6),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            if (a.awaitingConfirmation && match != null && match.startable) FilledButton(onPressed: () => _start(context), child: Text(context.t('emStartProtocol'))),
            if (a.isEscalated || (a.status == 'open' && run == null)) ...[
              const SizedBox(width: 8),
              TextButton(onPressed: () => _close(context), child: Text(context.t('emCloseCase'))),
            ],
          ]),
        ],
      ]),
    );
  }

  Future<void> _start(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(context.t('emStartProtocol')),
        content: Text(context.t('emConfirmStart')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(context.t('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(context.t('emIConfirm'))),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final result = await context.read<EmergencyProvider>().startRun(assessment.id);
    if (!context.mounted) return;
    _toast(context, messenger, result, context.t('emProtocolStarted'));
  }

  Future<void> _close(BuildContext context) async {
    final outcome = await askReason(context, title: context.t('emCloseCase'), label: context.t('emOutcome'));
    if (outcome == null || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final result = await context.read<EmergencyProvider>().closeAssessment(assessment.id, outcome);
    if (!context.mounted) return;
    _toast(context, messenger, result, context.t('saved'));
  }
}

/// The matched protocol: which version, who approved it, how well the
/// signs fit, what supported the fit, what is missing, and the warnings.
class _MatchBox extends StatelessWidget {
  const _MatchBox({required this.match});
  final ProtocolMatch match;

  @override
  Widget build(BuildContext context) {
    final m = match;
    return Container(
      padding: const EdgeInsets.all(FarmSpacing.sm),
      decoration: BoxDecoration(color: FarmColors.sand, borderRadius: BorderRadius.circular(FarmRadii.sm)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text('${m.protocolTitle ?? m.protocolCode} · v${m.versionNo}', style: FarmTypography.textTheme.titleSmall)),
          Text('${context.t('emMatch')} ${_pct(m.matchScore)} ≥ ${_pct(m.minimumMatchConfidence)}', style: FarmTypography.textTheme.bodySmall),
          const SizedBox(width: 6),
          StatusPill(label: context.t('emEligibility_${m.eligibilityResult}'), level: m.eligibilityResult == 'ELIGIBLE' ? FarmStatusLevel.good : (m.eligibilityResult == 'WARN' ? FarmStatusLevel.watch : FarmStatusLevel.alert), dense: true),
        ]),
        if (m.supporting.isNotEmpty) Text('${context.t('emSupportedBy')}: ${m.supporting.map((e) => e['detail']).join('; ')}', style: FarmTypography.textTheme.bodySmall),
        if (m.missing.isNotEmpty) Text('${context.t('emNotReported')}: ${m.missing.map((e) => e['code']).join(', ')}', style: FarmTypography.textTheme.bodySmall?.copyWith(color: FarmColors.muted)),
        for (final w in m.warnings) Text('⚠ $w', style: FarmTypography.textTheme.bodySmall?.copyWith(color: FarmColors.warningInk)),
        for (final b in m.blockingReasons) Text('⛔ $b', style: FarmTypography.textTheme.bodySmall?.copyWith(color: FarmColors.danger)),
      ]),
    );
  }
}

/// The run: protocol and approval, notifications, reassessment, and the
/// steps with what the person can do next.
class _RunBox extends StatelessWidget {
  const _RunBox({required this.run, required this.canAct});
  final EmergencyRun run;
  final bool canAct;

  @override
  Widget build(BuildContext context) {
    final r = run;
    return Container(
      padding: const EdgeInsets.all(FarmSpacing.sm),
      decoration: BoxDecoration(border: Border.all(color: FarmColors.mist), borderRadius: BorderRadius.circular(FarmRadii.sm)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text('${r.protocolTitle ?? r.protocolCode} · v${r.versionNo} · ${context.t('emApprovalRef')} ${r.approvalReference ?? '—'}', style: FarmTypography.textTheme.titleSmall)),
          StatusPill(label: context.t('emRunStatus_${r.status}'), level: r.status == 'escalated' ? FarmStatusLevel.alert : (r.status == 'completed' ? FarmStatusLevel.good : FarmStatusLevel.watch), dense: true),
        ]),
        Text(
          [
            if (r.managerNotifiedAt != null) context.t('emManagerNotified'),
            if (r.vetNotifiedAt != null) context.t('emVetNotified'),
            if (r.nextReassessmentAt != null) '${context.t('emReassessAt')} ${TimeOfDay.fromDateTime(r.nextReassessmentAt!.toLocal()).format(context)}${r.reassessmentOverdue ? ' (${context.t('emReassessmentOverdue').toLowerCase()})' : ''}',
            if (r.escalationReason != null) '${context.t('emEscalated')}: ${r.escalationReason}',
            if (r.outcome != null) '${context.t('emOutcome')}: ${r.outcome}',
          ].join(' · '),
          style: FarmTypography.textTheme.bodySmall?.copyWith(color: r.status == 'escalated' ? FarmColors.danger : FarmColors.muted),
        ),
        const SizedBox(height: 6),
        for (final s in r.steps) _StepRow(run: r, step: s, canAct: canAct && r.isActive && s.id == r.nextStepId),
        if (canAct && r.isActive) ...[
          const SizedBox(height: 4),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            TextButton(onPressed: () => showReassessDialog(context, r), child: Text(context.t('emReassess'))),
            TextButton(onPressed: () => _escalate(context), child: Text(context.t('emEscalateNow'), style: const TextStyle(color: FarmColors.danger))),
            TextButton(onPressed: () => _resolve(context), child: Text(context.t('emResolve'))),
          ]),
        ],
      ]),
    );
  }

  Future<void> _escalate(BuildContext context) async {
    final reason = await askReason(context, title: context.t('emEscalateNow'), label: context.t('reason'));
    if (reason == null || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final result = await context.read<EmergencyProvider>().escalate(run.id, reason);
    if (!context.mounted) return;
    _toast(context, messenger, result, context.t('saved'));
  }

  Future<void> _resolve(BuildContext context) async {
    final outcome = await askReason(context, title: context.t('emResolve'), label: context.t('emOutcome'));
    if (outcome == null || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final result = await context.read<EmergencyProvider>().resolveRun(run.id, outcome);
    if (!context.mounted) return;
    _toast(context, messenger, result, context.t('saved'));
  }
}

class _StepRow extends StatelessWidget {
  const _StepRow({required this.run, required this.step, required this.canAct});
  final EmergencyRun run;
  final ProtocolRunStep step;
  final bool canAct;

  @override
  Widget build(BuildContext context) {
    final s = step;
    final d = s.step;
    final med = d.medication;
    final p = s.result;
    final icon = switch (s.status) {
      'completed' => Icons.check_circle,
      'skipped' => Icons.remove_circle_outline,
      'blocked' => Icons.block,
      'presented' => Icons.play_circle_outline,
      _ => Icons.radio_button_unchecked,
    };
    final color = switch (s.status) {
      'completed' => FarmColors.olive,
      'blocked' => FarmColors.danger,
      'presented' => FarmColors.cedar2,
      _ => FarmColors.muted,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${d.stepNo}. ${d.title} · ${context.t('emStepType_${d.stepType}')}${d.required ? '' : ' · ${context.t('emOptional')}'}', style: FarmTypography.textTheme.titleSmall),
            Text(d.instructions, style: FarmTypography.textTheme.bodySmall),
            if (med != null)
              Text(
                '${med['medicine_name']} · ${med['route_code']} · ${med['dose_rule_type'] == 'FIXED' ? '${feedNumber(_num(med['fixed_dose_quantity']))} ${med['dose_unit']}' : '${_num(med['dose_per_weight_quantity'])} ${med['dose_unit']}/${med['weight_unit']}'}'
                '${med['minimum_dose_quantity'] != null || med['maximum_dose_quantity'] != null ? ' · ${context.t('emApprovedRange')} ${_n(med['minimum_dose_quantity'])}–${_n(med['maximum_dose_quantity'])} ${med['dose_unit']}' : ''}',
                style: FarmTypography.textTheme.bodySmall?.copyWith(color: FarmColors.cedar2),
              ),
            if (d.isMedication && (s.status == 'presented' || s.isDone) && p['dose_quantity'] != null)
              Container(
                margin: const EdgeInsets.only(top: 4),
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(color: FarmColors.sand, borderRadius: BorderRadius.circular(6)),
                child: Text(
                  '${context.t('emPreparedDose')}: ${feedNumber(_num(p['dose_quantity']))} ${p['dose_unit']} ${p['route_code']}'
                  '${p['weight_used_kg'] != null ? ' · ${_num(p['weight_used_kg']).toStringAsFixed(0)} kg (${p['weight_source']})' : ''}'
                  '${(p['head_count'] ?? 1) != 1 ? ' × ${p['head_count']}' : ''} · ${context.t('phLot')} ${p['lot_code'] ?? '—'}'
                  '${p['withdrawal_meat_until'] != null ? ' · ${context.t('phWithdrawal')} ${context.t('phMeat')} ${feedDate(DateTime.parse(p['withdrawal_meat_until'] as String))}' : ''}',
                  style: FarmTypography.textTheme.bodySmall,
                ),
              ),
            for (final problem in s.problems) Text('⛔ $problem', style: FarmTypography.textTheme.bodySmall?.copyWith(color: FarmColors.danger)),
            if (s.skipReason != null) Text('${context.t('emSkipped')}: ${s.skipReason}', style: FarmTypography.textTheme.bodySmall?.copyWith(color: FarmColors.muted)),
            if (s.confirmedByName != null && s.confirmedAt != null)
              Text('${s.confirmedByName} · ${TimeOfDay.fromDateTime(s.confirmedAt!.toLocal()).format(context)}', style: FarmTypography.textTheme.bodySmall?.copyWith(color: FarmColors.muted)),
          ]),
        ),
        if (canAct && !s.isDone && !s.isBlocked)
          Wrap(spacing: 4, children: [
            if (d.isMedication && s.status != 'presented') OutlinedButton(onPressed: () => _prepare(context), child: Text(context.t('emPrepare'))),
            if (!d.isMedication || s.status == 'presented') FilledButton(onPressed: () => _confirm(context), child: Text(context.t('emConfirmDone'))),
            if (!d.required) TextButton(onPressed: () => _skip(context), child: Text(context.t('emSkip'))),
          ]),
      ]),
    );
  }

  static double _num(Object? v) => (v as num?)?.toDouble() ?? 0;
  static String _n(Object? v) => v == null ? '—' : feedNumber(_num(v));

  Future<double?> _askWeight(BuildContext context) async {
    final controller = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(context.t('emWeightTitle')),
        content: TextField(controller: controller, autofocus: true, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: context.t('emWeightKg'), helperText: context.t('emWeightHelp'))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(context.t('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, controller.text.trim()), child: Text(context.t('save'))),
        ],
      ),
    );
    if (text == null) return null;
    return text.isEmpty ? -1 : double.tryParse(text);
  }

  Future<void> _prepare(BuildContext context) async {
    final med = step.step.medication ?? const {};
    double? weight;
    int? heads;
    if (med['dose_rule_type'] == 'PER_WEIGHT') {
      final w = await _askWeight(context);
      if (w == null || !context.mounted) return;
      weight = w < 0 ? null : w;
    } else if (run.subjectType == 'group') {
      final text = await askReason(context, title: context.t('emHeadCountTitle'), label: context.t('headCount'));
      if (text == null || !context.mounted) return;
      heads = int.tryParse(text);
    }
    final messenger = ScaffoldMessenger.of(context);
    final result = await context.read<EmergencyProvider>().prepareStep(run.id, step.id, weightKg: weight, headCount: heads);
    if (!context.mounted) return;
    _toast(context, messenger, result, context.t('emPrepared'));
  }

  Future<void> _confirm(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final notes = step.step.isMedication ? await askReason(context, title: context.t('emConfirmDone'), label: context.t('emConfirmGiven')) : '';
    if (notes == null || !context.mounted) return;
    final result = await context.read<EmergencyProvider>().confirmStep(run.id, step.id, notes: notes.isEmpty ? null : notes);
    if (!context.mounted) return;
    _toast(context, messenger, result, context.t('emStepDone'));
  }

  Future<void> _skip(BuildContext context) async {
    final reason = await askReason(context, title: context.t('emSkip'), label: context.t('reason'));
    if (reason == null || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final result = await context.read<EmergencyProvider>().skipStep(run.id, step.id, reason);
    if (!context.mounted) return;
    _toast(context, messenger, result, context.t('saved'));
  }
}

class _ProtocolRow extends StatelessWidget {
  const _ProtocolRow(this.p);
  final EmergencyProtocol p;

  @override
  Widget build(BuildContext context) {
    final lang = Localizations.localeOf(context).languageCode;
    final livestock = context.read<LivestockProvider>();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${p.title} · ${p.code}', style: FarmTypography.textTheme.titleSmall),
            Text(
              [
                p.speciesCode == null ? context.t('anySpecies') : livestock.speciesName(p.speciesCode!, lang),
                context.t('emScope_${p.subjectScope}'),
                if (p.currentVersionNo != null) 'v${p.currentVersionNo}',
                if (p.approvedByName != null) '${context.t('emApprovedBy')} ${p.approvedByName}${p.approvedAt == null ? '' : ' · ${feedDate(p.approvedAt!)}'}',
                if (p.approvalReference != null) p.approvalReference!,
                if (p.offlineEligible) context.t('emOfflineEligible'),
                '${p.steps.length} ${context.t('emSteps').toLowerCase()}',
              ].join(' · '),
              style: FarmTypography.textTheme.bodySmall?.copyWith(color: FarmColors.muted),
            ),
          ]),
        ),
        StatusPill(label: context.t('emProtocolStatus_${p.status}'), level: p.isActive ? FarmStatusLevel.good : (p.status == 'draft' ? FarmStatusLevel.watch : FarmStatusLevel.neutral), dense: true),
      ]),
    );
  }
}

// ------------------------------------------------------------------ assess
Future<void> showAssessDialog(BuildContext context, {String? subjectType, String? subjectId}) =>
    showDialog<void>(context: context, builder: (_) => _SignsDialog(subjectType: subjectType, subjectId: subjectId));

Future<void> showReassessDialog(BuildContext context, EmergencyRun run) =>
    showDialog<void>(context: context, builder: (_) => _SignsDialog(subjectType: run.subjectType, subjectId: run.subjectId, reassessRun: run));

/// The worker's signs: measurements, choices and yes/no, from the sign
/// vocabulary the server publishes. Used for a new triage and for the
/// reassessment of a run.
class _SignsDialog extends StatefulWidget {
  const _SignsDialog({this.subjectType, this.subjectId, this.reassessRun});
  final String? subjectType;
  final String? subjectId;
  final EmergencyRun? reassessRun;

  @override
  State<_SignsDialog> createState() => _SignsDialogState();
}

class _SignsDialogState extends State<_SignsDialog> {
  String? _subject;
  final Map<String, TextEditingController> _numbers = {};
  final Map<String, String?> _choices = {};
  final Set<String> _present = {};
  final _notes = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.subjectType != null && widget.subjectId != null) _subject = '${widget.subjectType}:${widget.subjectId}';
  }

  @override
  void dispose() {
    for (final c in _numbers.values) {
      c.dispose();
    }
    _notes.dispose();
    super.dispose();
  }

  TextEditingController _number(String code) => _numbers.putIfAbsent(code, TextEditingController.new);

  @override
  Widget build(BuildContext context) {
    final emergency = context.watch<EmergencyProvider>();
    final animals = context.watch<AnimalsProvider>().animals;
    final groups = context.watch<LivestockProvider>().groups;
    final subjects = <String, String>{
      for (final a in animals) 'animal:${a.id}': '${a.name}${a.tag == null ? '' : ' · ${a.tag}'}',
      for (final g in groups) 'group:${g.id}': '${g.name} · ${g.count}',
    };
    final subject = subjects.containsKey(_subject) ? _subject : null;
    final codes = emergency.signCodes;
    final numeric = codes.where((c) => c.kind == 'numeric').toList();
    final categorical = codes.where((c) => c.kind == 'categorical').toList();
    final booleans = codes.where((c) => c.kind == 'boolean').toList();
    final reassess = widget.reassessRun != null;

    return AlertDialog(
      title: Text(reassess ? context.t('emReassess') : context.t('emAssess')),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(context.t('emAssessHelp'), style: FarmTypography.textTheme.bodySmall?.copyWith(color: FarmColors.muted)),
            const SizedBox(height: 12),
            if (!reassess)
              DropdownButtonFormField<String>(
                initialValue: subject,
                decoration: InputDecoration(labelText: context.t('animalOrGroup')),
                items: [for (final e in subjects.entries) DropdownMenuItem(value: e.key, child: Text(e.value, overflow: TextOverflow.ellipsis))],
                onChanged: (v) => setState(() => _subject = v),
              )
            else
              Text(widget.reassessRun!.subjectName ?? widget.reassessRun!.subjectId, style: FarmTypography.textTheme.titleSmall),
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final c in numeric)
                SizedBox(
                  width: 150,
                  child: TextField(controller: _number(c.code), keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: c.label, suffixText: c.unit)),
                ),
            ]),
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final c in categorical)
                SizedBox(
                  width: 150,
                  child: DropdownButtonFormField<String?>(
                    initialValue: _choices[c.code],
                    decoration: InputDecoration(labelText: c.label),
                    items: [
                      const DropdownMenuItem<String?>(value: null, child: Text('—')),
                      for (final o in c.options) DropdownMenuItem<String?>(value: o, child: Text(o)),
                    ],
                    onChanged: (v) => setState(() => _choices[c.code] = v),
                  ),
                ),
            ]),
            const SizedBox(height: 12),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final c in booleans)
                FilterChip(label: Text(c.label), selected: _present.contains(c.code), onSelected: (v) => setState(() => v ? _present.add(c.code) : _present.remove(c.code))),
            ]),
            const SizedBox(height: 12),
            TextField(controller: _notes, decoration: InputDecoration(labelText: context.t('notes'))),
            if (_error != null) ...[const SizedBox(height: 8), Text(_error!, style: const TextStyle(color: FarmColors.danger, fontSize: 12))],
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: _saving ? null : () => Navigator.pop(context), child: Text(context.t('cancel'))),
        FilledButton(onPressed: _saving || (!reassess && subject == null) ? null : () => _save(subject), child: Text(reassess ? context.t('emReassess') : context.t('emTriage'))),
      ],
    );
  }

  List<Map<String, dynamic>> _signs() {
    final signs = <Map<String, dynamic>>[];
    for (final e in _numbers.entries) {
      final v = double.tryParse(e.value.text.trim());
      if (v != null) signs.add({'code': e.key, 'value_numeric': v});
    }
    for (final e in _choices.entries) {
      if (e.value != null) signs.add({'code': e.key, 'value_text': e.value});
    }
    for (final code in _present) {
      signs.add({'code': code, 'present': true});
    }
    return signs;
  }

  Future<void> _save(String? subject) async {
    final signs = _signs();
    if (signs.isEmpty) {
      setState(() => _error = context.t('emNoSigns'));
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final messenger = ScaffoldMessenger.of(context);
    final provider = context.read<EmergencyProvider>();
    final notes = _notes.text.trim().isEmpty ? null : _notes.text.trim();
    final result = widget.reassessRun != null
        ? await provider.reassess(widget.reassessRun!.id, signs, notes: notes)
        : await provider.assess({'subject_type': subject!.split(':').first, 'subject_id': subject.split(':').last, 'signs': signs, 'source': 'worker', if (notes != null) 'notes': notes});
    if (!mounted) return;
    if (result.success) {
      Navigator.pop(context);
      _toast(context, messenger, result, context.t('emTriaged'));
    } else {
      setState(() {
        _saving = false;
        _error = result.error ?? context.t('couldNotSave');
      });
    }
  }
}
