import 'package:flutter/material.dart';
import 'app_icon.dart';
import 'status_pill.dart';
import '../theme/colors.dart';
import '../theme/spacing.dart';
import '../theme/typography.dart';
import 'directional_icon.dart';

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
    // An alert row almost always sits inside a white SectionCard. It used
    // to be white-on-white held apart by a border; now it takes the page's
    // own paper as its fill, so the row reads as inset without a line
    // being drawn. Highlighted rows get a wash of their own accent.
    return Material(
      color: highlighted ? FarmColors.tint(accent, 0.10) : FarmColors.stone,
      borderRadius: BorderRadius.circular(FarmRadii.sm + 2),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(FarmRadii.sm + 2),
        child: Container(
          constraints: const BoxConstraints(minHeight: kFarmTouchTarget + 8),
          padding: const EdgeInsets.all(FarmSpacing.md - 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: FarmColors.tint(accent, 0.18),
                  borderRadius: BorderRadius.circular(13),
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
                const ForwardChevron(size: 18, color: FarmColors.muted),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
