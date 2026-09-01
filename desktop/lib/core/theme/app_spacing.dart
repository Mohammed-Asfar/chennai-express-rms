/// The single source of truth for spacing, sizing and shape.
///
/// Widgets use these constants rather than bare numbers, so density can be
/// tuned globally — which matters on a counter PC where staff work fast and a
/// mis-tap during billing is a wrong order.
abstract final class AppSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 16;
  static const double lg = 24;
  static const double xl = 32;
  static const double xxl = 48;

  /// Minimum touch target. Staff tap at speed, often without looking directly
  /// at the button they are reaching for.
  static const double minTapTarget = 48;

  /// Primary actions — Bill, Take payment — get more height than that minimum.
  /// They are the end of a flow and should feel like it.
  static const double primaryActionHeight = 56;

  // --- shape ---------------------------------------------------------------
  //
  // Restrained radii. Softer corners would read consumer-app; sharper would
  // read industrial. This is a working tool that people should still like
  // looking at after ten hours.

  static const double radiusSm = 8;
  static const double radiusMd = 12;
  static const double radiusLg = 16;

  static const double borderWidth = 1;
  static const double borderWidthFocus = 2;

  /// The left edge of a card that carries status, e.g. a table's state.
  static const double statusBarWidth = 4;
}
