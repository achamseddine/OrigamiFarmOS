import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/widgets/app_icon.dart';
import '../../core/widgets/charts/line_trend_chart.dart';
import '../../core/widgets/photo_slot.dart';
import '../../core/widgets/section_card.dart';
import '../../core/widgets/status_pill.dart';
import '../../core/widgets/top_bar.dart';
import '../../domain/entities/animal.dart';
import '../../domain/entities/production_records.dart';
import '../../providers/animals_provider.dart';
import '../../providers/production_provider.dart';
import 'animal_quick_actions.dart';

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

String _shortDate(DateTime? d) => d == null ? '—' : '${_months[d.month - 1]} ${d.day}';

/// Screen 4 — Animal Digital Twin. Pushed as a focused full-screen route
/// (no nav rail) — the Option C mockup itself drops the sidebar here in
/// favour of a "Back to Herd" header, so [AnimalDigitalTwinScreen] is a
/// plain [MaterialPageRoute] destination rather than an [AppShell] tab.
///
/// The base [Animal] profile comes from [AnimalsProvider] (already loaded
/// at startup), but the observation/event/recommendation history shown
/// here is per-animal and isn't part of that farm-wide list — so this
/// screen additionally fetches the backend's digital-twin endpoint
/// (`GET /animals/{id}`) itself, fetch-in-initState style.
class AnimalDigitalTwinScreen extends StatefulWidget {
  const AnimalDigitalTwinScreen({super.key, required this.animalId});

  final String animalId;

  @override
  State<AnimalDigitalTwinScreen> createState() => _AnimalDigitalTwinScreenState();
}

class _AnimalDigitalTwinScreenState extends State<AnimalDigitalTwinScreen> {
  Map<String, dynamic>? _twin;
  bool _twinLoading = true;
  String? _twinError;

  @override
  void initState() {
    super.initState();
    _loadTwin();
  }

