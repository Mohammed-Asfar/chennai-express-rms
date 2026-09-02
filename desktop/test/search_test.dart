import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chennai_express_pos/core/theme/app_theme.dart';
import 'package:chennai_express_pos/core/widgets/search_field.dart';
import 'package:chennai_express_pos/features/billing/data/bill_models.dart';
import 'package:chennai_express_pos/features/bookings/data/booking_models.dart';

Bill bill({
  String number = 'BILL/20260902/014',
  int? orderNo = 24,
  String? customerName,
  String? customerPhone,
}) => Bill(
  id: 'b1',
  orderId: 'o1',
  billNumber: number,
  businessDate: '2026-09-02',
  createdAt: DateTime(2026, 9, 2, 13, 53),
  subtotal: 41000,
  discountAmount: 0,
  cgst: 0,
  sgst: 0,
  roundOff: 0,
  total: 41000,
  amountPaid: 41000,
  outstanding: 0,
  paymentStatus: PaymentStatus.paid,
  taxBreakdown: const [],
  payments: const [],
  orderNo: orderNo,
  customerName: customerName,
  customerPhone: customerPhone,
);

Booking booking({
  String name = 'Ravi',
  String? phone,
  List<BookedTable> tables = const [
    BookedTable(id: 't1', name: 'T1', seats: 4),
  ],
}) => Booking(
  id: 'r1',
  customerName: name,
  customerPhone: phone,
  partySize: 4,
  reservedAt: DateTime(2026, 9, 2, 19, 30),
  status: BookingStatus.booked,
  tables: tables,
  seatCount: 4,
  isOverdue: false,
);

void main() {
  group('searching bills', () {
    test('an empty query keeps every bill', () {
      // The list must not empty itself before anything is typed.
      expect(bill().matches(''), isTrue);
    });

    test('a bill is found by the digits at the end of its number', () {
      // How a bill number is read aloud off a printed slip: "fourteen", not
      // the whole BILL/20260902/014 string.
      expect(bill(number: 'BILL/20260902/014').matches('014'), isTrue);
      expect(bill(number: 'BILL/20260902/014').matches('14'), isTrue);
    });

    test('a bill is found by its full number, whatever the case', () {
      expect(bill().matches('bill/20260902/014'), isTrue);
    });

    test('a bill is found by its order number', () {
      expect(bill(orderNo: 24).matches('24'), isTrue);
    });

    test('a bill is found by customer name and phone', () {
      final phoned = bill(customerName: 'Priya', customerPhone: '9876543210');
      expect(phoned.matches('priya'), isTrue);
      expect(phoned.matches('98765'), isTrue);
    });

    test('a walk-in with no customer still searches by number', () {
      // Most bills have no customer at all. Matching must never depend on it.
      final walkIn = bill(customerName: null, customerPhone: null);
      expect(walkIn.matches('014'), isTrue);
      expect(walkIn.matches('priya'), isFalse);
    });

    test('an unrelated query matches nothing', () {
      expect(bill().matches('zzz'), isFalse);
    });

    test('a bill with no order number does not crash the search', () {
      expect(bill(orderNo: null).matches('24'), isFalse);
      expect(bill(orderNo: null).matches('014'), isTrue);
    });
  });

  group('searching bookings', () {
    test('an empty query keeps every booking', () {
      expect(booking().matches(''), isTrue);
    });

    test('a booking is found by name, case-insensitively', () {
      expect(booking(name: 'Ravi Kumar').matches('ravi'), isTrue);
      expect(booking(name: 'Ravi Kumar').matches('kumar'), isTrue);
    });

    test('a booking is found by a fragment of the phone number', () {
      // The phone rings and shows the last few digits; that is what gets typed.
      expect(booking(phone: '9876543210').matches('3210'), isTrue);
    });

    test('a booking is found by any table it holds, not just the first', () {
      final party = booking(
        tables: const [
          BookedTable(id: 't1', name: 'T1', seats: 4),
          BookedTable(id: 't2', name: 'T7', seats: 4),
        ],
      );
      expect(party.matches('t7'), isTrue);
    });

    test('a booking with no phone does not crash the search', () {
      expect(booking(phone: null).matches('3210'), isFalse);
      expect(booking(phone: null).matches('ravi'), isTrue);
    });
  });

  group('the search field', () {
    testWidgets('it reports the query trimmed and lowercased', (tester) async {
      // Every caller filters against this shape, so normalising here is what
      // stops one screen matching case-sensitively and another not.
      final seen = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: SearchField(hintText: 'Search', onChanged: seen.add),
          ),
        ),
      );

      await tester.enterText(find.byType(TextField), '  RAVI  ');
      await tester.pump();
      expect(seen.last, 'ravi');
    });

    testWidgets('the clear button appears only once something is typed', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: SearchField(hintText: 'Search', onChanged: (_) {}),
          ),
        ),
      );

      expect(find.byIcon(Icons.close), findsNothing);

      await tester.enterText(find.byType(TextField), 'ravi');
      await tester.pump();
      expect(find.byIcon(Icons.close), findsOneWidget);
    });

    testWidgets('clearing empties the box and reports an empty query', (
      tester,
    ) async {
      // A stale query is why a list looks empty; getting everything back has
      // to be one tap, and the callback must fire or the list stays filtered.
      final seen = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: SearchField(hintText: 'Search', onChanged: seen.add),
          ),
        ),
      );

      await tester.enterText(find.byType(TextField), 'ravi');
      await tester.pump();

      await tester.tap(find.byIcon(Icons.close));
      await tester.pump();

      expect(seen.last, '');
      expect(find.text('ravi'), findsNothing);
    });
  });
}
