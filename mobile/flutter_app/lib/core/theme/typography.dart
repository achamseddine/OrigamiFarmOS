import 'package:flutter/material.dart';
import 'colors.dart';

/// Origami FarmOS type system.
///
/// Brand spec: Display/headings use Fraunces with a Georgia fallback; UI text
/// uses Inter with a system-ui fallback; Arabic uses Noto Sans Arabic with a
/// Tahoma fallback. This build ships no bundled font files (offline-first
/// tablets should not depend on a runtime font fetch), so it intentionally
/// uses the *fallback* tier everywhere: platform serif for display (resolves
/// to Georgia/Noto Serif) and the platform UI font for everything else
/// (resolves to Segoe UI / Roboto / San Francisco, and Android/iOS already
/// substitute Noto Sans Arabic glyphs for Arabic runs automatically). Drop
/// real Fraunces/Inter/Noto Sans Arabic .ttf files into `assets/fonts/` and
/// declare them in pubspec.yaml to upgrade to pixel-perfect brand type
/// without touching call sites.
class FarmTypography {
  FarmTypography._();

  static const String _displayFamily = 'serif';

  static TextStyle display({
    double size = 34,
    FontWeight weight = FontWeight.w600,
    Color color = FarmColors.ink,
    double? height,
  }) =>
      TextStyle(
        fontFamily: _displayFamily,
        fontSize: size,
        fontWeight: weight,
        color: color,
        height: height,
        letterSpacing: -0.2,
      );

  static const TextTheme textTheme = TextTheme(
    displayLarge: TextStyle(
      fontFamily: _displayFamily,
      fontSize: 44,
      fontWeight: FontWeight.w600,
      color: FarmColors.ink,
      letterSpacing: -0.4,
    ),
    displayMedium: TextStyle(
      fontFamily: _displayFamily,
      fontSize: 34,
      fontWeight: FontWeight.w600,
      color: FarmColors.ink,
      letterSpacing: -0.3,
    ),
    displaySmall: TextStyle(
      fontFamily: _displayFamily,
      fontSize: 26,
      fontWeight: FontWeight.w600,
      color: FarmColors.ink,
    ),
    headlineMedium: TextStyle(
      fontFamily: _displayFamily,
      fontSize: 22,
      fontWeight: FontWeight.w600,
      color: FarmColors.ink,
    ),
    titleLarge: TextStyle(
      fontSize: 18,
      fontWeight: FontWeight.w700,
      color: FarmColors.ink,
    ),
    titleMedium: TextStyle(
      fontSize: 16,
      fontWeight: FontWeight.w600,
      color: FarmColors.ink,
    ),
    titleSmall: TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w600,
      color: FarmColors.ink,
    ),
    bodyLarge: TextStyle(
      fontSize: 16,
      fontWeight: FontWeight.normal,
      color: FarmColors.ink,
      height: 1.4,
    ),
    bodyMedium: TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.normal,
      color: FarmColors.ink,
      height: 1.4,
    ),
    bodySmall: TextStyle(
      fontSize: 12.5,
      fontWeight: FontWeight.normal,
      color: FarmColors.muted,
      height: 1.35,
    ),
    labelLarge: TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w600,
      color: FarmColors.white,
    ),
    labelMedium: TextStyle(
      fontSize: 12.5,
      fontWeight: FontWeight.w600,
      color: FarmColors.muted,
      letterSpacing: 0.3,
    ),
    labelSmall: TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w700,
      color: FarmColors.muted,
      letterSpacing: 0.6,
    ),
  );
}
