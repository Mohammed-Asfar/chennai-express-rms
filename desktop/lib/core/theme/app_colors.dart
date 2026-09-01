import 'package:flutter/material.dart';

/// The single source of truth for every colour in the application.
///
/// Nothing outside this file may construct a [Color]. Widgets read colours from
/// `Theme.of(context)`, built from these values in `app_theme.dart`.
///
/// ## 60-30-10
///
/// **60% — neutral ground.** The working area: [canvas], [surface],
/// [surfaceSunken]. Warm rather than pure white, so cards read as raised and a
/// ten-hour shift under counter lighting is easier on the eyes.
///
/// **30% — charcoal.** The sidebar. A permanent dark anchor down the left edge
/// that separates navigation from work, and gives the layout a spine.
///
/// **10% — amber.** The accent, and only the accent: the active nav item, the
/// primary button, the focused field. Nothing decorative wears it.
///
/// ## Status is not part of the 10%
///
/// Green, red and amber-brown for free, seated and reserved carry *meaning*.
/// If the accent yellow also meant "reserved", staff would misread the floor —
/// so status colours sit deliberately outside the accent system, and every one
/// is paired with a text label rather than standing on colour alone.
abstract final class AppColors {
  // --- 60%: the neutral ground ---------------------------------------------

  /// The page behind everything.
  static const Color canvas = Color(0xFFF5F4F1);

  /// Cards, panels, the top bar.
  static const Color surface = Color(0xFFFFFFFF);

  /// Recessed areas: totals blocks, input fills, chips at rest.
  static const Color surfaceSunken = Color(0xFFF0EFEB);

  /// Hover and pressed states.
  static const Color surfaceHover = Color(0xFFEAE8E3);

  /// Hairlines. Low contrast on purpose — structure should be felt, not seen.
  static const Color border = Color(0xFFE4E2DD);
  static const Color borderStrong = Color(0xFFCDCAC3);

  static const Color ink = Color(0xFF1F1E1C);
  static const Color inkMuted = Color(0xFF6B6862);
  static const Color inkFaint = Color(0xFF9B978F);

  // --- 30%: the charcoal spine ---------------------------------------------

  /// The sidebar.
  static const Color shell = Color(0xFF1C1B19);

  /// A nav item under the cursor.
  static const Color shellHover = Color(0xFF2A2926);

  /// Dividers inside the sidebar.
  static const Color shellBorder = Color(0xFF35332F);

  static const Color onShell = Color(0xFFF2F0EC);
  static const Color onShellMuted = Color(0xFF908B83);

  // --- 10%: the accent ------------------------------------------------------

  static const Color accent = Color(0xFFF5C518);
  static const Color accentDim = Color(0xFFD9AC0E);

  /// A wash behind the accent, for selected rows on a light ground.
  static const Color accentTint = Color(0xFFFDF6DA);

  /// Text and icons on an accent fill. Dark, because amber is a light colour.
  static const Color onAccent = Color(0xFF1F1A05);

  // --- status: outside the accent system -----------------------------------

  static const Color success = Color(0xFF2E6B3E);
  static const Color warning = Color(0xFF8A5A16);
  static const Color danger = Color(0xFFB3261E);
  static const Color info = Color(0xFF1B5E9C);

  static const Color successTint = Color(0xFFE9F2EB);
  static const Color warningTint = Color(0xFFF6EEE1);
  static const Color dangerTint = Color(0xFFFAEAE9);

  /// Table states on the floor screen.
  static const Color tableFree = Color(0xFF2E6B3E);
  static const Color tableOccupied = Color(0xFFB3261E);
  static const Color tableReserved = Color(0xFF8A5A16);

  static const Color tableFreeTint = Color(0xFFE9F2EB);
  static const Color tableOccupiedTint = Color(0xFFFAEAE9);
  static const Color tableReservedTint = Color(0xFFF6EEE1);

  static const Color disabled = Color(0xFFDEDBD5);
  static const Color overlay = Color(0x661F1E1C);
}
