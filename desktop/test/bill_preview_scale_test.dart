import 'package:flutter_test/flutter_test.dart';
import 'package:chennai_express_pos/features/settings/data/settings_repository.dart';

PreviewLine line(Map<String, dynamic> overrides) => PreviewLine.fromJson({
  'text': 'Chennai Express',
  'large': false,
  'bold': false,
  'align': 'center',
  ...overrides,
});

void main() {
  group('preview line scaling', () {
    test('carries the real multipliers, not just a flag', () {
      // A boolean was not enough: a triple-height name and a double-height one
      // both arrived as `large`, so the preview drew them identically and the
      // size setting looked like it did nothing.
      final name = line({'heightScale': 3, 'widthScale': 2, 'large': true});
      expect(name.heightScale, 3);
      expect(name.widthScale, 2);
    });

    test('a normal line is 1x in both directions', () {
      expect(line({}).heightScale, 1);
      expect(line({}).widthScale, 1);
    });

    test('defaults to 1x when the backend omits the field', () {
      // An older backend must not make every line render at zero height.
      final bare = PreviewLine.fromJson({'text': 'x', 'align': 'left'});
      expect(bare.heightScale, 1);
      expect(bare.widthScale, 1);
    });

    test('large stays true for anything enlarged either way', () {
      // The bold styling keys off `large`, so it must not go false when only
      // the width is doubled.
      expect(line({'large': true, 'widthScale': 2}).large, isTrue);
    });
  });
}
