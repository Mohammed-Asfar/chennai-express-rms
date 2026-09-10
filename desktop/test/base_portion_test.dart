import 'package:flutter_test/flutter_test.dart';

import 'package:chennai_express_pos/features/billing/data/bill_models.dart';
import 'package:chennai_express_pos/features/order/data/order_models.dart';

BillItem billItem(String variant, {bool isBase = false}) => BillItem(
      itemName: 'Chicken Biryani',
      variantName: variant,
      variantIsBase: isBase,
      qty: 1,
      unitPrice: 18000,
      taxRate: 500,
      lineTax: 900,
      lineTotal: 18900,
    );

OrderLine orderLine(String variant, {bool isBase = false}) => OrderLine(
      id: 'l1',
      variantId: 'v1',
      itemName: 'Chicken Biryani',
      variantName: variant,
      variantIsBase: isBase,
      unitPrice: 18000,
      qty: 1,
      lineTotal: 18900,
      kotPrinted: false,
    );

void main() {
  group('the bill', () {
    test('leaves the base portion name off', () {
      // "Chicken Biryani (Regular)" tells the customer what they already know.
      expect(billItem('Regular', isBase: true).displayName, 'Chicken Biryani');
    });

    test('hides a base portion whatever it is called', () {
      // The flag decides, not the word — so "Base" or "Normal" work the same.
      for (final name in ['Regular', 'Base', 'Normal', 'Standard', 'Sadha']) {
        expect(billItem(name, isBase: true).displayName, 'Chicken Biryani');
      }
    });

    test('names a portion that is not the base', () {
      for (final name in ['Dry', 'Gravy', 'Half', 'Full', 'Single', 'Fry']) {
        expect(billItem(name).displayName, 'Chicken Biryani ($name)');
      }
    });

    test('names a non-base portion even when it is called Regular', () {
      // An item with Regular and Large has a real choice to show.
      expect(billItem('Regular').displayName, 'Chicken Biryani (Regular)');
    });

    test('falls back to the item name when there is no portion at all', () {
      expect(billItem('').displayName, 'Chicken Biryani');
    });
  });

  group('the order screen', () {
    test('names every portion, base or not', () {
      // Staff read this back to the customer and the kitchen works from it. A
      // portion inferred from an absence is a portion got wrong.
      expect(
        orderLine('Regular', isBase: true).displayName,
        'Chicken Biryani (Regular)',
      );
      expect(orderLine('Full').displayName, 'Chicken Biryani (Full)');
    });
  });
}
