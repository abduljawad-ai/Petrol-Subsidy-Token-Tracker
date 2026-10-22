import 'package:flutter/material.dart';

/// FuelToken design system (v2).
///
/// Every constant and method from the previous theme is kept under the same
/// name so no screen can break; values were refined and new tokens added.
class AppTheme {
  // ── Brand colours (palette contract: green, gold, tint, ink, used-blue) ───
  static const Color primary = Color(0xFF006400); // deep green
  static const Color primaryLight = Color(0xFF4CAF50); // medium green
  static const Color accent = Color(0xFFFFD700); // gold – token highlight
  static const Color tint = Color(0xFFE8F5E9); // soft green tint
  static const Color ink = Color(0xFF12341C); // deep ink green

  // Neutrals
  static const Color surface = Color(0xFFF3F7F3); // page background
  static const Color cardBg = Color(0xFFFFFFFF);
  static const Color line = Color(0xFFDDE7DE); // hairline borders
  static const Color textDark = ink;
  static const Color textMid = Color(0xFF4A5E4F);
  static const Color textLight = Color(0xFF7D8F81);

  // Status colours
  static const Color activeGreen = Color(0xFF1B7A2E);
  static const Color redeemedBlue = Color(0xFF1565C0);
  static const Color expiredGrey = Color(0xFF757575);
  static const Color pendingOrange = Color(0xFFE65100);
  static const Color danger = Color(0xFFC62828);

  // Shape + spacing scale
  static const double rSm = 10;
  static const double rMd = 14;
  static const double rLg = 20;
  static const double rXl = 28;

  /// Soft, low-cost shadow (cheap on low-end GPUs).
  static List<BoxShadow> get softShadow => [
        BoxShadow(
          color: ink.withValues(alpha: 0.07),
          blurRadius: 12,
          offset: const Offset(0, 4),
        ),
      ];

  static Color statusColor(String status) {
    switch (status) {
      case 'ACTIVE':
        return activeGreen;
      case 'REDEEMED':
        return redeemedBlue;
      case 'EXPIRED':
        return Colors.red.shade700; // overdue at the pump — loud, not grey
      case 'PENDING':
        return pendingOrange;
      default:
        return expiredGrey;
    }
  }

  static ThemeData get light => ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: primary,
          primary: primary,
          secondary: accent,
          surface: surface,
        ),
        scaffoldBackgroundColor: surface,
        splashFactory: InkRipple.splashFactory,
        appBarTheme: const AppBarTheme(
          backgroundColor: primary,
          foregroundColor: Colors.white,
          elevation: 0,
          scrolledUnderElevation: 0,
          centerTitle: false,
          titleSpacing: 16,
          titleTextStyle: TextStyle(
            color: Colors.white,
            fontSize: 19,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.2,
          ),
        ),
        cardTheme: CardThemeData(
          color: cardBg,
          elevation: 0,
          shadowColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(rLg),
            side: const BorderSide(color: line),
          ),
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: primary,
            foregroundColor: Colors.white,
            elevation: 0,
            minimumSize: const Size(64, 50),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rMd)),
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
            textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: primary,
            minimumSize: const Size(64, 50),
            side: const BorderSide(color: primary, width: 1.4),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rMd)),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            textStyle: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            foregroundColor: primary,
            textStyle: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(rMd),
            borderSide: const BorderSide(color: line),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(rMd),
            borderSide: const BorderSide(color: line),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(rMd),
            borderSide: const BorderSide(color: primary, width: 2),
          ),
          labelStyle: const TextStyle(color: textMid),
        ),
        chipTheme: ChipThemeData(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rSm)),
          side: const BorderSide(color: line),
          backgroundColor: Colors.white,
          selectedColor: tint,
        ),
        dialogTheme: DialogThemeData(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rXl)),
        ),
        bottomSheetTheme: const BottomSheetThemeData(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(rXl)),
          ),
        ),
        dividerTheme: const DividerThemeData(color: line, thickness: 1, space: 1),
        floatingActionButtonTheme: FloatingActionButtonThemeData(
          backgroundColor: accent,
          foregroundColor: ink,
          elevation: 3,
          extendedTextStyle: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        ),
        // Compact footer bar
        navigationBarTheme: NavigationBarThemeData(
          height: 64,
          elevation: 0,
          backgroundColor: cardBg,
          surfaceTintColor: Colors.transparent,
          indicatorColor: tint,
          indicatorShape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          iconTheme: WidgetStateProperty.resolveWith((states) => IconThemeData(
              size: 22,
              color: states.contains(WidgetState.selected) ? primary : textMid)),
          labelTextStyle: WidgetStateProperty.resolveWith((states) => TextStyle(
                fontSize: 11,
                fontWeight: states.contains(WidgetState.selected)
                    ? FontWeight.w800
                    : FontWeight.w500,
                color: states.contains(WidgetState.selected) ? primary : textMid,
              )),
        ),
        snackBarTheme: SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          backgroundColor: ink,
          contentTextStyle: const TextStyle(color: Colors.white, fontSize: 13.5),
          actionTextColor: accent,
          elevation: 4,
        ),
      );
}
