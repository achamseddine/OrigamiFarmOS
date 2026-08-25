import 'package:flutter/material.dart';

/// Origami FarmOS Option C brand palette.
/// Source of truth: design-system/tokens.json
class FarmColors {
  FarmColors._();

  static const Color cedar = Color(0xFF0B3D2E);
  static const Color cedar2 = Color(0xFF145C3D);
  static const Color olive = Color(0xFF1F7A4D);
  static const Color gold = Color(0xFFD6A84F);
  static const Color wheat = Color(0xFFF0D79A);
  static const Color stone = Color(0xFFF7F3EA);
  static const Color sand = Color(0xFFE8DEC9);
  static const Color clay = Color(0xFFB76E47);
  static const Color ink = Color(0xFF071814);
  static const Color muted = Color(0xFF65756D);
  static const Color mist = Color(0xFFEAF1EC);
  static const Color danger = Color(0xFFA63C35);
  static const Color warning = Color(0xFFD9822B);
  static const Color success = Color(0xFF1F7A4D);
  static const Color white = Color(0xFFFFFFFF);
  static const Color card = Color(0xFFFFFDF7);
  static const Color border = Color(0xFFE7DEC9);

  // Status colors (animal / recommendation status chips)
  static const Color statusHealthy = Color(0xFF1F7A4D);
  static const Color statusWatch = Color(0xFFD9822B);
  static const Color statusAlert = Color(0xFFA63C35);
  static const Color statusOffline = Color(0xFF8A7A5B);

  /// Soft tint backgrounds for status pills / icon roundels.
  static Color tint(Color c, [double opacity = 0.14]) =>
      Color.alphaBlend(c.withOpacity(opacity), card);
}