  @override
  void didUpdateWidget(covariant AnimalDigitalTwinScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animalId != widget.animalId) _loadTwin();
  }

  Future<void> _loadTwin() async {
    setState(() {
      _twinLoading = true;
      _twinError = null;
    });
    try {
      final twin = await context.read<AnimalsProvider>().fetchDigitalTwin(widget.animalId);
      if (!mounted) return;
      setState(() {
        _twin = twin;
        _twinLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _twinError = "Could not load this animal's history.";
        _twinLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final animal = context.watch<AnimalsProvider>().byId(widget.animalId);

    return Scaffold(
      backgroundColor: FarmColors.stone,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: FarmSpacing.xl, vertical: FarmSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  TextButton.icon(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.chevron_left),
                    label: Text(context.t('backToHerd')),
                  ),
                  const Spacer(),
                  const TopBar(),
                ],
              ),
              Expanded(
                child: SingleChildScrollView(
                  child: LayoutBuilder(builder: (context, constraints) {
                    final wide = constraints.maxWidth > kTabletBreakpoint;
                    final left = _ProfileColumn(animal: animal);
                    final center = _HistoryColumn(animal: animal, twin: _twin, twinLoading: _twinLoading, twinError: _twinError);
                    final right = _InsightsColumn(animal: animal, twin: _twin, twinLoading: _twinLoading);
                    if (!wide) {
                      return Column(children: [left, const SizedBox(height: FarmSpacing.md), center, const SizedBox(height: FarmSpacing.md), right]);
                    }
                    return IntrinsicHeight(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(width: 260, child: left),
                          const SizedBox(width: FarmSpacing.md),
                          Expanded(flex: 6, child: center),
                          const SizedBox(width: FarmSpacing.md),
                          SizedBox(width: 300, child: right),
                        ],
                      ),
                    );
                  }),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProfileColumn extends StatelessWidget {
  const _ProfileColumn({required this.animal});
  final Animal animal;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('${animal.name} #${animal.tag}', style: FarmTypography.display(size: 24)),
            const SizedBox(width: 8),
            StatusPill(label: context.t('active'), level: FarmStatusLevel.good, dense: true),
          ],
        ),
        const SizedBox(height: FarmSpacing.sm),
        AspectRatio(
          aspectRatio: 1.1,
          child: PhotoSlot(filePath: animal.photoPath, icon: _iconForSpecies(animal.species), label: animal.species.label),
        ),
        const SizedBox(height: FarmSpacing.md),
        SectionCard(
          padding: const EdgeInsets.all(FarmSpacing.md),
          child: Column(
            children: [
              _fact(context, context.t('species'), animal.species.label),
              _fact(context, context.t('breed'), animal.breed),
              _fact(context, context.t('age'), animal.ageLabel),
              _fact(context, context.t('location'), animal.location),
              _fact(context, context.t('healthScore'), '${animal.healthScore} / 100', valueColor: _scoreColor(animal.healthScore)),
              if (animal.pregnant)
                _fact(context, context.t('pregnancyStatus'), 'Confirmed (${animal.pregnancyDays} days)'),
              if (animal.lactating)
                _fact(context, context.t('lactationStatus'), 'Lactating — ${animal.lactationCycle ?? 1}'),
              const Divider(height: 20, color: FarmColors.border),
              _fact(context, context.t('earTag'), animal.tag),
              _fact(context, context.t('internalId'), 'COW-${animal.tag.padLeft(4, '0')}', last: true),
            ],
          ),
        ),
      ],
    );
  }

  Widget _fact(BuildContext context, String label, String value, {Color? valueColor, bool last = false}) {
    return Padding(
      padding: EdgeInsets.only(bottom: last ? 0 : 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: Text(label, style: FarmTypography.textTheme.bodySmall)),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: FarmTypography.textTheme.titleSmall?.copyWith(color: valueColor),
            ),
          ),
        ],
      ),
    );
  }

  Color _scoreColor(int score) {
    if (score >= 80) return FarmColors.success;
    if (score >= 60) return FarmColors.warning;
    return FarmColors.danger;
  }

  FarmIcon _iconForSpecies(AnimalSpecies s) => switch (s) {
        AnimalSpecies.cow => FarmIcon.cow,
        AnimalSpecies.goat => FarmIcon.goat,
        AnimalSpecies.sheep => FarmIcon.sheep,
        AnimalSpecies.horse => FarmIcon.horse,
        AnimalSpecies.layerHen || AnimalSpecies.turkey => FarmIcon.poultry,
        AnimalSpecies.duck => FarmIcon.duck,
      };
}

class _QuickAction {
  const _QuickAction(this.icon, this.labelKey, this.onTap);
  final FarmIcon icon;
  final String labelKey;
  final VoidCallback onTap;
}

class _HistoryColumn extends StatelessWidget {
  const _HistoryColumn({required this.animal, required this.twin, required this.twinLoading, required this.twinError});
  final Animal animal;
  final Map<String, dynamic>? twin;
  final bool twinLoading;
  final String? twinError;

