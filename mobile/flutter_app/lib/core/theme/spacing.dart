import 'package:flutter/material.dart';
import 'colors.dart';

/// Spacing / radius / shadow tokens from design-system/tokens.json.
class FarmSpacing {
  FarmSpacing._();

  static const double xs = 4;
  static const double sm = 8;
  static const double md = 16;
  static const double lg = 24;
  static const double xl = 32;
  static const double xxl = 48;
}

class FarmRadii {
  FarmRadii._();

  static const double xs = 8;
  static const double sm = 12;
  static const double md = 18;
  static const double lg = 24;
  static const double xl = 32;
  static const double pill = 999;

  static BorderRadius get card => BorderRadius.circular(md);
  static BorderRadius get panel => BorderRadius.circular(lg);
}

class FarmShadows {
  FarmShadows._();

  static List<BoxShadow> get card => [
        BoxShadow(
          color: FarmColors.ink.withOpacity(0.06),
          blurRadius: 28,
          offset: const Offset(0, 10),
        ),
      ];

  static List<BoxShadow> get elevated => [
        BoxShadow(
          color: FarmColors.ink.withOpacity(0.16),
          blurRadius: 48,
          offset: const Offset(0, 18),
        ),
      ];
}

/// Minimum touch target enforced across interactive FarmOS components.
const double kFarmTouchTarget = 48;

/// Tablet layout breakpoints.
const double kTabletBreakpoint = 900;
const double kTabletLandscapeMin = 1024;
