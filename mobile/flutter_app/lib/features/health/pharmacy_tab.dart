import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/widgets/app_icon.dart';
import '../../core/widgets/data_table_card.dart';
import '../../core/widgets/kpi_card.dart';
import '../../core/widgets/section_card.dart';
import '../../core/widgets/status_pill.dart';
import '../../domain/entities/access.dart';
import '../../domain/entities/pharmacy.dart';
import '../../providers/access_provider.dart';
import '../../providers/animals_provider.dart';
import '../../providers/livestock_provider.dart';
import '../../providers/pharmacy_provider.dart';
import '../feed/feed_workspace_screen.dart' show FeedEmpty, FeedKeyValue, feedDate, feedNumber;

/// The farm pharmacy (database/MEDICINE-PHARMACY-SCHEMA.md §10): what the
/// farm owns, what is *eligible* to use, the manager's own thresholds,
/// the alerts those produce and the doses given from exact lots. Stock
/// here is a logistics picture — a low fever-support shelf says nothing
/// about treating an animal with a fever, and stocking a medicine never
/// authorises its use.
class PharmacyTab extends StatelessWidget {
  const PharmacyTab({super.key});

  @override
  Widget build(BuildContext context) {
    final pharmacy = context.watch<PharmacyProvider>();
    final access = context.watch<AccessProvider>();
    final canStock = access.canCreate(FarmModule.inventory) || access.canEdit(FarmModule.inventory);
    final canEditStock = access.canEdit(FarmModule.inventory);
    final canConfigure = access.can(FarmModule.inventory, PermissionAction.configure) || canEditStock;
    final canApprove = access.can(FarmModule.inventory, PermissionAction.approve);
    final canAdminister = access.canCreate(FarmModule.animalHealth);
    final s = pharmacy.summary;

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      LayoutBuilder(builder: (context, c) {
        final perRow = c.maxWidth > 700 ? 4 : 2;
        final w = (c.maxWidth - FarmSpacing.md * (perRow - 1)) / perRow;
        final cards = [
          KpiCard(icon: FarmIcon.medicine, label: context.t('phEssential'), value: '${s.essential}', caption: '${s.medicines} ${context.t('phMedicines').toLowerCase()}', accent: FarmColors.cedar2),
          KpiCard(icon: FarmIcon.inventory, label: context.t('phShort'), value: '${s.short}', accent: s.short > 0 ? FarmColors.danger : FarmColors.olive),
          KpiCard(icon: FarmIcon.bell, label: context.t('phOpenAlerts'), value: '${s.openAlerts}', caption: s.unseenAlerts == 0 ? null : '${s.unseenAlerts} ${context.t('unreadNotifications')}',
              accent: s.openAlerts > 0 ? FarmColors.warningInk : FarmColors.olive),
          KpiCard(icon: FarmIcon.calendar, label: context.t('phExpiringSoon'), value: '${s.expiringSoon}', caption: s.storageExceptions == 0 ? null : '${s.storageExceptions} ${context.t('phAlert_STORAGE_EXCEPTION').toLowerCase()}', accent: FarmColors.gold),
        ];
        return Wrap(spacing: FarmSpacing.md, runSpacing: FarmSpacing.md, children: [for (final k in cards) SizedBox(width: w, child: k)]);
      }),
      const SizedBox(height: FarmSpacing.md),
      Wrap(spacing: 8, runSpacing: 8, children: [
        if (canStock) FilledButton.icon(onPressed: () => showReceiveMedicineDialog(context), icon: const Icon(Icons.add, size: 18), label: Text(context.t('phReceive'))),
        if (canAdminister) OutlinedButton.icon(onPressed: () => showAdministerDialog(context), icon: const Icon(Icons.vaccines_outlined, size: 18), label: Text(context.t('phAdminister'))),
        if (canStock) TextButton.icon(onPressed: () => _scan(context), icon: const Icon(Icons.refresh, size: 18), label: Text(context.t('phScanNow'))),
      ]),
      const SizedBox(height: FarmSpacing.md),
      SectionCard(
        title: context.t('phAlertsTitle'),
        subtitle: context.t('phAlertsSubtitle'),
        child: pharmacy.alerts.isEmpty
            ? const FeedEmpty('phNoAlerts')
            : Column(children: [
                for (final a in pharmacy.alerts)
                  _AlertCard(alert: a, canAcknowledge: canStock && a.isOpen, canRequisition: canStock && a.isShortage && a.requisitionTaskId == null, canResolve: canApprove && !a.isResolved),
              ]),
      ),
      const SizedBox(height: FarmSpacing.md),
      SectionCard(
        title: context.t('phDashboardTitle'),
        subtitle: context.t('phDashboardSubtitle'),
        child: pharmacy.medicines.isEmpty
            ? const FeedEmpty('phNoMedicines')
            : FarmDataTable(
                columns: [context.t('phMedicine'), context.t('phEligible'), context.t('phMinCritTarget'), context.t('lots'), context.t('phEarliestExpiry'), context.t('status'), ''],
                columnFlex: const [4, 2, 3, 1, 2, 2, 1],
                rowHeight: 58,
                rows: [
                  for (final m in pharmacy.medicines)
                    [
                      _MedicineCell(m),
                      Text('${feedNumber(m.eligibleAvailable)} / ${feedNumber(m.onHand)} ${m.unit}',
                          style: FarmTypography.textTheme.titleSmall?.copyWith(color: m.eligibleAvailable < m.onHand ? FarmColors.warningInk : null)),
                      Text(m.policy == null ? context.t('phNoPolicy') : '${_n(m.policy!.minimum)} / ${_n(m.policy!.critical)} / ${_n(m.policy!.target)}', style: FarmTypography.textTheme.bodySmall),
                      Text('${m.lotCount}'),
                      Text(m.earliestExpiry == null ? '—' : feedDate(m.earliestExpiry!),
                          style: FarmTypography.textTheme.bodySmall?.copyWith(color: m.expiringQuantity > 0 ? FarmColors.warningInk : null)),
                      Row(children: [
                        StatusPill(label: context.t('phStatus_${m.status}'), level: _statusLevel(m.status), dense: true),
                        if (m.storageException) ...[const SizedBox(width: 4), const Icon(Icons.ac_unit, size: 14, color: FarmColors.danger)],
                      ]),
                      PopupMenuButton<String>(
                        tooltip: context.t('phDetails'),
                        onSelected: (v) {
                          switch (v) {
                            case 'detail':
                              showMedicineDetailDialog(context, m.inventoryItemId);
                            case 'receive':
                              showReceiveMedicineDialog(context, medicineId: m.inventoryItemId);
                            case 'administer':
                              showAdministerDialog(context, medicineId: m.inventoryItemId);
                            case 'policy':
                              showPolicyDialog(context, m);
                          }
                        },
                        itemBuilder: (_) => [
                          PopupMenuItem(value: 'detail', child: Text(context.t('phDetails'))),
                          if (canStock) PopupMenuItem(value: 'receive', child: Text(context.t('phReceive'))),
                          if (canAdminister) PopupMenuItem(value: 'administer', child: Text(context.t('phAdminister'))),
                          if (canConfigure) PopupMenuItem(value: 'policy', child: Text(context.t('phSetPolicy'))),
                        ],
                      ),
                    ],
                ],
              ),
      ),
      const SizedBox(height: FarmSpacing.md),
      SectionCard(
        title: context.t('phAdministrationsTitle'),
        child: pharmacy.administrations.isEmpty
            ? const FeedEmpty('phNoAdministrations')
            : Column(children: [for (final a in pharmacy.administrations.take(12)) _AdministrationRow(a, canReverse: access.canEdit(FarmModule.animalHealth) && !a.isReversed)]),
      ),
    ]);
  }

  Future<void> _scan(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final done = context.t('phScanned');
    final queued = context.t('workingOffline');
    final failed = context.t('couldNotSave');
    final result = await context.read<PharmacyProvider>().evaluate();
    messenger.showSnackBar(SnackBar(content: Text(result.success ? (result.queued ? queued : done) : (result.error ?? failed))));
  }
}

