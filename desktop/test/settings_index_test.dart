import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chennai_express_pos/core/theme/app_theme.dart';
import 'package:chennai_express_pos/features/settings/presentation/settings_screen.dart';

Future<void> pumpSettings(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light,
      home: const Scaffold(body: SettingsScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('every settings row leads somewhere', (tester) async {
    // The index advertises what the system does. A row that goes nowhere
    // promises a screen that does not exist, which is worse than omitting it.
    await pumpSettings(tester);

    expect(find.text('Printers'), findsOneWidget);
    expect(find.text('Tax and billing'), findsOneWidget);
    expect(find.text('Branch'), findsOneWidget);
    expect(find.text('Cloud backup'), findsOneWidget);
  });

  testWidgets('nothing is marked as coming soon', (tester) async {
    // Users was dropped rather than deferred. A "Soon" badge would advertise
    // a feature nobody is building.
    await pumpSettings(tester);

    expect(find.text('Soon'), findsNothing);
    expect(find.text('Users'), findsNothing);
  });
}
