import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/i18n/strings.dart';
import '../../../core/theme/colors.dart';
import '../../../core/theme/spacing.dart';
import '../../../core/theme/typography.dart';
import '../../../core/widgets/app_icon.dart';
import '../../../core/widgets/data_table_card.dart';
import '../../../core/widgets/kpi_card.dart';
import '../../../core/widgets/section_card.dart';
import '../../../core/widgets/status_pill.dart';
import '../../../domain/entities/access.dart';
import '../../../domain/entities/feed_performance.dart';
import '../../../providers/access_provider.dart';
import '../../../providers/feeding_provider.dart';
import '../feed_workspace_screen.dart';

/// Feed performance intelligence (database/FEED-PERFORMANCE-INTELLIGENCE.md):
/// the alerts that are open, what is being watched against which baseline,
/// the score card of every numbered mix and the supplier rows, one per
/// ingredient. Everything on this tab is the server's explanation of
/// facts recorded elsewhere — an association with its evidence and its
/// confidence, never a diagnosis, and nothing here changes a lot, a
/// formula or a supplier's standing.
class PerformanceTab extends StatelessWidget {
  const PerformanceTab({super.key});

  @override
  Widget build(BuildContext context) {
    final feeding = context.watch<FeedingProvider>();
    final access = context.watch<AccessProvider>();
    final canEdit = access.canEdit(FarmModule.feedNutrition);
    final canApprove = access.can(FarmModule.feedNutrition, PermissionAction.approve);
    final summary = feeding.performance;
    final unseen = feeding.unseenPerformanceAlerts.length;

    return FeedTabScaffold(children: [
      LayoutBuilder(builder: (context, c) {
        final perRow = c.maxWidth > 700 ? 4 : 2;
        final w = (c.maxWidth - FarmSpacing.md * (perRow - 1)) / perRow;
        final cards = [
          KpiCard(
            icon: FarmIcon.bell,
            label: context.t('perfOpenAlerts'),
            value: '${feeding.performanceAlerts.length}',
            caption: unseen == 0 ? null : '$unseen ${context.t('unreadNotifications')}',
            accent: feeding.performanceAlerts.isEmpty ? FarmColors.olive : FarmColors.danger,
          ),
          KpiCard(icon: FarmIcon.chartLine, label: context.t('perfMonitors'), value: '${summary.monitors}', accent: FarmColors.cedar2),
          KpiCard(icon: FarmIcon.inventory, label: context.t('perfMixesScored'), value: '${summary.batchesScored}', accent: FarmColors.gold),
          KpiCard(
            icon: FarmIcon.calendar,
            label: context.t('perfLastEvaluated'),
            value: summary.lastEvaluatedAt == null ? context.t('perfNeverEvaluated') : feedDate(summary.lastEvaluatedAt!),
            caption: summary.modelReference.isEmpty ? null : '${context.t('perfModel')} ${summary.modelVersion}',
            accent: FarmColors.cedar,
          ),
        ];
        return Wrap(spacing: FarmSpacing.md, runSpacing: FarmSpacing.md, children: [for (final k in cards) SizedBox(width: w, child: k)]);
      }),
      SectionCard(
        title: context.t('perfAlertsTitle'),
        subtitle: context.t('perfAlertsSubtitle'),
        trailing: canEdit ? context.t('perfEvaluateNow') : null,
        onTrailingTap: canEdit ? () => _evaluate(context) : null,
        child: feeding.performanceAlerts.isEmpty
            ? const FeedEmpty('perfNoAlerts')
            : Column(children: [
                for (final a in feeding.performanceAlerts)
                  _AlertCard(alert: a, canAcknowledge: canEdit && a.isOpen, canResolve: canApprove && !a.isResolved),
              ]),
      ),
      SectionCard(
        title: context.t('perfMonitorsTitle'),
        subtitle: context.t('perfMonitorsSubtitle'),
        child: feeding.monitors.isEmpty
            ? const FeedEmpty('perfNoMonitors')
            : FarmDataTable(
                columns: [context.t('animalOrGroup'), context.t('perfMetric'), context.t('perfBaseline'), context.t('perfObserved'), context.t('perfVariance'), context.t('status')],
                columnFlex: const [3, 2, 2, 2, 2, 3],
                rowHeight: 56,
                rows: [
                  for (final m in feeding.monitors)
                    [
                      Text(m.subjectName ?? m.subjectId, style: FarmTypography.textTheme.titleSmall, overflow: TextOverflow.ellipsis),
                      Text(_metricLabel(context, m.metric), style: FarmTypography.textTheme.bodySmall),
                      Text(_value(m.latest?.baselineValue), style: FarmTypography.textTheme.bodySmall),
                      Text(_value(m.latest?.observedValue), style: FarmTypography.textTheme.bodyMedium),
                      Text(_pctChange(m.latest?.variancePercent),
                          style: FarmTypography.textTheme.titleSmall?.copyWith(color: _changeColor(m.latest?.variancePercent, m.thresholdPercent))),
                      _AssessmentPill(m.latest),
                    ],
                ],
              ),
      ),
      SectionCard(
        title: context.t('perfMixScoresTitle'),
        subtitle: context.t('perfMixScoresSubtitle'),
        child: feeding.batchScores.isEmpty
            ? const FeedEmpty('perfNoMixScores')
            : FarmDataTable(
                columns: [
                  context.t('mixCode'), context.t('perfOverall'), context.t('perfCompliance'), context.t('perfIntake'),
                  context.t('perfProduction'), context.t('perfHealth'), context.t('perfConfidence'),
                ],
                columnFlex: const [3, 2, 2, 2, 2, 2, 2],
                rows: [
                  for (final s in feeding.batchScores)
                    [
                      Row(children: [
                        Flexible(child: Text(s.mixCode ?? '#${s.mixNumber}', style: FarmTypography.textTheme.titleSmall, overflow: TextOverflow.ellipsis)),
                        if (s.openAlerts.isNotEmpty) ...[
                          const SizedBox(width: 6),
                          StatusPill(label: '${s.openAlerts.length}', level: FarmStatusLevel.alert, dense: true),
                        ],
                      ]),
                      Text(_score(s.overall), style: FarmTypography.textTheme.titleSmall?.copyWith(color: _scoreColor(s.overall))),
                      Text(_score(s.formulaCompliance), style: FarmTypography.textTheme.bodySmall),
                      Text(_score(s.intakeResponse), style: FarmTypography.textTheme.bodySmall),
                      Text(_score(s.productionResponse), style: FarmTypography.textTheme.bodySmall),
                      Text(_score(s.healthSignal), style: FarmTypography.textTheme.bodySmall),
                      Text(_score(s.confidence), style: FarmTypography.textTheme.bodySmall),
                    ],
                ],
              ),
      ),
      SectionCard(
        title: context.t('perfSuppliersTitle'),
        subtitle: context.t('perfSuppliersSubtitle'),
        child: feeding.supplierScores.isEmpty
            ? const FeedEmpty('perfNoSuppliers')
            : FarmDataTable(
                columns: [
                  context.t('supplier'), context.t('feed'), context.t('perfLots'), context.t('batches'), context.t('unitCost'),
                  context.t('perfDownstream'), context.t('perfIncidents'), context.t('perfConfidence'),
                ],
                columnFlex: const [3, 3, 1, 1, 2, 2, 1, 2],
                rows: [
                  for (final s in feeding.supplierScores)
                    [
                      Text(s.supplierLabel, style: FarmTypography.textTheme.titleSmall, overflow: TextOverflow.ellipsis),
                      Text(s.productName ?? s.feedProductId, style: FarmTypography.textTheme.bodySmall, overflow: TextOverflow.ellipsis),
                      Text('${s.lotCount}'),
                      Text('${s.feedBatchCount ?? 0}'),
                      Text(s.averageUnitCost == null ? '—' : '\$${s.averageUnitCost!.toStringAsFixed(3)}/${s.unit ?? 'kg'}', style: FarmTypography.textTheme.bodySmall),
                      Text(_score(s.downstreamPerformance), style: FarmTypography.textTheme.bodySmall),
                      Text('${s.incidentCount}', style: FarmTypography.textTheme.bodySmall?.copyWith(color: s.incidentCount > 0 ? FarmColors.danger : null)),
                      Text(_score(s.confidence), style: FarmTypography.textTheme.bodySmall),
                    ],
                ],
              ),
      ),
    ]);
  }