  @override
  Widget build(BuildContext context) {
    final actions = <_QuickAction>[
      _QuickAction(FarmIcon.eye, 'observe', () => showObserveDialog(context, animal.id)),
      _QuickAction(FarmIcon.stethoscope, 'treat', () => showTreatDialog(context, animal)),
      _QuickAction(FarmIcon.feedBag, 'feed', () => showFeedDialog(context, animal)),
      _QuickAction(FarmIcon.milkBottle, 'milk', () => showMilkDialog(context, animal)),
      _QuickAction(FarmIcon.location, 'move', () => showMoveDialog(context, animal)),
      _QuickAction(FarmIcon.calendar, 'viewHistory', () {}),
    ];

    final events = (twin?['recent_events'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
    final observations = (twin?['recent_observations'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
    final treatments = context.watch<AnimalsProvider>().treatmentsFor(animal.id);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LayoutBuilder(builder: (context, c) {
          final perRow = c.maxWidth > 560 ? 6 : 3;
          final w = (c.maxWidth - 8 * (perRow - 1)) / perRow;
          return Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [for (final a in actions) SizedBox(width: w, child: _ActionButton(action: a))],
          );
        }),
        const SizedBox(height: FarmSpacing.md),
        SectionCard(
          title: context.t('lifeHistory'),
          child: Column(
            children: [
              _twinBody(
                context,
                empty: 'No recorded history yet.',
                child: Column(
                  children: [
                    for (final e in events) ...[
                      _TimelineRow(entry: _timelineEntryFor(e)),
                      const Divider(height: 18, color: FarmColors.border),
                    ],
                  ],
                ),
                isEmpty: events.isEmpty,
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(onPressed: () {}, child: Text(context.t('viewFullHistory'))),
              ),
            ],
          ),
        ),
        const SizedBox(height: FarmSpacing.md),
        LayoutBuilder(builder: (context, c) {
          final wide = c.maxWidth > 560;
          final health = SectionCard(
            title: context.t('healthHistory'),
            trailing: context.t('viewAll'),
            child: treatments.isEmpty
                ? Text('No treatments recorded yet.', style: FarmTypography.textTheme.bodySmall)
                : Column(children: [for (final t in treatments) _TreatmentLine(treatment: t)]),
          );
          final observationsCard = SectionCard(
            title: 'Recent Observations',
            trailing: context.t('viewAll'),
            child: _twinBody(
              context,
              empty: 'No observations recorded yet.',
              isEmpty: observations.isEmpty,
              child: Column(children: [for (final o in observations.take(6)) _ObservationLine(obs: o)]),
            ),
          );
          if (!wide) return Column(children: [health, const SizedBox(height: FarmSpacing.md), observationsCard]);
          return IntrinsicHeight(
            child: Row(children: [
              Expanded(child: health),
              const SizedBox(width: FarmSpacing.md),
              Expanded(child: observationsCard),
            ]),
          );
        }),
      ],
    );
  }

  /// Shared loading/error/empty handling for the two sections backed by
  /// the digital-twin fetch (Life History, Recent Observations).
  Widget _twinBody(BuildContext context, {required Widget child, required bool isEmpty, required String empty}) {
    if (twinLoading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(child: SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))),
      );
    }
    if (twinError != null) {
      return Text(twinError!, style: const TextStyle(color: FarmColors.danger, fontSize: 12.5));
    }
    if (isEmpty) {
      return Text(empty, style: FarmTypography.textTheme.bodySmall);
    }
    return child;
  }

  _TimelineEntry _timelineEntryFor(Map<String, dynamic> e) {
    final type = e['event_type'] as String? ?? 'event';
    final payload = (e['payload'] as Map<String, dynamic>?) ?? const {};
    final createdAt = e['created_at'] != null ? DateTime.tryParse(e['created_at'] as String) : null;
    return _TimelineEntry(_iconForEvent(type), _titleForEvent(type), _valueForEvent(type, payload), _whenLabel(createdAt));
  }

  FarmIcon _iconForEvent(String type) => switch (type) {
        'milk_recorded' => FarmIcon.milkBottle,
        'observation_recorded' => FarmIcon.eye,
        'treatment_recorded' => FarmIcon.stethoscope,
        'animal_moved' => FarmIcon.location,
        _ => FarmIcon.calendar,
      };

  String _titleForEvent(String type) => switch (type) {
        'milk_recorded' => 'Milk recorded',
        'observation_recorded' => 'Observation recorded',
        'treatment_recorded' => 'Treatment recorded',
        'animal_moved' => 'Location changed',
        _ => type.replaceAll('_', ' '),
      };

  String _valueForEvent(String type, Map<String, dynamic> payload) => switch (type) {
        'milk_recorded' => '${payload['liters'] ?? '—'} L',
        'animal_moved' => '${payload['location_label'] ?? '—'}',
        'treatment_recorded' => '${payload['medication'] ?? '—'}',
        _ => '',
      };

  String _whenLabel(DateTime? when) {
    if (when == null) return '—';
    final diff = DateTime.now().difference(when);
    if (diff.inDays <= 0) return 'Today';
    if (diff.inDays == 1) return 'Yesterday';
    if (diff.inDays < 7) return '${diff.inDays} days ago';
    return _shortDate(when);
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({required this.action});
  final _QuickAction action;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: FarmColors.card,
      borderRadius: BorderRadius.circular(FarmRadii.sm),
      child: InkWell(
        onTap: action.onTap,
        borderRadius: BorderRadius.circular(FarmRadii.sm),
        child: Container(
          constraints: const BoxConstraints(minHeight: kFarmTouchTarget),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(FarmRadii.sm), border: Border.all(color: FarmColors.border)),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppIcon(action.icon, size: 18, color: FarmColors.cedar),
              const SizedBox(height: 4),
              Text(context.t(action.labelKey), style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
    );
  }
}