String _n(double? v) => v == null ? '—' : feedNumber(v);

FarmStatusLevel _statusLevel(String status) => switch (status) {
      'OK' => FarmStatusLevel.good,
      'LOW' => FarmStatusLevel.watch,
      'CRITICAL' || 'OUT' => FarmStatusLevel.alert,
      _ => FarmStatusLevel.neutral,
    };

FarmStatusLevel _severityLevel(String severity) => switch (severity) {
      'critical' || 'high' => FarmStatusLevel.alert,
      'medium' => FarmStatusLevel.watch,
      _ => FarmStatusLevel.info,
    };

void _toast(BuildContext context, ScaffoldMessengerState messenger, dynamic result, String done) {
  final text = result.success ? (result.queued ? context.t('workingOffline') : done) : (result.error ?? context.t('couldNotSave'));
  messenger.showSnackBar(SnackBar(content: Text(text)));
}

class _MedicineCell extends StatelessWidget {
  const _MedicineCell(this.m);
  final Medicine m;

  @override
  Widget build(BuildContext context) {
    final lang = Localizations.localeOf(context).languageCode;
    final pharmacy = context.read<PharmacyProvider>();
    final cats = [for (final code in m.categoryCodes) pharmacy.categories.where((c) => c.code == code).map((c) => c.label(lang)).firstOrNull ?? code];
    return InkWell(
      onTap: () => showMedicineDetailDialog(context, m.inventoryItemId),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          Flexible(child: Text(m.name, style: FarmTypography.textTheme.titleSmall, overflow: TextOverflow.ellipsis)),
          if (m.prescriptionRequired) ...[const SizedBox(width: 6), StatusPill(label: context.t('phPrescriptionOnly'), level: FarmStatusLevel.info, dense: true)],
          if (m.essential) ...[const SizedBox(width: 4), const Icon(Icons.star, size: 14, color: FarmColors.gold)],
        ]),
        Text(cats.join(' · '), style: FarmTypography.textTheme.bodySmall?.copyWith(color: FarmColors.muted), overflow: TextOverflow.ellipsis),
      ]),
    );
  }
}

/// One alert: what it is, the figures behind it, and what a person can
/// do — see it, open a draft requisition, or close it with a reason.
class _AlertCard extends StatelessWidget {
  const _AlertCard({required this.alert, required this.canAcknowledge, required this.canRequisition, required this.canResolve});
  final PharmacyAlert alert;
  final bool canAcknowledge;
  final bool canRequisition;
  final bool canResolve;

