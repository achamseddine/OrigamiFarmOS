import 'package:flutter/material.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/widgets/section_card.dart';
import '../../core/widgets/status_pill.dart';
import '../../domain/entities/pharmacy.dart';
import '../feed/feed_workspace_screen.dart' show feedDate, feedNumber;
import '../navigation/entity_router.dart';

/// The animal's care record on its profile (MEDICINE-PHARMACY-SCHEMA §11,
/// HEALTH-VETERINARY-SCHEMA, CLINICAL-DECISION-SUPPORT §14): the live
/// emergency and the open health case, the withdrawal in force, the
/// doses given — each bound to its lot — the standing conditions the
/// veterinarian recorded, and the latest dated weight. All of it comes
/// with the Digital Twin fetch; nothing here is computed on the tablet.
class AnimalCareSection extends StatelessWidget {
  const AnimalCareSection({super.key, required this.twin, required this.loading});

  final Map<String, dynamic>? twin;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final t = twin;
    final administrations = [
      for (final a in t?['recent_administrations'] as List<dynamic>? ?? const [])
        if (a is Map && a['id'] != null) MedicationAdministration.fromJson(a.cast<String, dynamic>()),
    ];
    final withdrawals = (t?['withdrawals'] as Map?)?.cast<String, dynamic>() ?? const <String, dynamic>{};
    final conditions = [for (final c in t?['active_conditions'] as List<dynamic>? ?? const []) if (c is Map) c.cast<String, dynamic>()];
    final weight = (t?['latest_weight'] as Map?)?.cast<String, dynamic>();
    final openCase = (t?['open_health_case'] as Map?)?.cast<String, dynamic>();
    final emergency = (t?['emergency'] as Map?)?.cast<String, dynamic>();
    final milkUntil = _dt(withdrawals['milk_until']);
    final meatUntil = _dt(withdrawals['meat_until']);
    final recordUntil = _dt(withdrawals['record_until']);
    final withdrawalActive = withdrawals['active'] == true;

