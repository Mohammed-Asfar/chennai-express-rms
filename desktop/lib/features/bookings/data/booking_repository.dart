import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_client.dart';
import '../../../core/api/providers.dart';
import 'booking_models.dart';

class BookingRepository {
  BookingRepository(this._api);

  final ApiClient _api;

  /// Bookings for a trading day, newest last. Omitting the date gives today.
  Future<BookingDay> list({DateTime? date}) async {
    final path = date == null ? '/reservations' : '/reservations?date=${wireDate(date)}';
    final json = await _api.get(path);

    return BookingDay(
      bookings: ((json['reservations'] as List<dynamic>?) ?? const [])
          .map((r) => Booking.fromJson(r as Map<String, dynamic>))
          .toList(),
      summary: BookingSummary.fromJson(
        (json['summary'] as Map<String, dynamic>?) ?? const {},
      ),
    );
  }

  Future<BookingResult> create({
    required String customerName,
    String? customerPhone,
    required int partySize,
    required DateTime reservedAt,
    required List<String> tableIds,
    String? notes,
  }) async {
    final json = await _api.post('/reservations', {
      'customerName': customerName,
      if (customerPhone != null && customerPhone.isNotEmpty)
        'customerPhone': customerPhone,
      'partySize': partySize,
      'reservedAt': reservedAt.toUtc().toIso8601String(),
      'tableIds': tableIds,
      if (notes != null && notes.isNotEmpty) 'notes': notes,
    });
    return BookingResult.fromJson(json);
  }

  Future<BookingResult> update(
    String id, {
    String? customerName,
    String? customerPhone,
    int? partySize,
    DateTime? reservedAt,
    List<String>? tableIds,
    String? notes,
  }) async {
    final json = await _api.patch('/reservations/$id', {
      if (customerName != null) 'customerName': customerName,
      if (customerPhone != null) 'customerPhone': customerPhone,
      if (partySize != null) 'partySize': partySize,
      if (reservedAt != null) 'reservedAt': reservedAt.toUtc().toIso8601String(),
      if (tableIds != null) 'tableIds': tableIds,
      if (notes != null) 'notes': notes,
    });
    return BookingResult.fromJson(json);
  }

  /// The party arrived. Opens the order and returns its id, so the till can go
  /// straight to taking what they want.
  ///
  /// [tableId] picks which of the booking's tables they sat at; omitted, the
  /// first is used. One order, however many tables were held — v1 has no table
  /// merge and the party is one bill.
  Future<String> seat(String id, {String? tableId}) async {
    final json = await _api.post('/reservations/$id/seat', {
      if (tableId != null) 'tableId': tableId,
    });
    return json['orderId'] as String;
  }

  Future<void> markNoShow(String id, {String? reason}) async {
    await _api.post('/reservations/$id/no-show', {
      if (reason != null && reason.isNotEmpty) 'reason': reason,
    });
  }

  Future<void> cancel(String id, {String? reason}) async {
    await _api.post('/reservations/$id/cancel', {
      if (reason != null && reason.isNotEmpty) 'reason': reason,
    });
  }

  /// Removes a booking from the day. Admin only, and never one already seated.
  Future<void> remove(String id) async {
    await _api.delete('/reservations/$id');
  }

  /// The `yyyy-MM-dd` business date the backend filters on.
  static String wireDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

final bookingRepositoryProvider = Provider<BookingRepository>((ref) {
  return BookingRepository(ref.watch(apiClientProvider));
});

/// The day being listed. Bookings are a today-first screen, so it starts there.
final bookingDateProvider = StateProvider<DateTime>((ref) {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day);
});

final bookingsProvider = FutureProvider<BookingDay>((ref) {
  return ref.watch(bookingRepositoryProvider).list(date: ref.watch(bookingDateProvider));
});
