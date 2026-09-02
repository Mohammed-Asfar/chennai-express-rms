import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chennai_express_pos/core/theme/app_theme.dart';
import 'package:chennai_express_pos/features/menu/data/menu_admin_models.dart';
import 'package:chennai_express_pos/features/menu/data/menu_admin_repository.dart';
import 'package:chennai_express_pos/features/menu/presentation/menu_admin_screen.dart';
import 'package:chennai_express_pos/features/menu/presentation/item_row.dart';

AdminCategory category(String id, String name, int count) => AdminCategory(
  id: id,
  name: name,
  sortOrder: 0,
  isActive: true,
  itemCount: count,
);

AdminMenuItem dish(
  String id,
  String categoryId,
  String name, {
  List<String> portions = const ['Standard'],
}) => AdminMenuItem(
  id: id,
  categoryId: categoryId,
  name: name,
  description: null,
  taxRate: 500,
  isAvailable: true,
  sortOrder: 0,
  variants: [
    for (final (index, portion) in portions.indexed)
      AdminVariant(
        id: '$id-v$index',
        name: portion,
        price: 18000,
        sortOrder: index,
        isAvailable: true,
      ),
  ],
);

final _categories = [
  category('c1', 'Biryani', 2),
  category('c2', 'Drinks', 2),
];

final _dishes = [
  dish('i1', 'c1', 'Chicken Biryani', portions: ['Half', 'Full']),
  dish('i2', 'c1', 'Veg Biryani', portions: ['Half', 'Full']),
  dish('i3', 'c2', 'Masala Chai'),
  dish('i4', 'c2', 'Filter Coffee'),
];

Widget harness({
  List<AdminCategory>? categories,
  List<AdminMenuItem>? items,
}) => ProviderScope(
  overrides: [
    adminCategoriesProvider.overrideWith(
      (ref) async => categories ?? _categories,
    ),
    adminItemsProvider.overrideWith((ref) async => items ?? _dishes),
  ],
  child: MaterialApp(
    theme: AppTheme.light,
    home: const Scaffold(body: MenuAdminScreen()),
  ),
);

/// Types into the menu's search box and settles the rebuild.
Future<void> search(WidgetTester tester, String query) async {
  await tester.enterText(find.byType(TextField).first, query);
  await tester.pumpAndSettle();
}

/// Wider than the default 800px test surface: the menu is two panes built for
/// a counter PC, and its header overflows a narrow one.
void useCounterScreen(WidgetTester tester) {
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('at rest the list shows only the selected category', (
    tester,
  ) async {
    useCounterScreen(tester);
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    expect(find.text('Chicken Biryani'), findsOneWidget);
    expect(find.text('Masala Chai'), findsNothing);
  });

  testWidgets('searching finds a dish filed under another category', (
    tester,
  ) async {
    // The whole point: Biryani is selected, but the dish being hunted for is
    // in Drinks. Scoping search to the category would answer "no dishes
    // match", which reads as a missing dish rather than a filter.
    useCounterScreen(tester);
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    await search(tester, 'chai');
    expect(find.text('Masala Chai'), findsOneWidget);
  });

  testWidgets('a dish found elsewhere is tagged with its category', (
    tester,
  ) async {
    useCounterScreen(tester);
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    await search(tester, 'chai');
    // Otherwise a bare name gives no clue where editing it takes effect.
    expect(find.text('Drinks'), findsWidgets);
  });

  testWidgets('a dish in the selected category is not tagged', (tester) async {
    useCounterScreen(tester);
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    await search(tester, 'chicken');
    expect(find.text('Chicken Biryani'), findsOneWidget);

    // "Biryani" is unavoidably on screen in the category pane, so its absence
    // cannot be asserted directly. Instead: the row carries no category pill,
    // which is what would be added for a dish from elsewhere. Searching for a
    // Drinks dish in the same view does produce one — see the test above.
    expect(
      find.descendant(
        of: find.byType(ItemRow),
        matching: find.text('Biryani'),
      ),
      findsNothing,
    );
  });

  testWidgets('the heading says the search spans the whole menu', (
    tester,
  ) async {
    useCounterScreen(tester);
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    await search(tester, 'biryani');
    expect(find.text('All dishes'), findsOneWidget);
    expect(find.text('2 of 4 match'), findsOneWidget);
  });

  testWidgets('clearing the search returns to the selected category', (
    tester,
  ) async {
    useCounterScreen(tester);
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    await search(tester, 'chai');
    expect(find.text('Masala Chai'), findsOneWidget);

    await search(tester, '');
    expect(find.text('Masala Chai'), findsNothing);
    expect(find.text('Chicken Biryani'), findsOneWidget);
  });

  testWidgets('a portion name is searchable', (tester) async {
    useCounterScreen(tester);
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    await search(tester, 'half');
    expect(find.text('Chicken Biryani'), findsOneWidget);
    expect(find.text('Masala Chai'), findsNothing);
  });

  testWidgets('a query matching nothing says so', (tester) async {
    useCounterScreen(tester);
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    await search(tester, 'pizza');
    expect(find.textContaining('No dishes match'), findsOneWidget);
  });

  testWidgets('an empty category still offers search across the menu', (
    tester,
  ) async {
    // Landing on an empty category is exactly when someone goes looking for a
    // dish they think exists. Hiding the box there strands them.
    useCounterScreen(tester);
    await tester.pumpWidget(
      harness(
        categories: [category('c1', 'Empty', 0), category('c2', 'Drinks', 1)],
        items: [dish('i3', 'c2', 'Masala Chai')],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsWidgets);
    await search(tester, 'chai');
    expect(find.text('Masala Chai'), findsOneWidget);
  });
}
