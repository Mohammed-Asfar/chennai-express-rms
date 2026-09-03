import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:chennai_express_pos/core/theme/app_theme.dart';
import 'package:chennai_express_pos/features/settings/presentation/about_screen.dart';

void main() {
  group('about', () {
    testWidgets('the developer and their address are shown', (tester) async {
      await tester.pumpWidget(_wrap(const AppVersion(version: '1.0.1', buildNumber: 2)));
      await tester.pump();

      expect(find.text('Mohammed Asfar'), findsOneWidget);
      expect(find.text('https://mohammed-asfar.devsyndicate.in/'), findsOneWidget);
    });

    testWidgets('the running version is named', (tester) async {
      // The first question support asks about any fault. A screen that shows
      // the developer but not the build would answer the less useful half.
      await tester.pumpWidget(_wrap(const AppVersion(version: '1.0.1', buildNumber: 2)));
      await tester.pump();

      expect(find.textContaining('1.0.1'), findsOneWidget);
      expect(find.textContaining('build 2'), findsOneWidget);
    });

    testWidgets('a backend that cannot be reached does not break the screen', (tester) async {
      // /version is unauthenticated and local, but a backend still starting is
      // the normal case for the first few seconds. The contact details are the
      // point of the screen and must survive it.
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appVersionProvider.overrideWith((ref) => Future<AppVersion>.error('offline')),
          ],
          child: MaterialApp(theme: AppTheme.light, home: const AboutScreen()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Unknown'), findsOneWidget);
      expect(find.text('Mohammed Asfar'), findsOneWidget);
    });
  });
}

Widget _wrap(AppVersion version) => ProviderScope(
      overrides: [
        appVersionProvider.overrideWith((ref) async => version),
      ],
      child: MaterialApp(theme: AppTheme.light, home: const AboutScreen()),
    );
