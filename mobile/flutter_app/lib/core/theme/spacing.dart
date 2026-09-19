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
  static const double xl = 30;
  static const double pill = 999;

  static BorderRadius get card => BorderRadius.circular(md);
  static BorderRadius get panel => BorderRadius.circular(lg);
}

class FarmShadows {
  FarmShadows._();

  /// The pack's card elevation: `0 8px 28px rgba(31,35,32,.06)`.
  ///
  /// This was empty for a while, and for a good reason — every panel used
  /// to carry a 28px shadow *and* a border on a beige ground, eleven to a
  /// screen, and that is a large part of why the tablet read as a web
  /// dashboard. The asset pack puts a shadow back but at six percent,
  /// which is a different thing entirely: it separates a white card from
  /// white-ish paper without claiming the card floats.
  static List<BoxShadow> get card => [
        BoxShadow(
          color: const Color(0xFF1F2320).withOpacity(0.06),
          blurRadius: 28,
          offset: const Offset(0, 8),
        ),
      ];

  /// The pack's modal elevation: `0 28px 80px rgba(13,23,19,.22)`. A
  /// sheet or a dialog really is above the page, and says so.
  static List<BoxShadow> get elevated => [
        BoxShadow(
          color: FarmColors.black.withOpacity(0.22),
          blurRadius: 80,
          offset: const Offset(0, 28),
        ),
      ];
}

/// Minimum touch target enforced across interactive FarmOS components.
const double kFarmTouchTarget = 48;

/// What a primary button gets. Taller than the minimum on purpose: this
/// is pressed with a glove on, in a barn, by someone not looking closely.
const double kFarmPrimaryTarget = 52;

/// Tablet layout breakpoints.
const double kTabletBreakpoint = 900;
const double kTabletLandscapeMin = 1024;
