import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chennai_express_pos/core/theme/app_theme.dart';
import 'package:chennai_express_pos/features/billing/data/bill_models.dart';
import 'package:chennai_express_pos/features/billing/presentation/bills_screen.dart';

Bill bill(String number, {String? orderType}) => Bill(
  id: number,
  orderId: 'o-$number',
  billNumber: number,
  businessDate: '2026-09-02',
  createdAt: DateTime(2026, 9, 2, 13),
  subtotal: 9900,
  discountAmount: 0,
  cgst: 0,
  sgst: 0,
  roundOff: 0,
  total: 9900,
  amountPaid: 9900,
  outstanding: 0,
  paymentStatus: PaymentStatus.paid,
  taxBreakdown: const [],
  payments: const [],
  orderNo: 7,
  orderType: orderType,
);

BillList listOf(List<Bill> bills) => BillList(
  bills: bills,
  summary: BillSummary(
    count: bills.length,
    total: bills.fold(0, (sum, b) => sum + b.total),
    collected: bills.fold(0, (sum, b) => sum + b.amountPaid),
    outstanding: 0,
  ),
);

Future<void> pumpBills(WidgetTester tester, List<Bill> bills) async {
  // Wider than the default 800px surface: the bills screen is built for a
  // billing counter and its range bar overflows a narrow one.
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [billListProvider.overrideWith((_) async => listOf(bills))],
      child: MaterialApp(
        theme: AppTheme.light,
        home: const Scaffold(body: BillsScreen()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a takeaway bill is marked with the bag', (tester) async {
    await pumpBills(tester, [bill('BILL/001', orderType: 'takeaway')]);

    expect(find.byIcon(Icons.shopping_bag_outlined), findsOneWidget);
    expect(find.byIcon(Icons.restaurant), findsNothing);
  });

  testWidgets('a dine-in bill is marked differently', (tester) async {
    await pumpBills(tester, [bill('BILL/001', orderType: 'dine_in')]);

    expect(find.byIcon(Icons.restaurant), findsOneWidget);
    expect(find.byIcon(Icons.shopping_bag_outlined), findsNothing);
  });

  testWidgets('the two are distinguishable in one list', (tester) async {
    // The whole point of the mark: scanning a day's bills for which were
    // takeaway without reading every line.
    await pumpBills(tester, [
      bill('BILL/001', orderType: 'takeaway'),
      bill('BILL/002', orderType: 'dine_in'),
    ]);

    expect(find.byIcon(Icons.shopping_bag_outlined), findsOneWidget);
    expect(find.byIcon(Icons.restaurant), findsOneWidget);
  });

  testWidgets('a bill whose order was purged still draws a mark', (
    tester,
  ) async {
    // orderType is null when the order is gone. The row must still render
    // rather than leaving a ragged gap where every other row has an icon.
    await pumpBills(tester, [bill('BILL/001')]);

    expect(find.byIcon(Icons.restaurant), findsOneWidget);
    expect(find.text('BILL/001'), findsOneWidget);
  });

  testWidgets('the mark says in words what it means', (tester) async {
    // An icon alone is a guess until someone is told once.
    await pumpBills(tester, [bill('BILL/001', orderType: 'takeaway')]);

    expect(
      find.ancestor(
        of: find.byIcon(Icons.shopping_bag_outlined),
        matching: find.byType(Tooltip),
      ),
      findsOneWidget,
    );
  });

  test('the bill model reads orderType from the list payload', () {
    // The list route had to be taught to join this in; without it every row
    // parses as null and the icon is meaningless.
    final parsed = Bill.fromJson({
      'id': 'b1',
      'orderId': 'o1',
      'billNumber': 'BILL/001',
      'businessDate': '2026-09-02',
      'subtotal': 9900,
      'total': 9900,
      'paymentStatus': 'paid',
      'orderType': 'takeaway',
    });

    expect(parsed.orderType, 'takeaway');
  });
}
