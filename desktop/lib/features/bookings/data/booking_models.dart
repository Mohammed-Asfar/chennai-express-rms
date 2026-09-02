enum BookingStatus { booked, seated, noShow, cancelled }

BookingStatus _statusFrom(String value) => switch (value) {
  'seated' => BookingStatus.seated,
  'no_show' => BookingStatus.noShow,
  'cancelled' => BookingStatus.cancelled,
  _ => BookingStatus.booked,
};

extension BookingStatusLabel on BookingStatus {
  String get label => switch (this) {
    BookingStatus.booked => 'Booked',
    BookingStatus.seated => 'Seated',
    BookingStatus.noShow => 'No-show',
    BookingStatus.cancelled => 'Cancelled',
  };
}

/// A table held by a booking.
class BookedTable {
  const BookedTable({required this.id, required this.name, required this.seats});

  final String id;
  final String name;
  final int seats;

  factory BookedTable.fromJson(Map<String, dynamic> json) => BookedTable(
    id: json['id'] as String,
    name: json['name'] as String,
    seats: json['seats'] as int? ?? 0,
  );
}

/// A booking. Holds one or more tables — a party of 12 across three tables is
/// one booking, not three.
class Booking {
  const Booking({
    required this.id,
    required this.customerName,
    required this.partySize,
    required this.reservedAt,
    required this.status,
    required this.tables,
    required this.seatCount,
    required this.isOverdue,
    this.customerPhone,
    this.notes,
    this.orderId,
  });

  final String id;
  final String customerName;
  final String? customerPhone;
  final int partySize;
  final DateTime reservedAt;
  final BookingStatus status;
  final List<BookedTable> tables;

  /// Seats across every table held, which is what tells staff whether the
  /// party actually fits.
  final int seatCount;

  /// Still `booked` well past its time. Decided by the backend so a screen left
  /// open overnight cannot rule a booking on time because its own clock says so.
  final bool isOverdue;

  final String? notes;

  /// The order opened when the party arrived. Null until they are seated.
  final String? orderId;

  bool get isOpen => status == BookingStatus.booked;

  /// Whether the tables held seat the party. Under-seating is worth flagging
  /// before the party arrives, not when they are standing at the door.
  bool get isUndersized => seatCount > 0 && seatCount < partySize;

  String get tableLabel =>
      tables.isEmpty ? 'No table' : tables.map((t) => t.name).join(', ');

  factory Booking.fromJson(Map<String, dynamic> json) => Booking(
    id: json['id'] as String,
    customerName: json['customerName'] as String,
    customerPhone: json['customerPhone'] as String?,
    partySize: json['partySize'] as int? ?? 0,
    reservedAt:
        DateTime.tryParse(json['reservedAt'] as String? ?? '')?.toLocal() ??
        DateTime.now(),
    status: _statusFrom(json['status'] as String? ?? 'booked'),
    tables: ((json['tables'] as List<dynamic>?) ?? const [])
        .map((t) => BookedTable.fromJson(t as Map<String, dynamic>))
        .toList(),
    seatCount: json['seatCount'] as int? ?? 0,
    isOverdue: json['isOverdue'] as bool? ?? false,
    notes: json['notes'] as String?,
    orderId: json['orderId'] as String?,
  );
}

/// How the day is going, for the strip above the list.
class BookingSummary {
  const BookingSummary({
    this.booked = 0,
    this.seated = 0,
    this.noShow = 0,
    this.cancelled = 0,
    this.overdue = 0,
    this.covers = 0,
  });

  final int booked;
  final int seated;
  final int noShow;
  final int cancelled;

  /// Bookings past their time and still unseated — the ones to chase.
  final int overdue;

  /// Guests expected across bookings that are still live.
  final int covers;

  factory BookingSummary.fromJson(Map<String, dynamic> json) => BookingSummary(
    booked: json['booked'] as int? ?? 0,
    seated: json['seated'] as int? ?? 0,
    noShow: json['noShow'] as int? ?? 0,
    cancelled: json['cancelled'] as int? ?? 0,
    overdue: json['overdue'] as int? ?? 0,
    covers: json['covers'] as int? ?? 0,
  );
}

class BookingDay {
  const BookingDay({required this.bookings, required this.summary});

  final List<Booking> bookings;
  final BookingSummary summary;
}

/// A booking plus anything the staff member should know about it.
///
/// Warnings never block a booking — they are returned alongside one that has
/// already been saved.
class BookingResult {
  const BookingResult({required this.booking, this.warnings = const []});

  final Booking booking;
  final List<String> warnings;

  factory BookingResult.fromJson(Map<String, dynamic> json) => BookingResult(
    booking: Booking.fromJson(json['reservation'] as Map<String, dynamic>),
    warnings: ((json['warnings'] as List<dynamic>?) ?? const [])
        .map((w) => w as String)
        .toList(),
  );
}