class _TimelineEntry {
  const _TimelineEntry(this.icon, this.title, this.value, this.time);
  final FarmIcon icon;
  final String title;
  final String value;
  final String time;
}

class _TimelineRow extends StatelessWidget {
  const _TimelineRow({required this.entry});
  final _TimelineEntry entry;

  @override
  Widget build(BuildContext context) {
    return Row(
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
              Text(entry.time, style: const TextStyle(fontSize: 11, color: FarmColors.muted)),
              Text(entry.title, style: FarmTypography.textTheme.titleSmall),
            ],
          ),
        ),
        Text(entry.value, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
      ],
    );
  }
}

class _TreatmentLine extends StatelessWidget {
  const _TreatmentLine({required this.treatment});
  final TreatmentRecord treatment;

  @override
  Widget build(BuildContext context) {
    final resolved = treatment.status.toLowerCase() != 'active';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Icon(resolved ? Icons.check_circle : Icons.radio_button_unchecked, size: 15, color: resolved ? FarmColors.success : FarmColors.warning),
          const SizedBox(width: 8),
          Expanded(
            child: Text(treatment.diagnosis ?? treatment.medication, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis),
          ),
          Text(treatment.status, style: TextStyle(fontSize: 11, color: resolved ? FarmColors.success : FarmColors.warning)),
          const SizedBox(width: 8),
          Text(_shortDate(treatment.startAt), style: const TextStyle(fontSize: 11, color: FarmColors.muted)),
        ],
      ),
    );
  }
}

class _ObservationLine extends StatelessWidget {
  const _ObservationLine({required this.obs});
  final Map<String, dynamic> obs;

  @override
  Widget build(BuildContext context) {
    final type = ((obs['observation_type'] as String?) ?? 'observation').replaceAll('_', ' ');
    final severity = obs['severity'] as String?;
    final observedAt = obs['observed_at'] != null ? DateTime.tryParse(obs['observed_at'] as String) : null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Icon(Icons.circle, size: 8, color: _severityColor(severity)),
          const SizedBox(width: 8),
          Expanded(child: Text(type, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis)),
          if (severity != null) ...[
            Text(severity, style: TextStyle(fontSize: 11, color: _severityColor(severity))),
            const SizedBox(width: 8),
          ],
          Text(_shortDate(observedAt), style: const TextStyle(fontSize: 11, color: FarmColors.muted)),
        ],
      ),
    );
  }

  Color _severityColor(String? s) => switch (s) {
        'severe' => FarmColors.danger,
        'moderate' => FarmColors.warning,
        _ => FarmColors.muted,
      };
}

class _InsightsColumn extends StatelessWidget {
  const _InsightsColumn({required this.animal, required this.twin, required this.twinLoading});
  final Animal animal;
  final Map<String, dynamic>? twin;
  final bool twinLoading;

