import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/i18n/strings.dart';
import '../../../core/theme/colors.dart';
import '../../../core/theme/spacing.dart';
import '../../../core/theme/typography.dart';
import '../../../core/widgets/status_pill.dart';
import '../../../domain/entities/feeding.dart';
import '../../../providers/feeding_provider.dart';
import '../../../providers/livestock_provider.dart';
import '../feed_workspace_screen.dart';

/// "Mix 0042 — what was in it, who received it, when, how much remains?"
/// (FEED-SCHEMA §20). One screen over `GET /feed-batches/{id}/usage`: the
/// recipe and the lots behind each ingredient, the output lot, every dated
/// issue to an animal or group, waste and corrections, and the remainder,
/// which is the lot's ledger balance and nothing the mix stores itself.
Future<void> showMixDetailSheet(BuildContext context, FeedBatch batch) => showDialog<void>(
      context: context,
      builder: (_) => _MixDetailDialog(batch: batch),
    );

class _MixDetailDialog extends StatefulWidget {
  const _MixDetailDialog({required this.batch});
  final FeedBatch batch;

  @override
  State<_MixDetailDialog> createState() => _MixDetailDialogState();
}

class _MixDetailDialogState extends State<_MixDetailDialog> {
  late final Future<MixUsage?> _usage = context.read<FeedingProvider>().mixUsage(widget.batch.id);

