import 'package:flutter_test/flutter_test.dart';
import 'package:chennai_express_pos/core/api/api_exception.dart';
import 'package:chennai_express_pos/features/order/data/order_models.dart';

void main() {
  group('what a person is shown when something fails', () {
    test('an API failure shows its message, not its class name', () {
      // What a cashier actually saw mid-service:
      //   ApiException(ALREADY_BILLED): This order has already been billed
      // The half before the colon is a class name and a wire constant.
      const error = ApiException(
        code: 'ALREADY_BILLED',
        message: 'This order has already been billed',
        statusCode: 409,
      );

      expect(userMessage(error), 'This order has already been billed');
      expect(userMessage(error), isNot(contains('ApiException')));
      expect(userMessage(error), isNot(contains('ALREADY_BILLED')));
    });

    test('an unexpected failure says what to do', () {
      // A raw exception has no text written for a user, so a sentence beats a
      // fragment of a stack trace.
      final message = userMessage(StateError('Bad state: null check'));

      expect(message, isNot(contains('StateError')));
      expect(message, isNot(contains('null check')));
      expect(message, contains('Try again'));
    });

    test('toString is still the debugging form', () {
      // Kept for logs — this change is about what reaches a screen.
      const error = ApiException(
        code: 'NOPE',
        message: 'Something failed',
        statusCode: 500,
      );
      expect(error.toString(), contains('NOPE'));
    });
  });

  group('an order reopened to correct a bill', () {
    test('knows it already has one', () {
      // Without this the till offered Take payment, which asks the backend to
      // create a second bill for the same order.
      final order = Order.fromJson(const {
        'id': 'o1',
        'orderNo': 9,
        'type': 'delivery',
        'status': 'open',
        'version': 2,
        'items': <Map<String, dynamic>>[],
        'billId': 'b1',
      });

      expect(order.isOpen, isTrue, reason: 'open so its lines can be changed');
      expect(order.isBeingCorrected, isTrue);
      expect(order.billId, 'b1');
    });

    test('an ordinary open order is not being corrected', () {
      final order = Order.fromJson(const {
        'id': 'o1',
        'orderNo': 10,
        'type': 'takeaway',
        'status': 'open',
        'version': 1,
        'items': <Map<String, dynamic>>[],
      });

      expect(order.isBeingCorrected, isFalse);
      expect(order.billId, isNull);
    });
  });
}