  @override
  Widget build(BuildContext context) {
    final a = alert;
    return Container(
      margin: const EdgeInsets.only(bottom: FarmSpacing.sm),
      padding: const EdgeInsets.all(FarmSpacing.md),
      decoration: BoxDecoration(color: a.isOpen ? FarmColors.sand : FarmColors.white, borderRadius: BorderRadius.circular(FarmRadii.md), border: Border.all(color: FarmColors.mist)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${a.medicineName ?? ''} — ${context.t('phAlert_${a.alertType}')}', style: FarmTypography.textTheme.titleSmall),
              const SizedBox(height: 2),
              Text(
                [
                  if (a.eligible != null) '${context.t('phEligible')} ${feedNumber(a.eligible!)} ${a.unit ?? ''}',
                  if (a.minimum != null) '${context.t('phMinimum').toLowerCase()} ${feedNumber(a.minimum!)}',
                  if (a.recommendedReorder != null && a.recommendedReorder! > 0) '${context.t('phRecommendedReorder').toLowerCase()} ${feedNumber(a.recommendedReorder!)} ${a.unit ?? ''}',
                  if (a.earliestExpiry != null) '${context.t('phEarliestExpiry').toLowerCase()} ${feedDate(a.earliestExpiry!)}',
                  if (a.detectedAt != null) feedDate(a.detectedAt!),
                ].join(' · '),
                style: FarmTypography.textTheme.bodySmall?.copyWith(color: FarmColors.muted),
              ),
            ]),
          ),
          const SizedBox(width: 8),
          StatusPill(label: context.t('perfSeverity_${a.severity}'), level: _severityLevel(a.severity), dense: true),
          if (a.status == 'acknowledged') ...[const SizedBox(width: 6), StatusPill(label: context.t('perfAcknowledged'), level: FarmStatusLevel.info, dense: true)],
          if (a.requisitionTaskId != null) ...[const SizedBox(width: 6), StatusPill(label: context.t('phRequisitionOpen'), level: FarmStatusLevel.good, dense: true)],
        ]),
        const SizedBox(height: 8),
        Text(a.explanation, style: FarmTypography.textTheme.bodySmall),
        if (canAcknowledge || canRequisition || canResolve) ...[
          const SizedBox(height: 6),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            if (canAcknowledge) TextButton(onPressed: () => _ack(context), child: Text(context.t('perfAcknowledge'))),
            if (canRequisition) TextButton(onPressed: () => _requisition(context), child: Text(context.t('phRequisition'))),
            if (canResolve) TextButton(onPressed: () => _resolve(context), child: Text(context.t('perfResolve'))),
          ]),
        ],
      ]),
    );
  }

  Future<void> _ack(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final result = await context.read<PharmacyProvider>().acknowledgeAlert(alert.id);
    if (!context.mounted) return;
    if (!result.success || result.queued) _toast(context, messenger, result, '');
  }

  Future<void> _requisition(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final result = await context.read<PharmacyProvider>().createRequisition(alert.id);
    if (!context.mounted) return;
    _toast(context, messenger, result, context.t('phRequisitionCreated'));
  }

  Future<void> _resolve(BuildContext context) async {
    final note = await askReason(context, title: context.t('perfResolve'), label: context.t('perfResolveReason'));
    if (note == null || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final result = await context.read<PharmacyProvider>().resolveAlert(alert.id, note);
    if (!context.mounted) return;
    _toast(context, messenger, result, context.t('saved'));
  }
}

class _AdministrationRow extends StatelessWidget {
  const _AdministrationRow(this.a, {required this.canReverse});
  final MedicationAdministration a;
  final bool canReverse;

  @override
  Widget build(BuildContext context) {
    final withdrawal = [
      if (a.withdrawalMilkUntil != null) '${context.t('phMilk')} ${feedDate(a.withdrawalMilkUntil!)}',
      if (a.withdrawalMeatUntil != null) '${context.t('phMeat')} ${feedDate(a.withdrawalMeatUntil!)}',
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 74, child: Text(a.administeredAt == null ? '—' : feedDate(a.administeredAt!), style: FarmTypography.textTheme.bodySmall)),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${a.subjectName ?? a.subjectId} · ${a.medicineName ?? ''}',
                style: FarmTypography.textTheme.titleSmall?.copyWith(decoration: a.isReversed ? TextDecoration.lineThrough : null)),
            Text(
              [
                '${feedNumber(a.doseQuantity)} ${a.doseUnit} ${a.routeCode}',
                if (a.headCount > 1) '${a.headCount} ${context.t('headCount').toLowerCase()}',
                '${context.t('phLot')} ${a.lotCode ?? ''}',
                if (a.administeredByName != null) a.administeredByName!,
                if (withdrawal.isNotEmpty) '${context.t('phWithdrawal')}: $withdrawal',
              ].join(' · '),
              style: FarmTypography.textTheme.bodySmall?.copyWith(color: FarmColors.muted),
            ),
          ]),
        ),
        Text('−${feedNumber(a.quantityConsumed)} ${a.unit}', style: FarmTypography.textTheme.bodyMedium),
        if (canReverse)
          IconButton(
            tooltip: context.t('phReverse'),
            icon: const Icon(Icons.undo, size: 18),
            onPressed: () async {
              final reason = await askReason(context, title: context.t('phReverse'), label: context.t('phReverseReason'));
              if (reason == null || !context.mounted) return;
              final messenger = ScaffoldMessenger.of(context);
              final result = await context.read<PharmacyProvider>().reverseAdministration(a.id, reason);
              if (!context.mounted) return;
              _toast(context, messenger, result, context.t('saved'));
            },
          ),
      ]),
    );
  }
}

