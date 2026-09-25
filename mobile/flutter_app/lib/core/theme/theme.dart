import 'package:flutter/material.dart';
import 'colors.dart';
import 'spacing.dart';
import 'typography.dart';

class FarmTheme {
  FarmTheme._();

  static ThemeData get light {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: FarmColors.cedar,
      brightness: Brightness.light,
      primary: FarmColors.cedar,
      secondary: FarmColors.gold,
      tertiary: FarmColors.olive,
      surface: FarmColors.card,
      error: FarmColors.danger,
      onPrimary: FarmColors.white,
      onSecondary: FarmColors.ink,
      onSurface: FarmColors.ink,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: FarmColors.stone,
      textTheme: FarmTypography.textTheme,
      fontFamily: FarmTypography.textTheme.bodyMedium?.fontFamily,
      splashFactory: InkRipple.splashFactory,
      dividerTheme: const DividerThemeData(
        color: FarmColors.border,
        thickness: 1,
        space: 1,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: FarmColors.stone,
        foregroundColor: FarmColors.ink,
        elevation: 0,
        centerTitle: false,
        surfaceTintColor: Colors.transparent,
      ),
      cardTheme: CardThemeData(
        color: FarmColors.card,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: FarmRadii.card,
          side: const BorderSide(color: FarmColors.border, width: 1),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: FarmColors.mist,
        labelStyle: FarmTypography.textTheme.labelMedium,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(FarmRadii.pill)),
        side: BorderSide.none,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: FarmColors.cedar,
          foregroundColor: FarmColors.white,
          disabledBackgroundColor: FarmColors.muted.withOpacity(0.4),
          minimumSize: const Size(kFarmTouchTarget * 2, kFarmTouchTarget),
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(FarmRadii.sm)),
          textStyle: FarmTypography.textTheme.labelLarge,
          elevation: 0,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: FarmColors.cedar,
          side: const BorderSide(color: FarmColors.border, width: 1.4),
          minimumSize: const Size(kFarmTouchTarget * 2, kFarmTouchTarget),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(FarmRadii.sm)),
          textStyle: FarmTypography.textTheme.titleSmall,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: FarmColors.cedar2,
          minimumSize: const Size(64, kFarmTouchTarget),
          textStyle: FarmTypography.textTheme.titleSmall,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: FarmColors.white,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(FarmRadii.sm),
          borderSide: const BorderSide(color: FarmColors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(FarmRadii.sm),
          borderSide: const BorderSide(color: FarmColors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(FarmRadii.sm),
          borderSide: const BorderSide(color: FarmColors.cedar, width: 1.6),
        ),
      ),
      iconTheme: const IconThemeData(color: FarmColors.cedar, size: 22),
    );
  }
}
