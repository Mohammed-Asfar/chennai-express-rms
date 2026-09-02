import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chennai_express_pos/core/theme/app_colors.dart';
import 'package:chennai_express_pos/core/theme/app_theme.dart';
import 'package:chennai_express_pos/features/sync/data/sync_repository.dart';
import 'package:chennai_express_pos/features/sync/presentation/sync_badge.dart';

SyncStatus status({
  bool enabled = true,
  bool healthy = true,
  int pending = 0,
  int quarantined = 0,
  String? problem,
  DateTime? lastSuccessAt,
}) => SyncStatus(
  enabled: enabled,
  running: false,
  healthy: healthy,
  pending: pending,
  quarantined: quarantined,
  problem: problem,
  lastSuccessAt: lastSuccessAt ?? (healthy ? DateTime.now() : null),
);

const _mb = 1024 * 1024;

CloudStorage space({int usedBytes = 10 * _mb, int limitBytes = 512 * _mb}) =>
    CloudStorage(
      usedBytes: usedBytes,
      limitBytes: limitBytes,
      bytesPerBill: 3000,
      billsPerDay: 100,
      daysMeasured: 30,
      largest: const [],
    );

Widget harness(SyncStatus value, {CloudStorage? storage}) => ProviderScope(
  overrides: [
    syncStreamProvider.overrideWith((ref) => Stream.value(value)),
    cloudStorageProvider.overrideWith((ref) async => storage),
  ],
  child: MaterialApp(
    theme: AppTheme.light,
    home: const Scaffold(body: SyncBadge()),
  ),
);

void main() {
  testWidgets('a healthy backup says when, and how much room is left', (
    tester,
  ) async {
    // Always present so the sidebar answers "is my data safe" without anyone
    // opening a settings page to ask.
    await tester.pumpWidget(
      harness(
        status(lastSuccessAt: DateTime.now().subtract(const Duration(minutes: 3))),
        storage: space(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Backed up 3 minutes ago'), findsOneWidget);
    expect(find.text('10 MB of 512 MB used'), findsOneWidget);
    // Not an alarm: the healthy state uses the done icon, not the off one.
    expect(find.byIcon(Icons.cloud_done_outlined), findsOneWidget);
    expect(find.byIcon(Icons.cloud_off_outlined), findsNothing);
  });

  testWidgets('a healthy backup still reads sensibly without a size', (
    tester,
  ) async {
    // The size costs a cloud round trip and may not have arrived, or may have
    // failed. The line must not go blank because of it.
    await tester.pumpWidget(harness(status(), storage: null));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.cloud_done_outlined), findsOneWidget);
    expect(find.text('Cloud storage'), findsOneWidget);
  });

  testWidgets('a problem outranks the space figure', (tester) async {
    // Nobody needs to know they have 500 MB free while their sales are not
    // leaving the building.
    await tester.pumpWidget(
      harness(
        status(healthy: false, quarantined: 31, problem: 'refused'),
        storage: space(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('31 records stuck'), findsOneWidget);
    expect(find.textContaining('of 512 MB used'), findsNothing);
  });

  /// The colour of the badge's title line.
  Color titleColour(WidgetTester tester, String text) =>
      tester.widget<Text>(find.text(text)).style!.color!;

  testWidgets('a working backup is green', (tester) async {
    await tester.pumpWidget(
      harness(
        status(lastSuccessAt: DateTime.now().subtract(const Duration(minutes: 3))),
        storage: space(),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      titleColour(tester, 'Backed up 3 minutes ago'),
      AppColors.successOnShell,
    );
  });

  testWidgets('a stopped backup is red', (tester) async {
    // Its own test rather than a second pump: swapping the ProviderScope
    // mid-test leaves the first scope's cached value in place.
    await tester.pumpWidget(
      harness(status(healthy: false, quarantined: 3, problem: 'refused')),
    );
    await tester.pumpAndSettle();

    expect(titleColour(tester, 'Backup stopped'), AppColors.dangerOnShell);
  });

  testWidgets('a backlog is amber, not the same red as records refused', (
    tester,
  ) async {
    // An unreachable cloud fixes itself when the internet returns. Painting it
    // the same red as rows the cloud has refused would cry wolf.
    await tester.pumpWidget(
      harness(
        status(
          healthy: false,
          pending: 12,
          lastSuccessAt: DateTime.now().subtract(const Duration(hours: 2)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(titleColour(tester, 'Backup behind'), AppColors.warningOnShell);
  });

  testWidgets('records the cloud refused are called stopped, not behind', (
    tester,
  ) async {
    // The live case: a schema mismatch quarantined every row. These never
    // leave without someone acting, so they are the alarm.
    await tester.pumpWidget(
      harness(
        status(healthy: false, quarantined: 31, problem: 'refused'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Backup stopped'), findsOneWidget);
    expect(find.text('31 records stuck'), findsOneWidget);
  });

  testWidgets('an unreachable cloud is behind, not stopped', (tester) async {
    // This one fixes itself when the internet returns, so it must not read as
    // the same emergency as rows that have been given up on.
    await tester.pumpWidget(
      harness(
        status(
          healthy: false,
          pending: 12,
          lastSuccessAt: DateTime.now().subtract(const Duration(hours: 2)),
          problem: 'Cannot reach the cloud.',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Backup behind'), findsOneWidget);
    expect(find.text('12 waiting'), findsOneWidget);
  });

  testWidgets('never having synced is an alarm even with nothing quarantined', (
    tester,
  ) async {
    // There is no backup at all yet. Reporting that as merely "behind" would
    // understate it.
    await tester.pumpWidget(
      harness(status(healthy: false, pending: 40, problem: 'Nothing yet.')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Backup stopped'), findsOneWidget);
    expect(find.text('Nothing sent yet'), findsOneWidget);
  });

  testWidgets('sync not set up says so', (tester) async {
    await tester.pumpWidget(
      harness(status(enabled: false, healthy: false, problem: 'Not set up.')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Not set up'), findsOneWidget);
  });

  testWidgets('a status that will not load shows nothing', (tester) async {
    // The backend being unreachable is already reported elsewhere. Two alarms
    // for one fault is noise.
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          syncStreamProvider.overrideWith(
            (ref) => Stream<SyncStatus>.error(Exception('backend down')),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light,
          home: const Scaffold(body: SyncBadge()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.cloud_off_outlined), findsNothing);
  });

  group('parsing the status', () {
    test('never having synced is recognised', () {
      final parsed = SyncStatus.fromJson({
        'enabled': true,
        'healthy': false,
        'pending': 31,
        'quarantined': 31,
        'lastSuccessAt': null,
      });

      expect(parsed.hasNeverSynced, isTrue);
      expect(parsed.quarantined, 31);
      expect(parsed.healthy, isFalse);
    });

    test('a missing healthy flag is treated as unhealthy', () {
      // An older backend that does not send the field must not be read as
      // "everything fine" — the safe default for a backup is doubt.
      expect(SyncStatus.fromJson(const {}).healthy, isFalse);
    });

    test('the last success time is held in local time', () {
      final utc = DateTime.utc(2026, 9, 2, 8);
      final parsed = SyncStatus.fromJson({
        'lastSuccessAt': utc.toIso8601String(),
      });

      expect(parsed.lastSuccessAt, utc.toLocal());
      expect(parsed.hasNeverSynced, isFalse);
    });
  });
}
