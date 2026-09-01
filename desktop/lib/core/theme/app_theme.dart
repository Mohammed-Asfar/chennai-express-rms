import 'package:flutter/material.dart';
import 'app_colors.dart';
import 'app_spacing.dart';
import 'app_text_styles.dart';

/// The single source of truth for [ThemeData].
///
/// Every colour, text style and shape a widget uses comes from here via
/// `Theme.of(context)`. Widgets must not hardcode any of them — see CLAUDE.md
/// section 6.1.
abstract final class AppTheme {
  static ThemeData get light {
    const scheme = ColorScheme(
      brightness: Brightness.light,
      primary: AppColors.accent,
      onPrimary: AppColors.onAccent,
      primaryContainer: AppColors.accentTint,
      onPrimaryContainer: AppColors.accent,
      secondary: AppColors.info,
      onSecondary: AppColors.onAccent,
      secondaryContainer: AppColors.surfaceSunken,
      onSecondaryContainer: AppColors.ink,
      error: AppColors.danger,
      onError: AppColors.onAccent,
      surface: AppColors.surface,
      onSurface: AppColors.ink,
      surfaceContainerHighest: AppColors.surfaceSunken,
      onSurfaceVariant: AppColors.inkMuted,
      outline: AppColors.border,
      outlineVariant: AppColors.borderStrong,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: AppColors.canvas,
      canvasColor: AppColors.canvas,
      fontFamily: AppTextStyles.interface,
      splashFactory: InkSparkle.splashFactory,

      textTheme: const TextTheme(
        displayLarge: AppTextStyles.displayLarge,
        headlineMedium: AppTextStyles.headlineMedium,
        titleLarge: AppTextStyles.titleLarge,
        titleMedium: AppTextStyles.titleMedium,
        bodyLarge: AppTextStyles.bodyLarge,
        bodyMedium: AppTextStyles.bodyMedium,
        bodySmall: AppTextStyles.bodySmall,
        labelLarge: AppTextStyles.labelLarge,
        labelSmall: AppTextStyles.overline,
      ),

      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.surface,
        foregroundColor: AppColors.ink,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: AppTextStyles.titleLarge,
        shape: Border(
          bottom: BorderSide(
            color: AppColors.border,
            width: AppSpacing.borderWidth,
          ),
        ),
      ),

      cardTheme: CardThemeData(
        color: AppColors.surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
          side: const BorderSide(
            color: AppColors.border,
            width: AppSpacing.borderWidth,
          ),
        ),
      ),

      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.accent,
          foregroundColor: AppColors.onAccent,
          disabledBackgroundColor: AppColors.disabled,
          disabledForegroundColor: AppColors.inkFaint,
          elevation: 0,
          minimumSize: const Size(0, AppSpacing.minTapTarget),
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
          textStyle: AppTextStyles.labelLarge,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
          ),
        ),
      ),

      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.surfaceSunken,
          foregroundColor: AppColors.ink,
          elevation: 0,
          minimumSize: const Size(0, AppSpacing.minTapTarget),
          textStyle: AppTextStyles.labelLarge,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
            side: const BorderSide(color: AppColors.border),
          ),
        ),
      ),

      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: AppColors.inkMuted,
          minimumSize: const Size(0, AppSpacing.minTapTarget),
          textStyle: AppTextStyles.labelLarge,
        ),
      ),

      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.ink,
          minimumSize: const Size(0, AppSpacing.minTapTarget),
          side: const BorderSide(color: AppColors.borderStrong),
          textStyle: AppTextStyles.labelLarge,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
          ),
        ),
      ),

      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: AppColors.inkMuted,
          hoverColor: AppColors.surfaceHover,
        ),
      ),

      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.surfaceSunken,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.md,
        ),
        border: _inputBorder(AppColors.border),
        enabledBorder: _inputBorder(AppColors.border),
        focusedBorder: _inputBorder(
          AppColors.accent,
          AppSpacing.borderWidthFocus,
        ),
        errorBorder: _inputBorder(AppColors.danger),
        focusedErrorBorder: _inputBorder(
          AppColors.danger,
          AppSpacing.borderWidthFocus,
        ),
        labelStyle: AppTextStyles.bodyMedium,
        hintStyle: AppTextStyles.bodyMedium,
        prefixIconColor: AppColors.inkMuted,
      ),

      chipTheme: ChipThemeData(
        backgroundColor: AppColors.surfaceSunken,
        selectedColor: AppColors.accent,
        side: const BorderSide(color: AppColors.border),
        labelStyle: AppTextStyles.labelLarge.copyWith(
          color: AppColors.inkMuted,
        ),
        secondaryLabelStyle: AppTextStyles.labelLarge.copyWith(
          color: AppColors.onAccent,
        ),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
        ),
        showCheckmark: false,
      ),

      dialogTheme: DialogThemeData(
        backgroundColor: AppColors.surfaceSunken,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppSpacing.radiusLg),
          side: const BorderSide(color: AppColors.border),
        ),
        titleTextStyle: AppTextStyles.titleLarge,
        contentTextStyle: AppTextStyles.bodyMedium,
      ),

      snackBarTheme: SnackBarThemeData(
        backgroundColor: AppColors.surfaceSunken,
        contentTextStyle: AppTextStyles.bodyMedium,
        actionTextColor: AppColors.accent,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
          side: const BorderSide(color: AppColors.border),
        ),
      ),

      listTileTheme: const ListTileThemeData(
        iconColor: AppColors.inkMuted,
        titleTextStyle: AppTextStyles.bodyLarge,
        subtitleTextStyle: AppTextStyles.bodySmall,
      ),

      dividerTheme: const DividerThemeData(
        color: AppColors.border,
        thickness: AppSpacing.borderWidth,
        space: AppSpacing.borderWidth,
      ),

      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          textStyle: const WidgetStatePropertyAll(AppTextStyles.labelLarge),
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            return states.contains(WidgetState.selected)
                ? AppColors.accent
                : AppColors.surfaceSunken;
          }),
          foregroundColor: WidgetStateProperty.resolveWith((states) {
            return states.contains(WidgetState.selected)
                ? AppColors.onAccent
                : AppColors.inkMuted;
          }),
          side: const WidgetStatePropertyAll(
            BorderSide(color: AppColors.border),
          ),
        ),
      ),

      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: AppColors.accent,
        linearTrackColor: AppColors.surfaceSunken,
        circularTrackColor: AppColors.surfaceSunken,
      ),

      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: AppColors.surfaceHover,
          borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
          border: Border.all(color: AppColors.border),
        ),
        textStyle: AppTextStyles.bodySmall,
      ),

      popupMenuTheme: PopupMenuThemeData(
        color: AppColors.surfaceSunken,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
          side: const BorderSide(color: AppColors.border),
        ),
        textStyle: AppTextStyles.bodyMedium,
      ),
    );
  }

  /// The light theme, re-tuned for content sitting on the charcoal shell.
  ///
  /// Used by the sign-in card, which is a dark island on a light page. Wrapping
  /// that subtree in this theme keeps widgets reading their colours from
  /// `Theme.of(context)` — the alternative, passing explicit colours into every
  /// field and label, is exactly the drift section 6.1 exists to prevent.
  static ThemeData get onShell {
    final base = light;

    return base.copyWith(
      colorScheme: base.colorScheme.copyWith(
        brightness: Brightness.dark,
        surface: AppColors.shell,
        onSurface: AppColors.onShell,
        surfaceContainerHighest: AppColors.shellHover,
        onSurfaceVariant: AppColors.onShellMuted,
        outline: AppColors.shellBorder,
      ),
      textTheme: base.textTheme.apply(
        bodyColor: AppColors.onShell,
        displayColor: AppColors.onShell,
      ),
      inputDecorationTheme: base.inputDecorationTheme.copyWith(
        fillColor: AppColors.shellHover,
        border: _inputBorder(AppColors.shellBorder),
        enabledBorder: _inputBorder(AppColors.shellBorder),
        focusedBorder: _inputBorder(
          AppColors.accent,
          AppSpacing.borderWidthFocus,
        ),
        labelStyle: AppTextStyles.bodyMedium.copyWith(
          color: AppColors.onShellMuted,
        ),
        hintStyle: AppTextStyles.bodyMedium.copyWith(
          color: AppColors.onShellMuted,
        ),
        prefixIconColor: AppColors.onShellMuted,
        suffixIconColor: AppColors.onShellMuted,
      ),
      iconTheme: const IconThemeData(color: AppColors.onShellMuted),
    );
  }

  static OutlineInputBorder _inputBorder(
    Color color, [
    double width = AppSpacing.borderWidth,
  ]) {
    return OutlineInputBorder(
      borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
      borderSide: BorderSide(color: color, width: width),
    );
  }
}
