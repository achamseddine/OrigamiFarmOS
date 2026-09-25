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
    final accent = tint ?? FarmColors.cedar;
    return Material(
      color: tint != null ? FarmColors.tint(accent, 0.10) : FarmColors.card,
      borderRadius: FarmRadii.card,
      child: InkWell(
        onTap: onTap,
        borderRadius: FarmRadii.card,
        child: Container(
          constraints: const BoxConstraints(minHeight: kFarmTouchTarget * 1.8),
          padding: const EdgeInsets.all(FarmSpacing.md),
          decoration: BoxDecoration(
            borderRadius: FarmRadii.card,
            border: Border.all(
              color: tint != null ? accent.withOpacity(0.35) : FarmColors.border,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: FarmColors.tint(accent, 0.16),
                      shape: BoxShape.circle,
                    ),
                    child: Center(child: AppIcon(icon, size: 17, color: accent)),
                  ),
                  const Spacer(),
                  if (trendLabel != null)
                    Row(
                      children: [
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
                    ),
                ],
              ),
              const SizedBox(height: 10),
              RichText(
                text: TextSpan(
                  children: [
                    TextSpan(
                      text: value,
                      style: FarmTypography.textTheme.headlineMedium,
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
              const SizedBox(height: 2),
              Text(label, style: FarmTypography.textTheme.bodySmall),
              if (caption != null) ...[
                const SizedBox(height: 4),
                Text(
                  caption!,
                  style: FarmTypography.textTheme.labelMedium?.copyWith(
                    color: tint != null ? accent : FarmColors.muted,
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
