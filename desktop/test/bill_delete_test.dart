import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chennai_express_pos/core/api/api_client.dart';
import 'package:chennai_express_pos/core/theme/app_theme.dart';
import 'package:chennai_express_pos/features/auth/data/user.dart';
import 'package:chennai_express_pos/features/auth/presentation/auth_controller.dart';
import 'package:chennai_express_pos/features/billing/data/bill_models.dart';
import 'package:chennai_express_pos/features/billing/data/bill_repository.dart';
import 'package:chennai_express_pos/features/billing/presentation/bill_detail_dialog.dart';

Bill bill({required List<BillPayment> payments, required int outstanding}) => Bill(
  id: 'b1',
  orderId: 'o1',
  billNumber: 'BILL/001',
  businessDate: '2026-09-02',
  createdAt: DateTime(2026, 9, 2, 12),
  subtotal: 16000,
  discountAmount: 0,
  cgst: 0,
  sgst: 0,
  roundOff: 0,
  total: 16000,
  amountPaid: 16000 - outstanding,
  outstanding: outstanding,
  paymentStatus: outstanding == 0
      ? PaymentStatus.paid
      : outstanding == 16000
      ? PaymentStatus.unpaid
      : PaymentStatus.partial,
  taxBreakdown: const [],
  payments: payments,
);

BillPayment payment({required bool reversed}) => BillPayment(
  id: 'p1',
  mode: PaymentMode.cash,
  amount: 16000,
  isReversed: reversed,
);

User user(UserRole role) => User(
  id: 'u1',
  username: role == UserRole.admin ? 'admin' : 'cash',
  fullName: 'Test',
  role: role,
  isActive: true,
  mustChangePassword: false,
);

/// A repository that never reaches the network: the dialog is being inspected,
/// not driven.
class _StubRepository extends BillRepository {
  _StubRepository(this.stub) : super(ApiClient(baseUrl: 'http://localhost:0'));

  final Bill stub;

  @override
  Future<Bill> fetch(String id) async => stub;
}

