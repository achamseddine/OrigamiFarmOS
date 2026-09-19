import 'package:flutter/material.dart';
import 'app_icon.dart';
import 'directional_icon.dart';
import '../theme/colors.dart';
import '../theme/spacing.dart';
import '../theme/typography.dart';

/// One figure from a screen's KPI strip.
///
/// Anatomy from the v1 redesign review, and it is read in this order:
/// the label and a tinted roundel across the top, the figure large
/// underneath, then one line saying what the figure is measured against.
/// A chevron sits on the far edge when the tile opens something, because
/// a tile that is tappable and does not say so is a tile nobody taps.
///
/// The roundel's colour names the *subject* — milk is the same blue
/// wherever milk appears — so a strip of six can be found by colour
/// before any of it is read. [tint] is the exception: it marks a tile
/// carrying bad news, and then the colour lands on the figure too.
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
    this.accent,
    this.onTap,
  });

  final FarmIcon icon;
  final String label;
  final String value;
  final String? unit;
  final String? trendLabel;
  final bool? trendUp;
  final String? caption;

  /// Set when this tile is carrying bad news; colours the figure.
  final Color? tint;

  /// The subject colour for the roundel. Defaults to cedar.
  final Color? accent;

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final roundel = accent ?? tint ?? FarmColors.cedar;
    final figureColor = tint == null
        ? FarmColors.ink
        : (tint == FarmColors.danger ? FarmColors.dangerInk : tint!);

    return Material(
      color: FarmColors.card,
      borderRadius: FarmRadii.card,
      child: InkWell(
        onTap: onTap,
        borderRadius: FarmRadii.card,
        child: Container(
          constraints: const BoxConstraints(minHeight: kFarmTouchTarget * 2),
          padding: const EdgeInsetsDirectional.fromSTEB(
              FarmSpacing.md + 4, FarmSpacing.md + 2, FarmSpacing.sm, FarmSpacing.md + 2),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: FarmTypography.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: FarmColors.ink,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: FarmColors.tint(roundel, 0.16),
                            shape: BoxShape.circle,
                          ),
                          child: Center(child: AppIcon(icon, size: 20, color: roundel)),
                        ),
                      ],
                    ),
                    const SizedBox(height: FarmSpacing.sm),
                    RichText(
                      text: TextSpan(
                        children: [
                          TextSpan(
                            text: value,
                            style: FarmTypography.textTheme.headlineMedium?.copyWith(color: figureColor),
                          ),
                          if (unit != null)
                            TextSpan(
                              text: ' $unit',
                              style: FarmTypography.textTheme.bodyMedium?.copyWith(color: FarmColors.muted),
                            ),
                        ],
                      ),
                    ),
                    if (trendLabel != null || caption != null) ...[
                      const SizedBox(height: 5),
                      Row(
                        children: [
                          if (trendLabel != null) ...[
                            Icon(
                              trendUp == false ? Icons.trending_down : Icons.trending_up,
                              size: 14,
                              color: trendUp == false ? FarmColors.danger : FarmColors.success,
                            ),
                            const SizedBox(width: 3),
                            Text(
                              trendLabel!,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: trendUp == false ? FarmColors.danger : FarmColors.success,
                              ),
                            ),
                            if (caption != null) const SizedBox(width: 6),
                          ],
                          if (caption != null)
                            Flexible(
                              child: Text(
                                caption!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: FarmTypography.textTheme.labelMedium?.copyWith(
                                  color: tint != null && trendLabel == null ? figureColor : FarmColors.muted,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              if (onTap != null) const ForwardChevron(size: 20, color: FarmColors.muted),
            ],
          ),
        ),
      ),
    );
  }
}
