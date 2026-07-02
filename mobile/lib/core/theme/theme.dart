import 'package:flutter/material.dart';
import 'colors.dart';
import 'typography.dart';

class FarmOSTheme {
  static ThemeData get lightTheme {
    return ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: FarmOSColors.teal,
        primary: FarmOSColors.teal,
        secondary: FarmOSColors.coral,
        tertiary: FarmOSColors.lavender,
        surface: FarmOSColors.background,
        onPrimary: FarmOSColors.surface,
        onSecondary: FarmOSColors.surface,
        onSurface: FarmOSColors.graphite,
      ),
      scaffoldBackgroundColor: FarmOSColors.background,
      textTheme: FarmOSTypography.textTheme,
      appBarTheme: const AppBarTheme(
        backgroundColor: FarmOSColors.surface,
        foregroundColor: FarmOSColors.graphite,
        elevation: 0,
        centerTitle: true,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: FarmOSColors.teal,
          foregroundColor: FarmOSColors.surface,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: FarmOSTypography.textTheme.labelLarge,
        ),
      ),
      cardTheme: CardThemeData(
        color: FarmOSColors.surface,
        elevation: 2,
        shadowColor: FarmOSColors.mist.withAlpha(51), // 0.2 opacity ~ 51 alpha
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
      ),
    );
  }
}
