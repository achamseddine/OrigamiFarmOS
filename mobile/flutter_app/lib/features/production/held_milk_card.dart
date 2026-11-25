import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/util/record_dates.dart';
import '../../core/widgets/section_card.dart';
import '../../core/widgets/status_pill.dart';
import '../../domain/entities/production_records.dart';
import '../../providers/access_provider.dart';
import '../../providers/production_provider.dart';
import '../health/pharmacy_tab.dart' show askReason;
import 'milk_sessions.dart';

/// Milk held for review (v0.8.5): kept, never counted in the tank or sold,
/// because the records cannot confirm it was clear of a withdrawal when it
/// was milked — or a withdrawal was recorded after it was saved. A
/// veterinarian or the farm manager releases it (saying why) or withholds
/// it; the server refuses to release milk a recorded withdrawal covers.
/// Everyone who sees the Milk page sees what is held.
class HeldMilkCard extends StatefulWidget {
  const HeldMilkCard({super.key});

  @override
  State<HeldMilkCard> createState() => _HeldMilkCardState();
}

class _HeldMilkCardState extends State<HeldMilkCard> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => context.read<ProductionProvider>().loadHeldMilk());
  }

  static const _reviewRoles = {'owner', 'manager', 'veterinarian'};

  Future<void> _decide(MilkRecord r, String decision) async {
    final why = await askReason(
      context,
      title: context.t(decision == 'release' ? 'hmRelease' : 'hmWithhold'),
      label: context.t(decision == 'release' ? 'hmReleaseWhy' : 'hmWithholdWhy'),
    );
    if (why == null || !mounted) return;
    final result = await context.read<ProductionProvider>().reviewMilk(r.id, decision: decision, note: why);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(result.success
          ? context.t(result.queued ? 'workingOffline' : (decision == 'release' ? 'hmReleased' : 'hmWithheld'))
          : (result.error ?? context.t('couldNotSave'))),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final held = context.watch<ProductionProvider>().heldMilk;
    if (held.isEmpty) return const SizedBox.shrink();
    final access = context.watch<AccessProvider>().access;
    final canReview = access.fullAccess || _reviewRoles.contains(access.role);
    final total = held.fold<double>(0, (s, r) => s + r.liters);
    return Padding(
      padding: const EdgeInsets.only(bottom: FarmSpacing.md),
      child: SectionCard(
        key: const ValueKey('held-milk-card'),
        title: context.t('hmTitle').replaceAll('{liters}', total.toStringAsFixed(total == total.roundToDouble() ? 0 : 1)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(context.t(canReview ? 'hmIntroReviewer' : 'hmIntroWorker'), style: FarmTypography.textTheme.bodySmall),
          const SizedBox(height: 8),
          for (final r in held)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(
                    child: Text(
                      '${r.animalName ?? r.animalId} · ${dayLabel(r.recordedAt.toLocal())} · ${milkSessionLabel(context, r.session)} · ${r.liters.toStringAsFixed(1)} L',
                      style: FarmTypography.textTheme.titleSmall,
                    ),
                  ),
                  StatusPill(label: context.t('hmHeld'), level: FarmStatusLevel.watch, dense: true),
                ]),
                if (r.safetyNote != null) Text(r.safetyNote!, style: const TextStyle(fontSize: 12, color: FarmColors.muted)),
                if (canReview)
                  Wrap(spacing: 8, children: [
                    TextButton(key: ValueKey('hm-withhold-${r.id}'), onPressed: () => _decide(r, 'withhold'), child: Text(context.t('hmWithhold'))),
                    FilledButton.tonal(key: ValueKey('hm-release-${r.id}'), onPressed: () => _decide(r, 'release'), child: Text(context.t('hmRelease'))),
                  ]),
              ]),
            ),
        ]),
      ),
    );
  }
}
