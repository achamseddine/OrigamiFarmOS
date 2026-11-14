import 'package:flutter/material.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/util/record_dates.dart';
import '../../core/widgets/ux_blocks.dart';

/// Where a female stands on the pregnancy line, as the farmer says it.
///
/// * [open] — not pregnant (or not known to be);
/// * [inseminated] — served (insemination or mating), not yet confirmed;
/// * [pregnant] — confirmed pregnant.
///
/// None of these is stored as a flag: the form turns the farmer's answer
/// into the records the server keeps (a breeding event, a pregnancy check),
/// and the animal's status is the projection of those records.
enum PregnancyChoice { open, inseminated, pregnant }

/// Whether she is being milked. "Dry" covers both never-milked and dried
/// off ahead of the next birth.
enum MilkChoice { milking, dry }

const kServiceTypes = ['ARTIFICIAL_INSEMINATION', 'NATURAL_MATING'];

/// The days a species needs from service to birth, used for the preview
/// only — the server dates the pregnancy.
DateTime? expectedBirthFrom(DateTime? service, int? gestationDays) =>
    service == null || gestationDays == null ? null : service.add(Duration(days: gestationDays));

String shortDate(DateTime d) => '${d.day}/${d.month}/${d.year}';

/// The "Pregnancy & milk" block of the Add / Edit Animal form: two plain
/// questions with tap targets, an insemination date when it matters, and
/// what follows from the answers (expected birth, the farm's dry-off date).
class AnimalStatusSection extends StatelessWidget {
  const AnimalStatusSection({
    super.key,
    required this.showPregnancy,
    required this.showMilk,
    required this.pregnancy,
    required this.serviceDate,
    required this.serviceType,
    required this.milk,
    required this.gestationDays,
    required this.dryOffDays,
    required this.isEdit,
    required this.wasLactating,
    required this.onPregnancy,
    required this.onServiceDate,
    required this.onServiceType,
    required this.onMilk,
    this.adjustedNote,
    this.loadingHistory = false,
    this.calvingDate,
    this.onCalvingDate,
    this.calvingLocked = false,
    this.peakStartDays = 40,
    this.peakEndDays = 70,
    this.breedingWaitDays = 50,
  });

  final bool showPregnancy;
  final bool showMilk;
  final PregnancyChoice pregnancy;
  final DateTime? serviceDate;
  final String serviceType;
  final MilkChoice milk;
  final int? gestationDays;
  final int dryOffDays;
  final bool isEdit;
  final bool wasLactating;
  final ValueChanged<PregnancyChoice> onPregnancy;
  final ValueChanged<DateTime> onServiceDate;
  final ValueChanged<String> onServiceType;
  final ValueChanged<MilkChoice> onMilk;

  /// Set when an answer changed the life stage or profile above (a cow said
  /// to be in milk becomes a dairy cow) — said, never done silently.
  final String? adjustedNote;
  final bool loadingHistory;

  /// The calving (start of milking) of the current lactation, and the
  /// farm's calendar after it. [calvingLocked] when a recorded birth dates it.
  final DateTime? calvingDate;
  final ValueChanged<DateTime>? onCalvingDate;
  final bool calvingLocked;
  final int peakStartDays;
  final int peakEndDays;
  final int breedingWaitDays;

