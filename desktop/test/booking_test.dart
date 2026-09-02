import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chennai_express_pos/core/theme/app_theme.dart';
import 'package:chennai_express_pos/features/bookings/data/booking_models.dart';
import 'package:chennai_express_pos/features/bookings/data/booking_repository.dart';
import 'package:chennai_express_pos/features/bookings/presentation/booking_row.dart';

Booking booking({
  String name = 'Ravi',
  int partySize = 4,
  BookingStatus status = BookingStatus.booked,
  List<BookedTable> tables = const [
    BookedTable(id: 't1', name: 'T1', seats: 4),
  ],
  int? seatCount,
  bool isOverdue = false,
  String? notes,
  DateTime? at,
}) => Booking(
  id: 'b1',
  customerName: name,
  partySize: partySize,
  reservedAt: at ?? DateTime(2026, 9, 2, 19, 30),
  status: status,
  tables: tables,
  seatCount: seatCount ?? tables.fold(0, (sum, t) => sum + t.seats),
  isOverdue: isOverdue,
  notes: notes,
);

Widget wrap(Widget child) => MaterialApp(
  theme: AppTheme.light,
  home: Scaffold(body: child),
);

void main() {
  group('booking model', () {
    test('a booking parses the fields the list is built from', () {
      final parsed = Booking.fromJson({
        'id': 'b1',
        'customerName': 'Priya',
        'customerPhone': '9876543210',
        'partySize': 6,
        'reservedAt': '2026-09-02T14:00:00.000Z',
        'status': 'booked',
        'seatCount': 8,
        'isOverdue': true,
        'tables': [
          {'id': 't1', 'name': 'T1', 'seats': 4},
          {'id': 't2', 'name': 'T2', 'seats': 4},
        ],
      });

      expect(parsed.customerName, 'Priya');
      expect(parsed.partySize, 6);
      expect(parsed.tables.length, 2);
      expect(parsed.seatCount, 8);
      expect(parsed.isOverdue, isTrue);
      expect(parsed.status, BookingStatus.booked);
    });

    test('no_show arrives underscored on the wire and reads as a no-show', () {
      // The enum name and the wire value differ, so a plain byName lookup here
      // would silently fall through to `booked` and show a Seat button for a
      // party that never arrived.
      final parsed = Booking.fromJson({
        'id': 'b1',
        'customerName': 'Ravi',
        'partySize': 2,
        'reservedAt': '2026-09-02T14:00:00.000Z',
        'status': 'no_show',
      });

      expect(parsed.status, BookingStatus.noShow);
      expect(parsed.isOpen, isFalse);
    });

    test('a time is held in local time, not UTC', () {
      // Printed straight onto the row: an 8pm booking shown at 2:30pm because
      // the offset was dropped would have staff holding a table at the wrong time.
      final utc = DateTime.utc(2026, 9, 2, 14, 30);
      final parsed = Booking.fromJson({
        'id': 'b1',
        'customerName': 'Ravi',
        'partySize': 2,
        'reservedAt': utc.toIso8601String(),
      });

      expect(parsed.reservedAt, utc.toLocal());
      expect(parsed.reservedAt.isUtc, isFalse);
    });

    test('tables that do not seat the party are flagged', () {
      final tight = booking(
        partySize: 8,
        tables: const [BookedTable(id: 't1', name: 'T1', seats: 4)],
      );
      expect(tight.isUndersized, isTrue);

      final fits = booking(partySize: 4);
      expect(fits.isUndersized, isFalse);
    });

    test('a booking with no tables left is not called undersized', () {
      // Its tables were deleted. That is a different problem, and reporting it
      // as a tight fit would send staff looking for a bigger table instead of
      // any table.
      final stranded = booking(partySize: 4, tables: const [], seatCount: 0);
      expect(stranded.isUndersized, isFalse);
    });

    test('every table held is named, not just the first', () {
      final party = booking(
        partySize: 12,
        tables: const [
          BookedTable(id: 't1', name: 'T1', seats: 4),
          BookedTable(id: 't2', name: 'T2', seats: 4),
          BookedTable(id: 't3', name: 'T3', seats: 4),
        ],
      );
      expect(party.tableLabel, 'T1, T2, T3');
      expect(party.seatCount, 12);
    });

    test('only a booked reservation is still open', () {
      expect(booking(status: BookingStatus.booked).isOpen, isTrue);
      expect(booking(status: BookingStatus.seated).isOpen, isFalse);
      expect(booking(status: BookingStatus.cancelled).isOpen, isFalse);
      expect(booking(status: BookingStatus.noShow).isOpen, isFalse);
    });
  });

  group('the wire date', () {
    test('a single-digit month and day are padded', () {
      // '2026-9-2' would filter nothing and the day would look empty.
      expect(
        BookingRepository.wireDate(DateTime(2026, 9, 2)),
        '2026-09-02',
      );
      expect(
        BookingRepository.wireDate(DateTime(2026, 12, 25)),
        '2026-12-25',
      );
    });
  });

  group('the booking row', () {
    testWidgets('an open booking offers Seat', (tester) async {
      await tester.pumpWidget(
        wrap(
          BookingRow(
            booking: booking(),
            onSeat: () {},
            onEdit: () {},
            onNoShow: () {},
            onCancel: () {},
          ),
        ),
      );

      expect(find.text('Seat'), findsOneWidget);
      expect(find.text('Ravi'), findsOneWidget);
      expect(find.text('4 guests · T1'), findsOneWidget);
    });

    testWidgets('a seated booking cannot be seated again', (tester) async {
      await tester.pumpWidget(
        wrap(
          BookingRow(
            booking: booking(status: BookingStatus.seated),
            onSeat: () {},
            onEdit: () {},
            onNoShow: () {},
            onCancel: () {},
          ),
        ),
      );

      expect(find.text('Seat'), findsNothing);
      expect(find.text('Seated'), findsOneWidget);
    });

    testWidgets('a cancelled booking says so rather than offering actions', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(
          BookingRow(
            booking: booking(status: BookingStatus.cancelled),
            onSeat: () {},
            onEdit: () {},
            onNoShow: () {},
            onCancel: () {},
          ),
        ),
      );

      expect(find.text('Cancelled'), findsOneWidget);
      expect(find.text('Seat'), findsNothing);
    });

    testWidgets('a late booking is marked, in words as well as colour', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(
          BookingRow(
            booking: booking(isOverdue: true),
            onSeat: () {},
            onEdit: () {},
            onNoShow: () {},
            onCancel: () {},
          ),
        ),
      );

      // Colour alone would fail anyone who cannot separate it, and this is the
      // cue that decides whether a table gets given away.
      expect(find.text('Late'), findsOneWidget);
    });

    testWidgets('a tight fit is flagged before the party arrives', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(
          BookingRow(
            booking: booking(partySize: 8),
            onSeat: () {},
            onEdit: () {},
            onNoShow: () {},
            onCancel: () {},
          ),
        ),
      );

      expect(find.text('Tight fit'), findsOneWidget);
    });

    testWidgets('a seated booking is not nagged about its size', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(
          BookingRow(
            booking: booking(partySize: 8, status: BookingStatus.seated),
            onSeat: () {},
            onEdit: () {},
            onNoShow: () {},
            onCancel: () {},
          ),
        ),
      );

      // They are already sitting down. The fit is no longer a decision.
      expect(find.text('Tight fit'), findsNothing);
    });

    testWidgets('seating fires the callback', (tester) async {
      var seated = false;
      await tester.pumpWidget(
        wrap(
          BookingRow(
            booking: booking(),
            onSeat: () => seated = true,
            onEdit: () {},
            onNoShow: () {},
            onCancel: () {},
          ),
        ),
      );

      await tester.tap(find.text('Seat'));
      await tester.pump();
      expect(seated, isTrue);
    });

    testWidgets('a note on the booking is shown', (tester) async {
      await tester.pumpWidget(
        wrap(
          BookingRow(
            booking: booking(notes: 'window seat, birthday'),
            onSeat: () {},
            onEdit: () {},
            onNoShow: () {},
            onCancel: () {},
          ),
        ),
      );

      expect(find.text('window seat, birthday'), findsOneWidget);
    });
  });
}
