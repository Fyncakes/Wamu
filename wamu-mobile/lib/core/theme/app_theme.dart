import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

/// Wamu themes — marketplace light + messenger dark (Sprint 1 default).
class AppTheme {
  AppTheme._();

  static const Color primaryGreen = Color(0xFF0B6E4F);
  static const Color accentGreen = Color(0xFF1DAA61);
  static const Color primaryDark = Color(0xFF084A36);
  static const Color sand = Color(0xFFF5E6D3);
  static const Color sandDark = Color(0xFFE8D5BC);
  static const Color warmBrown = Color(0xFF6B4E3D);
  static const Color surfaceLight = Color(0xFFFFFBF7);
  static const Color errorRed = Color(0xFFC0392B);

  // Messenger dark tokens (WhatsApp-like OLED, own green)
  static const Color messengerBg = Color(0xFF0B141A);
  static const Color messengerSurface = Color(0xFF111B21);
  static const Color messengerElevated = Color(0xFF1F2C34);
  static const Color messengerInput = Color(0xFF2A3942);
  static const Color messengerText = Color(0xFFE9EDEF);
  static const Color messengerMuted = Color(0xFF8696A0);

  static ThemeData get lightTheme {
    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: ColorScheme.fromSeed(
        seedColor: primaryGreen,
        primary: primaryGreen,
        onPrimary: Colors.white,
        secondary: sandDark,
        onSecondary: warmBrown,
        surface: surfaceLight,
        error: errorRed,
      ),
      scaffoldBackgroundColor: surfaceLight,
    );