/// A one-field dialog for the reasons the pharmacy insists on: why a lot
/// leaves use, why an alert is closed by hand, why an entry is reversed.
Future<String?> askReason(BuildContext context, {required String title, required String label}) async {
  final controller = TextEditingController();
  final text = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(controller: controller, autofocus: true, maxLines: 3, decoration: InputDecoration(labelText: label)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: Text(context.t('cancel'))),
        FilledButton(onPressed: () => Navigator.pop(ctx, controller.text.trim()), child: Text(context.t('save'))),
      ],
    ),
  );
  return text == null || text.isEmpty ? null : text;
}

// ------------------------------------------------------------------ detail
Future<void> showMedicineDetailDialog(BuildContext context, String medicineId) =>
    showDialog<void>(context: context, builder: (_) => _MedicineDetailDialog(medicineId: medicineId));

class _MedicineDetailDialog extends StatefulWidget {
  const _MedicineDetailDialog({required this.medicineId});
  final String medicineId;

  @override
  State<_MedicineDetailDialog> createState() => _MedicineDetailDialogState();
}

class _MedicineDetailDialogState extends State<_MedicineDetailDialog> {
  late Future<Medicine?> _future = context.read<PharmacyProvider>().detail(widget.medicineId);

  void _refresh() => setState(() => _future = context.read<PharmacyProvider>().detail(widget.medicineId));

  @override
  Widget build(BuildContext context) {
    final access = context.watch<AccessProvider>();
    final canEditStock = access.canEdit(FarmModule.inventory);
    final canStock = canEditStock || access.canCreate(FarmModule.inventory);
    return AlertDialog(
      content: SizedBox(
        width: 640,
        child: FutureBuilder<Medicine?>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Padding(padding: EdgeInsets.all(24), child: Center(child: SizedBox(height: 22, width: 22, child: CircularProgressIndicator(strokeWidth: 2))));
            }
            final m = snap.data;
            if (m == null) return const FeedEmpty('phNoMedicines');
            final rules = m.withdrawalRules;
            return SingleChildScrollView(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(child: Text(m.name, style: FarmTypography.textTheme.titleMedium)),
                  StatusPill(label: context.t('phStatus_${m.status}'), level: _statusLevel(m.status), dense: true),
                ]),
                const SizedBox(height: 4),
                Text(
                  [
                    if (m.genericName != null) m.genericName!,
                    m.dosageForm.replaceAll('_', ' '),
                    if (m.strengthValue != null) '${feedNumber(m.strengthValue!)} ${m.strengthUom ?? ''}',
                    if (m.routes.isNotEmpty) m.routes.join('/'),
                    if (m.prescriptionRequired) context.t('phPrescriptionOnly'),
                    if (m.speciesCodes.isNotEmpty) m.speciesCodes.join(', '),
                  ].join(' · '),
                  style: FarmTypography.textTheme.bodySmall?.copyWith(color: FarmColors.muted),
                ),
                _Section(context.t('status')),
                FeedKeyValue(context.t('phEligible'), '${feedNumber(m.eligibleAvailable)} ${m.unit}', bold: true),
                FeedKeyValue(context.t('onHand'), '${feedNumber(m.onHand)} ${m.unit}'),
                if (m.expired > 0) FeedKeyValue(context.t('phIneligible_expired'), '${feedNumber(m.expired)} ${m.unit}', valueColor: FarmColors.danger),
                if (m.quarantined > 0) FeedKeyValue(context.t('phIneligible_quarantined'), '${feedNumber(m.quarantined)} ${m.unit}', valueColor: FarmColors.warningInk),
                if (m.storageExceptionQuantity > 0) FeedKeyValue(context.t('phIneligible_storage_exception'), '${feedNumber(m.storageExceptionQuantity)} ${m.unit}', valueColor: FarmColors.danger),
                FeedKeyValue(context.t('phMinCritTarget'), m.policy == null ? context.t('phNoPolicy') : '${_n(m.policy!.minimum)} / ${_n(m.policy!.critical)} / ${_n(m.policy!.target)} ${m.unit}'),
                if (m.recommendedReorder > 0) FeedKeyValue(context.t('phRecommendedReorder'), '${feedNumber(m.recommendedReorder)} ${m.unit}', valueColor: FarmColors.warningInk),
                if (m.averageDailyUse > 0) FeedKeyValue(context.t('phAverageDailyUse'), '${m.averageDailyUse.toStringAsFixed(2)} ${m.unit}'),
                if (rules.isNotEmpty)
                  FeedKeyValue(context.t('phWithdrawal'), [
                    if (rules['milk_days'] != null) '${context.t('phMilk')} ${rules['milk_days']} ${context.t('days')}',
                    if (rules['meat_days'] != null) '${context.t('phMeat')} ${rules['meat_days']} ${context.t('days')}',
                  ].join(' · ')),
                _Section(context.t('lots')),
                if (m.lots.isEmpty) const FeedEmpty('phNoLots'),
                for (final l in m.lots) _LotRow(lot: l, medicine: m, canEditStock: canEditStock, canStock: canStock, onChanged: _refresh),
                if (m.administrations.isNotEmpty) ...[
                  _Section(context.t('phAdministrationsTitle')),
                  for (final a in m.administrations.take(8)) _AdministrationRow(a, canReverse: false),
                ],
              ]),
            );
          },
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(context.t('close')))],
    );
  }
}

