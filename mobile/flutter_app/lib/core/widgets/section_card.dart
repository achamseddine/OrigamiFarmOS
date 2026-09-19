import 'package:flutter/material.dart';
import '../theme/colors.dart';
import '../theme/spacing.dart';
import '../theme/typography.dart';

/// The grouped panel every screen is built from.
///
/// It used to carry a 1px border *and* a 28px drop shadow, on a beige
/// ground. Both are gone: white on warm paper is already the whole
/// separation, and a shadow claims the panel floats above the page, which
/// on a farm tablet nothing does. What is left is fill, radius and
/// padding — which is what a grouped list looks like on a tablet, and is
/// the single edit that restyles all thirty screens that use this.
class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    this.title,
    this.subtitle,
    this.trailing,
    this.onTrailingTap,
    required this.child,
    this.padding = const EdgeInsets.all(FarmSpacing.lg),
    this.elevated = false,
  });

  final String? title;
  final String? subtitle;
  final String? trailing;
  final VoidCallback? onTrailingTap;
  final Widget child;
  final EdgeInsets padding;
  final bool elevated;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: FarmColors.card,
        borderRadius: FarmRadii.card,
        boxShadow: elevated ? FarmShadows.elevated : FarmShadows.card,
      ),
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title != null) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title!, style: FarmTypography.textTheme.titleLarge),
                      if (subtitle != null) ...[
                        const SizedBox(height: 2),
                        Text(subtitle!, style: FarmTypography.textTheme.bodySmall),
                      ],
                    ],
                  ),
                ),
                if (trailing != null)
                  InkWell(
                    onTap: onTrailingTap,
                    borderRadius: BorderRadius.circular(FarmRadii.xs),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            trailing!,
                            style: FarmTypography.textTheme.labelMedium
                                ?.copyWith(color: FarmColors.cedar2),
                          ),
                          const SizedBox(width: 2),
                          const Icon(Icons.chevron_right, size: 16, color: FarmColors.cedar2),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: FarmSpacing.md),
          ],
          child,
        ],
      ),
    );
  }
}
