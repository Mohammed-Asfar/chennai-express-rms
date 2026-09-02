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

  Future<Bill> reversePayment(String billId, String paymentId, String reason) async {
    final json = await _api.post(
      '/bills/$billId/payments/$paymentId/reverse',
      {'reason': reason},
    );
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
  Future<BillList> list({String? from, String? to, bool unpaidOnly = false}) async {
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