  @override
  Widget build(BuildContext context) {
    final milkRecords = context.watch<ProductionProvider>().milkRecords.where((r) => r.animalId == animal.id).toList();
    final recs = (twin?['open_recommendations'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionCard(
          title: context.t('milkTrend'),
          child: milkRecords.isEmpty
              ? Text('No milk records for this animal yet.', style: FarmTypography.textTheme.bodySmall)
              : _MilkTrend(records: milkRecords),
        ),
        const SizedBox(height: FarmSpacing.md),
        SectionCard(
          title: context.t('aiRecommendation'),
          child: twinLoading
              ? const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Center(child: SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))),
                )
              : recs.isEmpty
                  ? Text('No active recommendations for this animal.', style: FarmTypography.textTheme.bodySmall)
                  : _RecommendationSummary(rec: recs.first),
        ),
      ],
    );
  }
}

/// Per-animal milk trend, bucketed client-side from [ProductionProvider]'s
/// already-loaded milk records (the backend has no per-animal trend
/// endpoint — this mirrors [ProductionProvider]'s own day-bucketing).
class _MilkTrend extends StatelessWidget {
  const _MilkTrend({required this.records});
  final List<MilkRecord> records;

  @override
  Widget build(BuildContext context) {
    final last7 = _byDay(7);
    final prev7 = _byDay(14).sublist(0, 7);
    final last7Sum = last7.fold(0.0, (a, b) => a + b);
    final prev7Sum = prev7.fold(0.0, (a, b) => a + b);
    final pctChange = prev7Sum > 0 ? ((last7Sum - prev7Sum) / prev7Sum * 100) : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('${last7Sum.toStringAsFixed(1)} ${context.t('liters')}', style: FarmTypography.textTheme.headlineMedium),
        Text(
          pctChange == null ? 'Last 7 days' : '${pctChange >= 0 ? '+' : ''}${pctChange.toStringAsFixed(1)}% vs previous 7 days',
          style: TextStyle(
            color: pctChange == null ? FarmColors.muted : (pctChange >= 0 ? FarmColors.success : FarmColors.danger),
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        LineTrendChart(values: last7, height: 90, showDots: false),
      ],
    );
  }

  List<double> _byDay(int days) {
    final today = DateTime.now();
    final start = DateTime(today.year, today.month, today.day).subtract(Duration(days: days - 1));
    final buckets = List<double>.filled(days, 0);
    for (final r in records) {
      final d = r.recordedAt;
      final dayIndex = DateTime(d.year, d.month, d.day).difference(start).inDays;
      if (dayIndex >= 0 && dayIndex < days) buckets[dayIndex] += r.liters;
    }
    return buckets;
  }
}

/// Renders one of the animal's `open_recommendations` (from the
/// digital-twin fetch) — a thinner shape than the full [Recommendation]
/// entity (`{id, title, priority, confidence}`, no rationale/evidence),
/// since that's all the backend's per-animal endpoint returns.
class _RecommendationSummary extends StatelessWidget {
  const _RecommendationSummary({required this.rec});
  final Map<String, dynamic> rec;

  @override
  Widget build(BuildContext context) {
    final confidence = (rec['confidence'] as num?)?.toDouble() ?? 0;
    final confidencePct = (confidence * 100).round();
    final priority = (rec['priority'] as String?) ?? 'medium';
    final priorityLabel = priority.isEmpty ? priority : '${priority[0].toUpperCase()}${priority.substring(1)}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Expanded(child: Text((rec['title'] as String?) ?? '', style: FarmTypography.textTheme.titleSmall)),
          StatusPill(label: '$confidencePct%', level: FarmStatusLevel.info, dense: true),
        ]),
        const SizedBox(height: 6),
        Text('Priority: $priorityLabel', style: FarmTypography.textTheme.bodySmall),
      ],
    );
  }
}
