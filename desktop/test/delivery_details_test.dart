import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chennai_express_pos/core/theme/app_theme.dart';
import 'package:chennai_express_pos/features/order/data/order_models.dart';
import 'package:chennai_express_pos/features/order/presentation/delivery_details_dialog.dart';

/// Opens the dialog and hands back whatever it returned.
Future<({String name, String phone})?> open(WidgetTester tester) async {
  ({String name, String phone})? result;
  bool opened = false;

  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light,
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              opened = true;
              result = await DeliveryDetailsDialog.show(context);
            },
            child: const Text('start'),
          ),
        ),
      ),
    ),
  );

  await tester.tap(find.text('start'));
  await tester.pumpAndSettle();
  expect(opened, isTrue);
  return result;
}

void main() {
  group('taking a delivery order', () {
    testWidgets('asks for the phone and the address', (tester) async {
      // A delivery with neither cannot be delivered. Takeaway is not asked,
      // because the customer is standing at the counter.
      await open(tester);

      expect(find.text('Delivery details'), findsOneWidget);
      expect(find.text('Phone'), findsOneWidget);
      expect(find.text('Name and address'), findsOneWidget);
    });

    testWidgets('the phone field is focused, so typing starts there',
        (tester) async {
      // The number is the detail a rider reaches for when they cannot find the
      // door, and it is usually the first thing said on the phone.
      await open(tester);

      // First field in the dialog, and the only autofocused one.
      final phone = tester.widget<TextField>(find.byType(TextField).first);
      expect(phone.autofocus, isTrue);

      final address = tester.widget<TextField>(find.byType(TextField).at(1));
      expect(address.autofocus, isFalse, reason: 'focus starts at the phone');
    });

    testWidgets('what was typed comes back', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  final r = await DeliveryDetailsDialog.show(context);
                  expect(r?.phone, '9940817315');
                  expect(r?.name, 'Ravi, 3rd cross');
                },
                child: const Text('start'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('start'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).at(0), '9940817315');
      await tester.enterText(find.byType(TextField).at(1), 'Ravi, 3rd cross');
      await tester.tap(find.text('Start order'));
      await tester.pumpAndSettle();
    });

    testWidgets('an empty form still starts the order', (tester) async {
      // A shop that already knows the customer, or one taking the address over
      // the phone while the food is started, must not be held up by this.
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  final r = await DeliveryDetailsDialog.show(context);
                  expect(r, isNotNull, reason: 'blank is not a dismissal');
                  expect(r?.phone, '');
                },
                child: const Text('start'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('start'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Start order'));
      await tester.pumpAndSettle();
    });

    testWidgets('cancel starts nothing at all', (tester) async {
      // Distinct from an empty form: null means no order, not an order with no
      // details. Confusing the two would leave a stray order on the floor.
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  final r = await DeliveryDetailsDialog.show(context);
                  expect(r, isNull);
                },
                child: const Text('start'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('start'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
    });
  });

  group('the order model', () {
    test('reads a delivery as delivery, not takeaway', () {
      // The order screen titles itself from this. Falling back to takeaway
      // would label a delivery wrongly on the screen staff work from.
      final order = Order.fromJson(const {
        'id': 'o1',
        'orderNo': 7,
        'type': 'delivery',
        'status': 'open',
        'version': 1,
        'items': <Map<String, dynamic>>[],
        'customerName': 'Ravi, 3rd cross',
        'customerPhone': '9940817315',
      });

      expect(order.type, OrderType.delivery);
      expect(order.type.label, 'Delivery');
      expect(order.customerPhone, '9940817315');
    });

    test('every kind has a label a person would say', () {
      for (final type in OrderType.values) {
        expect(type.label, isNotEmpty);
      }
      expect(OrderType.dineIn.label, 'Dine-in');
      expect(OrderType.takeaway.label, 'Takeaway');
    });
  });
}
