import 'package:flutter/material.dart';

/// Origami FarmOS palette — paper, ink, and one seal.
///
/// Values are the v1 asset pack's `06_design_tokens/design_tokens.json`
/// (and its Dart twin, `08_flutter/origami_design_tokens.dart`). Where
/// the pack's name differs from the one this codebase grew up with, both
/// names exist and point at the one value, so either reads correctly.
///
/// The names are unchanged on purpose: every screen already reads
/// `FarmColors.cedar`, `FarmColors.gold` and the rest, so swapping the
/// values restyles the whole product without touching a single screen.
/// What each name *means* has shifted, and that is deliberate:
///
///   - The ground was a dusty beige (#F7F3EA) and is now near-white
///     paper. The old palette read heavy because of the ground and the
///     card fills, not because of the green.
///   - Mustard, rust and brick are gone. One bold colour is left —
///     persimmon, the seal — spent only on what is actually urgent. When
///     you see it, something wants you.
///   - Buttons and the selected tab stay dark enough for white text to
///     survive a tablet held up in July sunlight (>4.5:1).
///
/// Status is never carried by colour alone; see `StatusPill`, which pairs
/// every tint with an icon and a label.
class FarmColors {
  FarmColors._();

  // --- paper and ink ---------------------------------------------------
  /// The page. Warm near-white, not beige.
  static const Color stone = Color(0xFFF7F5F0);

  /// A raised sheet: grouped lists, tiles, the tab bar.
  static const Color card = Color(0xFFFFFFFF);

  /// Every rule in the product is this, one pixel, and nothing heavier.
  static const Color border = Color(0xFFE3DFD7);

  /// A slightly deeper paper, for a segmented-control track or an inset.
  static const Color sand = Color(0xFFE8E4DA);

  static const Color ink = Color(0xFF1F2320);
  static const Color muted = Color(0xFF656A65);
  static const Color white = Color(0xFFFFFFFF);

  // --- the farm --------------------------------------------------------
  /// Primary. Nav selection, primary buttons, the brand mark.
  static const Color cedar = Color(0xFF2F6B4F);

  /// The underside of a folded corner — see [FarmFold].
  static const Color cedarFold = Color(0xFF245640);

  /// Links and quiet accents.
  static const Color cedar2 = Color(0xFF35795A);
  static const Color olive = Color(0xFF35795A);

  /// The pack's name for the same value (`cedar_mid`), kept so code
  /// written against `08_flutter/origami_design_tokens.dart` reads here.
  static const Color cedarMid = Color(0xFF35795A);

  /// A pale wash of the primary, for icon roundels and tints.
  static const Color mist = Color(0xFFE9EFEA);

  /// Pack name for [mist] (`cedar_pale`).
  static const Color cedarPale = Color(0xFFE9EFEA);

  // --- the seal --------------------------------------------------------
  /// Persimmon. The one bold colour, and the only one that means "now".
  static const Color clay = Color(0xFFC2543C);
  static const Color danger = Color(0xFFC2543C);

  /// Persimmon dark enough to read as small text on paper.
  static const Color dangerInk = Color(0xFFA8432D);
  static const Color dangerPale = Color(0xFFF6E6E1);

  // --- brand gold ------------------------------------------------------
  //
  // The v1 asset pack splits these two, and they had been one colour
  // here. Gold is the *brand* accent — the sun on the sign-in card, the
  // rule under the headline, the egg roundel — and it is brighter than
  // anything that means "be careful". Warning is the semantic one and
  // keeps the darker value, because a caution colour has to hold its own
  // as small text on paper in outdoor light.
  static const Color gold = Color(0xFFD6A84F);

  // --- watch -----------------------------------------------------------
  static const Color warning = Color(0xFFA67A2B);
  static const Color warningInk = Color(0xFF8A6320);
  static const Color wheat = Color(0xFFF4ECDC);

  /// Pack name for [wheat] (`warning_pale`).
  static const Color warningPale = Color(0xFFF4ECDC);

  static const Color success = Color(0xFF2F6B4F);

  /// The deepest cedar in the pack — the cedar tree in the artwork, and
  /// text that has to hold on a cedar fill.
  static const Color cedarDark = Color(0xFF174936);

  /// One step off paper. Used where a surface needs to recede without
  /// becoming a bordered box.
  static const Color surfaceSoft = Color(0xFFF1F0EA);

  /// Near-black from the pack, for scrims rather than for text.
  static const Color black = Color(0xFF0D1713);

  // --- subject colours -------------------------------------------------
  //
  // Not severity. These say *what a thing is* so a grid of roundels can
  // be read by colour before the labels are: milk is always this blue,
  // medicine always this lilac, wherever they appear. Both are muted
  // enough to sit beside cedar and gold without shouting, and neither is
  // ever used to mean "good" or "wrong".
  static const Color milkBlue = Color(0xFF3E7FA6);
  static const Color lilac = Color(0xFF7A5EA6);

  /// The pale fills the pack pairs with them, for roundels behind those
  /// two icons — exact values rather than a computed tint.
  static const Color skyBluePale = Color(0xFFDFF1F7);
  static const Color purplePale = Color(0xFFEDE5F7);

  // Status colors (animal / recommendation status chips)
  static const Color statusHealthy = Color(0xFF2F6B4F);
  static const Color statusWatch = Color(0xFFA67A2B);
  static const Color statusAlert = Color(0xFFC2543C);
  static const Color statusOffline = Color(0xFF8A8F89);

  /// Soft tint backgrounds for status pills / icon roundels.
  static Color tint(Color c, [double opacity = 0.14]) =>
      Color.alphaBlend(c.withOpacity(opacity), card);
}

/// The origami cue: a corner folded back, showing the paper's underside.
///
/// Used in exactly three places — the brand mark, the selected tab, and
/// the primary button — and nowhere else. A fold on every surface stops
/// being a fold and becomes a texture.
class FarmFold {
  FarmFold._();

  /// How far the corner is turned back, in logical pixels.
  static const double size = 14;

  /// The same fold on a small mark (a 40-44px square).
  static const double sizeSmall = 12;
}
