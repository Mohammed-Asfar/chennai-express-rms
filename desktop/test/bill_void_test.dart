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

void main() {
  group('voiding a bill', () {
    testWidgets('an admin sees Void on a bill with no live payments', (
      tester,
    ) async {
      await pump(
        tester,
        withBill: bill(payments: const [], outstanding: 16000),
        role: UserRole.admin,
      );
      expect(find.text('Void'), findsOneWidget);
    });

    testWidgets('a cashier never sees it', (tester) async {
      // Voiding erases a sale from the day's takings, so it is the owner's
      // call. The backend refuses it too; this just avoids offering a button
      // that can only fail.
      await pump(
        tester,
        withBill: bill(payments: const [], outstanding: 16000),
        role: UserRole.cashier,
      );
      expect(find.text('Void'), findsNothing);
    });

    testWidgets('it is hidden while a payment still stands', (tester) async {
      // The backend refuses this with BILL_HAS_PAYMENTS: money must not sit
      // recorded against a sale that no longer exists.
      await pump(
        tester,
        withBill: bill(payments: [payment(reversed: false)], outstanding: 0),
        role: UserRole.admin,
      );
      expect(find.text('Void'), findsNothing);
    });

    testWidgets('it returns once the payment is reversed', (tester) async {
      await pump(
        tester,
        withBill: bill(payments: [payment(reversed: true)], outstanding: 16000),
        role: UserRole.admin,
      );
      expect(find.text('Void'), findsOneWidget);
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
}