    return SectionCard(
      title: context.t('twinCareTitle'),
      subtitle: context.t('twinCareSubtitle'),
      child: loading
          ? const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Center(child: SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))),
            )
          : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (emergency != null) ...[
                InkWell(
                  onTap: () => EntityRouter.openEntityOrExplain(context, 'emergency_assessment', emergency['id'] as String?),
                  borderRadius: BorderRadius.circular(FarmRadii.sm),
                  child: Container(
                    padding: const EdgeInsets.all(FarmSpacing.sm),
                    decoration: BoxDecoration(
                      color: emergency['status'] == 'escalated' ? FarmColors.danger : FarmColors.tint(FarmColors.warning, 0.18),
                      borderRadius: BorderRadius.circular(FarmRadii.sm),
                    ),
                    child: Row(children: [
                      Icon(Icons.emergency_outlined, size: 18, color: emergency['status'] == 'escalated' ? Colors.white : FarmColors.warningInk),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '${context.t('twinEmergencyLive')} · ${context.t('emTriage_${emergency['triage_level'] ?? 'LOW'}')} · ${context.t('emStatus_${emergency['status'] ?? 'open'}')}',
                          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5, color: emergency['status'] == 'escalated' ? Colors.white : FarmColors.ink),
                        ),
                      ),
                      Icon(Icons.chevron_right, size: 18, color: emergency['status'] == 'escalated' ? Colors.white : FarmColors.muted),
                    ]),
                  ),
                ),
                const SizedBox(height: 8),
              ],
              if (openCase != null) ...[
                _line(context, context.t('twinOpenCase'), [openCase['case_code'], openCase['severity_code'], openCase['status']].whereType<String>().join(' · ')),
                const SizedBox(height: 6),
              ],
              if (withdrawalActive)
                Container(
                  padding: const EdgeInsets.all(FarmSpacing.sm),
                  decoration: BoxDecoration(color: FarmColors.tint(FarmColors.danger, 0.12), borderRadius: BorderRadius.circular(FarmRadii.sm)),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    if (milkUntil != null) Text('${context.t('twinWithdrawalMilk')} ${feedDate(milkUntil)}', style: const TextStyle(color: FarmColors.danger, fontSize: 12.5, fontWeight: FontWeight.w700)),
                    if (meatUntil != null) Text('${context.t('twinWithdrawalMeat')} ${feedDate(meatUntil)}', style: const TextStyle(color: FarmColors.danger, fontSize: 12.5, fontWeight: FontWeight.w700)),
                    if (milkUntil == null && meatUntil == null && recordUntil != null)
                      Text('${context.t('phWithdrawal')} ${feedDate(recordUntil)}${withdrawals['reason'] != null ? ' · ${withdrawals['reason']}' : ''}', style: const TextStyle(color: FarmColors.danger, fontSize: 12.5, fontWeight: FontWeight.w700)),
                  ]),
                )
              else
                Text(context.t('twinNoWithdrawal'), style: FarmTypography.textTheme.bodySmall?.copyWith(color: FarmColors.muted)),
              const SizedBox(height: 8),
              if (administrations.isEmpty)
                Text(context.t('twinNoAdministrations'), style: FarmTypography.textTheme.bodySmall)
              else
                for (final a in administrations.take(5)) _AdministrationLine(a: a),
              if (conditions.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(context.t('twinConditions'), style: const TextStyle(fontSize: 11, color: FarmColors.muted, fontWeight: FontWeight.w700, letterSpacing: 0.4)),
                const SizedBox(height: 4),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final c in conditions)
                    StatusPill(
                      label: '${c['label'] ?? c['code']}',
                      level: c['severity'] == 'high' || c['severity'] == 'severe' ? FarmStatusLevel.alert : FarmStatusLevel.watch,
                      dense: true,
                    ),
                ]),
              ],
              if (weight != null) ...[
                const SizedBox(height: 8),
                _line(
                  context,
                  context.t('twinLatestWeight'),
                  '${feedNumber((weight['weight_kg'] as num?)?.toDouble() ?? 0)} kg'
                  '${weight['method'] != null ? ' · ${weight['method']}' : ''}'
                  '${_dt(weight['measured_at']) != null ? ' · ${feedDate(_dt(weight['measured_at'])!)}' : ''}',
                ),
              ],
            ]),
    );
  }

  static DateTime? _dt(Object? v) => v == null ? null : DateTime.tryParse(v.toString());

  Widget _line(BuildContext context, String label, String value) => Row(children: [
        Expanded(child: Text(label, style: FarmTypography.textTheme.bodySmall)),
        Flexible(child: Text(value, textAlign: TextAlign.right, style: FarmTypography.textTheme.titleSmall)),
      ]);
}

class _AdministrationLine extends StatelessWidget {
  const _AdministrationLine({required this.a});
  final MedicationAdministration a;

  @override
  Widget build(BuildContext context) {
    final muted = a.isReversed;
    final style = TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: muted ? FarmColors.muted : FarmColors.ink, decoration: muted ? TextDecoration.lineThrough : null);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        Icon(Icons.vaccines_outlined, size: 15, color: muted ? FarmColors.muted : FarmColors.cedar2),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            '${a.medicineName ?? a.inventoryItemId} · ${feedNumber(a.doseQuantity)} ${a.doseUnit} ${a.routeCode}'
            '${a.headCount != 1 ? ' × ${a.headCount}' : ''}'
            '${a.lotCode != null ? ' · ${context.t('phLot')} ${a.lotCode}' : ''}',
            style: style,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (a.withdrawalMilkUntil != null || a.withdrawalMeatUntil != null)
          Padding(
            padding: const EdgeInsets.only(left: 6),
            child: Text(context.t('phWithdrawal'), style: const TextStyle(fontSize: 11, color: FarmColors.warningInk, fontWeight: FontWeight.w700)),
          ),
        const SizedBox(width: 8),
        Text(a.administeredAt == null ? '—' : feedDate(a.administeredAt!), style: const TextStyle(fontSize: 11, color: FarmColors.muted)),
      ]),
    );
  }
}