  Future<void> _evaluate(BuildContext context) async {
    final feeding = context.read<FeedingProvider>();
    final messenger = ScaffoldMessenger.of(context);
    final done = context.t('perfEvaluated');
    final queued = context.t('workingOffline');
    final failed = context.t('couldNotSave');
    final result = await feeding.evaluatePerformance();
    if (result.success) {
      messenger.showSnackBar(SnackBar(content: Text(result.queued ? queued : done)));
    } else {
      messenger.showSnackBar(SnackBar(content: Text(result.error ?? failed)));
    }
  }
}

String _metricLabel(BuildContext context, String metric) => context.t('perfMetric_$metric');

String _value(double? v) => v == null ? '—' : v.toStringAsFixed(v >= 100 ? 0 : 2);

String _pctChange(double? v) => v == null ? '—' : '${v > 0 ? '+' : ''}${v.toStringAsFixed(1)}%';

Color? _changeColor(double? v, double threshold) {
  if (v == null) return null;
  if (v <= -threshold) return FarmColors.danger;
  if (v >= threshold) return FarmColors.olive;
  return null;
}

/// A 0–1 score as a percentage; null stays blank — it was not measured.
String _score(double? v) => v == null ? '—' : '${(v * 100).round()}%';

Color? _scoreColor(double? v) {
  if (v == null) return FarmColors.muted;
  if (v < 0.5) return FarmColors.danger;
  if (v < 0.75) return FarmColors.warningInk;
  return FarmColors.olive;
}

