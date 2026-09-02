import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chennai_express_pos/core/theme/app_theme.dart';
import 'package:chennai_express_pos/features/sync/data/sync_repository.dart';
import 'package:chennai_express_pos/features/sync/presentation/sync_screen.dart';

const _mb = 1024 * 1024;

CloudStorage storage({
  int usedBytes = 10 * _mb,
  int limitBytes = 512 * _mb,
  int bytesPerBill = 3000,
  double billsPerDay = 100,
  int daysMeasured = 30,
  double? yearsRemaining = 5,
  List<({String table, int bytes})> largest = const [],
}) => CloudStorage(
  usedBytes: usedBytes,
  limitBytes: limitBytes,
  bytesPerBill: bytesPerBill,
  billsPerDay: billsPerDay,
  daysMeasured: daysMeasured,
  yearsRemaining: yearsRemaining,
  largest: largest,
);

SyncStatus healthy() => SyncStatus(
  enabled: true,
  running: false,
  healthy: true,
  pending: 0,
  quarantined: 0,
  lastSuccessAt: DateTime.now(),
);

Future<void> pump(WidgetTester tester, CloudStorage? value) async {
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        syncStatusProvider.overrideWith((_) async => healthy()),
        cloudStorageProvider.overrideWith((_) async => value),
      ],
      child: MaterialApp(theme: AppTheme.light, home: const SyncScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('the storage card', () {
    testWidgets('shows what is used against the limit', (tester) async {
      await pump(tester, storage(usedBytes: 10 * _mb));

      expect(find.text('Cloud space used'), findsOneWidget);
      expect(find.text('10.0 MB of 512.0 MB'), findsOneWidget);
    });

    testWidgets('projects the years left at the current rate', (tester) async {
      await pump(tester, storage(yearsRemaining: 5, billsPerDay: 100));

      expect(
        find.textContaining('room for about 5 more years'),
        findsOneWidget,
      );
      expect(find.textContaining('100 bills a day'), findsOneWidget);
    });

    testWidgets('says months, not a fraction of a year, when it is close', (
      tester,
    ) async {
      // "0.5 years left" is the kind of phrasing that gets misread as fine.
      await pump(tester, storage(usedBytes: 480 * _mb, yearsRemaining: 0.5));

      expect(find.textContaining('about 6 months left'), findsOneWidget);
    });

    testWidgets('does not invent a projection without enough history', (
      tester,
    ) async {
      // Two busy opening days must not be extrapolated into a decade.
      await pump(tester, storage(daysMeasured: 2, yearsRemaining: null));

      expect(find.textContaining('Too few trading days'), findsOneWidget);
      expect(find.textContaining('years'), findsNothing);
    });

    testWidgets('says so plainly when nothing has been billed', (tester) async {
      await pump(
        tester,
        storage(daysMeasured: 0, billsPerDay: 0, yearsRemaining: null),
      );

      expect(find.textContaining('Nothing billed yet'), findsOneWidget);
    });

    testWidgets('does not promise a number it cannot support', (tester) async {
      // A tiny restaurant would otherwise be told "412 years", which reads as
      // a broken calculation rather than reassurance.
      await pump(tester, storage(yearsRemaining: 400, billsPerDay: 5));

      expect(find.textContaining('will not run out'), findsOneWidget);
      expect(find.textContaining('400'), findsNothing);
    });

    testWidgets('names the biggest tables only once space is tight', (
      tester,
    ) async {
      await pump(
        tester,
        storage(
          usedBytes: 400 * _mb,
          yearsRemaining: 0.5,
          largest: [(table: 'branches', bytes: 600 * 1024)],
        ),
      );

      expect(find.textContaining('Largest:'), findsOneWidget);
    });

    testWidgets('stays quiet about table sizes when there is plenty of room', (
      tester,
    ) async {
      // Naming a big table at 2% used invites someone to optimise nothing.
      await pump(
        tester,
        storage(
          usedBytes: 10 * _mb,
          largest: [(table: 'branches', bytes: 600 * 1024)],
        ),
      );

      expect(find.textContaining('Largest:'), findsNothing);
    });

    testWidgets('shows nothing at all when the size cannot be read', (
      tester,
    ) async {
      // Not knowing the size is not a fault worth an error in front of anyone.
      await pump(tester, null);

      expect(find.text('Cloud space used'), findsNothing);
      // The rest of the screen still works.
      expect(find.textContaining('backed up to the cloud'), findsOneWidget);
    });
  });

  group('the storage model', () {
    test('a percentage is derived from the fraction used', () {
      expect(storage(usedBytes: 256 * _mb).percent, 50);
      expect(storage(usedBytes: 10 * _mb).percent, 2);
    });

    test('running out starts at three quarters full', () {
      expect(storage(usedBytes: 383 * _mb).isRunningOut, isFalse);
      expect(storage(usedBytes: 384 * _mb).isRunningOut, isTrue);
    });

    test('a zero limit does not divide by zero', () {
      expect(storage(limitBytes: 0).fraction, 0);
      expect(storage(limitBytes: 0).percent, 0);
    });

    test('a missing projection parses as null rather than zero', () {
      // Zero years would render as "0 months left" — a false alarm.
      final parsed = CloudStorage.fromJson(const {
        'usedBytes': 1000,
        'limitBytes': 2000,
        'yearsRemaining': null,
      });

      expect(parsed.yearsRemaining, isNull);
    });

    test('the largest tables parse into pairs', () {
      final parsed = CloudStorage.fromJson(const {
        'usedBytes': 1000,
        'limitBytes': 2000,
        'largest': [
          {'table': 'branches', 'bytes': 600},
        ],
      });

      expect(parsed.largest.first.table, 'branches');
      expect(parsed.largest.first.bytes, 600);
    });
  });
}
