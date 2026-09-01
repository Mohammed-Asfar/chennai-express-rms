import 'package:flutter/material.dart';
import 'app_colors.dart';

/// The single source of truth for typography.
///
/// These feed [ThemeData.textTheme]; widgets read
/// `Theme.of(context).textTheme.*` rather than referencing this class directly.
///
/// **Two roles, deliberately separated.** Interface text uses Segoe UI, which
/// ships with Windows and renders cleanly at every size. Money uses Consolas
/// with tabular figures, so a column of amounts aligns on the decimal and a
/// total does not jitter as digits change — the difference between a figure a
/// cashier can scan and one they have to read.
abstract final class AppTextStyles {
  static const String interface = 'Segoe UI';

  /// Monospace, for money and any figure that must line up in a column.
  static const String numeric = 'Consolas';

  static const List<FontFeature> _tabular = [FontFeature.tabularFigures()];

  // --- display: used sparingly, for the one number that matters ------------

  static const TextStyle displayLarge = TextStyle(
    fontFamily: numeric,
    fontSize: 40,
    fontWeight: FontWeight.w700,
    color: AppColors.ink,
    height: 1.1,
    letterSpacing: -1,
    fontFeatures: _tabular,
  );

  static const TextStyle headlineMedium = TextStyle(
    fontSize: 22,
    fontWeight: FontWeight.w600,
    color: AppColors.ink,
    height: 1.25,
    letterSpacing: -0.3,
  );

  // --- interface ------------------------------------------------------------

  static const TextStyle titleLarge = TextStyle(
    fontSize: 18,
    fontWeight: FontWeight.w600,
    color: AppColors.ink,
    letterSpacing: -0.2,
  );

  static const TextStyle titleMedium = TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w600,
    color: AppColors.ink,
  );

  static const TextStyle bodyLarge = TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w400,
    color: AppColors.ink,
    height: 1.4,
  );

  static const TextStyle bodyMedium = TextStyle(
    fontSize: 13.5,
    fontWeight: FontWeight.w400,
    color: AppColors.ink,
    height: 1.4,
  );

  static const TextStyle bodySmall = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w400,
    color: AppColors.inkMuted,
    height: 1.35,
  );

  static const TextStyle labelLarge = TextStyle(
    fontSize: 13.5,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.1,
  );

  /// Section headers and eyebrows. Wide tracking earns its keep at this size —
  /// it separates a label from the content beneath without needing a rule.
  static const TextStyle overline = TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w600,
    color: AppColors.inkMuted,
    letterSpacing: 1.2,
  );

  // --- money ----------------------------------------------------------------

  static const TextStyle money = TextStyle(
    fontFamily: numeric,
    fontSize: 14,
    fontWeight: FontWeight.w600,
    color: AppColors.ink,
    fontFeatures: _tabular,
  );

  static const TextStyle moneyLarge = TextStyle(
    fontFamily: numeric,
    fontSize: 26,
    fontWeight: FontWeight.w700,
    color: AppColors.ink,
    letterSpacing: -0.5,
    fontFeatures: _tabular,
  );

  /// Quantities in the order panel and on the KOT.
  static const TextStyle quantity = TextStyle(
    fontFamily: numeric,
    fontSize: 15,
    fontWeight: FontWeight.w700,
    color: AppColors.ink,
    fontFeatures: _tabular,
  );
}
