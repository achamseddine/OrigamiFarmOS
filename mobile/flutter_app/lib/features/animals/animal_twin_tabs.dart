import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/widgets/app_icon.dart';
import '../../core/widgets/charts/line_trend_chart.dart';
import '../../core/widgets/kpi_card.dart';
import '../../core/widgets/section_card.dart';
import '../../core/widgets/status_pill.dart';
import '../../core/widgets/ux_blocks.dart';
import '../../domain/entities/animal.dart';
import '../../domain/entities/livestock.dart';
import '../../domain/entities/production_records.dart';
import '../../domain/entities/reproduction.dart';
import '../../providers/animals_provider.dart';
import '../../providers/herd_records_provider.dart';
import '../../providers/production_provider.dart';
import '../feed/feed_workspace_screen.dart' show feedDate;
import '../sync/sync_pill.dart' show PendingChip;
import 'animal_feeding_section.dart';
import 'animal_quick_actions.dart' show observationLabel;
import 'animal_reproduction_section.dart';

/// The tabs of the Digital Twin past its Overview (see
/// `animal_digital_twin_screen.dart`). Each opens on the prototype's
/// anatomy — eyebrow, heading, one line, the action — then its figures,
/// its records, and the caveat that keeps the figures honest.

String _d(DateTime d) => feedDate(d);

String _sessionLabel(BuildContext context, String session) => switch (session) {
      'morning' => context.t('sessionMorning'),
      'evening' => context.t('sessionEvening'),
      _ => session,
    };

// ---------------------------------------------------------------- milk

class TwinMilkTab extends StatelessWidget {
  const TwinMilkTab({super.key, required this.animal, this.onRecord});
  final Animal animal;
  final VoidCallback? onRecord;

  @override
  Widget build(BuildContext context) {
    final records = context.watch<ProductionProvider>().milkRecords.where((r) => r.animalId == animal.id).toList()
      ..sort((a, b) => b.recordedAt.compareTo(a.recordedAt));
    final now = DateTime.now();
    final week = records.where((r) => r.recordedAt.isAfter(now.subtract(const Duration(days: 7)))).toList();
    final weekTotal = week.fold<double>(0, (s, r) => s + r.liters);
    final month = records.where((r) => r.recordedAt.isAfter(now.subtract(const Duration(days: 30)))).length;
    final last = records.isEmpty ? null : records.first;
    final recordButton = onRecord == null
        ? null
        : FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: FarmColors.cedarDark),
            onPressed: onRecord,
            icon: const Icon(Icons.add, size: 18),
            label: Text(context.t('twRecordMilk')),
          );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeading(eyebrow: context.t('twTabMilk'), title: context.t('twMilkTitle'), subtitle: context.t('twMilkSub'), actions: [?recordButton]),
        const SizedBox(height: FarmSpacing.md),
        EqualGrid(minTileWidth: 190, children: [
          KpiCard(icon: FarmIcon.milkBottle, accent: FarmColors.milkBlue, label: context.t('twKpiMilk7'), value: weekTotal.toStringAsFixed(1), unit: 'L', caption: context.t('twKpiMilk7Cap')),
          KpiCard(icon: FarmIcon.chartLine, accent: FarmColors.milkBlue, label: context.t('twMilkAvg'), value: (weekTotal / 7).toStringAsFixed(1), unit: 'L', caption: context.t('twMilkAvgCap')),
          KpiCard(
            icon: FarmIcon.calendar,
            label: context.t('twMilkLast'),
            value: last == null ? '—' : last.liters.toStringAsFixed(1),
            unit: last == null ? null : 'L',
            caption: last == null ? context.t('twNotYet') : '${_d(last.recordedAt)} · ${_sessionLabel(context, last.session)}',
          ),
          KpiCard(icon: FarmIcon.report, label: context.t('twMilkCount'), value: '$month', caption: context.t('twLast30Days')),
        ]),
        const SizedBox(height: FarmSpacing.md),
        if (records.isEmpty)
          SectionCard(child: EmptyState(message: context.t('twNoMilk'), icon: FarmIcon.milkBottle, action: recordButton))
        else ...[
          SectionCard(
            title: context.t('twMilkTrend14'),
            child: LineTrendChart(values: _byDay(records, 14), height: 120, color: FarmColors.milkBlue, showDots: false),
          ),
          const SizedBox(height: FarmSpacing.md),
          SectionCard(
            title: context.t('twMilkRecent'),
            child: Column(children: [
              for (final r in records.take(14))
                FactRow(
                  label: '${_d(r.recordedAt)} · ${_sessionLabel(context, r.session)}',
                  value: '${r.liters.toStringAsFixed(1)} L · ${context.t(r.destination)}',
                  last: r == records.take(14).last,
                ),
            ]),
          ),
        ],
        const SizedBox(height: FarmSpacing.md),
        NoticeBanner(text: context.t('twMilkCaveat')),
      ],
    );
  }

  static List<double> _byDay(List<MilkRecord> records, int days) {
    final today = DateTime.now();
    final start = DateTime(today.year, today.month, today.day).subtract(Duration(days: days - 1));
    final buckets = List<double>.filled(days, 0);
    for (final r in records) {
      final d = r.recordedAt.toLocal();
      final i = DateTime(d.year, d.month, d.day).difference(start).inDays;
      if (i >= 0 && i < days) buckets[i] += r.liters;
    }
    return buckets;
  }
}