class _LotRow extends StatelessWidget {
  const _LotRow({required this.lot, required this.medicine, required this.canEditStock, required this.canStock, required this.onChanged});
  final MedicineLot lot;
  final Medicine medicine;
  final bool canEditStock;
  final bool canStock;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final l = lot;
    final why = l.ineligibleReason;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text(l.lotCode, style: FarmTypography.textTheme.titleSmall),
              const SizedBox(width: 6),
              StatusPill(label: why == null ? context.t('phEligibleLot') : context.t('phIneligible_$why'), level: why == null ? FarmStatusLevel.good : FarmStatusLevel.alert, dense: true),
            ]),
            Text(
              [
                if (l.expiryDate != null) '${context.t('phExpiryDate')} ${feedDate(l.expiryDate!)}',
                if (l.useByAfterOpening != null) '${context.t('phUseByAfterOpening')} ${feedDate(l.useByAfterOpening!)}',
                if (l.supplierLabel != null) l.supplierLabel!,
                if (l.quarantineReason != null) l.quarantineReason!,
                if (l.storageNote != null) l.storageNote!,
              ].join(' · '),
              style: FarmTypography.textTheme.bodySmall?.copyWith(color: FarmColors.muted),
            ),
          ]),
        ),
        Text('${feedNumber(l.quantityOnHand)} ${l.unit}', style: FarmTypography.textTheme.bodyMedium),
        if (canStock)
          PopupMenuButton<String>(
            onSelected: (v) => _act(context, v),
            itemBuilder: (_) => [
              if (canEditStock && l.status == 'active') PopupMenuItem(value: 'quarantined', child: Text(context.t('phQuarantine'))),
              if (canEditStock && l.status == 'active') PopupMenuItem(value: 'recalled', child: Text(context.t('phRecall'))),
              if (canEditStock && (l.status == 'quarantined' || l.status == 'blocked' || l.status == 'recalled')) PopupMenuItem(value: 'active', child: Text(context.t('phRelease'))),
              if (l.openedAt == null && medicine.openedShelfLifeDays != null) PopupMenuItem(value: 'open', child: Text(context.t('phOpenLot'))),
              if (canEditStock && (l.storageStatus != 'COMPLIANT' || l.coldChainException)) PopupMenuItem(value: 'storage', child: Text(context.t('phClearStorage'))),
            ],
          ),
      ]),
    );
  }

  Future<void> _act(BuildContext context, String action) async {
    final pharmacy = context.read<PharmacyProvider>();
    final messenger = ScaffoldMessenger.of(context);
    dynamic result;
    switch (action) {
      case 'open':
        result = await pharmacy.openLot(lot.id);
      case 'storage':
        final note = await askReason(context, title: context.t('phClearStorage'), label: context.t('perfResolveReason'));
        if (note == null) return;
        result = await pharmacy.setLotStorage(lot.id, storageStatus: 'COMPLIANT', coldChainException: false, note: note);
      default:
        final reason = await askReason(context, title: context.t('phLotReason'), label: context.t('reason'));
        if (reason == null) return;
        result = await pharmacy.setLotStatus(lot.id, action, reason: reason);
    }
    if (!context.mounted) return;
    _toast(context, messenger, result, context.t('saved'));
    onChanged();
  }
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

// ----------------------------------------------------------------- receive
Future<void> showReceiveMedicineDialog(BuildContext context, {String? medicineId}) =>
    showDialog<void>(context: context, builder: (_) => _ReceiveDialog(medicineId: medicineId));

class _ReceiveDialog extends StatefulWidget {
  const _ReceiveDialog({this.medicineId});
  final String? medicineId;

  @override
  State<_ReceiveDialog> createState() => _ReceiveDialogState();
}