Future<void> pump(
  WidgetTester tester, {
  required Bill withBill,
  required UserRole role,
}) async {
  tester.view.physicalSize = const Size(1200, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        billRepositoryProvider.overrideWithValue(_StubRepository(withBill)),
        authControllerProvider.overrideWith(
          (ref) => _StubAuth(
            AuthState(status: AuthStatus.authenticated, user: user(role)),
          ),
        ),
      ],
      child: MaterialApp(
        theme: AppTheme.light,
        home: const Scaffold(body: BillDetailDialog(billId: 'b1')),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Holds a fixed signed-in user.
///
/// Not the real AuthController: that restores a session in its constructor,
/// which would reach the network. The dialog only reads `state.user`.
class _StubAuth extends StateNotifier<AuthState> implements AuthController {
  _StubAuth(super.initial);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not needed here');
}

/// Opens the "other changes" menu, where Delete lives.
///
/// It is not a button on the action row: four full-width buttons do not fit a
/// 520px dialog, and deleting a bill does not belong one stray click from
/// settling one.
Future<void> openActions(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Other changes'));
  await tester.pumpAndSettle();
}

void main() {
  group('deleting a bill', () {
    testWidgets('an admin sees Delete on a bill with no live payments', (
      tester,
    ) async {
      await pump(
        tester,
        withBill: bill(payments: const [], outstanding: 16000),
        role: UserRole.admin,
      );
      await openActions(tester);
      expect(find.text('Delete this bill…'), findsOneWidget);
    });

    testWidgets('a cashier never sees it', (tester) async {
      // Deleting erases a sale from the day's takings, so it is the owner's
      // call. The backend refuses it too; this just avoids offering a button
      // that can only fail.
      await pump(
        tester,
        withBill: bill(payments: const [], outstanding: 16000),
        role: UserRole.cashier,
      );
      expect(find.byTooltip('Other changes'), findsNothing, reason: 'no admin menu at all');
    });

    testWidgets('it is offered on a paid bill too', (tester) async {
      // It used to be hidden here, because the backend refuses a bare delete
      // while money stands. A sale rung up in error still has to be undone
      // after the customer has paid, so the button now asks to reverse the
      // payments in the same act rather than disappearing.
      await pump(
        tester,
        withBill: bill(payments: [payment(reversed: false)], outstanding: 0),
        role: UserRole.admin,
      );
      await openActions(tester);
      expect(find.text('Delete this bill…'), findsOneWidget);
    });

    testWidgets('deleting a paid bill names the money being reversed', (
      tester,
    ) async {
      // Taking ₹160 back out of the day's takings is the part someone has to
      // have read before agreeing. A generic "are you sure" would not say it.
      await pump(
        tester,
        withBill: bill(payments: [payment(reversed: false)], outstanding: 0),
        role: UserRole.admin,
      );

      await openActions(tester);
      await tester.tap(find.text('Delete this bill…'));
      await tester.pumpAndSettle();

      // Scoped to the question being asked: the amount also appears on the
      // bill behind it, which says nothing about what the button will do.
      expect(
        find.textContaining('reverses the ₹160.00'),
        findsOneWidget,
        reason: 'the confirmation names what comes back out of the drawer',
      );
      expect(find.text('Reverse and delete'), findsOneWidget);
    });

    testWidgets('an unpaid bill is not warned about money', (tester) async {
      // Nothing was taken, so mentioning a reversal would be describing an
      // event that is not going to happen.
      await pump(
        tester,
        withBill: bill(payments: const [], outstanding: 16000),
        role: UserRole.admin,
      );

      await openActions(tester);
      await tester.tap(find.text('Delete this bill…'));
      await tester.pumpAndSettle();

      expect(find.text('Delete it'), findsOneWidget);
      expect(find.textContaining('reverses'), findsNothing);
    });

    testWidgets('a reversed payment is not counted as money to reverse', (
      tester,
    ) async {
      // It is already undone. Naming it again would overstate what is coming
      // back out of the drawer.
      await pump(
        tester,
        withBill: bill(payments: [payment(reversed: true)], outstanding: 16000),
        role: UserRole.admin,
      );

      await openActions(tester);
      await tester.tap(find.text('Delete this bill…'));
      await tester.pumpAndSettle();

      expect(find.text('Delete it'), findsOneWidget);
    });

    testWidgets('it returns once the payment is reversed', (tester) async {
      await pump(
        tester,
        withBill: bill(payments: [payment(reversed: true)], outstanding: 16000),
        role: UserRole.admin,
      );
      await openActions(tester);
      expect(find.text('Delete this bill…'), findsOneWidget);
    });
  });

  group('reversed payments', () {
    testWidgets('stay listed, marked, rather than disappearing', (
      tester,
    ) async {
      // They are the audit trail. Hiding them makes a corrected bill look like
      // it was always right.
      await pump(
        tester,
        withBill: bill(payments: [payment(reversed: true)], outstanding: 16000),
        role: UserRole.admin,
      );
      expect(find.text('Cash (reversed)'), findsOneWidget);
    });

    testWidgets('offer no second reversal', (tester) async {
      await pump(
        tester,
        withBill: bill(payments: [payment(reversed: true)], outstanding: 16000),
        role: UserRole.admin,
      );
      expect(find.byTooltip('Reverse this payment'), findsNothing);
    });

    testWidgets('a live payment can be reversed', (tester) async {
      await pump(
        tester,
        withBill: bill(payments: [payment(reversed: false)], outstanding: 0),
        role: UserRole.admin,
      );
      expect(find.byTooltip('Reverse this payment'), findsOneWidget);
    });
  });

  group('the action row fits', () {
    /// Every label rendered on one line.
    ///
    /// An overflow throws and is caught elsewhere, but a button squeezed
    /// below the width of its own text does not — it silently wraps, which is
    /// how "Print" came to read "Prin / t" on an unpaid bill.
    void expectNoWrapping(WidgetTester tester, List<String> labels) {
      for (final label in labels) {
        // Measured by height, not width: a label given less room than its text
        // needs wraps to a second line and grows taller. `getMaxIntrinsicHeight`
        // with unbounded width is that same text on one line, so anything above
        // it means it wrapped — and it needs no guess at the resolved style.
        final box = tester.renderObject<RenderBox>(find.text(label));

        expect(
          box.size.height,
          lessThanOrEqualTo(box.getMaxIntrinsicHeight(double.infinity) + 0.5),
          reason: '"$label" is taller than one line, so it wrapped',
        );
      }
    }

    testWidgets('an unpaid bill with a wide total does not squeeze Print', (
      tester,
    ) async {
      // The case that broke: "Take payment ₹1239.00" took the width, leaving
      // Print less room than the word needs. Every admin control is on screen
      // here, which is the tightest the row ever gets.
      await pump(
        tester,
        withBill: bill(payments: const [], outstanding: 16000),
        role: UserRole.admin,
      );

      expect(tester.takeException(), isNull);
      expectNoWrapping(tester, ['Print', 'Edit']);
    });

    testWidgets('a paid bill keeps its buttons whole', (tester) async {
      // No settle button, so there is room to spare — but the row must not
      // have come to depend on that.
      await pump(
        tester,
        withBill: bill(payments: [payment(reversed: false)], outstanding: 0),
        role: UserRole.admin,
      );

      expect(tester.takeException(), isNull);
      expectNoWrapping(tester, ['Print', 'Edit']);
    });

    testWidgets('a cashier sees a shorter row, still whole', (tester) async {
      await pump(
        tester,
        withBill: bill(payments: const [], outstanding: 16000),
        role: UserRole.cashier,
      );

      expect(tester.takeException(), isNull);
      expectNoWrapping(tester, ['Print']);
    });
  });
}
