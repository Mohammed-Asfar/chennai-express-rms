import 'package:flutter_test/flutter_test.dart';
import 'package:chennai_express_pos/features/menu/data/menu_admin_models.dart';
import 'package:chennai_express_pos/features/menu/data/menu_models.dart';

void main() {
  group('a portion carries its own availability', () {
    test('a draft is available unless said otherwise', () {
      expect(VariantDraft(name: 'Full', price: 38000).isAvailable, isTrue);
    });

    test('a new portion can be created sold out', () {
      final draft = VariantDraft(name: 'Full', price: 38000, isAvailable: false);
      expect(draft.isAvailable, isFalse);
    });

    test('an existing portion reads its state from the backend', () {
      final variant = AdminVariant.fromJson({
        'id': 'v1',
        'name': 'Full',
        'price': 38000,
        'isAvailable': false,
      });
      expect(variant.isAvailable, isFalse);
    });

    test('an older payload without the field counts as available', () {
      // Defaulting to sold out would take a dish off the menu on an upgrade.
      final variant = AdminVariant.fromJson({
        'id': 'v1',
        'name': 'Full',
        'price': 38000,
      });
      expect(variant.isAvailable, isTrue);
    });
  });

  group('what the order screen can offer', () {
    MenuItem item(List<bool> portionsAvailable, {bool itemAvailable = true}) =>
        MenuItem.fromJson({
          'id': 'i1',
          'categoryId': 'c1',
          'name': 'Mutton Biryani',
          'taxRate': 500,
          'isAvailable': itemAvailable,
          'variants': [
            for (var i = 0; i < portionsAvailable.length; i++)
              {
                'id': 'v$i',
                'name': i == 0 ? 'Half' : 'Full',
                'price': 20000 + i * 18000,
                'isAvailable': portionsAvailable[i],
              },
          ],
        });

    test('one sold-out portion does not take the dish off', () {
      // The whole point: the kitchen runs out of the large size while the small
      // one is still on. Hiding the dish would lose the sale.
      expect(item([true, false]).canOrder, isTrue);
    });

    test('a dish with every portion sold out is not orderable', () {
      expect(item([false, false]).canOrder, isFalse);
    });

    test('switching the whole item off beats an available portion', () {
      expect(item([true, true], itemAvailable: false).canOrder, isFalse);
    });
  });
}
