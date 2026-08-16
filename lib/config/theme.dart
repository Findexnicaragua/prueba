import 'package:flutter/material.dart';

/// Paleta del CRM — iOS-inspired, light-only.
class AppColors {
  // Primarios
  static const primary = Color(0xFF007AFF);        // Azul celeste iOS
  static const onPrimary = Colors.white;

  // Fondos
  static const background = Color(0xFFFAFAFC);      // Fondo principal (off-white)
  static const surface = Colors.white;               // Cards, dialogs
  static const surfaceContainer = Color(0xFFF2F2F7); // Sidebar, containers
  static const surfaceContainerHigh = Color(0xFFE5E5EA); // Bordes, dividers

  // Texto
  static const textPrimary = Color(0xFF1C1C1E);     // Texto principal
  static const textSecondary = Color(0xFF636366);   // Texto secundario (más oscuro)
  static const outline = Color(0xFF9A9AA0);          // Bordes inputs (más visible)

  // Semánticos (contrastes WCAG AA con blanco)
  static const error = Color(0xFFD63029);            // Rojo oscurecido (5.0:1)
  static const success = Color(0xFF1B8A35);          // Verde oscurecido (4.6:1)
  static const warning = Color(0xFFCC7700);          // Naranja oscurecido (4.5:1)
}

class AppTheme {
  static ThemeData light() {
    const primary = AppColors.primary;

    final scheme = ColorScheme.light(
      primary: primary,
      onPrimary: AppColors.onPrimary,
      secondary: primary.withValues(alpha: 0.1),
      onSecondary: primary,
      surface: AppColors.surface,
      onSurface: AppColors.textPrimary,
      onSurfaceVariant: AppColors.textSecondary,
      surfaceContainerLow: AppColors.surfaceContainer,
      surfaceContainerHighest: AppColors.surfaceContainer,
      outline: AppColors.textSecondary,
      outlineVariant: AppColors.outline,
      error: AppColors.error,
      onError: Colors.white,
      errorContainer: AppColors.error.withValues(alpha: 0.1),
      onErrorContainer: AppColors.error,
      primaryContainer: primary.withValues(alpha: 0.08),
      onPrimaryContainer: primary,
      secondaryContainer: AppColors.surfaceContainer,
      onSecondaryContainer: AppColors.textPrimary,
      tertiaryContainer: AppColors.success.withValues(alpha: 0.1),
      onTertiaryContainer: AppColors.success,
      tertiary: AppColors.success,
    );

    return _build(scheme);
  }

  static ThemeData _build(ColorScheme scheme) {
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      scaffoldBackgroundColor: AppColors.background,
      visualDensity: VisualDensity.adaptivePlatformDensity,
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: _FadeTransitionsBuilder(),
          TargetPlatform.iOS: _FadeTransitionsBuilder(),
          TargetPlatform.linux: _FadeTransitionsBuilder(),
          TargetPlatform.macOS: _FadeTransitionsBuilder(),
          TargetPlatform.windows: _FadeTransitionsBuilder(),
          TargetPlatform.fuchsia: _FadeTransitionsBuilder(),
        },
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.background,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
        scrolledUnderElevation: 0.5,
        centerTitle: false,
        surfaceTintColor: Colors.transparent,
        shape: Border(
          bottom: BorderSide(color: AppColors.surfaceContainerHigh, width: 0.5),
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: AppColors.surfaceContainerHigh, width: 0.5),
        ),
        margin: EdgeInsets.zero,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.primary,
          foregroundColor: AppColors.onPrimary,
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 24),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.primary,
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 20),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          side: const BorderSide(color: AppColors.outline),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: AppColors.primary,
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: AppColors.primary,
        foregroundColor: AppColors.onPrimary,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: AppColors.outline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: AppColors.outline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: AppColors.primary, width: 1.5),
        ),
        filled: true,
        fillColor: AppColors.surfaceContainer.withValues(alpha: 0.5),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
      listTileTheme: const ListTileThemeData(
        contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: AppColors.surfaceContainer,
        selectedColor: AppColors.primary.withValues(alpha: 0.18),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        // Borde visible + label en textPrimary: sin color/borde los chips NO
        // seleccionados quedaban casi ilegibles (gris claro sobre fondo claro).
        side: const BorderSide(color: AppColors.outline),
        labelStyle: const TextStyle(
          fontSize: 13,
          color: AppColors.textPrimary,
          fontWeight: FontWeight.w500,
        ),
        secondaryLabelStyle: const TextStyle(
          fontSize: 13,
          color: AppColors.textPrimary,
          fontWeight: FontWeight.w600,
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: AppColors.surfaceContainerHigh,
        thickness: 0.5,
        space: 0.5,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return AppColors.primary;
          return AppColors.outline;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return AppColors.primary.withValues(alpha: 0.3);
          }
          return AppColors.surfaceContainerHigh;
        }),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      dialogTheme: DialogThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        surfaceTintColor: Colors.transparent,
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
      ),
    );
  }
}

class _FadeTransitionsBuilder extends PageTransitionsBuilder {
  const _FadeTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return FadeTransition(opacity: animation, child: child);
  }
}
