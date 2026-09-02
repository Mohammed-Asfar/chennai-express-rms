import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chennai_express_pos/core/theme/app_theme.dart';
import 'package:chennai_express_pos/core/widgets/app_sidebar.dart';

void main() {
  testWidgets('the sidebar shows the restaurant logo', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: AppSidebar(
            items: const [SidebarItem(icon: Icons.grid_view_rounded, label: 'Floor')],
            selectedIndex: 0,
            onSelect: (_) {},
          ),
        ),
      ),
    );

    final logo = tester.widget<Image>(
      find.byWidgetPredicate(
        (w) => w is Image && w.image is AssetImage,
      ),
    );
    expect((logo.image as AssetImage).assetName, 'assets/logo.png');
  });

  testWidgets('the name is text, not only artwork', (tester) async {
    // The logo carries the name as pixels. A screen reader gets nothing from
    // that, and neither does anyone who cannot make out the lettering at 36px.
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: AppSidebar(
            items: const [SidebarItem(icon: Icons.grid_view_rounded, label: 'Floor')],
            selectedIndex: 0,
            onSelect: (_) {},
          ),
        ),
      ),
    );

    expect(find.text('Chennai Express'), findsOneWidget);
    expect(find.text('Restaurant management system'), findsOneWidget);
  });
}
