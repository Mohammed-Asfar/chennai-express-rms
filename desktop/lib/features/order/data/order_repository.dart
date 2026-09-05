import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_client.dart';
import '../../../core/api/providers.dart';
import 'order_models.dart';

class OrderRepository {
  OrderRepository(this._api);

  final ApiClient _api;

  Future<Order> fetch(String orderId) async {
    final json = await _api.get('/orders/$orderId');
    return Order.fromJson(json['order'] as Map<String, dynamic>);
  }

  Future<Order> startDineIn(String tableId, {String? seatLabel}) async {
    final json = await _api.post('/orders', {
      'type': 'dine_in',
      'tableId': tableId,
      if (seatLabel != null && seatLabel.isNotEmpty) 'seatLabel': seatLabel,
    });
    return Order.fromJson(json['order'] as Map<String, dynamic>);
  }

  Future<Order> startTakeaway({String? customerName, String? customerPhone}) async {
    final json = await _api.post('/orders', {
      'type': 'takeaway',
      if (customerName != null && customerName.isNotEmpty) 'customerName': customerName,
      if (customerPhone != null && customerPhone.isNotEmpty) 'customerPhone': customerPhone,
    });
    return Order.fromJson(json['order'] as Map<String, dynamic>);
  }

  Future<Order> addItem(
    String orderId, {
    required String variantId,
    int qty = 1,
    String? notes,
  }) async {
    final json = await _api.post('/orders/$orderId/items', {
      'variantId': variantId,
      'qty': qty,
      if (notes != null && notes.isNotEmpty) 'notes': notes,
    });
    return Order.fromJson(json['order'] as Map<String, dynamic>);
  }

  Future<Order> setQty(String orderId, String lineId, int qty) async {
    final json = await _api.patch('/orders/$orderId/items/$lineId', {'qty': qty});
    return Order.fromJson(json['order'] as Map<String, dynamic>);
  }

  /// Returns the updated order and whether the kitchen already has this line.
  Future<({Order order, bool kotAlreadyPrinted})> removeLine(
    String orderId,
    String lineId,
  ) async {
    final json = await _api.delete('/orders/$orderId/items/$lineId');
    return (
      order: Order.fromJson(json['order'] as Map<String, dynamic>),
      kotAlreadyPrinted: json['kotAlreadyPrinted'] as bool? ?? false,
    );
  }

  /// Sends unsent lines to the kitchen.
  ///
  /// `printed` is whether paper actually came out; a queued job that has not
  /// fired yet is not an error, but the cashier should still be told.
  Future<({bool printed, int itemsSent, String? error})> printKot(String orderId) async {
    final json = await _api.post('/orders/$orderId/kot');
    return (
      printed: json['printed'] as bool? ?? false,
      itemsSent: json['itemsSent'] as int? ?? 0,
      error: json['printError'] as String?,
    );
  }

  /// Returns whether the kitchen needs a cancellation slip.
  ///
  /// [reason] is optional — most cancellations are an order opened on the wrong
  /// table seconds earlier, and there is nothing useful to write. Omitted from
  /// the body when blank rather than sent empty, so the record holds null and
  /// reports do not show a reason that happens to be an empty string.
  Future<bool> cancel(String orderId, String reason) async {
    final json = await _api.post('/orders/$orderId/cancel', {
      if (reason.isNotEmpty) 'reason': reason,
    });
    return json['kotCancellationNeeded'] as bool? ?? false;
  }
}

final orderRepositoryProvider = Provider<OrderRepository>((ref) {
  return OrderRepository(ref.watch(apiClientProvider));
});
