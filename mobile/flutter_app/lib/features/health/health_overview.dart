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
import '../../core/widgets/ux_blocks.dart';
import '../../domain/entities/animal.dart';
import '../../domain/entities/health_case.dart';
import '../../domain/entities/pharmacy.dart';
import '../../domain/entities/production_records.dart';
import '../../providers/animals_provider.dart';
import '../../providers/emergency_provider.dart';
import '../../providers/health_records_provider.dart';
import '../../providers/pharmacy_provider.dart';
import '../animals/animal_digital_twin_screen.dart';
import '../animals/animal_quick_actions.dart' show observationLabel;
import '../feed/feed_workspace_screen.dart' show feedDate;
import 'health_cases.dart';

/// The Health screen's first tab, laid out as the V3 prototype's "Health
/// command center": open cases and follow-up beside the animals whose
/// milk or meat is held, then the clinical record — observations,
/// treatments and medicines given — newest first.

/// Open cases, reassessments due, animals on withdrawal, recent records —
/// each counted from the server's records, each saying what it counts.
class HealthKpiRow extends StatelessWidget {
  const HealthKpiRow({super.key});

  @override
  Widget build(BuildContext context) {
    final health = context.watch<HealthRecordsProvider>();
    final emergency = context.watch<EmergencyProvider>().summary;
    final animals = context.watch<AnimalsProvider>();
    final pharmacy = context.watch<PharmacyProvider>();
    final open = health.openCases;
    final monitoring = open.where((c) => c.status == 'monitoring').length;
    final held = animals.animals.where((a) => a.onFarm && a.isUnderWithdrawal).length;
    final records = clinicalRecords(observations: health.observations, treatments: animals.treatments, administrations: pharmacy.administrations, days: 30).length;
    return EqualGrid(minTileWidth: 200, children: [
      KpiCard(icon: FarmIcon.stethoscope, label: context.t('hlKpiOpenCases'), value: '${open.length}', caption: '$monitoring ${context.t('hlKpiMonitoring')}',
          tint: open.any((c) => c.severity == 'critical' || c.severity == 'high') ? FarmColors.danger : null),
      KpiCard(
        icon: FarmIcon.calendar,
        label: context.t('hlKpiReassess'),
        value: '${emergency.awaitingReassessment}',
        caption: '${emergency.reassessmentsOverdue} ${context.t('hlKpiOverdue')}',
        tint: emergency.reassessmentsOverdue > 0 ? FarmColors.danger : null,
      ),
      KpiCard(icon: FarmIcon.warning, label: context.t('hlKpiWithdrawal'), value: '$held', caption: context.t('hlKpiWithdrawalCap'), tint: held > 0 ? FarmColors.warning : null),
      KpiCard(icon: FarmIcon.report, label: context.t('hlKpiRecords'), value: '$records', caption: context.t('hlKpiRecordsCap')),
    ]);
  }
}

/// One line of the clinical record, whatever produced it.
class ClinicalRecord {
  const ClinicalRecord({required this.kind, required this.subjectType, required this.subjectId, this.subjectName, required this.title, required this.detail, required this.at});
  final ClinicalKind kind;
  final String subjectType;
  final String subjectId;
  final String? subjectName;
  final String title;
  final String detail;
  final DateTime at;
}

enum ClinicalKind { observation, treatment, medicine }

/// Observations, treatments and medicines given in the last [days],
/// newest first. A reversed dose is left out — it was not given.
List<ClinicalRecord> clinicalRecords({
  required List<ObservationRecord> observations,
  required List<TreatmentRecord> treatments,
  required List<MedicationAdministration> administrations,
  int days = 30,
  DateTime? now,
}) {
  final since = (now ?? DateTime.now()).subtract(Duration(days: days));
  final out = <ClinicalRecord>[
    for (final o in observations)
      if (o.observedAt.isAfter(since))
        ClinicalRecord(kind: ClinicalKind.observation, subjectType: o.entityType, subjectId: o.entityId, title: o.type, detail: o.severity ?? '', at: o.observedAt),
    for (final t in treatments)
      if (t.startAt.isAfter(since))
        ClinicalRecord(kind: ClinicalKind.treatment, subjectType: t.entityType, subjectId: t.entityId, title: t.diagnosis ?? t.medication, detail: t.medication, at: t.startAt),
    for (final a in administrations)
      if (!a.isReversed && a.administeredAt != null && a.administeredAt!.isAfter(since))
        ClinicalRecord(
          kind: ClinicalKind.medicine,
          subjectType: a.subjectType,
          subjectId: a.subjectId,
          subjectName: a.subjectName,
          title: a.medicineName ?? a.inventoryItemId,
          detail: '${a.doseQuantity} ${a.doseUnit}',
          at: a.administeredAt!,
        ),
  ]..sort((a, b) => b.at.compareTo(a.at));
  return out;
}

class HealthOverviewTab extends StatelessWidget {
  const HealthOverviewTab({super.key, required this.onAllCases});
  final VoidCallback onAllCases;

