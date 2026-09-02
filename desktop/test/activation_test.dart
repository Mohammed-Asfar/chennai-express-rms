import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:chennai_express_pos/core/theme/app_theme.dart';
import 'package:chennai_express_pos/features/activation/data/activation_repository.dart';
import 'package:chennai_express_pos/features/activation/data/activation_status.dart';
import 'package:chennai_express_pos/features/activation/presentation/activation_screen.dart';
import 'package:chennai_express_pos/features/activation/presentation/license_banner.dart';
import 'package:chennai_express_pos/features/activation/presentation/activation_controller.dart';

void main() {
  group('activation status', () {
    test('an unactivated installation is blocked', () {
      const status = ActivationStatus(allowed: false, activated: false);
      expect(status.allowed, isFalse);
      expect(status.showBanner, isFalse);
    });

    test('a healthy licence shows no banner', () {
      const status = ActivationStatus(allowed: true, activated: true, warn: false);
      expect(status.showBanner, isFalse);
    });

    test('a warning inside the grace period shows the banner', () {
      const status = ActivationStatus(
        allowed: true,
        activated: true,
        warn: true,
        graceDaysRemaining: 2,
        message: 'Billing stops in 2 days.',
      );
      expect(status.showBanner, isTrue);
    });

    test('a blocked licence shows no banner', () {
      // It gets the whole screen instead. A banner over a blocked app would be
      // the second place saying the same thing.
      const status = ActivationStatus(
        allowed: false,
        activated: true,
        warn: true,
        message: 'This licence has been withdrawn.',
      );
      expect(status.showBanner, isFalse);
    });

    test('the backend verdict is read as sent', () {
      final status = ActivationStatus.fromJson(const {
        'allowed': true,
        'activated': true,
        'status': 'active',
        'branchCode': 'BR1',
        'restaurant': 'Chennai Express',
        'graceDaysRemaining': 3,
        'warn': true,
        'message': 'Could not reach the licence server.',
        'lastVerifiedAt': '2026-09-02T12:00:00.000Z',
      });

      expect(status.allowed, isTrue);
      expect(status.branchCode, 'BR1');
      expect(status.restaurant, 'Chennai Express');
      expect(status.graceDaysRemaining, 3);
      expect(status.warn, isTrue);
    });

    test('a response missing every optional field does not throw', () {
      // A backend one version behind must not crash the screen that decides
      // whether the app may run at all.
      final status = ActivationStatus.fromJson(const {'allowed': true});
      expect(status.allowed, isTrue);
      expect(status.activated, isFalse);
      expect(status.message, isNull);
    });

    test('an empty response fails closed', () {
      final status = ActivationStatus.fromJson(const {});
      expect(status.allowed, isFalse, reason: 'absent means blocked, not allowed');
    });
  });

  group('key entry', () {
    testWidgets('typing is grouped and upper-cased as you go', (tester) async {
      await tester.pumpWidget(_wrap(const ActivationScreen()));
      await tester.pump();

      await tester.enterText(find.byType(TextFormField), 'cxv8g8gwaekd9f');
      await tester.pump();

      expect(find.text('CX-V8G8-GWAE-KD9F'), findsOneWidget);
    });

    testWidgets('a key pasted with its dashes is not doubled up', (tester) async {
      await tester.pumpWidget(_wrap(const ActivationScreen()));
      await tester.pump();

      await tester.enterText(find.byType(TextFormField), 'CX-V8G8-GWAE-KD9F');
      await tester.pump();

      expect(find.text('CX-V8G8-GWAE-KD9F'), findsOneWidget);
    });

    testWidgets('the field stops at a full key', (tester) async {
      await tester.pumpWidget(_wrap(const ActivationScreen()));
      await tester.pump();

      await tester.enterText(find.byType(TextFormField), 'CXV8G8GWAEKD9FEXTRA');
      await tester.pump();

      expect(find.text('CX-V8G8-GWAE-KD9F'), findsOneWidget);
    });

    testWidgets('the screen asks for a key and explains the binding', (tester) async {
      await tester.pumpWidget(_wrap(const ActivationScreen()));
      await tester.pump();

      expect(find.text('Activate this PC'), findsOneWidget);
      expect(find.textContaining('linked to this PC'), findsOneWidget);
      expect(find.text('Activate'), findsOneWidget);
    });
  });

  group('licence banner', () {
    testWidgets('nothing is shown for a healthy licence', (tester) async {
      await tester.pumpWidget(
        _wrapWith(
          const LicenseBanner(),
          const ActivationStatus(allowed: true, activated: true),
        ),
      );
      await tester.pump();

      expect(find.byType(SizedBox), findsWidgets);
      expect(find.textContaining('Billing stops'), findsNothing);
      expect(find.text('Retry now'), findsNothing);
    });

    testWidgets('the warning names the days left and offers a retry', (tester) async {
      await tester.pumpWidget(
        _wrapWith(
          const LicenseBanner(),
          const ActivationStatus(
            allowed: true,
            activated: true,
            warn: true,
            graceDaysRemaining: 2,
            message: 'Could not reach the licence server. Billing stops in 2 days.',
          ),
        ),
      );
      await tester.pump();

      expect(find.textContaining('Billing stops in 2 days'), findsOneWidget);
      expect(find.text('Retry now'), findsOneWidget);
    });
  });
}

Widget _wrap(Widget child) => ProviderScope(
      child: MaterialApp(theme: AppTheme.light, home: child),
    );

/// Pins the controller to a known state, so a banner test does not depend on a
/// backend being reachable.
Widget _wrapWith(Widget child, ActivationStatus status) => ProviderScope(
      overrides: [
        activationControllerProvider.overrideWith(
          (ref) => _StubController(status),
        ),
      ],
      child: MaterialApp(theme: AppTheme.light, home: Scaffold(body: child)),
    );

class _StubController extends ActivationController {
  _StubController(ActivationStatus status) : super(_FakeRepository(status)) {
    state = ActivationState(phase: ActivationPhase.allowed, status: status);
  }

  @override
  Future<void> check() async {}
}

/// Answers without a backend. The constructor calls check(), which the stub
/// overrides, so nothing here is reached in practice.
class _FakeRepository implements ActivationRepository {
  _FakeRepository(this._status);

  final ActivationStatus _status;

  @override
  Future<ActivationStatus> status() async => _status;

  @override
  Future<ActivationStatus> claim(String key) async => _status;
}
