import 'package:flutter_test/flutter_test.dart';
import 'package:chennai_express_pos/features/tables/data/table_admin_models.dart';
import 'package:chennai_express_pos/features/menu/data/menu_admin_models.dart';
import 'package:chennai_express_pos/features/menu/data/menu_admin_repository.dart';
import 'package:chennai_express_pos/features/floor/data/floor_models.dart';
import 'package:chennai_express_pos/features/menu/data/menu_models.dart';
import 'package:chennai_express_pos/features/order/data/order_models.dart';

Map<String, dynamic> sectionJson({int? surcharge}) => {
  'id': 's1',
  'name': 'AC',
  'sortOrder': 0,
  'isActive': true,
  'tableCount': 4,
  if (surcharge != null) 'surcharge': surcharge,
};

Map<String, dynamic> itemJson({Object? acSurcharge = 'absent'}) => {
  'id': 'i1',
  'categoryId': 'c1',
  'name': 'Chicken Soup',
  'taxRate': 500,
  'isAvailable': true,
  'sortOrder': 0,
  'variants': const [],
  if (acSurcharge != 'absent') 'acSurcharge': acSurcharge,
};

void main() {
  group('a section that charges extra', () {
    test('carries the amount in paise', () {
      final section = AdminSection.fromJson(sectionJson(surcharge: 1000));
      expect(section.surcharge, 1000, reason: '₹10');
      expect(section.chargesExtra, isTrue);
    });

    test('a section charging nothing says so', () {
      final section = AdminSection.fromJson(sectionJson(surcharge: 0));
      expect(section.chargesExtra, isFalse);
    });

    test('an older backend that omits the field charges nothing', () {
      // A till may briefly run against a backend from before this shipped.
      // Defaulting to anything other than zero would invent a charge.
      final section = AdminSection.fromJson(sectionJson());
      expect(section.surcharge, 0);
      expect(section.chargesExtra, isFalse);
    });
  });

  group('the floor model', () {
    test('carries the surcharge through', () {
      // Editing a section starts from the floor screen, which builds an
      // AdminSection from this. Without the field the dialog would open
      // showing no charge and save that back, wiping it.
      final section = FloorSection.fromJson({
        'id': 's1',
        'name': 'AC',
        'surcharge': 1000,
        'tables': const [],
      });

      expect(section.surcharge, 1000);
      expect(section.chargesExtra, isTrue);
    });

    test('an edit round-trips without losing the charge', () {
      // The bug this guards: a rename saving zero over a real AC charge.
      final floor = FloorSection.fromJson({
        'id': 's1',
        'name': 'AC',
        'surcharge': 1000,
        'tables': const [],
      });

      final forDialog = AdminSection(
        id: floor.id,
        name: floor.name,
        sortOrder: 0,
        isActive: true,
        tableCount: floor.tables.length,
        surcharge: floor.surcharge,
      );

      expect(forDialog.surcharge, 1000, reason: 'not silently reset to zero');
    });
  });

  group("an item's own amount", () {
    test('null follows the section', () {
      final item = AdminMenuItem.fromJson(itemJson(acSurcharge: null));
      expect(item.acSurcharge, isNull);
      expect(item.followsSection, isTrue);
      expect(item.isExempt, isFalse);
    });

    test('zero is an exemption, not an absence', () {
      // The distinction the whole nullable column exists for. Collapsing them
      // would put tea back on the section's ₹10 the next time it was saved.
      final item = AdminMenuItem.fromJson(itemJson(acSurcharge: 0));
      expect(item.acSurcharge, 0);
      expect(item.isExempt, isTrue);
      expect(item.followsSection, isFalse);
    });

    test('an amount overrides the section', () {
      final item = AdminMenuItem.fromJson(itemJson(acSurcharge: 2500));
      expect(item.acSurcharge, 2500);
      expect(item.followsSection, isFalse);
    });

    test('a backend that omits the field means follow the section', () {
      final item = AdminMenuItem.fromJson(itemJson());
      expect(item.acSurcharge, isNull);
      expect(item.followsSection, isTrue);
    });
  });

  group('the price shown on the menu', () {
    MenuItem menuItem({int price = 7500, int? acSurcharge, int portions = 1}) =>
        MenuItem.fromJson({
          'id': 'i1',
          'categoryId': 'c1',
          'name': 'Chicken Soup',
          'isAvailable': true,
          if (acSurcharge != null) 'acSurcharge': acSurcharge,
          'variants': [
            for (var i = 0; i < portions; i++)
              {
                'id': 'v$i',
                'name': portions == 1 ? 'Standard' : 'Size $i',
                'price': price + (i * 5000),
                'isAvailable': true,
              },
          ],
        });

    test('includes the section charge', () {
      // A cashier reading ₹75 here and seeing ₹85 on the bill has no way to
      // tell a surcharge from a mistake.
      expect(menuItem().singlePriceIn(1000), 8500);
    });

    test('is the menu price where nothing is charged', () {
      expect(menuItem().singlePriceIn(0), 7500);
    });

    test('an exempt item ignores the section', () {
      expect(menuItem(acSurcharge: 0).singlePriceIn(1000), 7500);
    });

    test("an item's own amount replaces the section's", () {
      expect(menuItem(acSurcharge: 2500).singlePriceIn(1000), 10000);
    });

    test('a multi-portion item still shows no single price', () {
      // The tile reads "2 sizes" instead, and adding a surcharge must not
      // conjure a figure that would be wrong for one of them.
      expect(menuItem(portions: 2).singlePriceIn(1000), isNull);
    });

    test('each portion is priced separately in the picker', () {
      // Per item, so both portions take the charge — not the order as a whole.
      final item = menuItem(portions: 2);
      expect(item.priceIn(item.variants[0], 1000), 8500);
      expect(item.priceIn(item.variants[1], 1000), 13500);
    });

    test('agrees with the backend on every combination', () {
      // The rule is implemented twice — here for display, and in the backend
      // for what is charged. They must not drift, because the gap between them
      // is a price a customer was quoted and then not charged.
      //
      // Mirrors backend/src/lib/surcharge.ts: the item wins when set, null
      // follows the section.
      for (final section in [0, 1000, 5000]) {
        for (final item in [null, 0, 1000, 2500]) {
          final expected = 7500 + (item ?? section);
          expect(
            menuItem(acSurcharge: item).singlePriceIn(section),
            expected,
            reason: 'section $section, item $item',
          );
        }
      }
    });
  });

  group('the order carries its section charge', () {
    Order order({int? surcharge}) => Order.fromJson({
      'id': 'o1',
      'orderNo': 21,
      'type': 'dine_in',
      'status': 'open',
      'version': 1,
      'items': const [],
      'subtotal': 0,
      'tax': 0,
      'total': 0,
      'itemCount': 0,
      if (surcharge != null) 'surcharge': surcharge,
    });

    test('so the menu can show what this table pays', () {
      expect(order(surcharge: 1000).surcharge, 1000);
      expect(order(surcharge: 1000).hasSurcharge, isTrue);
    });

    test('a table charging nothing says so', () {
      expect(order(surcharge: 0).hasSurcharge, isFalse);
    });

    test('a backend that omits it charges nothing', () {
      // A till may briefly run against an older backend. Inventing a charge
      // would be worse than showing the menu price.
      expect(order().surcharge, 0);
      expect(order().hasSurcharge, isFalse);
    });
  });

  group('Patch', () {
    test('holds a value', () {
      expect(const Patch(2500).value, 2500);
    });

    test('holds an explicit null, which is not the same as no patch', () {
      // `Patch(null)` clears the override; passing no Patch at all leaves it
      // alone. A bare int? could not express both.
      const Patch<int>? absent = null;
      const cleared = Patch<int>(null);

      expect(absent, isNull, reason: 'nothing to send');
      expect(cleared.value, isNull, reason: 'send null');
      expect(cleared, isNotNull);
    });

    test('zero survives, rather than reading as empty', () {
      // The failure mode a truthiness check would produce: an exemption
      // quietly dropped from the request.
      const exempt = Patch<int>(0);
      expect(exempt.value, 0);
    });
  });
}