  @override
  Widget build(BuildContext context) {
    final birth = pregnancy == PregnancyChoice.pregnant ? expectedBirthFrom(serviceDate, gestationDays) : null;
    final dryFrom = birth?.subtract(Duration(days: dryOffDays));
    final served = pregnancy != PregnancyChoice.open;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (loadingHistory) const LinearProgressIndicator(minHeight: 2),
      if (showPregnancy) ...[
        Text(context.t('stPregnancyQuestion'), style: FarmTypography.textTheme.titleSmall),
        const SizedBox(height: 6),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final c in PregnancyChoice.values)
            ChoiceChip(
              label: Text(context.t('stPreg_${c.name}')),
              selected: pregnancy == c,
              onSelected: (_) => onPregnancy(c),
            ),
        ]),
        if (served) ...[
          const SizedBox(height: 10),
          Wrap(spacing: 12, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
            SizedBox(
              width: 230,
              child: OutlinedButton.icon(
                onPressed: () async {
                  final now = DateTime.now();
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: serviceDate ?? now,
                    firstDate: now.subtract(Duration(days: (gestationDays ?? 370) + 30)),
                    lastDate: now,
                    helpText: context.t('stServiceDate'),
                  );
                  if (picked != null) onServiceDate(picked);
                },
                icon: const Icon(Icons.event, size: 18),
                label: Text(
                  serviceDate == null ? '${context.t('stServiceDate')}…' : '${context.t('stServiceDate')}: ${shortDate(serviceDate!)}',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            SizedBox(
              width: 230,
              child: DropdownButtonFormField<String>(
                value: kServiceTypes.contains(serviceType) ? serviceType : kServiceTypes.first,
                isExpanded: true,
                decoration: InputDecoration(labelText: context.t('stServiceType'), isDense: true),
                items: [for (final t in kServiceTypes) DropdownMenuItem(value: t, child: Text(context.t('stService_$t'), overflow: TextOverflow.ellipsis))],
                onChanged: (v) {
                  if (v != null) onServiceType(v);
                },
              ),
            ),
          ]),
          const SizedBox(height: 6),
          if (pregnancy == PregnancyChoice.inseminated)
            Text(context.t('stInseminatedNote'), style: FarmTypography.textTheme.bodySmall)
          else if (birth != null)
            Text(
              '${context.t('stExpectedBirth')} ${shortDate(birth)}'
              '${dryFrom != null && showMilk ? ' · ${context.t('stDryOffFrom')} ${shortDate(dryFrom)} ($dryOffDays ${context.t('stDaysBefore')})' : ''}',
              style: FarmTypography.textTheme.bodySmall?.copyWith(color: FarmColors.cedarDark, fontWeight: FontWeight.w600),
            )
          else
            Text(context.t('stAddServiceDate'), style: FarmTypography.textTheme.bodySmall),
        ],
        const SizedBox(height: FarmSpacing.md),
      ],
      if (showMilk) ...[
        Text(context.t('stMilkQuestion'), style: FarmTypography.textTheme.titleSmall),
        const SizedBox(height: 6),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final c in MilkChoice.values)
            ChoiceChip(
              label: Text(context.t('stMilk_${c.name}')),
              selected: milk == c,
              onSelected: (_) => onMilk(c),
            ),
        ]),
        if (milk == MilkChoice.milking && onCalvingDate != null) ...[
          const SizedBox(height: 10),
          if (calvingLocked)
            Text('${context.t('calvingDate')}: ${calvingDate != null ? shortDate(calvingDate!) : '—'} · ${context.t('stCalvingFromBirth')}',
                style: FarmTypography.textTheme.bodySmall)
          else
            RecordDateButton(
              label: context.t('calvingDate'),
              value: calvingDate ?? DateTime.now(),
              maxDaysBack: 700,
              onPicked: onCalvingDate!,
            ),
          if (calvingDate != null) ...[
            const SizedBox(height: 4),
            Text(
              '${context.t('stMilkPeak')} ${shortDate(calvingDate!.add(Duration(days: peakStartDays)))} – ${shortDate(calvingDate!.add(Duration(days: peakEndDays)))}'
              '${pregnancy == PregnancyChoice.open ? ' · ${context.t('stInseminateFrom')} ${shortDate(calvingDate!.add(Duration(days: breedingWaitDays)))}' : ''}',
              style: FarmTypography.textTheme.bodySmall?.copyWith(color: FarmColors.cedarDark, fontWeight: FontWeight.w600),
            ),
          ],
        ],
        const SizedBox(height: 6),
        if (milk == MilkChoice.milking && !wasLactating)
          Text(context.t('stMilkOpensAfterSave'), style: FarmTypography.textTheme.bodySmall)
        else if (milk == MilkChoice.dry && wasLactating)
          Text(context.t('stDryOffRecorded'), style: FarmTypography.textTheme.bodySmall)
        else if (milk == MilkChoice.milking && dryFrom != null)
          Text('${context.t('stDryOffFrom')} ${shortDate(dryFrom)} ($dryOffDays ${context.t('stDaysBefore')})', style: FarmTypography.textTheme.bodySmall),
      ],
      if (adjustedNote != null) ...[
        const SizedBox(height: FarmSpacing.sm),
        NoticeBanner(text: adjustedNote!, tone: NoticeTone.info),
      ],
      if (isEdit) ...[
        const SizedBox(height: 6),
        Text(context.t('stSavedAsRecords'), style: const TextStyle(fontSize: 12, color: FarmColors.muted)),
      ],
    ]);
  }
}