  @override
  Widget build(BuildContext context) {
    final lang = Localizations.localeOf(context).languageCode;
    final livestock = context.watch<LivestockProvider>();
    return AlertDialog(
      title: Row(children: [
        Expanded(child: Text('${widget.batch.label} · ${widget.batch.productName ?? ''}', style: FarmTypography.textTheme.titleMedium)),
        StatusPill(label: context.t('batch_${widget.batch.status}'), level: feedStatusLevel(widget.batch.status), dense: true),
      ]),
      content: SizedBox(
        width: 640,
        child: FutureBuilder<MixUsage?>(
          future: _usage,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Padding(padding: EdgeInsets.all(24), child: Center(child: SizedBox(height: 22, width: 22, child: CircularProgressIndicator(strokeWidth: 2))));
            }
            final u = snap.data;
            if (u == null) return const FeedEmpty('mixUsageUnavailable');
            return SingleChildScrollView(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                _Section(context.t('mixIdentity')),
                FeedKeyValue(context.t('mixCode'), u.mixCode, bold: true),
                if (u.formulaCode != null) FeedKeyValue(context.t('formula'), '${u.formulaName ?? u.formulaCode} · v${u.formulaVersion}'),
                FeedKeyValue(context.t('intendedFor'), [
                  if (u.intendedSpeciesCode != null) livestock.speciesName(u.intendedSpeciesCode!, lang),
                  if (u.intendedManagementProfile != null) u.intendedManagementProfile!,
                ].join(' · ').isEmpty ? context.t('anySpecies') : [
                  if (u.intendedSpeciesCode != null) livestock.speciesName(u.intendedSpeciesCode!, lang),
                  if (u.intendedManagementProfile != null) u.intendedManagementProfile!,
                ].join(' · ')),
                if (u.productionDate != null) FeedKeyValue(context.t('productionDate'), feedDate(u.productionDate!)),
                if (u.useByDate != null) FeedKeyValue(context.t('useBy'), feedDate(u.useByDate!)),
                if (u.operatorName != null) FeedKeyValue(context.t('operator'), u.operatorName!),
                if (u.mixerAssetId != null) FeedKeyValue(context.t('mixer'), u.mixerAssetId!),
                if (u.outputLot != null) FeedKeyValue(context.t('lotCode'), '${u.outputLot!['lot_code']} · ${context.t('lotStatus_${u.outputLot!['status']}')}'),

                _Section(context.t('quantities')),
                FeedKeyValue(context.t('producedQuantity'), '${feedNumber(u.producedQuantity)} ${u.unit}'),
                FeedKeyValue(context.t('issuedQuantity'), '${feedNumber(u.issuedQuantity)} ${u.unit}'),
                FeedKeyValue(context.t('consumedEstimate'), u.consumedEstimate == null ? '—' : '${feedNumber(u.consumedEstimate!)} ${u.unit}'),
                if (u.refusedQuantity > 0) FeedKeyValue(context.t('refusedQuantity'), '${feedNumber(u.refusedQuantity)} ${u.unit}'),
                if (u.wasteQuantity > 0) FeedKeyValue(context.t('waste'), '${feedNumber(u.wasteQuantity)} ${u.unit}'),
                if (u.otherIssuedQuantity > 0) FeedKeyValue(context.t('otherIssued'), '${feedNumber(u.otherIssuedQuantity)} ${u.unit}'),
                if (u.returnedQuantity > 0) FeedKeyValue(context.t('returned'), '${feedNumber(u.returnedQuantity)} ${u.unit}'),
                FeedKeyValue(context.t('remainingQuantity'), '${feedNumber(u.remainingQuantity)} ${u.unit}', bold: true),
                if (u.eligibleRemainingQuantity != u.remainingQuantity)
                  FeedKeyValue(context.t('eligibleRemaining'), '${feedNumber(u.eligibleRemainingQuantity)} ${u.unit}', valueColor: FarmColors.danger),
                if (u.firstUseAt != null) FeedKeyValue(context.t('firstUse'), feedDate(u.firstUseAt!)),
                if (u.lastUseAt != null) FeedKeyValue(context.t('lastUse'), feedDate(u.lastUseAt!)),
                FeedKeyValue(context.t('daysUsed'), '${u.daysUsed}'),
                FeedKeyValue(context.t('headDays'), '${u.headDays}'),
                if (u.costPerUnit != null) FeedKeyValue(context.t('unitCost'), '\$${u.costPerUnit!.toStringAsFixed(3)}/${u.unit}'),
                if (u.actualCost != null) FeedKeyValue(context.t('actualCost'), feedMoney(u.actualCost!)),
                if (u.worstVariancePct != null)
                  FeedKeyValue(context.t('worstVariance'), '${u.worstVariancePct!.toStringAsFixed(1)}%', valueColor: u.worstVariancePct!.abs() > 5 ? FarmColors.warningInk : null),

                if (u.performance != null) ...[
                  // The cycle's score card (FEED-PERFORMANCE-INTELLIGENCE §7):
                  // explanatory, and blank where there is no evidence.
                  _Section(context.t('feedTabPerformance')),
                  FeedKeyValue(context.t('perfOverall'), _score(u.performance!['overall_score']), bold: true),
                  FeedKeyValue(context.t('perfCompliance'), _score(u.performance!['formula_compliance_score'])),
                  FeedKeyValue(context.t('perfIntake'), _score(u.performance!['intake_response_score'])),
                  FeedKeyValue(context.t('perfProduction'), _score(u.performance!['production_response_score'])),
                  FeedKeyValue(context.t('perfHealth'), _score(u.performance!['health_signal_score'])),
                  FeedKeyValue(context.t('perfConfidence'), _score(u.performance!['confidence_score'])),
                  for (final a in (u.performance!['open_alerts'] as List<dynamic>? ?? const []))
                    FeedKeyValue(context.t('perfAlert_${(a as Map<String, dynamic>)['alert_type']}'), a['title'] as String? ?? '', valueColor: FarmColors.danger),
                ],

                _Section(context.t('components')),
                for (final c in u.components)
                  FeedKeyValue(
                    [c['product_name'] ?? c['feed_product_id'], if (c['lot_code'] != null) c['lot_code'], if (c['supplier_label'] != null) c['supplier_label']].join(' · '),
                    '${c['target_quantity'] == null ? '' : '${feedNumber(_num(c['target_quantity']))} → '}${feedNumber(_num(c['actual_quantity']))} ${c['unit'] ?? u.unit}',
                  ),

                _Section(context.t('issues')),
                if (u.issues.isEmpty) const FeedEmpty('noIssuesYet'),
                for (final i in u.issues)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      SizedBox(width: 74, child: Text(feedDate(DateTime.tryParse(i['occurred_at'] as String? ?? '') ?? DateTime.now()), style: FarmTypography.textTheme.bodySmall)),
                      Expanded(
                        child: Text(
                          [
                            i['subject_name'] ?? i['subject_id'],
                            if (i['head_count'] != null && i['subject_type'] == 'group') '${i['head_count']} ${context.t('headCount').toLowerCase()}',
                            context.t('event_${i['event_type']}'),
                            if (i['recorded_by_name'] != null) i['recorded_by_name'],
                          ].join(' · '),
                          style: FarmTypography.textTheme.bodySmall?.copyWith(decoration: i['status'] == 'reversed' ? TextDecoration.lineThrough : null),
                        ),
                      ),
                      Text('${feedNumber(_num(i['quantity_offered']))} ${i['unit'] ?? u.unit}', style: FarmTypography.textTheme.bodyMedium),
                    ]),
                  ),

                if (u.ledgerAdjustments.isNotEmpty) ...[
                  _Section(context.t('ledgerAdjustments')),
                  for (final a in u.ledgerAdjustments)
                    FeedKeyValue('${feedDate(DateTime.tryParse(a['occurred_at'] as String? ?? '') ?? DateTime.now())} · ${a['reason']}',
                        '${a['direction'] == 'out' ? '−' : '+'}${feedNumber(_num(a['quantity']))} ${u.unit}'),
                ],

                if (u.exposedSubjects.isNotEmpty) ...[
                  _Section(context.t('exposedSubjects')),
                  for (final s in u.exposedSubjects)
                    FeedKeyValue('${s['name'] ?? s['subject_id']} · ${livestock.speciesName(s['species'] as String? ?? '', lang)}',
                        '${feedNumber(_num(s['quantity']))} ${u.unit} · ${s['events']} ${context.t('feedings')}'),
                ],
                if (u.notes != null) ...[const SizedBox(height: 8), Text(u.notes!, style: FarmTypography.textTheme.bodySmall)],
              ]),
            );
          },
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(context.t('close')))],
    );
  }

  static double _num(Object? v) => (v as num?)?.toDouble() ?? 0;

  /// A 0–1 score as a percentage; null stays blank — it was not measured.
  static String _score(Object? v) => v == null ? '—' : '${((v as num).toDouble() * 100).round()}%';
}

class _Section extends StatelessWidget {
  const _Section(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: FarmSpacing.md, bottom: 2),
        child: Text(text.toUpperCase(), style: const TextStyle(fontSize: 11, color: FarmColors.muted, fontWeight: FontWeight.w700, letterSpacing: 0.4)),
      );
}
