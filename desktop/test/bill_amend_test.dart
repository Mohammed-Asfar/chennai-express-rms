import 'package:flutter_test/flutter_test.dart';
import 'package:chennai_express_pos/features/billing/data/bill_models.dart';

/// The JSON a bill arrives as, with only the fields a test cares about set.
Map<String, dynamic> billJson({
  int total = 32000,
  int amountPaid = 0,
  int outstanding = 32000,
  bool orderReopened = false,
  int amendmentCount = 0,
}) => {
  'id': 'b1',
  'orderId': 'o1',
  'billNumber': 'CE-0042',
  'businessDate': '2026-09-05',
  'subtotal': total,
  'total': total,
  'amountPaid': amountPaid,
  'outstanding': outstanding,
  'paymentStatus': amountPaid >= total ? 'paid' : amountPaid > 0 ? 'partial' : 'unpaid',
  'orderReopened': orderReopened,
  'amendmentCount': amendmentCount,
};

void main() {
  group('a bill that has been amended', () {
    test('an untouched bill offers no history', () {
      // Most bills are never changed. A history section on all of them would
      // be noise on the ones that have nothing to show.
      final bill = Bill.fromJson(billJson());
      expect(bill.wasAmended, isFalse);
      expect(bill.amendmentCount, 0);
    });

    test('an amended bill says how many times', () {
      final bill = Bill.fromJson(billJson(amendmentCount: 3));
      expect(bill.wasAmended, isTrue);
      expect(bill.amendmentCount, 3);
    });

    test('a backend that does not send the fields is not a crash', () {
      // The list endpoint omits both, and a till may briefly run against an
      // older backend after an update.
      final bill = Bill.fromJson({
        'id': 'b1',
        'orderId': 'o1',
        'billNumber': 'CE-1',
        'subtotal': 100,
        'total': 100,
      });
      expect(bill.orderReopened, isFalse, reason: 'absent means not reopened');
      expect(bill.wasAmended, isFalse);
    });
  });

  group('a reopened order', () {
    test('is carried through so the total can be marked stale', () {
      // While the order is open its lines and this total disagree. The screen
      // has to know, or it shows a settled-looking figure someone will collect
      // against.
      final bill = Bill.fromJson(billJson(orderReopened: true));
      expect(bill.orderReopened, isTrue);
    });
  });

  group('outstanding after an amendment', () {
    test('a bill reduced below what was paid owes change', () {
      // 320 collected, total amended down to 270. The customer is owed 50, and
      // clamping that to zero would lose it silently.
      final bill = Bill.fromJson(
        billJson(total: 27000, amountPaid: 32000, outstanding: -5000),
      );
      expect(bill.outstanding, -5000);
      expect(bill.outstanding.isNegative, isTrue);
    });

    test('a paid bill that grew is owed the difference', () {
      final bill = Bill.fromJson(
        billJson(total: 34000, amountPaid: 32000, outstanding: 2000),
      );
      expect(bill.outstanding, 2000);
      expect(bill.paymentStatus, PaymentStatus.partial);
    });
  });

  group('the customer fields', () {
    test('belong to a delivery', () {
      // The number a rider calls, and the address they are going to. Worth
      // being able to correct without reopening the order.
      final bill = Bill.fromJson({...billJson(), 'orderType': 'delivery'});
      expect(bill.isDelivery, isTrue);
    });

    test('are not shown on a takeaway or a dine-in', () {
      // That customer was standing at the counter. Offering the fields put two
      // blank boxes in front of staff on most bills.
      for (final type in ['takeaway', 'dine_in']) {
        final bill = Bill.fromJson({...billJson(), 'orderType': type});
        expect(bill.isDelivery, isFalse, reason: type);
      }
    });

    test('a bill whose order was purged is not treated as a delivery', () {
      // orderType is null once the order is gone, and null is not delivery.
      final bill = Bill.fromJson(billJson());
      expect(bill.isDelivery, isFalse);
    });
  });

  group('an amendment record', () {
    test('carries the totals either side', () {
      // The reason the record exists: bills holds only the latest figures.
      final a = BillAmendment.fromJson(const {
        'id': 'a1',
        'kind': 'discount',
        'totalBefore': 32000,
        'totalAfter': 30000,
        'wasPrinted': true,
        'wasPaid': false,
        'reason': 'Regular customer',
        'amendedBy': 'admin',
        'createdAt': '2026-09-05T13:22:00.000Z',
      });

      expect(a.totalBefore, 32000);
      expect(a.totalAfter, 30000);
      expect(a.movedMoney, isTrue);
      expect(a.wasPrinted, isTrue, reason: 'a document existed when it changed');
      expect(a.label, 'Discount changed');
    });

    test('a customer edit records no totals', () {
      // Nothing moved, so showing an arrow between two identical figures would
      // imply something did.
      final a = BillAmendment.fromJson(const {
        'id': 'a1',
        'kind': 'customer',
        'wasPrinted': false,
        'wasPaid': false,
      });

      expect(a.movedMoney, isFalse);
      expect(a.totalBefore, isNull);
      expect(a.label, 'Customer details changed');
    });

    test('every kind reads as something a person would say', () {
      for (final kind in ['items', 'discount', 'customer']) {
        final a = BillAmendment.fromJson({
          'id': 'a1',
          'kind': kind,
          'wasPrinted': false,
          'wasPaid': false,
        });
        expect(a.label, isNotEmpty);
        expect(a.label, isNot(contains(kind)), reason: 'not the raw wire value');
      }
    });
  });
}
