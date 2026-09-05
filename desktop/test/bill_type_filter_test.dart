import 'package:flutter_test/flutter_test.dart';
import 'package:chennai_express_pos/features/billing/data/bill_models.dart';
import 'package:chennai_express_pos/features/billing/presentation/bills_screen.dart';

Bill bill({
  required String id,
  String? type,
  int total = 10000,
  List<Map<String, dynamic>> payments = const [],
  int outstanding = 0,
}) => Bill.fromJson({
  'id': id,
  'orderId': 'o$id',
  'billNumber': id,
  'subtotal': total,
  'total': total,
  'outstanding': outstanding,
  'amountPaid': total - outstanding,
  'orderType': type,
  'payments': payments,
});

Map<String, dynamic> paid(int amount, {bool reversed = false}) => {
  'id': 'p$amount${reversed ? 'r' : ''}',
  'mode': 'cash',
  'amount': amount,
  if (reversed) 'reversedAt': '2026-09-05T10:00:00.000Z',
};

void main() {
  group('the type a bill is filtered by', () {
    test('matches what orders.type holds', () {
      // These strings are the wire values the backend stores and the row
      // already switches on. A typo here silently filters to nothing.
      expect(BillType.dineIn.wire, 'dine_in');
      expect(BillType.takeaway.wire, 'takeaway');
      expect(BillType.delivery.wire, 'delivery');
    });

    test('every kind reads as a person would say it', () {
      for (final type in BillType.values) {
        expect(type.label, isNot(contains('_')), reason: type.wire);
      }
    });

    test('each kind has its own mark', () {
      // The icon is what someone scans the list by, so two kinds sharing one
      // would undo the point of telling delivery and takeaway apart.
      final icons = BillType.values.map((t) => iconFor(t.wire)).toSet();
      expect(icons.length, BillType.values.length);
    });
  });

  group('the totals for one kind of order', () {
    test('count only the bills of that kind', () {
      // The whole reason this exists: the backend's summary covers the range,
      // so a filtered list showing it would report the day's takings under a
      // heading that says Delivery.
      final bills = [
        bill(id: '1', type: 'delivery', total: 50000, payments: [paid(50000)]),
        bill(id: '2', type: 'takeaway', total: 30000, payments: [paid(30000)]),
        bill(id: '3', type: 'delivery', total: 20000, payments: [paid(20000)]),
      ];

      final deliveries = bills.where((b) => b.orderType == 'delivery');
      final summary = BillSummary.of(deliveries);

      expect(summary.count, 2);
      expect(summary.total, 70000);
      expect(summary.collected, 70000);
    });

    test('a reversed payment was never in the drawer', () {
      // It stays on the record for audit. Counting it would overstate what was
      // collected by exactly the amount that was handed back.
      final one = bill(
        id: '1',
        type: 'delivery',
        total: 50000,
        payments: [paid(50000), paid(20000, reversed: true)],
      );

      expect(BillSummary.of([one]).collected, 50000);
    });

    test('an overpaid bill does not cancel out an unpaid one', () {
      // Netting these would report a day as settled while ₹500 is still owed.
      final bills = [
        bill(id: '1', type: 'delivery', total: 50000, outstanding: 50000),
        bill(id: '2', type: 'delivery', total: 20000, outstanding: -50000),
      ];

      expect(BillSummary.of(bills).outstanding, 50000);
    });

    test('no bills of a kind totals zero, not the day', () {
      expect(BillSummary.of(const []).count, 0);
      expect(BillSummary.of(const []).total, 0);
    });

    test('a bill whose order was purged belongs to no kind', () {
      // orderType is null once the order is gone. It must not fall into
      // dine-in, which is what a null-as-default switch would do.
      final orphan = bill(id: '1', total: 50000);

      for (final type in BillType.values) {
        final matched = [orphan].where((b) => b.orderType == type.wire);
        expect(matched, isEmpty, reason: type.wire);
      }
    });

    test('summing stays in integer paise', () {
      // Three bills at ₹333.33. A float would land on 99998.999... and format
      // a rupee short.
      final bills = [
        for (var i = 0; i < 3; i++)
          bill(id: '$i', type: 'takeaway', total: 33333, payments: [paid(33333)]),
      ];

      final summary = BillSummary.of(bills);
      expect(summary.total, 99999);
      expect(summary.collected, 99999);
    });
  });
}
