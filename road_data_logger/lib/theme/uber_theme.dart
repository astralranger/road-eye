import 'package:flutter/material.dart';

class UberColors {
  // Pure Monochromatic Core
  static const Color background = Color(0xFF000000);
  static const Color surface = Color(0xFF121212);
  static const Color surfaceElevated = Color(0xFF1A1A1A);
  static const Color surfaceInput = Color(0xFF222222);
  static const Color surfaceHighlight = Color(0xFF2C2C2C);

  // Borders & Dividers
  static const Color border = Color(0xFF2A2A2A);
  static const Color borderSubtle = Color(0xFF1F1F1F);
  static const Color borderActive = Color(0xFFFFFFFF);

  // High-Contrast Typography
  static const Color textPrimary = Color(0xFFFFFFFF);
  static const Color textSecondary = Color(0xFFA6A6A6);
  static const Color textTertiary = Color(0xFF6E6E6E);

  // Brand Accents
  static const Color white = Color(0xFFFFFFFF);
  static const Color black = Color(0xFF000000);
  static const Color blue = Color(0xFF276EF1); // Uber Safety Blue
  static const Color red = Color(0xFFE11900);  // Uber Alert / Stop Red
  static const Color amber = Color(0xFFFFC043); // Warning Amber
  static const Color green = Color(0xFF048848); // Success Green
}

class UberTypography {
  static const TextStyle display = TextStyle(
    color: UberColors.textPrimary,
    fontSize: 34,
    fontWeight: FontWeight.w800,
    letterSpacing: -0.5,
    height: 1.1,
  );

  static const TextStyle headline = TextStyle(
    color: UberColors.textPrimary,
    fontSize: 24,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.3,
  );

  static const TextStyle title = TextStyle(
    color: UberColors.textPrimary,
    fontSize: 17,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.2,
  );

  static const TextStyle body = TextStyle(
    color: UberColors.textPrimary,
    fontSize: 14,
    fontWeight: FontWeight.w400,
    height: 1.4,
  );

  static const TextStyle bodyMedium = TextStyle(
    color: UberColors.textPrimary,
    fontSize: 14,
    fontWeight: FontWeight.w500,
  );

  static const TextStyle caption = TextStyle(
    color: UberColors.textSecondary,
    fontSize: 11,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.8,
  );
}

class UberTheme {
  static ThemeData get darkTheme {
    return ThemeData.dark().copyWith(
      scaffoldBackgroundColor: UberColors.background,
      primaryColor: UberColors.white,
      colorScheme: const ColorScheme.dark(
        primary: UberColors.white,
        onPrimary: UberColors.black,
        secondary: UberColors.blue,
        onSecondary: UberColors.white,
        surface: UberColors.surface,
        onSurface: UberColors.textPrimary,
        error: UberColors.red,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: UberColors.background,
        elevation: 0,
        centerTitle: false,
        scrolledUnderElevation: 0,
        titleTextStyle: TextStyle(
          color: UberColors.textPrimary,
          fontSize: 18,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.2,
        ),
        iconTheme: IconThemeData(color: UberColors.white),
      ),
      cardTheme: CardThemeData(
        color: UberColors.surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: UberColors.border, width: 1),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: UberColors.surfaceElevated,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        labelStyle: const TextStyle(color: UberColors.textSecondary, fontSize: 14),
        hintStyle: const TextStyle(color: UberColors.textTertiary, fontSize: 14),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: UberColors.border, width: 1),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: UberColors.white, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: UberColors.red, width: 1),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: UberColors.red, width: 1.5),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: UberColors.white,
          foregroundColor: UberColors.black,
          elevation: 0,
          minimumSize: const Size(double.infinity, 52),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          textStyle: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.2,
          ),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: UberColors.surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: UberColors.border, width: 1),
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: UberColors.borderSubtle,
        thickness: 1,
        space: 1,
      ),
    );
  }
}
