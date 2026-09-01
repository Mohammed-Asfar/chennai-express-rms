import 'package:flutter_test/flutter_test.dart';
import 'package:chennai_express_pos/core/utils/money.dart';

void main() {
  group('price entry round-trips as exact paise', () {
    test('typed rupees become paise', () {
      expect(Money.parse('180.50'), 18050);
      expect(Money.parse('320'), 32000);
      expect(Money.parse('0.05'), 5);
      expect(Money.parse('1,250.75'), 125075);
    });

    test('paise render back to what was typed', () {
      expect(Money.format(18050), '180.50');
      expect(Money.format(32000), '320.00');
      expect(Money.format(5), '0.05');
    });

    // The editor pre-fills a price with Money.format and re-parses it on save.
    // If that round trip drifted, editing a dish without touching the price
    // would silently reprice it.
    test('format then parse is lossless', () {
      for (final paise in [1, 5, 99, 100, 18050, 32000, 999999]) {
        expect(Money.parse(Money.format(paise)), paise, reason: 'paise=$paise');
      }
    });

    test('rejects nonsense', () {
      expect(Money.parse('abc'), isNull);
      expect(Money.parse(''), isNull);
    });
  });

  group('tax rate display', () {
    test('basis points to percent', () {
      expect(Money.formatRate(500), '5');
      expect(Money.formatRate(250), '2.5');
      expect(Money.formatRate(1800), '18');
      expect(Money.formatRate(0), '0');
    });

    // The editor shows formatRate and converts back with rate*100 on save.
    test('percent text converts back to the same basis points', () {
      for (final bp in [0, 250, 500, 1200, 1800]) {
        final shown = Money.formatRate(bp);
        final back = (double.parse(shown) * 100).round();
        expect(back, bp, reason: 'bp=$bp shown=$shown');
      }
    });
  });
}