class _ReceiveDialogState extends State<_ReceiveDialog> {
  String? _medicineId;
  final _quantity = TextEditingController();
  final _lotCode = TextEditingController();
  final _unitCost = TextEditingController();
  final _supplier = TextEditingController();
  final _reference = TextEditingController();
  DateTime? _expiry;
  bool _storageException = false;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _medicineId = widget.medicineId;
  }

  @override
  void dispose() {
    for (final c in [_quantity, _lotCode, _unitCost, _supplier, _reference]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final medicines = context.watch<PharmacyProvider>().medicines;
    if (medicines.isEmpty) {
      return AlertDialog(title: Text(context.t('phReceive')), content: const FeedEmpty('phNoMedicines'), actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(context.t('close')))]);
    }
    final selected = medicines.any((m) => m.inventoryItemId == _medicineId) ? _medicineId! : medicines.first.inventoryItemId;
    final medicine = medicines.firstWhere((m) => m.inventoryItemId == selected);
    return AlertDialog(
      title: Text(context.t('phReceive')),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            DropdownButtonFormField<String>(
              initialValue: selected,
              decoration: InputDecoration(labelText: context.t('phMedicine')),
              items: [for (final m in medicines) DropdownMenuItem(value: m.inventoryItemId, child: Text(m.name, overflow: TextOverflow.ellipsis))],
              onChanged: (v) => setState(() => _medicineId = v ?? selected),
            ),
            const SizedBox(height: 12),
            TextField(controller: _quantity, autofocus: true, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: '${context.t('quantity')} (${medicine.unit})')),
            const SizedBox(height: 12),
            TextField(controller: _lotCode, decoration: InputDecoration(labelText: context.t('phLotNumber'))),
            const SizedBox(height: 12),
            InkWell(
              onTap: () async {
                final picked = await showDatePicker(context: context, initialDate: _expiry ?? DateTime.now().add(const Duration(days: 365)), firstDate: DateTime.now().subtract(const Duration(days: 3650)), lastDate: DateTime.now().add(const Duration(days: 3650)));
                if (picked != null) setState(() => _expiry = picked);
              },
              child: InputDecorator(
                decoration: InputDecoration(labelText: context.t('phExpiryDate'), suffixIcon: const Icon(Icons.event)),
                child: Text(_expiry == null ? '—' : feedDate(_expiry!)),
              ),
            ),
            const SizedBox(height: 4),
            Text(context.t('phLotAndExpiryRequired'), style: FarmTypography.textTheme.bodySmall?.copyWith(color: FarmColors.muted)),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: TextField(controller: _unitCost, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: '${context.t('unitCost')} (\$/${medicine.unit})'))),
              const SizedBox(width: 12),
              Expanded(child: TextField(controller: _supplier, decoration: InputDecoration(labelText: context.t('supplier')))),
            ]),
            const SizedBox(height: 12),
            TextField(controller: _reference, decoration: InputDecoration(labelText: context.t('reference'))),
            SwitchListTile(contentPadding: EdgeInsets.zero, dense: true, value: _storageException, onChanged: (v) => setState(() => _storageException = v), title: Text(context.t('phStorageException'), style: FarmTypography.textTheme.bodySmall)),
            if (_error != null) ...[const SizedBox(height: 8), Text(_error!, style: const TextStyle(color: FarmColors.danger, fontSize: 12))],
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: _saving ? null : () => Navigator.pop(context), child: Text(context.t('cancel'))),
        FilledButton(onPressed: _saving ? null : () => _save(medicine), child: Text(context.t('save'))),
      ],
    );
  }

  Future<void> _save(Medicine medicine) async {
    final qty = double.tryParse(_quantity.text.trim());
    if (qty == null || qty <= 0) {
      setState(() => _error = context.t('enterQuantity'));
      return;
    }
    if (_lotCode.text.trim().isEmpty || _expiry == null) {
      setState(() => _error = context.t('phLotAndExpiryRequired'));
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final messenger = ScaffoldMessenger.of(context);
    final result = await context.read<PharmacyProvider>().receiveLot({
      'inventory_item_id': medicine.inventoryItemId,
      'quantity': qty,
      'lot_code': _lotCode.text.trim(),
      'expiry_date': DateTime(_expiry!.year, _expiry!.month, _expiry!.day, 23, 59).toUtc().toIso8601String(),
      if (_unitCost.text.trim().isNotEmpty) 'unit_cost': double.tryParse(_unitCost.text.trim()),
      if (_supplier.text.trim().isNotEmpty) 'supplier_label': _supplier.text.trim(),
      if (_reference.text.trim().isNotEmpty) 'reference': _reference.text.trim(),
      'storage_status': _storageException ? 'EXCEPTION' : 'COMPLIANT',
      'cold_chain_exception': _storageException,
    });
    if (!mounted) return;
    if (result.success) {
      Navigator.pop(context);
      _toast(context, messenger, result, context.t('saved'));
    } else {
      setState(() {
        _saving = false;
        _error = result.error ?? context.t('couldNotSave');
      });
    }
  }
}

// -------------------------------------------------------------- administer
Future<void> showAdministerDialog(BuildContext context, {String? medicineId, String? subjectType, String? subjectId}) =>
    showDialog<void>(context: context, builder: (_) => _AdministerDialog(medicineId: medicineId, subjectType: subjectType, subjectId: subjectId));

class _AdministerDialog extends StatefulWidget {
  const _AdministerDialog({this.medicineId, this.subjectType, this.subjectId});
  final String? medicineId;
  final String? subjectType;
  final String? subjectId;

  @override
  State<_AdministerDialog> createState() => _AdministerDialogState();
}

