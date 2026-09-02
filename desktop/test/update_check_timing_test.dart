import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chennai_express_pos/core/api/api_client.dart';
import 'package:chennai_express_pos/core/theme/app_theme.dart';
import 'package:chennai_express_pos/features/updates/data/release_info.dart';
import 'package:chennai_express_pos/features/updates/data/update_repository.dart';
import 'package:chennai_express_pos/features/updates/presentation/update_watcher.dart';

/// Counts checks without touching the network.
class _CountingRepository extends UpdateRepository {
  _CountingRepository() : super(ApiClient());

  int checks = 0;

  @override
  Future<UpdateCheckResult?> check() async {
    checks += 1;
    // No update: the dialog is not what this file is about, and showing one
    // would need a Navigator to settle.
    return const UpdateCheckResult(
      currentVersion: '1.0.0',
      currentBuild: 1,
      updateAvailable: false,
      isForced: false,
    );
  }
}

void main() {
  testWidgets('the app checks once when it opens', (tester) async {
    final repository = _CountingRepository();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [updateRepositoryProvider.overrideWithValue(repository)],
        child: const MaterialApp(
          home: UpdateWatcher(child: Scaffold(body: Text('till'))),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(repository.checks, 1);
  });

  testWidgets('it does not check again while the app is left open', (
    tester,
  ) async {
    // A till stays open all day. A check on a timer means an update dialog can
    // appear mid-service for someone who never asked for it — FR-U11 can only
    // defer that, not prevent it.
    final repository = _CountingRepository();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [updateRepositoryProvider.overrideWithValue(repository)],
        child: MaterialApp(
          theme: AppTheme.light,
          home: const UpdateWatcher(child: Scaffold(body: Text('till'))),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(repository.checks, 1);

    // Well past the daily timer that used to live here. pump rather than
    // pumpAndSettle: a periodic timer never settles, so pumpAndSettle would
    // time out instead of failing on the count.
    await tester.pump(const Duration(hours: 25));
    await tester.pump();

    expect(
      repository.checks,
      1,
      reason: 'opening the app is the only automatic check',
    );

    await tester.pumpWidget(const SizedBox());
  });
}