// ---------------------------------------------------------------- feed

class TwinFeedTab extends StatelessWidget {
  const TwinFeedTab({super.key, required this.animal, required this.caps, required this.twin, required this.repro});
  final Animal animal;
  final CapabilitySet caps;
  final Map<String, dynamic>? twin;
  final ReproSummary? repro;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeading(eyebrow: context.t('twTabFeed'), title: context.t('twFeedTitle'), subtitle: context.t('twFeedSub')),
        const SizedBox(height: FarmSpacing.md),
        AnimalFeedingSection(animal: animal),
        const SizedBox(height: FarmSpacing.md),
        RationReadinessCard(animal: animal, caps: caps, twin: twin, repro: repro),
      ],
    );
  }
}

/// Which of the inputs an individual ration would need are on record for
/// this animal. It calculates nothing: the program sets today's
/// quantities, and an individual ration needs a validated nutrition model
/// and measured feed analysis that this farm system does not have yet
/// (prototype README: "design requirements, not working services").
class RationReadinessCard extends StatelessWidget {
  const RationReadinessCard({super.key, required this.animal, required this.caps, required this.twin, required this.repro});
  final Animal animal;
  final CapabilitySet caps;
  final Map<String, dynamic>? twin;
  final ReproSummary? repro;

  @override
  Widget build(BuildContext context) {
    final latest = twin?['latest_weight'];
    final kg = latest is Map ? (latest['weight_kg'] as num?)?.toDouble() : animal.weightKg;
    final milk = context.watch<ProductionProvider>().milkRecords.where((r) => r.animalId == animal.id && r.recordedAt.isAfter(DateTime.now().subtract(const Duration(days: 7))));
    final milk7 = milk.fold<double>(0, (s, r) => s + r.liters);
    final s = repro;

    final inputs = <(String, String?)>[
      (context.t('twInWeight'), kg == null ? null : '${kg.toStringAsFixed(kg >= 100 ? 0 : 1)} kg'),
      if (caps.has(Cap.milkProduction)) (context.t('twInMilk'), milk.isEmpty ? null : '${(milk7 / 7).toStringAsFixed(1)} L/${context.t('twPerDay')}'),
      if (s != null && s.applies.lactation)
        (context.t('twInLactation'), s.lactation == null ? context.t('reproDry') : '${s.lactation!.daysInMilk ?? '–'} ${context.t('reproDaysInMilk')}'),
      if (s != null && s.applies.pregnancy)
        (context.t('twInPregnancy'), s.pregnant ? '${context.t('twDay')} ${s.pregnancy?.daysPregnant ?? '–'}' : (s.awaitingCheck ? context.t('reproAwaitingCheck') : context.t('reproOpen'))),
      (context.t('twInFeedAnalysis'), null),
    ];

    return SectionCard(
      title: context.t('twReadinessTitle'),
      subtitle: context.t('twReadinessSub'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(alignment: AlignmentDirectional.centerStart, child: StatusPill(label: context.t('twEngineNotConnected'), level: FarmStatusLevel.watch, dense: true)),
          const SizedBox(height: FarmSpacing.sm),
          for (final (label, value) in inputs)
            FactRow(
              label: label,
              value: value ?? context.t('twMissing'),
              valueColor: value == null ? FarmColors.warningInk : null,
              trailing: Icon(value == null ? Icons.radio_button_unchecked : Icons.check_circle, size: 15, color: value == null ? FarmColors.warning : FarmColors.success),
              last: label == inputs.last.$1,
            ),
          const SizedBox(height: FarmSpacing.sm),
          NoticeBanner(tone: NoticeTone.info, text: context.t('twReadinessNote')),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- weight

class TwinWeightTab extends StatefulWidget {
  const TwinWeightTab({super.key, required this.animal, required this.caps, this.onRecord});
  final Animal animal;
  final CapabilitySet caps;
  final VoidCallback? onRecord;

  @override
  State<TwinWeightTab> createState() => _TwinWeightTabState();
}

class _TwinWeightTabState extends State<TwinWeightTab> {
  late final Future<List<WeightRecord>> _weights = context.read<AnimalsProvider>().fetchWeights(widget.animal.id);

  @override
  Widget build(BuildContext context) {
    final recordButton = widget.onRecord == null
        ? null
        : FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: FarmColors.cedarDark),
            onPressed: widget.onRecord,
            icon: const Icon(Icons.add, size: 18),
            label: Text(context.t('twRecordWeight')),
          );
    return FutureBuilder<List<WeightRecord>>(
      future: _weights,
      builder: (context, snap) {
        final weights = snap.data ?? const <WeightRecord>[];
        final latest = weights.isEmpty ? null : weights.first;
        final previous = weights.length < 2 ? null : weights[1];
        final change = latest != null && previous != null ? latest.weightKg - previous.weightKg : null;
        final days = latest != null && previous != null ? latest.measuredAt.difference(previous.measuredAt).inDays : null;

        Widget body;
        if (snap.connectionState != ConnectionState.done) {
          body = const Padding(padding: EdgeInsets.all(FarmSpacing.lg), child: Center(child: CircularProgressIndicator()));
        } else if (snap.hasError) {
          body = NoticeBanner(tone: NoticeTone.danger, text: context.t('twinLoadFailed'));
        } else if (weights.isEmpty) {
          body = SectionCard(child: EmptyState(message: context.t('twNoWeights'), icon: FarmIcon.scale, action: recordButton));
        } else {
          body = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (weights.length >= 2) ...[
              SectionCard(
                title: context.t('twWeightTrend'),
                child: LineTrendChart(values: [for (final w in weights.reversed) w.weightKg], height: 120),
              ),
              const SizedBox(height: FarmSpacing.md),
            ],
            SectionCard(
              title: context.t('twWeighings'),
              child: Column(children: [
                for (final w in weights)
                  FactRow(
                    label: [_d(w.measuredAt), context.t('wm_${w.method}'), if (w.recordedByName != null) w.recordedByName!].join(' · '),
                    value: '${w.weightKg.toStringAsFixed(w.weightKg >= 100 ? 0 : 1)} kg',
                    trailing: w.pending ? const PendingChip() : null,
                    last: w == weights.last,
                  ),
              ]),
            ),
          ]);
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SectionHeading(eyebrow: context.t('twTabWeight'), title: context.t('twWeightTitle'), subtitle: context.t('twWeightSub'), actions: [?recordButton]),
            const SizedBox(height: FarmSpacing.md),
            EqualGrid(minTileWidth: 190, maxColumns: 3, children: [
              KpiCard(
                icon: FarmIcon.scale,
                label: context.t('twKpiWeight'),
                value: latest == null ? '—' : latest.weightKg.toStringAsFixed(latest.weightKg >= 100 ? 0 : 1),
                unit: latest == null ? null : 'kg',
                caption: latest == null ? context.t('twNotWeighed') : '${_d(latest.measuredAt)} · ${context.t('wm_${latest.method}')}',
              ),
              KpiCard(
                icon: FarmIcon.chartLine,
                label: context.t('twWeightChange'),
                value: change == null ? '—' : '${change >= 0 ? '+' : ''}${change.toStringAsFixed(1)}',
                unit: change == null ? null : 'kg',
                caption: days == null ? context.t('twNeedsTwo') : '${context.t('twOver')} $days ${context.t('twDays')}',
              ),
              KpiCard(icon: FarmIcon.report, label: context.t('twWeighings'), value: '${weights.length}', caption: context.t('twAllRecorded')),
            ]),
            const SizedBox(height: FarmSpacing.md),
            body,
            const SizedBox(height: FarmSpacing.md),
            NoticeBanner(text: context.t('twWeightCaveat')),
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------- reproduction

class TwinReproductionTab extends StatelessWidget {
  const TwinReproductionTab({super.key, required this.animal, required this.twin, required this.loading, this.onChanged});
  final Animal animal;
  final Map<String, dynamic>? twin;
  final bool loading;
  final VoidCallback? onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AnimalReproductionSection(animal: animal, twin: twin, loading: loading, onChanged: onChanged),
        const SizedBox(height: FarmSpacing.md),
        SectionCard(title: context.t('twReproHistory'), child: ReproTimelineView(animal: animal, embedded: true)),
      ],
    );
  }
}

// ---------------------------------------------------------------- timeline

/// One line of the animal's history, whatever produced it.
class TimelineEntry {
  const TimelineEntry(this.icon, this.title, this.value, this.when, {this.kind = TimelineKind.event});
  final FarmIcon icon;
  final String title;
  final String value;
  final DateTime? when;
  final TimelineKind kind;

  /// A domain event from the twin's `recent_events`.
  factory TimelineEntry.fromEvent(BuildContext context, Map<String, dynamic> e) {
    final type = e['event_type'] as String? ?? 'event';
    final payload = (e['payload'] as Map?)?.cast<String, dynamic>() ?? const <String, dynamic>{};
    return TimelineEntry(_eventIcon(type), eventTitle(context, type), _eventValue(type, payload), DateTime.tryParse(e['created_at'] as String? ?? ''));
  }

  factory TimelineEntry.fromObservation(BuildContext context, Map<String, dynamic> o) {
    final severity = o['severity'] as String?;
    return TimelineEntry(
      FarmIcon.eye,
      observationLabel(context, o['observation_type'] as String? ?? 'observation'),
      severity == null ? '' : context.t('sev${severity[0].toUpperCase()}${severity.substring(1)}'),
      DateTime.tryParse(o['observed_at'] as String? ?? ''),
      kind: TimelineKind.observation,
    );
  }

  factory TimelineEntry.fromState(BuildContext context, StateChange h) {
    final v = h.value;
    final value = v == null ? '—' : (h.stateType == 'STATUS' ? (v == 'active' ? context.t('active') : context.t('exit_$v')) : v.replaceAll('_', ' '));
    final icon = switch (h.stateType) {
      'LOCATION' => FarmIcon.location,
      'LIFE_STAGE' => FarmIcon.calendar,
      'STATUS' => FarmIcon.check,
      _ => FarmIcon.report,
    };
    return TimelineEntry(icon, context.t('state_${h.stateType}'), value, h.effectiveFrom, kind: TimelineKind.state);
  }
}

enum TimelineKind { event, observation, state }

/// "Milk recorded", "Medicine given"… — the reader's language, or the
/// event code spelt out for a type the table does not know yet.
String eventTitle(BuildContext context, String type) {
  final key = 'ev_$type';
  final translated = context.t(key);
  if (translated != key) return translated;
  final words = type.replaceAll('_', ' ');
  return words.isEmpty ? words : '${words[0].toUpperCase()}${words.substring(1)}';
}

FarmIcon _eventIcon(String type) => switch (type) {
      'milk_recorded' => FarmIcon.milkBottle,
      'observation_recorded' => FarmIcon.eye,
      'treatment_recorded' || 'treatment_prescribed' || 'health_case_opened' || 'health_case_closed' || 'diagnosis_recorded' => FarmIcon.stethoscope,
      'medication_administered' || 'medication_administration_reversed' || 'protocol_medication_prepared' || 'protocol_step_completed' => FarmIcon.syringe,
      'withdrawal_started' => FarmIcon.warning,
      'animal_weight_recorded' => FarmIcon.scale,
      'feeding_recorded' || 'feeding_event_recorded' => FarmIcon.feedBag,
      'animal_moved' || 'animal_group_changed' => FarmIcon.location,
      _ when type.startsWith('emergency_') => FarmIcon.bell,
      _ when type.contains('pregnan') || type.contains('breeding') || type.contains('birth') => FarmIcon.pregnancy,
      _ => FarmIcon.calendar,
    };

String _eventValue(String type, Map<String, dynamic> payload) => switch (type) {
      'milk_recorded' => payload['liters'] == null ? '' : '${payload['liters']} L',
      'animal_moved' => '${payload['location_label'] ?? ''}',
      'treatment_recorded' || 'treatment_prescribed' => '${payload['medication'] ?? ''}',
      'medication_administered' =>
        '${payload['medicine'] ?? payload['medicine_name'] ?? ''}${payload['dose'] != null ? ' ${payload['dose']} ${payload['dose_unit'] ?? ''}' : ''}'.trim(),
      'animal_weight_recorded' => payload['weight_kg'] == null ? '' : '${payload['weight_kg']} kg',
      'emergency_protocol_matched' || 'emergency_protocol_started' => '${payload['protocol'] ?? ''}',
      'emergency_escalated' || 'emergency_protocol_blocked' => '${payload['triage'] ?? ''}',
      'diagnosis_recorded' => '${payload['diagnosis_code'] ?? ''}',
      _ => '',
    };

/// "Today", "Yesterday", "3 days ago", then the date.
String relativeDay(BuildContext context, DateTime? when) {
  if (when == null) return '—';
  final now = DateTime.now();
  final local = when.toLocal();
  final days = DateTime(now.year, now.month, now.day).difference(DateTime(local.year, local.month, local.day)).inDays;
  if (days <= 0) return context.t('twToday');
  if (days == 1) return context.t('twYesterday');
  if (days < 7) return '$days ${context.t('twDaysAgo')}';
  return _d(local);
}

class TimelineRow extends StatelessWidget {
  const TimelineRow({super.key, required this.entry, this.showDay = true});
  final TimelineEntry entry;
  final bool showDay;

  @override
  Widget build(BuildContext context) {
    final time = entry.when == null ? '' : TimeOfDay.fromDateTime(entry.when!.toLocal()).format(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: const BoxDecoration(color: FarmColors.mist, shape: BoxShape.circle),
            child: Center(child: AppIcon(entry.icon, size: 15, color: FarmColors.cedar)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(showDay ? relativeDay(context, entry.when) : time, style: const TextStyle(fontSize: 11, color: FarmColors.muted)),
                Text(entry.title, style: FarmTypography.textTheme.titleSmall),
              ],
            ),
          ),
          if (entry.value.isNotEmpty)
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 200),
              child: Text(entry.value, textAlign: TextAlign.end, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
            ),
        ],
      ),
    );
  }
}

