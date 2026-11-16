import 'package:flutter/material.dart';

abstract final class NiptoColors {
  // Derived from the supplied Nipto mark: cyan-blue through violet to magenta,
  // balanced with a deep navy wordmark and clean white surfaces.
  static const ink = Color(0xFF101C50);
  static const muted = Color(0xFF737A94);
  static const canvas = Color(0xFFF7F8FF);
  static const surface = Color(0xFFFFFFFF);
  static const violet = Color(0xFF5528E8);
  static const violetSoft = Color(0xFFEDE9FF);
  static const coral = Color(0xFFFF4D9B);
  static const brandCyan = Color(0xFF08C9F4);
  static const brandBlue = Color(0xFF0876F8);
  static const brandMagenta = Color(0xFFE516B8);
  static const border = Color(0xFFE9E9F1);
  static const success = Color(0xFF239B74);
  static const danger = Color(0xFFD94B5B);
}

abstract final class NiptoBrand {
  static const markGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [
      NiptoColors.brandCyan,
      NiptoColors.brandBlue,
      NiptoColors.violet,
      NiptoColors.brandMagenta,
    ],
  );
}

abstract final class NiptoTheme {
  static ThemeData get light {
    final scheme = ColorScheme.fromSeed(
      seedColor: NiptoColors.violet,
      brightness: Brightness.light,
      surface: NiptoColors.surface,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme.copyWith(
        primary: NiptoColors.violet,
        onPrimary: Colors.white,
        surface: NiptoColors.surface,
        error: NiptoColors.danger,
      ),
      scaffoldBackgroundColor: NiptoColors.canvas,
      appBarTheme: const AppBarTheme(
        backgroundColor: NiptoColors.canvas,
        foregroundColor: NiptoColors.ink,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: NiptoColors.ink,
          fontSize: 23,
          fontWeight: FontWeight.w800,
          letterSpacing: -0.7,
        ),
      ),
      cardTheme: CardThemeData(
        color: NiptoColors.surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: NiptoColors.border),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: NiptoColors.surface,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 15,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: NiptoColors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: NiptoColors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: NiptoColors.violet, width: 1.5),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: NiptoColors.violet,
          foregroundColor: Colors.white,
          minimumSize: const Size.fromHeight(52),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          textStyle: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      navigationBarTheme: const NavigationBarThemeData(
        backgroundColor: NiptoColors.surface,
        indicatorColor: NiptoColors.violetSoft,
        elevation: 0,
        labelTextStyle: WidgetStatePropertyAll(
          TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
        ),
      ),
      dividerColor: NiptoColors.border,
      textTheme: const TextTheme(
        headlineSmall: TextStyle(
          color: NiptoColors.ink,
          fontWeight: FontWeight.w800,
          letterSpacing: -0.7,
        ),
        titleLarge: TextStyle(
          color: NiptoColors.ink,
          fontWeight: FontWeight.w800,
        ),
        titleMedium: TextStyle(
          color: NiptoColors.ink,
          fontWeight: FontWeight.w700,
        ),
        bodyMedium: TextStyle(color: NiptoColors.ink, height: 1.35),
        bodySmall: TextStyle(color: NiptoColors.muted, height: 1.35),
      ),
    );
  }
}
