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

/// The mark on a row, not the same icon on a filter chip.
///
/// The chips above the list carry these icons too, deliberately — the mark
/// someone taps is the mark they then scan for. So these finders are scoped to
/// the list, or every one of them counts two.
Finder markInList(IconData icon) =>
    find.descendant(of: find.byType(ListView), matching: find.byIcon(icon));

/// The figure printed under a summary heading.
///
/// Read by its label rather than by counting how many times an amount appears
/// on screen: the same total shows up on a row as well, and which one is being
/// asserted should not depend on that.
String statUnder(WidgetTester tester, String label) {
  final column = find.ancestor(
    of: find.text(label.toUpperCase()),
    matching: find.byType(Column),
  );
  return tester
      .widget<Text>(find.descendant(of: column.first, matching: find.byType(Text)).last)
      .data!;
}

String billed(WidgetTester tester) => statUnder(tester, 'Billed');

/// The count, whose own heading turns singular at one.
String billCount(WidgetTester tester) =>
    find.text('BILLS').evaluate().isEmpty
    ? statUnder(tester, 'Bill')
    : statUnder(tester, 'Bills');

void main() {
  testWidgets('a takeaway bill is marked with the bag', (tester) async {
    await pumpBills(tester, [bill('BILL/001', orderType: 'takeaway')]);

    expect(markInList(Icons.shopping_bag_outlined), findsOneWidget);
    expect(markInList(Icons.restaurant), findsNothing);
  });

  testWidgets('a dine-in bill is marked differently', (tester) async {
    await pumpBills(tester, [bill('BILL/001', orderType: 'dine_in')]);

    expect(markInList(Icons.restaurant), findsOneWidget);
    expect(markInList(Icons.shopping_bag_outlined), findsNothing);
  });

  testWidgets('the two are distinguishable in one list', (tester) async {
    // The whole point of the mark: scanning a day's bills for which were
    // takeaway without reading every line.
    await pumpBills(tester, [
      bill('BILL/001', orderType: 'takeaway'),
      bill('BILL/002', orderType: 'dine_in'),
    ]);

    expect(markInList(Icons.shopping_bag_outlined), findsOneWidget);
    expect(markInList(Icons.restaurant), findsOneWidget);
  });

  testWidgets('a bill whose order was purged still draws a mark', (
    tester,
  ) async {
    // orderType is null when the order is gone. The row must still render
    // rather than leaving a ragged gap where every other row has an icon.
    //
    // Its own mark, not the dine-in one: with delivery added there are three
    // real kinds, and borrowing any of their icons would state something about
    // a bill whose order nobody can look up.
    await pumpBills(tester, [bill('BILL/001')]);

    expect(markInList(Icons.help_outline), findsOneWidget);
    expect(
      markInList(Icons.restaurant),
      findsNothing,
      reason: 'not claimed as dine-in',
    );
    expect(find.text('BILL/001'), findsOneWidget);
  });

  testWidgets('delivery and takeaway do not share a mark', (tester) async {
    // Both are counter sales with no table, so in a list of a hundred bills
    // this icon is the only thing telling them apart.
    await pumpBills(tester, [
      bill('BILL/001', orderType: 'takeaway'),
      bill('BILL/002', orderType: 'delivery'),
    ]);

    expect(markInList(Icons.shopping_bag_outlined), findsOneWidget);
    expect(markInList(Icons.delivery_dining_outlined), findsOneWidget);
  });

  testWidgets('a delivery bill says so in words', (tester) async {
    await pumpBills(tester, [bill('BILL/001', orderType: 'delivery')]);

    final tooltip = tester.widget<Tooltip>(
      find.ancestor(
        of: markInList(Icons.delivery_dining_outlined),
        matching: find.byType(Tooltip),
      ),
    );
    expect(tooltip.message, 'Delivery');
  });

  testWidgets('the mark says in words what it means', (tester) async {
    // An icon alone is a guess until someone is told once.
    await pumpBills(tester, [bill('BILL/001', orderType: 'takeaway')]);

    expect(
      find.ancestor(
        of: markInList(Icons.shopping_bag_outlined),
        matching: find.byType(Tooltip),
      ),
      findsOneWidget,
    );
  });

  group('filtering the list by kind', () {
    testWidgets('opens on all of them', (tester) async {
      await pumpBills(tester, [
        bill('BILL/001', orderType: 'takeaway'),
        bill('BILL/002', orderType: 'delivery'),
      ]);

      expect(find.text('BILL/001'), findsOneWidget);
      expect(find.text('BILL/002'), findsOneWidget);
    });

    testWidgets('picking a kind hides the others', (tester) async {
      await pumpBills(tester, [
        bill('BILL/001', orderType: 'takeaway'),
        bill('BILL/002', orderType: 'delivery'),
        bill('BILL/003', orderType: 'dine_in'),
      ]);

      await tester.tap(find.text('Delivery'));
      await tester.pumpAndSettle();

      expect(find.text('BILL/002'), findsOneWidget);
      expect(find.text('BILL/001'), findsNothing);
      expect(find.text('BILL/003'), findsNothing);
    });

    testWidgets('the totals follow the filter', (tester) async {
      // A filtered list under the day's full takings would be read as that kind
      // having taken them. ₹99 each: two bills, one delivery.
      await pumpBills(tester, [
        bill('BILL/001', orderType: 'takeaway'),
        bill('BILL/002', orderType: 'delivery'),
      ]);

      expect(billed(tester), '₹198.00', reason: 'both, to start');
      expect(billCount(tester), '2');

      await tester.tap(find.text('Delivery'));
      await tester.pumpAndSettle();

      expect(billed(tester), '₹99.00', reason: 'the delivery alone');
      expect(billCount(tester), '1');
    });

    testWidgets('tapping the same kind again clears it', (tester) async {
      // Clearing the filter is the button that set it, so nobody has to find a
      // separate way back.
      await pumpBills(tester, [
        bill('BILL/001', orderType: 'takeaway'),
        bill('BILL/002', orderType: 'delivery'),
      ]);

      await tester.tap(find.text('Delivery'));
      await tester.pumpAndSettle();
      expect(find.text('BILL/001'), findsNothing);

      await tester.tap(find.text('Delivery'));
      await tester.pumpAndSettle();
      expect(find.text('BILL/001'), findsOneWidget);
    });

    testWidgets('All orders brings them back', (tester) async {
      await pumpBills(tester, [
        bill('BILL/001', orderType: 'takeaway'),
        bill('BILL/002', orderType: 'delivery'),
      ]);

      await tester.tap(find.text('Delivery'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('All orders'));
      await tester.pumpAndSettle();

      expect(find.text('BILL/001'), findsOneWidget);
      expect(find.text('BILL/002'), findsOneWidget);
    });

    testWidgets('a kind with no bills says so, not that the day was empty', (
      tester,
    ) async {
      // A busy day with no deliveries must not read as lost data.
      await pumpBills(tester, [bill('BILL/001', orderType: 'takeaway')]);

      await tester.tap(find.text('Delivery'));
      await tester.pumpAndSettle();

      expect(find.text('No delivery bills'), findsOneWidget);
      expect(find.text('Nothing billed yet today'), findsNothing);
    });

    testWidgets('the filter row does not overflow a billing counter', (
      tester,
    ) async {
      // Four chips added to a row of five. An overflow here is a yellow bar
      // across the top of the screen a restaurant sees every day.
      await pumpBills(tester, [bill('BILL/001', orderType: 'takeaway')]);
      expect(tester.takeException(), isNull);
    });
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
