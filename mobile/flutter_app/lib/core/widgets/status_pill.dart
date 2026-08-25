import 'package:flutter/material.dart';
import '../theme/colors.dart';
import '../theme/spacing.dart';

/// Status is never color-only (tech spec §18 accessibility rule): every pill
/// carries an icon and a label alongside its tint.
enum FarmStatusLevel { good, watch, alert, info, neutral }

class StatusPill extends StatelessWidget {
  const StatusPill({
    super.key,
    required this.label,
    required this.level,
    this.icon,
    this.dense = false,
  });

  final String label;
  final FarmStatusLevel level;
  final IconData? icon;
  final bool dense;

  Color get _color {
    switch (level) {
      case FarmStatusLevel.good:
        return FarmColors.statusHealthy;
      case FarmStatusLevel.watch:
        return FarmColors.statusWatch;
      case FarmStatusLevel.alert:
        return FarmColors.statusAlert;
      case FarmStatusLevel.info:
        return FarmColors.cedar2;
      case FarmStatusLevel.neutral:
        return FarmColors.muted;
    }
  }

  IconData get _defaultIcon {
    switch (level) {
      case FarmStatusLevel.good:
        return Icons.check_circle;
      case FarmStatusLevel.watch:
        return Icons.remove_red_eye_outlined;
      case FarmStatusLevel.alert:
        return Icons.error;
      case FarmStatusLevel.info:
        return Icons.info;
      case FarmStatusLevel.neutral:
        return Icons.circle;
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = _color;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: dense ? 8 : 12,
        vertical: dense ? 4 : 7,
      ),
      decoration: BoxDecoration(
        color: FarmColors.tint(color, 0.14),
        borderRadius: BorderRadius.circular(FarmRadii.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon ?? _defaultIcon, size: dense ? 12 : 14, color: color),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w700,
              fontSize: dense ? 11 : 12.5,
            ),
          ),
        ],
      ),
    );
  }
}
