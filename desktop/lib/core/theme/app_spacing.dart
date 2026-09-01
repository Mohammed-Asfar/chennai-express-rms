/// The single source of truth for spacing and sizing.
///
/// Widgets use these constants rather than bare numbers, so density can be
/// adjusted globally — which matters on a counter PC where staff work fast and
/// tap targets need to stay large.
abstract final class AppSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 16;
  static const double lg = 24;
  static const double xl = 32;
  static const double xxl = 48;

  /// Minimum touch target. Billing staff work at speed; small targets cause
  /// mis-taps, and a mis-tap during billing is a wrong order.
  static const double minTapTarget = 48;

  static const double radiusSm = 6;
  static const double radiusMd = 10;
  static const double radiusLg = 16;

  static const double borderWidth = 1;
  static const double borderWidthFocus = 2;
}
