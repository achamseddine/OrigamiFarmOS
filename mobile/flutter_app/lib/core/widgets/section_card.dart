import 'package:flutter/material.dart';
import '../theme/colors.dart';
import '../theme/spacing.dart';
import '../theme/typography.dart';

/// Generic rounded card wrapper used by every panel so radius / shadow /
/// padding stay consistent across the 10 screens.
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
        border: Border.all(color: FarmColors.border),
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
