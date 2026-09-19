import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/widgets/app_icon.dart';
import '../../core/widgets/status_pill.dart';
import '../../domain/entities/access.dart';
import '../../domain/entities/notification.dart';
import '../../providers/access_provider.dart';
import '../../providers/notifications_provider.dart';
import '../../providers/tasks_provider.dart';
import '../navigation/entity_router.dart';
import '../notifications/notification_panel.dart' show priorityLevel, priorityColor;

/// One Today's Priorities card (tech spec §4).
///
/// The whole card is a tap target that opens the record behind it — the
/// version this replaces rendered the same information as flat, dead text.
/// A card for a task also carries a Done button, so the most common action
/// does not need a trip to another screen.
class PriorityCard extends StatelessWidget {
  const PriorityCard({super.key, required this.priority, this.onChanged, this.dense = false});

  final FarmPriority priority;
  final VoidCallback? onChanged;
  final bool dense;

  static const _iconForModule = {
    FarmModule.animals: FarmIcon.cow,
    FarmModule.animalHealth: FarmIcon.stethoscope,
    FarmModule.feedNutrition: FarmIcon.feedBag,
    FarmModule.inventory: FarmIcon.inventory,
    FarmModule.milkProduction: FarmIcon.milkBottle,
    FarmModule.eggProduction: FarmIcon.egg,
    FarmModule.agriculture: FarmIcon.leaf,
    FarmModule.produceHarvest: FarmIcon.harvestBasket,
    FarmModule.mounehProduction: FarmIcon.inventory,
    FarmModule.mounehInventory: FarmIcon.inventory,
    FarmModule.farmVisits: FarmIcon.calendar,
    FarmModule.finance: FarmIcon.money,
    FarmModule.sales: FarmIcon.money,
    FarmModule.tasks: FarmIcon.task,
    FarmModule.aiIntelligence: FarmIcon.chartLine,
  };

  @override
  Widget build(BuildContext context) {
    final access = context.read<AccessProvider>();
    final language = Localizations.localeOf(context).languageCode;
    final accent = priorityColor(priority.priority);
    final icon = _iconForModule[priority.moduleCode] ?? FarmIcon.warning;

    // Paper fill inside the white panel this sits in, like every other row
    // in the product. The card used to carry a border on three sides plus
    // a 3px accent rail on the fourth — but the roundel below is already
    // tinted with that same accent and the row ends in a status pill, so
    // the rail was the third telling of one fact. Urgency reads from the
    // roundel and the pill; the row is allowed to be a row.
    return Material(
      color: FarmColors.stone,
      borderRadius: BorderRadius.circular(FarmRadii.sm + 2),
      child: InkWell(
        onTap: () => EntityRouter.openEntityOrExplain(context, priority.entityType, priority.entityId),
        borderRadius: BorderRadius.circular(FarmRadii.sm + 2),
        child: Container(
          padding: EdgeInsets.all(dense ? 12 : FarmSpacing.md),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: FarmColors.tint(accent, 0.18),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Center(child: AppIcon(icon, size: 18, color: accent)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(priority.title, style: FarmTypography.textTheme.titleSmall),
                    if (priority.description != null && priority.description!.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          priority.description!,
                          style: FarmTypography.textTheme.bodySmall,
                          maxLines: dense ? 1 : 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        StatusPill(label: priority.priority, level: priorityLevel(priority.priority), dense: true),
                        StatusPill(
                          label: access.moduleLabel(priority.moduleCode, language),
                          level: FarmStatusLevel.neutral,
                          dense: true,
                        ),
                        if (priority.isTask)
                          StatusPill(label: context.t('task'), level: FarmStatusLevel.info, dense: true),
                        if (priority.assignedToName != null)
                          Text('· ${priority.assignedToName}', style: const TextStyle(fontSize: 11, color: FarmColors.muted)),
                        if (priority.dueAt != null)
                          Text(
                            '· ${TimeOfDay.fromDateTime(priority.dueAt!).format(context)}',
                            style: const TextStyle(fontSize: 11, color: FarmColors.muted),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              if (priority.taskId != null)
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: Tooltip(
                    message: context.t('markDone'),
                    child: IconButton(
                      icon: const Icon(Icons.check_circle_outline, size: 20),
                      color: FarmColors.success,
                      onPressed: () async {
                        await context.read<TasksProvider>().toggle(priority.taskId!);
                        if (!context.mounted) return;
                        await context.read<NotificationsProvider>().load();
                        onChanged?.call();
                      },
                    ),
                  ),
                )
              else
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Icon(Icons.chevron_right, size: 18, color: FarmColors.muted),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