  @override
  Widget build(BuildContext context) {
    final health = context.watch<HealthRecordsProvider>();
    final animals = context.watch<AnimalsProvider>();
    final pharmacy = context.watch<PharmacyProvider>();
    final open = health.openCases;
    final held = [for (final a in animals.animals) if (a.onFarm && a.isUnderWithdrawal) a]
      ..sort((a, b) => b.underWithdrawalUntil!.compareTo(a.underWithdrawalUntil!));
    final records = clinicalRecords(observations: health.observations, treatments: animals.treatments, administrations: pharmacy.administrations);

    final casesCard = SectionCard(
      title: context.t('hlCasesCard'),
      subtitle: context.t('hlCasesCardSub'),
      trailing: health.cases.isEmpty ? null : context.t('hlAllCases'),
      onTrailingTap: health.cases.isEmpty ? null : onAllCases,
      child: open.isEmpty
          ? EmptyState(message: context.t('hcNoOpenCases'), icon: FarmIcon.heart, compact: true)
          : Column(children: [for (final c in open.take(6)) CaseRow(healthCase: c)]),
    );
    final withdrawalCard = SectionCard(
      title: context.t('hlWithdrawalCard'),
      subtitle: context.t('hlWithdrawalCardSub'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (held.isEmpty)
          EmptyState(message: context.t('hlNoWithdrawal'), icon: FarmIcon.check, compact: true)
        else
          for (final a in held) _WithdrawalRow(animal: a),
        const SizedBox(height: FarmSpacing.sm),
        NoticeBanner(text: context.t('twWithdrawalCaveat')),
      ]),
    );

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      LayoutBuilder(builder: (context, c) {
        if (c.maxWidth < 760) return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [casesCard, const SizedBox(height: FarmSpacing.md), withdrawalCard]);
        return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: casesCard),
          const SizedBox(width: FarmSpacing.md),
          Expanded(child: withdrawalCard),
        ]);
      }),
      const SizedBox(height: FarmSpacing.md),
      SectionCard(
        title: context.t('hlRecordCard'),
        subtitle: context.t('hlRecordCardSub'),
        child: records.isEmpty
            ? EmptyState(message: context.t('hlNoRecords'), icon: FarmIcon.heart)
            : Column(children: [for (final r in records.take(15)) _ClinicalRow(record: r)]),
      ),
    ]);
  }
}

void _openAnimal(BuildContext context, String animalId) => Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => AnimalDigitalTwinScreen(animalId: animalId, initialTab: TwinTab.health)),
    );

class _WithdrawalRow extends StatelessWidget {
  const _WithdrawalRow({required this.animal});
  final Animal animal;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => _openAnimal(context, animal.id),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: FarmColors.border))),
        child: Row(children: [
          const AppIcon(FarmIcon.warning, size: 18, color: FarmColors.warning),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(animal.primaryId.isEmpty ? animal.name : '${animal.name} #${animal.primaryId}', style: FarmTypography.textTheme.titleSmall),
              Text(animal.withdrawalReason ?? context.t('hlWithdrawalReview'), style: FarmTypography.textTheme.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
            ]),
          ),
          StatusPill(label: '${context.t('twWithdrawalUntil')} ${feedDate(animal.underWithdrawalUntil!)}', level: FarmStatusLevel.watch, dense: true),
        ]),
      ),
    );
  }
}

class _ClinicalRow extends StatelessWidget {
  const _ClinicalRow({required this.record});
  final ClinicalRecord record;

  @override
  Widget build(BuildContext context) {
    final r = record;
    final (icon, kind, title) = switch (r.kind) {
      ClinicalKind.observation => (FarmIcon.eye, context.t('hlKindObservation'), observationLabel(context, r.title)),
      ClinicalKind.treatment => (FarmIcon.stethoscope, context.t('hlKindTreatment'), r.title),
      ClinicalKind.medicine => (FarmIcon.syringe, context.t('hlKindMedicine'), r.title),
    };
    final detail = switch (r.kind) {
      ClinicalKind.observation when r.detail.isNotEmpty => context.t('sev${r.detail[0].toUpperCase()}${r.detail.substring(1)}'),
      _ => r.detail,
    };
    final subject = subjectLabel(context, r.subjectType, r.subjectId, known: r.subjectName);
    return InkWell(
      onTap: r.subjectType == 'animal' ? () => _openAnimal(context, r.subjectId) : null,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 4),
        decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: FarmColors.border))),
        child: Row(children: [
          Container(
            width: 32,
            height: 32,
            decoration: const BoxDecoration(color: FarmColors.mist, shape: BoxShape.circle),
            child: Center(child: AppIcon(icon, size: 15, color: r.kind == ClinicalKind.medicine ? FarmColors.lilac : FarmColors.cedar)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('$subject · $title', style: FarmTypography.textTheme.titleSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
              Text([kind, feedDate(r.at), if (detail.isNotEmpty) detail].join(' · '), style: FarmTypography.textTheme.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
            ]),
          ),
        ]),
      ),
    );
  }
}
