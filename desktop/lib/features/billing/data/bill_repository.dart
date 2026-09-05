import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_client.dart';
import '../../../core/api/providers.dart';
import 'bill_models.dart';

enum DiscountType { none, fixed, percent }

class BillRepository {
  BillRepository(this._api);

  final ApiClient _api;

  /// Totals without persisting, so the till can show a figure before committing.
  Future<BillPreview> preview(
    String orderId, {
    DiscountType discountType = DiscountType.none,
    int discountValue = 0,
  }) async {
    final json = await _api.post('/bills/preview', {
      'orderId': orderId,
      'discountType': discountType.name,
      'discountValue': discountValue,
    });
    return BillPreview.fromJson(json['preview'] as Map<String, dynamic>);
  }

  Future<Bill> create(
    String orderId, {
    DiscountType discountType = DiscountType.none,
    int discountValue = 0,
  }) async {
    final json = await _api.post('/bills', {
      'orderId': orderId,
      'discountType': discountType.name,
      'discountValue': discountValue,
    });
    return Bill.fromJson(json['bill'] as Map<String, dynamic>);
  }

  Future<Bill> fetch(String billId) async {
    final json = await _api.get('/bills/$billId');
    return Bill.fromJson(json['bill'] as Map<String, dynamic>);
  }

  Future<Bill> pay(
    String billId, {
    required PaymentMode mode,
    required int amount,
    String? reference,
  }) async {
    final json = await _api.post('/bills/$billId/payments', {
      'mode': mode.wire,
      'amount': amount,
      if (reference != null && reference.isNotEmpty) 'reference': reference,
    });
    return Bill.fromJson(json['bill'] as Map<String, dynamic>);
  }

  /// Voids a bill raised in error. Admin only.
  ///
  /// Refused while any live payment stands: money must not sit recorded
  /// against a sale that no longer exists. The order reopens so it can be
  /// corrected and billed again, and the bill number stays consumed — a gap in
  /// the sequence looks worse to an auditor than a number marked void.
  Future<void> voidBill(String billId, String reason) async {
    await _api.post('/bills/$billId/void', {'reason': reason});
  }

  /// Changes a bill that already exists, keeping its number. Admin only.
  ///
  /// The bill is overwritten rather than replaced: staff correct a mistake
  /// without handing the customer a second piece of paper with a different
  /// number for the same meal. The previous figures survive only in the
  /// amendment history, which the backend writes on every call.
  ///
  /// [recalculate] re-reads the order's lines, and is what a change to items
  /// needs. A discount or customer edit does not.
  Future<Bill> amend(
    String billId, {
    DiscountType? discountType,
    int? discountValue,
    String? customerName,
    String? customerPhone,
    bool recalculate = false,
    String? reason,
  }) async {
    final json = await _api.patch('/bills/$billId', {
      if (discountType != null) 'discountType': discountType.name,
      if (discountValue != null) 'discountValue': discountValue,
      if (customerName != null) 'customerName': customerName,
      if (customerPhone != null) 'customerPhone': customerPhone,
      if (recalculate) 'recalculate': true,
      if (reason != null && reason.isNotEmpty) 'reason': reason,
    });
    return Bill.fromJson(json['bill'] as Map<String, dynamic>);
  }

  /// Reopens the billed order so its lines can be changed. Admin only.
  ///
  /// Items live on the order, not the bill — the bill's totals are computed
  /// from `order_items` — so editing them means editing the order and then
  /// amending the bill with `recalculate`. The bill number survives; between
  /// the two calls its total is stale, which the till shows rather than hides.
  Future<String> reopenOrder(String billId) async {
    final json = await _api.post('/bills/$billId/reopen');
    return json['orderId'] as String;
  }

  /// What this bill said before each change made to it.
  Future<List<BillAmendment>> amendments(String billId) async {
    final json = await _api.get('/bills/$billId/amendments');
    return ((json['amendments'] as List<dynamic>?) ?? const [])
        .map((a) => BillAmendment.fromJson(a as Map<String, dynamic>))
        .toList();
  }

  Future<Bill> reversePayment(
    String billId,
    String paymentId,
    String reason,
  ) async {
    final json = await _api.post('/bills/$billId/payments/$paymentId/reverse', {
      'reason': reason,
    });
    return Bill.fromJson(json['bill'] as Map<String, dynamic>);
  }

  Future<List<Bill>> recent() async {
    final json = await _api.get('/bills');
    return ((json['bills'] as List<dynamic>?) ?? const [])
        .map((b) => Bill.fromJson(b as Map<String, dynamic>))
        .toList();
  }

  /// Bills for a trading-day range, with the totals for that whole range.
  ///
  /// Dates are `yyyy-MM-dd` business dates, inclusive at both ends. Omitting
  /// both gives today.
  Future<BillList> list({
    String? from,
    String? to,
    bool unpaidOnly = false,
  }) async {
    final query = <String>[
      if (from != null) 'from=$from',
      if (to != null) 'to=$to',
      if (unpaidOnly) 'unpaid=true',
    ];
    final path = query.isEmpty ? '/bills' : '/bills?${query.join('&')}';

    final json = await _api.get(path);
    return BillList(
      bills: ((json['bills'] as List<dynamic>?) ?? const [])
          .map((b) => Bill.fromJson(b as Map<String, dynamic>))
          .toList(),
      summary: BillSummary.fromJson(
        (json['summary'] as Map<String, dynamic>?) ?? const {},
      ),
    );
  }
}

final billRepositoryProvider = Provider<BillRepository>((ref) {
  return BillRepository(ref.watch(apiClientProvider));
});