    return base.copyWith(
      textTheme: _lightText(base.textTheme),
      appBarTheme: AppBarTheme(
        backgroundColor: primaryGreen,
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: true,
        titleTextStyle: GoogleFonts.outfit(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: Colors.white,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: Colors.white,
        indicatorColor: primaryGreen.withValues(alpha: 0.15),
        labelTextStyle: WidgetStatePropertyAll(
          GoogleFonts.outfit(fontSize: 12, fontWeight: FontWeight.w500),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primaryGreen,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          textStyle: GoogleFonts.outfit(fontWeight: FontWeight.w600),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: sandDark.withValues(alpha: 0.8)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: primaryGreen, width: 2),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
      cardTheme: CardThemeData(
        elevation: 2,
        color: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: primaryGreen,
        foregroundColor: Colors.white,
      ),
    );
  }

  /// Default for messaging-first Wamu (Sprint 1).
  static ThemeData get messengerDarkTheme {
    final scheme = const ColorScheme.dark(
      primary: accentGreen,
      onPrimary: Colors.black,
      secondary: messengerElevated,
      onSecondary: messengerText,
      secondaryContainer: Color(0xFF0A3D2E),
      onSecondaryContainer: accentGreen,
      surface: messengerSurface,
      onSurface: messengerText,
      onSurfaceVariant: messengerMuted,
      surfaceContainerHighest: messengerElevated,
      error: errorRed,
      onError: Colors.white,
    );

    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: messengerBg,
      canvasColor: messengerBg,
    );

    final text = TextTheme(
      displayLarge: GoogleFonts.fraunces(
        fontSize: 48,
        fontWeight: FontWeight.w700,
        color: messengerText,
      ),
      displayMedium: GoogleFonts.fraunces(
        fontSize: 36,
        fontWeight: FontWeight.w600,
        color: messengerText,
      ),
      headlineLarge: GoogleFonts.outfit(
        fontSize: 28,
        fontWeight: FontWeight.w700,
        color: messengerText,
      ),
      headlineMedium: GoogleFonts.outfit(
        fontSize: 24,
        fontWeight: FontWeight.w600,
        color: messengerText,
      ),
      headlineSmall: GoogleFonts.outfit(
        fontSize: 22,
        fontWeight: FontWeight.w700,
        color: messengerText,
      ),
      titleLarge: GoogleFonts.outfit(
        fontSize: 20,
        fontWeight: FontWeight.w600,
        color: messengerText,
      ),
      titleMedium: GoogleFonts.outfit(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: messengerText,
      ),
      titleSmall: GoogleFonts.outfit(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: messengerText,
      ),
      bodyLarge: GoogleFonts.outfit(fontSize: 16, color: messengerText),
      bodyMedium: GoogleFonts.outfit(fontSize: 14, color: messengerMuted),
      bodySmall: GoogleFonts.outfit(fontSize: 12, color: messengerMuted),
      labelLarge: GoogleFonts.outfit(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: messengerText,
      ),
      labelMedium: GoogleFonts.outfit(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: messengerText,
      ),
      labelSmall: GoogleFonts.outfit(
        fontSize: 11,
        fontWeight: FontWeight.w500,
        color: messengerMuted,
      ),
    );

    return base.copyWith(
      textTheme: text,
      appBarTheme: AppBarTheme(
        backgroundColor: messengerBg,
        foregroundColor: messengerText,
        elevation: 0,
        centerTitle: false,
        systemOverlayStyle: SystemUiOverlayStyle.light,
        titleTextStyle: GoogleFonts.outfit(
          fontSize: 22,
          fontWeight: FontWeight.w700,
          color: messengerText,
        ),
        iconTheme: const IconThemeData(color: messengerMuted),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: messengerSurface,
        indicatorColor: const Color(0xFF0A3D2E),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return GoogleFonts.outfit(
            fontSize: 11,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            color: selected ? accentGreen : messengerMuted,
          );
        }),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return IconThemeData(color: selected ? accentGreen : messengerMuted);
        }),
        height: 68,
      ),
      dividerTheme: const DividerThemeData(color: Color(0xFF222C32), thickness: 0.5),
      listTileTheme: const ListTileThemeData(
        iconColor: messengerMuted,
        textColor: messengerText,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: accentGreen,
          foregroundColor: Colors.black,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          textStyle: GoogleFonts.outfit(fontWeight: FontWeight.w700),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: messengerInput,
        hintStyle: GoogleFonts.outfit(color: messengerMuted),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(24),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(24),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(24),
          borderSide: const BorderSide(color: accentGreen, width: 1.2),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      ),
      cardTheme: CardThemeData(
        color: messengerElevated,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: messengerElevated,
        selectedColor: const Color(0xFF0A3D2E),
        disabledColor: messengerElevated,
        labelStyle: GoogleFonts.outfit(color: messengerText, fontSize: 13),
        secondaryLabelStyle: GoogleFonts.outfit(
          color: accentGreen,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
        checkmarkColor: accentGreen,
        side: BorderSide.none,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        padding: const EdgeInsets.symmetric(horizontal: 4),
        brightness: Brightness.dark,
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: accentGreen,
        foregroundColor: Colors.black,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(16)),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: messengerElevated,
        titleTextStyle: GoogleFonts.outfit(
          color: messengerText,
          fontSize: 18,
          fontWeight: FontWeight.w600,
        ),
        contentTextStyle: GoogleFonts.outfit(color: messengerMuted, fontSize: 14),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: messengerElevated,
        contentTextStyle: GoogleFonts.outfit(color: messengerText),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(color: accentGreen),
    );
  }

  /// Messenger light / white theme (WhatsApp-parity Appearance option).
  static ThemeData get messengerLightTheme {
    const bg = Color(0xFFFFFFFF);
    const surface = Color(0xFFF0F2F5);
    const elevated = Color(0xFFFFFFFF);
    const input = Color(0xFFF0F2F5);
    const text = Color(0xFF111B21);
    const muted = Color(0xFF667781);

    final scheme = const ColorScheme.light(
      primary: accentGreen,
      onPrimary: Colors.black,
      secondary: surface,
      onSecondary: text,
      surface: elevated,
      onSurface: text,
      error: errorRed,
      onError: Colors.white,
    );

    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: scheme,
      scaffoldBackgroundColor: bg,
      canvasColor: bg,
    );

    final textTheme = TextTheme(
      displayLarge: GoogleFonts.fraunces(
        fontSize: 48,
        fontWeight: FontWeight.w700,
        color: text,
      ),
      displayMedium: GoogleFonts.fraunces(
        fontSize: 36,
        fontWeight: FontWeight.w600,
        color: text,
      ),
      headlineMedium: GoogleFonts.outfit(
        fontSize: 24,
        fontWeight: FontWeight.w600,
        color: text,
      ),
      titleLarge: GoogleFonts.outfit(
        fontSize: 20,
        fontWeight: FontWeight.w600,
        color: text,
      ),
      titleMedium: GoogleFonts.outfit(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: text,
      ),
      bodyLarge: GoogleFonts.outfit(fontSize: 16, color: text),
      bodyMedium: GoogleFonts.outfit(fontSize: 14, color: muted),
      bodySmall: GoogleFonts.outfit(fontSize: 12, color: muted),
      labelLarge: GoogleFonts.outfit(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: Colors.white,
      ),
    );

    return base.copyWith(
      textTheme: textTheme,
      appBarTheme: AppBarTheme(
        backgroundColor: bg,
        foregroundColor: text,
        elevation: 0,
        centerTitle: false,
        systemOverlayStyle: SystemUiOverlayStyle.dark,
        titleTextStyle: GoogleFonts.outfit(
          fontSize: 22,
          fontWeight: FontWeight.w700,
          color: text,
        ),
        iconTheme: const IconThemeData(color: muted),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: surface,
        indicatorColor: const Color(0xFFD1F4DD),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return GoogleFonts.outfit(
            fontSize: 11,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            color: selected ? primaryDark : muted,
          );
        }),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return IconThemeData(color: selected ? primaryDark : muted);
        }),
        height: 68,
      ),
      dividerTheme: const DividerThemeData(color: Color(0xFFE9EDEF), thickness: 0.5),
      listTileTheme: const ListTileThemeData(iconColor: muted, textColor: text),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: accentGreen,
          foregroundColor: Colors.black,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          textStyle: GoogleFonts.outfit(fontWeight: FontWeight.w700),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: input,
        hintStyle: GoogleFonts.outfit(color: muted),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(24),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(24),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(24),
          borderSide: const BorderSide(color: accentGreen, width: 1.2),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      ),
      cardTheme: CardThemeData(
        color: elevated,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: surface,
        selectedColor: const Color(0xFFD1F4DD),
        labelStyle: GoogleFonts.outfit(color: text, fontSize: 13),
        secondaryLabelStyle: GoogleFonts.outfit(color: primaryDark, fontSize: 13),
        side: BorderSide.none,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        padding: const EdgeInsets.symmetric(horizontal: 4),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: accentGreen,
        foregroundColor: Colors.black,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(16)),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: elevated,
        titleTextStyle: GoogleFonts.outfit(
          color: text,
          fontSize: 18,
          fontWeight: FontWeight.w600,
        ),
        contentTextStyle: GoogleFonts.outfit(color: muted, fontSize: 14),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: const Color(0xFF111B21),
        contentTextStyle: GoogleFonts.outfit(color: Colors.white),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(color: accentGreen),
    );
  }

  static TextTheme _lightText(TextTheme base) {
    return TextTheme(
      displayLarge: GoogleFonts.fraunces(
        fontSize: 48,
        fontWeight: FontWeight.w700,
        color: primaryGreen,
      ),
      displayMedium: GoogleFonts.fraunces(
        fontSize: 36,
        fontWeight: FontWeight.w600,
        color: primaryGreen,
      ),
      headlineMedium: GoogleFonts.fraunces(
        fontSize: 24,
        fontWeight: FontWeight.w600,
        color: primaryDark,
      ),
      titleLarge: GoogleFonts.outfit(
        fontSize: 20,
        fontWeight: FontWeight.w600,
        color: primaryDark,
      ),
      titleMedium: GoogleFonts.outfit(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: primaryDark,
      ),
      bodyLarge: GoogleFonts.outfit(fontSize: 16, color: warmBrown),
      bodyMedium: GoogleFonts.outfit(fontSize: 14, color: warmBrown),
      labelLarge: GoogleFonts.outfit(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: Colors.white,
      ),
    );
  }

  static TextStyle get brandHero => GoogleFonts.fraunces(
        fontSize: 56,
        fontWeight: FontWeight.w800,
        color: accentGreen,
        letterSpacing: 4,
      );

  static TextStyle get tagline => GoogleFonts.outfit(
        fontSize: 16,
        fontWeight: FontWeight.w400,
        color: messengerMuted,
        letterSpacing: 0.5,
      );
}
