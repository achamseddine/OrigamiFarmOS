import 'package:flutter/material.dart';
import 'app_icon.dart';
import '../theme/colors.dart';
import '../theme/spacing.dart';
import '../theme/typography.dart';

/// Compact metric card: icon, label, value, unit, trend.
/// Used in KPI strips across every dashboard screen.
class KpiCard extends StatelessWidget {
  const KpiCard({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    this.unit,
    this.trendLabel,
    this.trendUp,
    this.caption,
    this.tint,
    this.onTap,
  });

  final FarmIcon icon;
  final String label;
  final String value;
  final String? unit;
  final String? trendLabel;
  final bool? trendUp;
  final String? caption;
  final Color? tint;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    // `tint` marks a tile carrying bad news. It used to wash the whole
    // card and outline it, which made one tile shout over every other
    // figure on the screen. The tile now stays paper-white like its
    // neighbours and the colour lands on the icon and the figure — the
    // two things actually being read.
    final accent = tint ?? FarmColors.muted;
    final figureColor = tint == null
        ? FarmColors.ink
        : (tint == FarmColors.danger ? FarmColors.dangerInk : accent);

    return Material(
      color: FarmColors.card,
      borderRadius: FarmRadii.card,
      child: InkWell(
        onTap: onTap,
        borderRadius: FarmRadii.card,
        child: Container(
          constraints: const BoxConstraints(minHeight: kFarmTouchTarget * 2),
          padding: const EdgeInsets.symmetric(
            horizontal: FarmSpacing.md + 4,
            vertical: FarmSpacing.md + 2,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // Label above, figure below. A tile is read top to bottom,
              // and the label is what says which figure this is.
              Row(
                children: [
                  AppIcon(icon, size: 17, color: accent),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: FarmTypography.textTheme.bodySmall
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                  if (trendLabel != null) ...[
                    Icon(
                      trendUp == false ? Icons.trending_down : Icons.trending_up,
                      size: 14,
                      color: trendUp == false ? FarmColors.danger : FarmColors.success,
                    ),
                    const SizedBox(width: 2),
                    Text(
                      trendLabel!,
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: trendUp == false ? FarmColors.danger : FarmColors.success,
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: FarmSpacing.md),
              RichText(
                text: TextSpan(
                  children: [
                    TextSpan(
                      text: value,
                      style: FarmTypography.textTheme.headlineMedium
                          ?.copyWith(color: figureColor),
                    ),
                    if (unit != null)
                      TextSpan(
                        text: ' $unit',
                        style: FarmTypography.textTheme.bodyMedium
                            ?.copyWith(color: FarmColors.muted),
                      ),
                  ],
                ),
              ),
              if (caption != null) ...[
                const SizedBox(height: 5),
                Text(
                  caption!,
                  style: FarmTypography.textTheme.labelMedium?.copyWith(
                    color: tint != null ? figureColor : FarmColors.muted,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
