import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chennai_express_pos/core/api/api_client.dart';
import 'package:chennai_express_pos/core/theme/app_theme.dart';
import 'package:chennai_express_pos/features/billing/data/bill_models.dart';
import 'package:chennai_express_pos/features/billing/data/bill_repository.dart';
import 'package:chennai_express_pos/features/billing/presentation/billing_dialog.dart';
import 'package:chennai_express_pos/features/order/data/order_models.dart';

Order order() => Order.fromJson({
  'id': 'o1',
  'orderNo': 33,
  'type': 'takeaway',
  'status': 'open',
  'version': 1,
  'items': [
    {
      'id': 'l1',
      'variantId': 'v1',
      'itemName': 'Chicken Clear Soup',
      'variantName': 'Regular',
      'unitPrice': 7500,
      'qty': 1,
      'lineTotal': 7500,
      'kotPrinted': false,
    },
  ],
  'subtotal': 7500,
  'tax': 0,
  'total': 7500,
  'itemCount': 1,
});

/// Records what was asked of it, and never reaches the network.
class StubRepository extends BillRepository {
  StubRepository() : super(ApiClient(baseUrl: 'http://localhost:0'));

  int created = 0;

  @override
  Future<BillPreview> preview(
    String orderId, {
    DiscountType discountType = DiscountType.none,
    int discountValue = 0,
  }) async => BillPreview.fromJson(const {
    'subtotal': 7500,
    'discountAmount': 0,
    'cgst': 0,
    'sgst': 0,
    'roundOff': 0,
    'total': 7500,
    'taxBreakdown': [],
  });

  @override
  Future<Bill> create(
    String orderId, {
    DiscountType discountType = DiscountType.none,
    int discountValue = 0,
  }) async {
    created++;
    return Bill.fromJson(const {
      'id': 'b1',
      'orderId': 'o1',
      'billNumber': '0012',
      'subtotal': 7500,
      'total': 7500,
      'amountPaid': 0,
      'outstanding': 7500,
      'paymentStatus': 'unpaid',
    });
  }
}

Future<StubRepository> pump(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final repo = StubRepository();

  await tester.pumpWidget(
    ProviderScope(
      overrides: [billRepositoryProvider.overrideWithValue(repo)],
      child: MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(body: BillingDialog(order: order())),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return repo;
}

void main() {
  group('billing without taking payment', () {
    testWidgets('the dialog offers saving the bill unpaid', (tester) async {
      // A phoned-in takeaway needs the sale recorded and the order closed long
      // before anyone arrives to pay. Before this the only choices were to
      // print it or to take money that had not been handed over.
      await pump(tester);
      expect(find.text('Save unpaid'), findsOneWidget);
    });

    testWidgets('it raises the bill', (tester) async {
      final repo = await pump(tester);

      await tester.tap(find.text('Save unpaid'));
      await tester.pumpAndSettle();

      expect(repo.created, 1, reason: 'the sale is recorded');
    });

    testWidgets('printing unpaid is still offered separately', (tester) async {
      // The table that wants to see what it owes before paying. Both raise the
      // same bill; only the paper differs.
      await pump(tester);
      expect(find.text('Print'), findsOneWidget);
    });

    testWidgets('the settle action is still the prominent one', (tester) async {
      // Most bills are paid on the spot, so the two unpaid routes must not
      // crowd out the ordinary one.
      await pump(tester);
      expect(find.textContaining('Take cash'), findsOneWidget);
    });

    testWidgets('three actions fit without wrapping a label', (tester) async {
      // The row gained a button. A label given less room than its text needs
      // wraps and grows taller, which is how Print once read "Prin / t".
      await pump(tester);
      expect(tester.takeException(), isNull);

      for (final label in ['Save unpaid', 'Print']) {
        final box = tester.renderObject<RenderBox>(find.text(label));
        expect(
          box.size.height,
          lessThanOrEqualTo(box.getMaxIntrinsicHeight(double.infinity) + 0.5),
          reason: '"$label" wrapped',
        );
      }
    });
  });
}
