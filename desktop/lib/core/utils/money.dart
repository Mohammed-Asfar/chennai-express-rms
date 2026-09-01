/// Display helpers for money and rates.
///
/// The backend owns all arithmetic. These functions only format what it sends
/// and parse what the user types; nothing here computes a total.
abstract final class Money {
  /// Paise to a display string. `45050` -> `450.50`.
  static String format(int paise) {
    final sign = paise < 0 ? '-' : '';
    final abs = paise.abs();
    return '$sign${abs ~/ 100}.${(abs % 100).toString().padLeft(2, '0')}';
  }

  /// Paise with a rupee sign. `45050` -> `₹450.50`.
  static String formatWithSymbol(int paise) => '₹${format(paise)}';

  /// Rupees typed by a user to paise. Returns null if unparseable.
  static int? parse(String input) {
    final value = double.tryParse(input.trim().replaceAll(',', ''));
    if (value == null) return null;
    return (value * 100).round();
  }

  /// Basis points to a percentage string. `500` -> `5`, `250` -> `2.5`.
  static String formatRate(int basisPoints) {
    final whole = basisPoints ~/ 100;
    final frac = basisPoints % 100;
    if (frac == 0) return '$whole';
    return '$whole.${frac.toString().padLeft(2, '0').replaceAll(RegExp(r'0+$'), '')}';
  }
}
