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

SyncStatus healthy({DateTime? lastSuccessAt, DateTime? lastAttemptAt}) =>
    SyncStatus(
      enabled: true,
      running: false,
      healthy: true,
      pending: 0,
      quarantined: 0,
      lastSuccessAt: lastSuccessAt ?? DateTime.now(),
      lastAttemptAt: lastAttemptAt,
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

  group('the last-backed-up time', () {
    final at = DateTime(2026, 9, 2, 12, 0);
    String when(Duration ago) =>
        SyncScreen.relativeTime(at, now: at.add(ago));

    test('a single minute is not pluralised', () {
      // "1 minutes ago" is the kind of thing nobody notices until a client does.
      expect(when(const Duration(minutes: 1)), '1 minute ago');
      expect(when(const Duration(minutes: 2)), '2 minutes ago');
    });

    test('under a minute reads as just now', () {
      expect(when(const Duration(seconds: 5)), 'Just now');
      expect(when(const Duration(seconds: 59)), 'Just now');
    });

    test('hours and days are pluralised correctly too', () {
      expect(when(const Duration(hours: 1)), '1 hour ago');
      expect(when(const Duration(hours: 5)), '5 hours ago');
      expect(when(const Duration(days: 1)), '1 day ago');
      expect(when(const Duration(days: 3)), '3 days ago');
    });

    test('a timestamp in the future does not read as negative', () {
      // A server clock slightly ahead would otherwise give "-1 minutes ago".
      expect(when(const Duration(minutes: -5)), 'Just now');
    });

    test('the time moves on as the clock does', () {
      // The bug this guards: the screen rendered once and froze, so a backup
      // taken a minute before opening it still said "1 minute ago" an hour on.
      expect(when(const Duration(minutes: 1)), '1 minute ago');
      expect(when(const Duration(minutes: 90)), '1 hour ago');
    });
  });

  group('last checked', () {
    Future<void> pumpStatus(WidgetTester tester, SyncStatus value) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            syncStatusProvider.overrideWith((_) async => value),
            cloudStorageProvider.overrideWith((_) async => null),
          ],
          child: MaterialApp(theme: AppTheme.light, home: const SyncScreen()),
        ),
      );
      await tester.pumpAndSettle();
      addTearDown(() async => tester.pumpWidget(const SizedBox()));
    }

    testWidgets('is shown beside when it was last backed up', (tester) async {
      final now = DateTime.now();
      await pumpStatus(
        tester,
        healthy(
          lastSuccessAt: now.subtract(const Duration(hours: 3)),
          lastAttemptAt: now.subtract(const Duration(minutes: 2)),
        ),
      );

      // The reassuring pair: nothing has needed sending for three hours, but
      // the system looked two minutes ago. Without the second line the first
      // reads as neglect.
      expect(find.text('Last backed up'), findsOneWidget);
      expect(find.text('3 hours ago'), findsOneWidget);
      expect(find.text('Last checked'), findsOneWidget);
      expect(find.text('2 minutes ago'), findsOneWidget);
    });

    testWidgets('is hidden before the first cycle has run', (tester) async {
      // Nothing has been attempted yet, so "Last checked: Never" would be
      // noise on a screen that already says the backup is fine.
      await pumpStatus(tester, healthy(lastAttemptAt: null));

      expect(find.text('Last checked'), findsNothing);
    });

    test('it parses from the wire in local time', () {
      final utc = DateTime.utc(2026, 9, 2, 8);
      final parsed = SyncStatus.fromJson({
        'enabled': true,
        'healthy': true,
        'lastAttemptAt': utc.toIso8601String(),
      });

      expect(parsed.lastAttemptAt, utc.toLocal());
      expect(parsed.lastAttemptAt!.isUtc, isFalse);
    });

    test('a missing attempt time is null, not the epoch', () {
      // DateTime.tryParse('') returning null is what keeps the row hidden.
      expect(SyncStatus.fromJson(const {}).lastAttemptAt, isNull);
    });
  });

  group('the screen keeps itself current', () {
    testWidgets('it refetches the status while left open', (tester) async {
      var fetches = 0;

      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            syncStatusProvider.overrideWith((_) async {
              fetches++;
              return healthy();
            }),
            cloudStorageProvider.overrideWith((_) async => null),
          ],
          child: MaterialApp(theme: AppTheme.light, home: const SyncScreen()),
        ),
      );
      await tester.pumpAndSettle();
      final first = fetches;

      // Past the 30s tick. pump rather than pumpAndSettle: a periodic timer
      // never settles, and pumpAndSettle would time out waiting for it.
      await tester.pump(const Duration(seconds: 31));
      await tester.pump();

      expect(
        fetches,
        greaterThan(first),
        reason: 'the screen asked again rather than freezing on first paint',
      );

      // Let the timer be cancelled cleanly by the teardown.
      await tester.pumpWidget(const SizedBox());
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
