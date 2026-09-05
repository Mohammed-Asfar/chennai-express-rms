import 'package:flutter_test/flutter_test.dart';
import 'package:chennai_express_pos/features/tables/data/table_admin_models.dart';
import 'package:chennai_express_pos/features/menu/data/menu_admin_models.dart';
import 'package:chennai_express_pos/features/menu/data/menu_admin_repository.dart';
import 'package:chennai_express_pos/features/floor/data/floor_models.dart';

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
