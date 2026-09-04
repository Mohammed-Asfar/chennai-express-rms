import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chennai_express_pos/core/theme/app_theme.dart';
import 'package:chennai_express_pos/features/menu/data/menu_models.dart';
import 'package:chennai_express_pos/features/menu/data/menu_repository.dart';
import 'package:chennai_express_pos/features/order/presentation/menu_panel.dart';

/// The real card's categories, including the longest name on it.
const _categories = [
  MenuCategory(id: 'c1', name: 'Soup - Veg', itemCount: 8),
  MenuCategory(id: 'c2', name: 'Fried Rice & Noodles - Non Veg', itemCount: 20),
  MenuCategory(id: 'c3', name: 'Rice', itemCount: 8),
];

final _items = [
  const MenuItem(
    id: 'i1',
    categoryId: 'c1',
    name: 'Veg Clear Soup',
    isAvailable: true,
    variants: [MenuVariant(id: 'v1', name: 'Regular', price: 5500, isAvailable: true)],
  ),
  const MenuItem(
    id: 'i2',
    categoryId: 'c3',
    name: 'Steam Rice',
    isAvailable: true,
    variants: [MenuVariant(id: 'v2', name: 'Regular', price: 6000, isAvailable: true)],
  ),
];

Widget _harness({Size size = const Size(1280, 800)}) {
  return ProviderScope(
    overrides: [
      categoriesProvider.overrideWith((ref) async => _categories),
      menuItemsProvider.overrideWith((ref) async => _items),
    ],
    child: MaterialApp(
      theme: AppTheme.light,
      home: Scaffold(
        body: SizedBox(
          width: size.width,
          height: size.height,
          child: MenuPanel(onPick: (_) {}, enabled: true),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('every category name is readable in full', (tester) async {
    // The reason the rail replaced a horizontal strip: sixteen categories never
    // fitted on one line, and the ones past the edge could not be read at all.
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    for (final category in _categories) {
      expect(find.text(category.name), findsOneWidget, reason: category.name);
    }
    expect(find.text('All'), findsOneWidget);
  });

  testWidgets('the longest name is not clipped', (tester) async {
    // "Fried Rice & Noodles - Non Veg" is the widest on the printed card. If it
    // overflows, staff read a truncated category and pick the wrong one.
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);

    final text = tester.widget<Text>(find.text('Fried Rice & Noodles - Non Veg'));
    expect(text.overflow, isNot(TextOverflow.ellipsis));
  });

  testWidgets('picking a category filters the grid', (tester) async {
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    expect(find.text('Veg Clear Soup'), findsOneWidget);
    expect(find.text('Steam Rice'), findsOneWidget);

    await tester.tap(find.text('Rice'));
    await tester.pumpAndSettle();

    expect(find.text('Steam Rice'), findsOneWidget);
    expect(find.text('Veg Clear Soup'), findsNothing, reason: 'filtered out');
  });

  testWidgets('All brings every item back', (tester) async {
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Rice'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('All'));
    await tester.pumpAndSettle();

    expect(find.text('Veg Clear Soup'), findsOneWidget);
    expect(find.text('Steam Rice'), findsOneWidget);
  });

  testWidgets('the rail sits to the right of the items', (tester) async {
    // A filter belongs beside the results, not in front of them: the grid is
    // what the eye works through.
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    final rail = tester.getTopLeft(find.text('Soup - Veg')).dx;
    final grid = tester.getTopLeft(find.text('Veg Clear Soup')).dx;

    expect(rail, greaterThan(grid));
  });

  testWidgets('a category row is big enough to hit at speed', (tester) async {
    // Staff tap without looking directly at the target.
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    final row = find.ancestor(
      of: find.text('Rice'),
      matching: find.byType(Container),
    );
    expect(tester.getSize(row.first).height, greaterThanOrEqualTo(48));
  });
}
