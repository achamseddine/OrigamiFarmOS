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
  static const double md = 20;
  static const double lg = 24;
  static const double xl = 32;
  static const double pill = 999;

  static BorderRadius get card => BorderRadius.circular(md);
  static BorderRadius get panel => BorderRadius.circular(lg);
}

class FarmShadows {
  FarmShadows._();

  /// Deliberately empty.
  ///
  /// Every panel used to carry a 28px drop shadow *and* a border, on a
  /// beige ground. Eleven of those on one screen is a large part of why
  /// the tablet read as a web dashboard: a shadow says "this floats above
  /// the page", and nothing on a farm screen floats. A grouped list on
  /// paper needs its own white fill and nothing else — the fill against
  /// the warm ground is already the whole separation.
  ///
  /// Kept as a token rather than deleted so every call site still
  /// compiles, and so putting elevation back anywhere is one edit here
  /// instead of a hunt through the screens.
  static List<BoxShadow> get card => const [];

  /// The one thing that really is above the page: a sheet or a dialog.
  static List<BoxShadow> get elevated => [
        BoxShadow(
          color: FarmColors.ink.withOpacity(0.13),
          blurRadius: 40,
          offset: const Offset(0, 14),
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
