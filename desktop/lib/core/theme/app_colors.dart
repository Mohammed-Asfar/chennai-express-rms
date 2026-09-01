import 'package:flutter/material.dart';

/// The single source of truth for every colour in the application.
///
/// Nothing outside this file may construct a [Color]. Widgets read colours from
/// `Theme.of(context)`, which is built from these values in `app_theme.dart`.
/// Changing the restaurant's accent colour must be a one-line edit here.
abstract final class AppColors {
  // Brand — a warm South Indian red, chosen to read clearly under counter lighting.
  static const Color primary = Color(0xFFC62828);
  static const Color primaryDark = Color(0xFF8E0000);
  static const Color primaryLight = Color(0xFFFF5F52);
  static const Color onPrimary = Color(0xFFFFFFFF);

  // Secondary — a deep amber used for highlights that must not read as an error.
  static const Color secondary = Color(0xFFF9A825);
  static const Color secondaryDark = Color(0xFFC17900);
  static const Color onSecondary = Color(0xFF1A1A1A);

  // Surfaces
  static const Color background = Color(0xFFF7F6F4);
  static const Color surface = Color(0xFFFFFFFF);
  static const Color surfaceVariant = Color(0xFFEFEDEA);
  static const Color onSurface = Color(0xFF1A1A1A);
  static const Color onSurfaceMuted = Color(0xFF6B6B6B);
  static const Color border = Color(0xFFDDDAD5);

  // Status — used for table state and job outcomes, not decoration.
  static const Color success = Color(0xFF2E7D32);
  static const Color warning = Color(0xFFEF6C00);
  static const Color error = Color(0xFFC62828);
  static const Color info = Color(0xFF1565C0);
  static const Color onStatus = Color(0xFFFFFFFF);

  /// Table states on the floor screen. Distinguishable without relying on colour
  /// alone — the UI also labels them, for staff who cannot separate red and green.
  static const Color tableFree = Color(0xFF2E7D32);
  static const Color tableOccupied = Color(0xFFC62828);
  static const Color tableReserved = Color(0xFFF9A825);

  static const Color disabled = Color(0xFFBDBDBD);
  static const Color overlay = Color(0x66000000);
}
