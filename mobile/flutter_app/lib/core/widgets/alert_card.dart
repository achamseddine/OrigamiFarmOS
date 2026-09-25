import 'package:flutter/material.dart';
import 'app_icon.dart';
import 'status_pill.dart';
import '../theme/colors.dart';
import '../theme/spacing.dart';
import '../theme/typography.dart';

/// Alert / recommendation row: priority pill, icon roundel, title, evidence
/// lines, optional chevron. Used for animal alerts, feed warnings, harvest
/// reminders and health-intelligence alerts (tech spec component-spec.md).
class AlertCard extends StatelessWidget {
  const AlertCard({
    super.key,
    required this.icon,
    required this.title,
    required this.level,
    this.eyebrow,
    this.evidence = const [],
    this.trailingLabel,
    this.onTap,
    this.highlighted = false,
  });

  final FarmIcon icon;
  final String title;
  final FarmStatusLevel level;
  final String? eyebrow;
  final List<String> evidence;
  final String? trailingLabel;
  final VoidCallback? onTap;
  final bool highlighted;

  Color get _accent {
    switch (level) {
      case FarmStatusLevel.alert:
        return FarmColors.danger;
      case FarmStatusLevel.watch:
        return FarmColors.warning;
      case FarmStatusLevel.good:
        return FarmColors.success;
      case FarmStatusLevel.info:
        return FarmColors.cedar2;
      case FarmStatusLevel.neutral:
        return FarmColors.muted;
    }
  }

  @override
  Widget build(BuildContext context) {
    final accent = _accent;
    return Material(
      color: highlighted ? FarmColors.tint(accent, 0.08) : FarmColors.card,
      borderRadius: BorderRadius.circular(FarmRadii.sm),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(FarmRadii.sm),
        child: Container(
          constraints: const BoxConstraints(minHeight: kFarmTouchTarget),
          padding: const EdgeInsets.all(FarmSpacing.sm + 4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(FarmRadii.sm),
            border: Border.all(
              color: highlighted ? accent.withOpacity(0.35) : FarmColors.border,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: FarmColors.tint(accent, 0.16),
                  shape: BoxShape.circle,
                ),
                child: Center(child: AppIcon(icon, size: 19, color: accent)),
              ),
              const SizedBox(width: FarmSpacing.sm + 4),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (eyebrow != null)
                      Text(
                        eyebrow!,
                        style: FarmTypography.textTheme.labelSmall?.copyWith(color: accent),
                      ),
                    if (eyebrow != null) const SizedBox(height: 3),
                    Text(title, style: FarmTypography.textTheme.titleSmall),
                    for (final line in evidence) ...[
                      const SizedBox(height: 2),
                      Text(line, style: FarmTypography.textTheme.bodySmall),
                    ],
                  ],
                ),
              ),
              if (trailingLabel != null) ...[
                const SizedBox(width: FarmSpacing.sm),
                StatusPill(label: trailingLabel!, level: level, dense: true),
              ],
              if (onTap != null) ...[
                const SizedBox(width: 4),
                const Icon(Icons.chevron_right, size: 18, color: FarmColors.muted),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
