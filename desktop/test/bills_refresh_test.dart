import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chennai_express_pos/core/theme/app_theme.dart';
import 'package:chennai_express_pos/features/billing/data/bill_models.dart';
import 'package:chennai_express_pos/features/billing/presentation/bills_screen.dart';

Bill bill(String number, int total) => Bill(
  id: number,
  orderId: 'o-$number',
  billNumber: number,
  businessDate: '2026-09-02',
  createdAt: DateTime(2026, 9, 2, 12),
  subtotal: total,
  discountAmount: 0,
  cgst: 0,
  sgst: 0,
  roundOff: 0,
  total: total,
  amountPaid: total,
  outstanding: 0,
  paymentStatus: PaymentStatus.paid,
  taxBreakdown: const [],
  payments: const [],
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

void main() {
  testWidgets('the bills list refetches when the screen is opened', (
    tester,
  ) async {
    // A takeaway billed on the floor was missing from a list that looked
    // complete, because the provider had cached an earlier fetch. Opening the
    // screen has to ask again.
    // Wider than the default 800px test surface: the range bar is built for a
    // billing counter's screen and overflows a narrow one.
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    var fetches = 0;
    final bills = [bill('BILL/001', 9900)];

    final container = ProviderContainer(
      overrides: [
        billListProvider.overrideWith((_) async {
          fetches++;
          return listOf(bills);
        }),
      ],
    );
    addTearDown(container.dispose);

    Widget app(Widget child) => UncontrolledProviderScope(
      container: container,
      child: MaterialApp(theme: AppTheme.light, home: Scaffold(body: child)),
    );

    await tester.pumpWidget(app(const BillsScreen()));
    await tester.pumpAndSettle();
    expect(find.text('BILL/001'), findsOneWidget);
    final first = fetches;

    // Leave the screen, bill something else, come back — as switching tabs and
    // billing a takeaway would.
    await tester.pumpWidget(app(const SizedBox()));
    await tester.pumpAndSettle();
    bills.add(bill('BILL/002', 35150));

    await tester.pumpWidget(app(const BillsScreen()));
    await tester.pumpAndSettle();

    expect(fetches, greaterThan(first), reason: 'asked the backend again');
    expect(
      find.text('BILL/002'),
      findsOneWidget,
      reason: 'the bill taken while away is listed',
    );
  });
}