/// Everything recorded about the animal, newest first and grouped by day:
/// the domain events, the observations, and every change of state
/// (status, stage, location) from the state history.
class TwinTimelineTab extends StatefulWidget {
  const TwinTimelineTab({super.key, required this.animal, required this.twin, required this.loading, required this.error});
  final Animal animal;
  final Map<String, dynamic>? twin;
  final bool loading;
  final String? error;

  @override
  State<TwinTimelineTab> createState() => _TwinTimelineTabState();
}

class _TwinTimelineTabState extends State<TwinTimelineTab> {
  late final Future<List<StateChange>> _history = context.read<HerdRecordsProvider>().history(widget.animal.id).catchError((_) => <StateChange>[]);
  TimelineKind? _filter;

  @override
  Widget build(BuildContext context) {
    final events = (widget.twin?['recent_events'] as List<dynamic>? ?? const []).whereType<Map<String, dynamic>>();
    final observations = (widget.twin?['recent_observations'] as List<dynamic>? ?? const []).whereType<Map<String, dynamic>>();
    return FutureBuilder<List<StateChange>>(
      future: _history,
      builder: (context, snap) {
        final all = <TimelineEntry>[
          for (final e in events) TimelineEntry.fromEvent(context, e),
          for (final o in observations) TimelineEntry.fromObservation(context, o),
          for (final h in snap.data ?? const <StateChange>[]) TimelineEntry.fromState(context, h),
        ]..sort((a, b) => (b.when ?? DateTime(1970)).compareTo(a.when ?? DateTime(1970)));
        final shown = [for (final e in all) if (_filter == null || e.kind == _filter) e];

        final byDay = <String, List<TimelineEntry>>{};
        for (final e in shown) {
          byDay.putIfAbsent(relativeDay(context, e.when), () => []).add(e);
        }

        final filters = <(String, TimelineKind?)>[
          (context.t('twAll'), null),
          (context.t('twEvents'), TimelineKind.event),
          (context.t('twObservations'), TimelineKind.observation),
          (context.t('twStateChanges'), TimelineKind.state),
        ];

        final loading = widget.loading || snap.connectionState != ConnectionState.done;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SectionHeading(eyebrow: context.t('twTabTimeline'), title: context.t('twTimelineTitle'), subtitle: context.t('twTimelineSub')),
            const SizedBox(height: FarmSpacing.sm),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final (label, kind) in filters) ChoiceChip(label: Text(label), selected: _filter == kind, onSelected: (_) => setState(() => _filter = kind)),
            ]),
            const SizedBox(height: FarmSpacing.md),
            SectionCard(
              child: loading
                  ? const Padding(padding: EdgeInsets.all(FarmSpacing.lg), child: Center(child: CircularProgressIndicator()))
                  : widget.error != null
                      ? NoticeBanner(tone: NoticeTone.danger, text: widget.error!)
                      : shown.isEmpty
                          ? EmptyState(message: context.t('twNoEvents'), icon: FarmIcon.calendar)
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                for (final day in byDay.entries) ...[
                                  Padding(padding: const EdgeInsets.only(top: 8, bottom: 2), child: Eyebrow(day.key, color: FarmColors.muted)),
                                  for (final e in day.value) TimelineRow(entry: e, showDay: false),
                                  const Divider(height: 12, color: FarmColors.border),
                                ],
                              ],
                            ),
            ),
            const SizedBox(height: FarmSpacing.sm),
            Text(context.t('twTimelineLimit'), style: FarmTypography.textTheme.bodySmall),
          ],
        );
      },
    );
  }
}