FarmStatusLevel _severityLevel(String severity) => switch (severity) {
      'critical' || 'high' => FarmStatusLevel.alert,
      'medium' => FarmStatusLevel.watch,
      'info' => FarmStatusLevel.good,
      _ => FarmStatusLevel.info,
    };

class _AssessmentPill extends StatelessWidget {
  const _AssessmentPill(this.assessment);
  final FeedPerformanceAssessment? assessment;

  @override
  Widget build(BuildContext context) {
    final a = assessment;
    if (a == null) return StatusPill(label: context.t('perfNeverEvaluated'), level: FarmStatusLevel.neutral, dense: true);
    final level = a.isAnomaly ? FarmStatusLevel.alert : (a.isInsufficient ? FarmStatusLevel.neutral : FarmStatusLevel.good);
    return Tooltip(
      message: a.explanation,
      child: StatusPill(
        label: a.isAnomaly ? '${context.t('perfStatus_anomaly')} · ${context.t('perfLikelihood_${a.likelihood}')}' : context.t('perfStatus_${a.status}'),
        level: level,
        dense: true,
      ),
    );
  }
}

/// One alert: what it is, how sure the model is, the whole explanation,
/// and the two things a person can do — see it, or close it with a reason.
class _AlertCard extends StatelessWidget {
  const _AlertCard({required this.alert, required this.canAcknowledge, required this.canResolve});
  final FeedPerformanceAlert alert;
  final bool canAcknowledge;
  final bool canResolve;

  @override
  Widget build(BuildContext context) {
    final a = alert;
    final where = [if (a.mixCode != null) a.mixCode!, if (a.subjectName != null) a.subjectName!, if (a.productName != null && a.mixCode == null) a.productName!].join(' · ');
    return Container(
      margin: const EdgeInsets.only(bottom: FarmSpacing.sm),
      padding: const EdgeInsets.all(FarmSpacing.md),
      decoration: BoxDecoration(
        color: a.isOpen ? FarmColors.sand : FarmColors.white,
        borderRadius: BorderRadius.circular(FarmRadii.md),
        border: Border.all(color: FarmColors.mist),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(a.title, style: FarmTypography.textTheme.titleSmall),
              const SizedBox(height: 2),
              Text(
                [context.t('perfAlert_${a.alertType}'), if (where.isNotEmpty) where, if (a.detectedAt != null) feedDate(a.detectedAt!)].join(' · '),
                style: FarmTypography.textTheme.bodySmall?.copyWith(color: FarmColors.muted),
              ),
            ]),
          ),
          const SizedBox(width: 8),
          StatusPill(label: context.t('perfSeverity_${a.severity}'), level: _severityLevel(a.severity), dense: true),
          if (a.status == 'acknowledged') ...[
            const SizedBox(width: 6),
            StatusPill(label: context.t('perfAcknowledged'), level: FarmStatusLevel.info, dense: true),
          ],
        ]),
        const SizedBox(height: 8),
        Text(a.explanation, style: FarmTypography.textTheme.bodySmall),
        if (a.confidence != null) ...[
          const SizedBox(height: 6),
          Row(children: [
            Text('${context.t('perfConfidence')} ', style: FarmTypography.textTheme.bodySmall?.copyWith(color: FarmColors.muted)),
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(value: a.confidence!.clamp(0, 1), minHeight: 6, backgroundColor: FarmColors.mist, color: FarmColors.cedar2),
              ),
            ),
            const SizedBox(width: 8),
            Text(_score(a.confidence), style: FarmTypography.textTheme.bodySmall),
          ]),
        ],
        if (canAcknowledge || canResolve) ...[
          const SizedBox(height: 6),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            if (canAcknowledge)
              TextButton(onPressed: () => _acknowledge(context), child: Text(context.t('perfAcknowledge'))),
            if (canResolve)
              TextButton(onPressed: () => _resolve(context), child: Text(context.t('perfResolve'))),
          ]),
        ],
      ]),
    );
  }

  Future<void> _acknowledge(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final savedOffline = context.t('workingOffline');
    final failed = context.t('couldNotSave');
    final result = await context.read<FeedingProvider>().acknowledgePerformanceAlert(alert.id);
    if (!result.success) {
      messenger.showSnackBar(SnackBar(content: Text(result.error ?? failed)));
    } else if (result.queued) {
      messenger.showSnackBar(SnackBar(content: Text(savedOffline)));
    }
  }

  Future<void> _resolve(BuildContext context) async {
    final controller = TextEditingController();
    final note = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(context.t('perfResolve')),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 3,
          decoration: InputDecoration(labelText: context.t('perfResolveReason')),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(context.t('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, controller.text.trim()), child: Text(context.t('save'))),
        ],
      ),
    );
    if (note == null || note.isEmpty || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final savedOffline = context.t('workingOffline');
    final failed = context.t('couldNotSave');
    final result = await context.read<FeedingProvider>().resolvePerformanceAlert(alert.id, note);
    if (!result.success) {
      messenger.showSnackBar(SnackBar(content: Text(result.error ?? failed)));
    } else if (result.queued) {
      messenger.showSnackBar(SnackBar(content: Text(savedOffline)));
    }
  }
}