class _AdministerDialogState extends State<_AdministerDialog> {
  String? _medicineId;
  String? _subject; // 'animal:<id>' | 'group:<id>'
  String? _lotId;
  String? _treatmentId;
  String? _route;
  final _dose = TextEditingController();
  final _doseUnit = TextEditingController();
  final _heads = TextEditingController();
  final _reason = TextEditingController();
  List<MedicineLot> _lots = const [];
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _medicineId = widget.medicineId;
    if (widget.subjectType != null && widget.subjectId != null) _subject = '${widget.subjectType}:${widget.subjectId}';
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadLots());
  }

  @override
  void dispose() {
    for (final c in [_dose, _doseUnit, _heads, _reason]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _loadLots() async {
    final id = _medicineId;
    if (id == null) return;
    final detail = await context.read<PharmacyProvider>().detail(id);
    if (!mounted || detail == null) return;
    setState(() {
      _lots = [for (final l in detail.lots) if (l.eligible) l];
      if (_doseUnit.text.isEmpty) _doseUnit.text = detail.unit;
      if (_route == null && detail.routes.isNotEmpty) _route = detail.routes.first;
    });
  }

  @override
  Widget build(BuildContext context) {
    final pharmacy = context.watch<PharmacyProvider>();
    final animals = context.watch<AnimalsProvider>();
    final groups = context.watch<LivestockProvider>().groups;
    final medicines = pharmacy.medicines;
    if (medicines.isEmpty) {
      return AlertDialog(title: Text(context.t('phAdminister')), content: const FeedEmpty('phNoMedicines'), actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(context.t('close')))]);
    }
    final selectedId = medicines.any((m) => m.inventoryItemId == _medicineId) ? _medicineId! : medicines.first.inventoryItemId;
    if (_medicineId != selectedId) {
      _medicineId = selectedId;
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadLots());
    }
    final medicine = medicines.firstWhere((m) => m.inventoryItemId == selectedId);
    final subjects = <String, String>{
      for (final a in animals.animals) 'animal:${a.id}': '${a.name}${a.tag == null ? '' : ' · ${a.tag}'}',
      for (final g in groups) 'group:${g.id}': '${g.name} · ${g.count}',
    };
    final subject = subjects.containsKey(_subject) ? _subject : null;
    final subjectId = subject?.split(':').last;
    final subjectType = subject?.split(':').first;
    final treatments = [
      for (final t in animals.treatments)
        if (subjectId != null && t.entityId == subjectId) t,
    ];
    final routes = medicine.routes.isEmpty ? const ['IM', 'IV', 'SC', 'PO', 'topical', 'intramammary', 'pour_on', 'intranasal', 'ocular', 'other'] : medicine.routes;
    final route = routes.contains(_route) ? _route : routes.first;

    return AlertDialog(
      title: Text(context.t('phAdminister')),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            DropdownButtonFormField<String>(
              initialValue: selectedId,
              decoration: InputDecoration(labelText: context.t('phMedicine')),
              items: [
                for (final m in medicines)
                  DropdownMenuItem(value: m.inventoryItemId, child: Text('${m.name} — ${feedNumber(m.eligibleAvailable)} ${m.unit}', overflow: TextOverflow.ellipsis)),
              ],
              onChanged: (v) => setState(() {
                _medicineId = v;
                _lotId = null;
                _route = null;
                _doseUnit.clear();
                _lots = const [];
              }),
            ),
            if (medicine.prescriptionRequired) ...[
              const SizedBox(height: 6),
              Text(context.t('phPrescriptionRequired'), style: FarmTypography.textTheme.bodySmall?.copyWith(color: FarmColors.warningInk)),
            ],
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: subject,
              decoration: InputDecoration(labelText: context.t('animalOrGroup')),
              items: [for (final e in subjects.entries) DropdownMenuItem(value: e.key, child: Text(e.value, overflow: TextOverflow.ellipsis))],
              onChanged: (v) => setState(() {
                _subject = v;
                _treatmentId = null;
              }),
            ),
            if (subjectType == 'animal') ...[
              const SizedBox(height: 12),
              DropdownButtonFormField<String?>(
                initialValue: treatments.any((t) => t.id == _treatmentId) ? _treatmentId : null,
                decoration: InputDecoration(labelText: context.t('phTreatment')),
                items: [
                  DropdownMenuItem<String?>(value: null, child: Text(context.t('phTreatmentNone'))),
                  for (final t in treatments) DropdownMenuItem<String?>(value: t.id, child: Text('${t.medication} · ${feedDate(t.startAt)}', overflow: TextOverflow.ellipsis)),
                ],
                onChanged: (v) => setState(() => _treatmentId = v),
              ),
            ],
            const SizedBox(height: 12),
            Row(children: [
              Expanded(flex: 2, child: TextField(controller: _dose, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: context.t('phDose')))),
              const SizedBox(width: 8),
              Expanded(child: TextField(controller: _doseUnit, decoration: InputDecoration(labelText: context.t('phDoseUnit')))),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: DropdownButtonFormField<String>(
                  initialValue: route,
                  decoration: InputDecoration(labelText: context.t('phRoute')),
                  items: [for (final r in routes) DropdownMenuItem(value: r, child: Text(r))],
                  onChanged: (v) => setState(() => _route = v),
                ),
              ),
            ]),
            if (subjectType == 'group') ...[
              const SizedBox(height: 12),
              TextField(controller: _heads, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: context.t('headCount'))),
            ],
            const SizedBox(height: 12),
            DropdownButtonFormField<String?>(
              initialValue: _lots.any((l) => l.id == _lotId) ? _lotId : null,
              decoration: InputDecoration(labelText: context.t('phLot')),
              items: [
                DropdownMenuItem<String?>(value: null, child: Text(context.t('phFefo'))),
                for (final l in _lots)
                  DropdownMenuItem<String?>(value: l.id, child: Text('${l.lotCode} · ${feedNumber(l.quantityOnHand)} ${l.unit}${l.effectiveExpiry == null ? '' : ' · ${feedDate(l.effectiveExpiry!)}'}', overflow: TextOverflow.ellipsis)),
              ],
              onChanged: (v) => setState(() => _lotId = v),
            ),
            const SizedBox(height: 12),
            TextField(controller: _reason, decoration: InputDecoration(labelText: context.t('reason'))),
            if (_error != null) ...[const SizedBox(height: 8), Text(_error!, style: const TextStyle(color: FarmColors.danger, fontSize: 12))],
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: _saving ? null : () => Navigator.pop(context), child: Text(context.t('cancel'))),
        FilledButton(onPressed: _saving || subject == null ? null : () => _save(medicine, subjectType!, subjectId!, route!), child: Text(context.t('save'))),
      ],
    );
  }

  Future<void> _save(Medicine medicine, String subjectType, String subjectId, String route) async {
    final dose = double.tryParse(_dose.text.trim());
    if (dose == null || dose <= 0) {
      setState(() => _error = context.t('enterQuantity'));
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final messenger = ScaffoldMessenger.of(context);
    final heads = int.tryParse(_heads.text.trim());
    final result = await context.read<PharmacyProvider>().administer({
      'subject_type': subjectType,
      'subject_id': subjectId,
      'inventory_item_id': medicine.inventoryItemId,
      if (_lotId != null) 'lot_id': _lotId,
      'dose_quantity': dose,
      'dose_unit': _doseUnit.text.trim().isEmpty ? medicine.unit : _doseUnit.text.trim(),
      'route_code': route,
      if (heads != null) 'head_count': heads,
      if (_treatmentId != null) 'treatment_id': _treatmentId,
      if (_reason.text.trim().isNotEmpty) 'reason': _reason.text.trim(),
    });
    if (!mounted) return;
    if (result.success) {
      Navigator.pop(context);
      _toast(context, messenger, result, context.t('phAdministered'));
    } else {
      setState(() {
        _saving = false;
        _error = result.error ?? context.t('couldNotSave');
      });
    }
  }
}

