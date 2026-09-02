import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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

Widget harness(SyncStatus value) => ProviderScope(
  overrides: [syncStatusProvider.overrideWith((ref) async => value)],
  child: MaterialApp(
    theme: AppTheme.light,
    home: const Scaffold(body: SyncBadge()),
  ),
);

void main() {
  testWidgets('a healthy backup shows nothing at all', (tester) async {
    // A green tick every day trains people to ignore the spot, and then the
    // red one is ignored too.
    await tester.pumpWidget(harness(status()));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.cloud_off_outlined), findsNothing);
    expect(find.textContaining('Backup'), findsNothing);
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
          syncStatusProvider.overrideWith(
            (ref) async => throw Exception('backend down'),
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