// ------------------------------------------------------------------ policy
Future<void> showPolicyDialog(BuildContext context, Medicine medicine) => showDialog<void>(context: context, builder: (_) => _PolicyDialog(medicine: medicine));

class _PolicyDialog extends StatefulWidget {
  const _PolicyDialog({required this.medicine});
  final Medicine medicine;

  @override
  State<_PolicyDialog> createState() => _PolicyDialogState();
}

class _PolicyDialogState extends State<_PolicyDialog> {
  late bool _essential = widget.medicine.policy?.essential ?? false;
  late bool _alerts = widget.medicine.policy?.alertEnabled ?? true;
  late bool _autoRequisition = widget.medicine.policy?.autoDraftRequisition ?? false;
  late final _minimum = TextEditingController(text: _text(widget.medicine.policy?.minimum));
  late final _critical = TextEditingController(text: _text(widget.medicine.policy?.critical));
  late final _target = TextEditingController(text: _text(widget.medicine.policy?.target));
  late final _warning = TextEditingController(text: '${widget.medicine.policy?.expiryWarningDays ?? 60}');
  bool _saving = false;
  String? _error;

  static String _text(double? v) => v == null ? '' : feedNumber(v);

  @override
  void dispose() {
    for (final c in [_minimum, _critical, _target, _warning]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final unit = widget.medicine.unit;
    return AlertDialog(
      title: Text('${context.t('phPolicyTitle')} · ${widget.medicine.name}'),
      content: SizedBox(
        width: 400,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(context.t('phPolicySubtitle'), style: FarmTypography.textTheme.bodySmall?.copyWith(color: FarmColors.muted)),
          SwitchListTile(contentPadding: EdgeInsets.zero, dense: true, value: _essential, onChanged: (v) => setState(() => _essential = v), title: Text(context.t('phEssentialToggle'), style: FarmTypography.textTheme.bodyMedium)),
          Row(children: [
            Expanded(child: TextField(controller: _minimum, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: '${context.t('phMinimum')} ($unit)'))),
            const SizedBox(width: 8),
            Expanded(child: TextField(controller: _critical, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: '${context.t('phCritical')} ($unit)'))),
            const SizedBox(width: 8),
            Expanded(child: TextField(controller: _target, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: '${context.t('phTarget')} ($unit)'))),
          ]),
          const SizedBox(height: 12),
          TextField(controller: _warning, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: context.t('phExpiryWarningDays'))),
          SwitchListTile(contentPadding: EdgeInsets.zero, dense: true, value: _alerts, onChanged: (v) => setState(() => _alerts = v), title: Text(context.t('phAlertsEnabled'), style: FarmTypography.textTheme.bodySmall)),
          SwitchListTile(contentPadding: EdgeInsets.zero, dense: true, value: _autoRequisition, onChanged: (v) => setState(() => _autoRequisition = v), title: Text(context.t('phAutoRequisition'), style: FarmTypography.textTheme.bodySmall)),
          if (_error != null) ...[const SizedBox(height: 8), Text(_error!, style: const TextStyle(color: FarmColors.danger, fontSize: 12))],
        ]),
      ),
      actions: [
        TextButton(onPressed: _saving ? null : () => Navigator.pop(context), child: Text(context.t('cancel'))),
        FilledButton(onPressed: _saving ? null : _save, child: Text(context.t('save'))),
      ],
    );
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    final messenger = ScaffoldMessenger.of(context);
    double? num(TextEditingController c) => c.text.trim().isEmpty ? null : double.tryParse(c.text.trim());
    final result = await context.read<PharmacyProvider>().setPolicy(widget.medicine.inventoryItemId, {
      'essential': _essential,
      'minimum_stock_base': num(_minimum),
      'critical_stock_base': num(_critical),
      'target_stock_base': num(_target),
      'alert_enabled': _alerts,
      'expiry_warning_days': int.tryParse(_warning.text.trim()) ?? 60,
      'auto_draft_requisition': _autoRequisition,
    });
    if (!mounted) return;
    if (result.success) {
      Navigator.pop(context);
      _toast(context, messenger, result, context.t('saved'));
    } else {
      setState(() {
        _saving = false;
        _error = result.error ?? context.t('couldNotSave');
      });
    }
  }
}
