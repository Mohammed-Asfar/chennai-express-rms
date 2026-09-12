import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chennai_express_pos/core/theme/app_theme.dart';
import 'package:chennai_express_pos/features/menu/data/menu_models.dart';
import 'package:chennai_express_pos/features/menu/data/menu_repository.dart';
import 'package:chennai_express_pos/features/order/presentation/menu_panel.dart';

MenuVariant _variant(String id, String name, {bool available = true}) =>
    MenuVariant(id: id, name: name, price: 14000, isAvailable: available);

MenuItem _dish(
  String id,
  String name, {
  List<MenuVariant>? variants,
  bool available = true,
}) =>
    MenuItem(
      id: id,
      categoryId: 'c1',
      name: name,
      isAvailable: available,
      variants: variants ?? [_variant('$id-v0', 'Standard')],
    );

final _dishes = [
  _dish('i1', 'Chicken Biriyani'),
  _dish('i2', 'Mutton Biriyani'),
  // Two portions, so tapping it opens the picker rather than adding at once.
  _dish(
    'i3',
    'Tandoori Chicken',
    variants: [_variant('i3-v0', 'Half'), _variant('i3-v1', 'Full')],
  ),
];

/// The tile the arrow keys are sitting on, found by its 2px accent border.
String? _highlighted(WidgetTester tester) {
  for (final name in ['Chicken Biriyani', 'Mutton Biriyani', 'Tandoori Chicken']) {
    final container = find.ancestor(
      of: find.text(name),
      matching: find.byType(AnimatedContainer),
    );
    if (container.evaluate().isEmpty) continue;
    final decoration =
        tester.widget<AnimatedContainer>(container.first).decoration as BoxDecoration;
    if (decoration.border is Border &&
        (decoration.border as Border).top.width == 2) {
      return name;
    }
  }
  return null;
}

Future<void> _press(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pumpAndSettle();
}

Widget _harness({required void Function(MenuVariant) onPick}) => ProviderScope(
      overrides: [
        categoriesProvider.overrideWith((ref) async => <MenuCategory>[]),
        menuItemsProvider.overrideWith((ref) async => _dishes),
      ],
      child: MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: MenuPanel(onPick: onPick, enabled: true),
        ),
      ),
    );

/// A menu long enough to scroll, like the real one.
final _longMenu = [
  for (var i = 0; i < 60; i++) _dish('d$i', 'Dish ${i.toString().padLeft(2, '0')}'),
];

Widget _longHarness({required void Function(MenuVariant) onPick}) => ProviderScope(
      overrides: [
        categoriesProvider.overrideWith((ref) async => <MenuCategory>[]),
        menuItemsProvider.overrideWith((ref) async => _longMenu),
      ],
      child: MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(body: MenuPanel(onPick: onPick, enabled: true)),
      ),
    );

/// The name on the tile the arrow keys are sitting on, whatever it is.
String? _highlightedAnywhere(WidgetTester tester) {
  for (final element in find.byType(AnimatedContainer).evaluate()) {
    final widget = element.widget as AnimatedContainer;
    final decoration = widget.decoration;
    if (decoration is! BoxDecoration) continue;
    final border = decoration.border;
    if (border is! Border || border.top.width != 2) continue;
    final text = find.descendant(
      of: find.byWidget(widget),
      matching: find.byType(Text),
    );
    if (text.evaluate().isEmpty) continue;
    return (text.evaluate().first.widget as Text).data;
  }
  return null;
}

/// Whether that tile is actually inside the viewport the cashier is looking at.
bool _highlightOnScreen(WidgetTester tester) {
  final name = _highlightedAnywhere(tester);
  if (name == null) return false;

  final tile = find.ancestor(
    of: find.text(name),
    matching: find.byType(AnimatedContainer),
  ).first;

  final box = tester.renderObject<RenderBox>(tile);
  final topLeft = box.localToGlobal(Offset.zero);
  final screen = tester.view.physicalSize / tester.view.devicePixelRatio;

  // Fully visible, not merely clipped at an edge.
  return topLeft.dy >= 0 && topLeft.dy + box.size.height <= screen.height;
}

/// The search box's live text, read off the widget rather than the model.
String _searchText(WidgetTester tester) {
  final field = tester.widget<TextField>(
    find.widgetWithText(TextField, 'Search the menu').first,
  );
  return field.controller!.text;
}

bool _searchHasFocus(WidgetTester tester) {
  final field = tester.widget<TextField>(
    find.widgetWithText(TextField, 'Search the menu').first,
  );
  return field.focusNode!.hasFocus;
}

Future<void> _search(WidgetTester tester, String query) async {
  await tester.enterText(find.byType(TextField).first, query);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('adding an item clears the search and refocuses it', (tester) async {
    final picked = <MenuVariant>[];
    await tester.pumpWidget(_harness(onPick: picked.add));
    await tester.pumpAndSettle();

    await _search(tester, 'chicken');
    expect(_searchText(tester), 'chicken');
    // Filtered down, so the tap below is unambiguous.
    expect(find.text('Mutton Biriyani'), findsNothing);

    await tester.tap(find.text('Chicken Biriyani'));
    await tester.pumpAndSettle();

    expect(picked, hasLength(1));
    expect(_searchText(tester), isEmpty, reason: 'the box must be empty');
    expect(_searchHasFocus(tester), isTrue,
        reason: 'the next dish is typed without reaching for the mouse');
    // The whole menu is back, not the previous query's slice.
    expect(find.text('Mutton Biriyani'), findsOneWidget);
  });

  testWidgets('choosing a portion also clears and refocuses', (tester) async {
    final picked = <MenuVariant>[];
    await tester.pumpWidget(_harness(onPick: picked.add));
    await tester.pumpAndSettle();

    await _search(tester, 'tandoori');
    await tester.tap(find.text('Tandoori Chicken'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Full'));
    await tester.pumpAndSettle();

    expect(picked, hasLength(1));
    expect(_searchText(tester), isEmpty);
    expect(_searchHasFocus(tester), isTrue);
  });

  testWidgets('cancelling the portion picker leaves the search alone', (tester) async {
    // Nothing was added, so the cashier is still hunting for that dish. Wiping
    // the query here would make them type it again.
    final picked = <MenuVariant>[];
    await tester.pumpWidget(_harness(onPick: picked.add));
    await tester.pumpAndSettle();

    await _search(tester, 'tandoori');
    await tester.tap(find.text('Tandoori Chicken'));
    await tester.pumpAndSettle();

    await tester.tapAt(const Offset(10, 10)); // dismiss the dialog
    await tester.pumpAndSettle();

    expect(picked, isEmpty);
    expect(_searchText(tester), 'tandoori');
  });

  testWidgets('the clear button disappears once the box is emptied', (tester) async {
    // The button's visibility follows the controller, not the last keystroke,
    // because the panel now clears the text from outside the field.
    await tester.pumpWidget(_harness(onPick: (_) {}));
    await tester.pumpAndSettle();

    await _search(tester, 'chicken');
    expect(find.byTooltip('Clear'), findsOneWidget);

    await tester.tap(find.text('Chicken Biriyani'));
    await tester.pumpAndSettle();

    expect(find.byTooltip('Clear'), findsNothing);
  });

  testWidgets('the first dish is highlighted to start with', (tester) async {
    await tester.pumpWidget(_harness(onPick: (_) {}));
    await tester.pumpAndSettle();

    expect(_highlighted(tester), 'Chicken Biriyani');
  });

  testWidgets('arrow keys walk the grid and Enter adds the dish', (tester) async {
    final picked = <MenuVariant>[];
    await tester.pumpWidget(_harness(onPick: picked.add));
    await tester.pumpAndSettle();

    await _press(tester, LogicalKeyboardKey.arrowRight);
    expect(_highlighted(tester), 'Mutton Biriyani');

    await _press(tester, LogicalKeyboardKey.arrowLeft);
    expect(_highlighted(tester), 'Chicken Biriyani');

    await _press(tester, LogicalKeyboardKey.arrowRight);
    await _press(tester, LogicalKeyboardKey.enter);

    expect(picked, hasLength(1));
    expect(picked.single.id, 'i2-v0', reason: 'the highlighted dish, not the first');
  });

  testWidgets('typing then arrowing adds without touching the mouse', (tester) async {
    // The whole point: type a few letters, arrow to the dish, press Enter.
    final picked = <MenuVariant>[];
    await tester.pumpWidget(_harness(onPick: picked.add));
    await tester.pumpAndSettle();

    await _search(tester, 'biriyani');
    // The query narrowed the list, so the highlight restarts at the top.
    expect(_highlighted(tester), 'Chicken Biriyani');

    await _press(tester, LogicalKeyboardKey.arrowRight);
    await _press(tester, LogicalKeyboardKey.enter);

    expect(picked.single.id, 'i2-v0');
    // And it is ready for the next dish.
    expect(_searchText(tester), isEmpty);
    expect(_searchHasFocus(tester), isTrue);
  });

  testWidgets('the highlight stops at the ends rather than wrapping', (tester) async {
    await tester.pumpWidget(_harness(onPick: (_) {}));
    await tester.pumpAndSettle();

    // Already at the first: Left must not jump to the last.
    await _press(tester, LogicalKeyboardKey.arrowLeft);
    expect(_highlighted(tester), 'Chicken Biriyani');

    for (var i = 0; i < 6; i++) {
      await _press(tester, LogicalKeyboardKey.arrowRight);
    }
    expect(_highlighted(tester), 'Tandoori Chicken');
  });

  testWidgets('Enter on a multi-portion dish opens the picker', (tester) async {
    final picked = <MenuVariant>[];
    await tester.pumpWidget(_harness(onPick: picked.add));
    await tester.pumpAndSettle();

    await _search(tester, 'tandoori');
    await _press(tester, LogicalKeyboardKey.enter);

    expect(find.text('Half'), findsOneWidget);
    expect(picked, isEmpty, reason: 'nothing is added until a portion is chosen');

    await tester.tap(find.text('Half'));
    await tester.pumpAndSettle();
    expect(picked.single.id, 'i3-v0');
  });

  testWidgets('letters still reach the search box', (tester) async {
    // The panel only claims the arrows and Enter. Everything else must fall
    // through, or the box could not be typed into at all.
    await tester.pumpWidget(_harness(onPick: (_) {}));
    await tester.pumpAndSettle();

    await _search(tester, 'mutton');
    expect(_searchText(tester), 'mutton');
    expect(find.text('Chicken Biriyani'), findsNothing);
  });

  testWidgets('the search box is focused when the screen opens', (tester) async {
    // Without this the first keystroke of an order goes nowhere, and the arrow
    // keys do nothing until someone clicks the box.
    await tester.pumpWidget(_harness(onPick: (_) {}));
    await tester.pumpAndSettle();

    expect(_searchHasFocus(tester), isTrue);
  });

  testWidgets('arrowing down keeps the highlight on screen', (tester) async {
    // The bug: the highlight scrolled out of sight, so the grid moved but
    // nothing on screen was marked and Enter would add a dish nobody could see.
    await tester.pumpWidget(_longHarness(onPick: (_) {}));
    await tester.pumpAndSettle();

    expect(_highlightOnScreen(tester), isTrue, reason: 'visible before moving');

    for (var press = 1; press <= 12; press++) {
      await _press(tester, LogicalKeyboardKey.arrowDown);
      expect(
        _highlightOnScreen(tester),
        isTrue,
        reason: 'the highlight vanished after $press press(es) of Down',
      );
    }
  });

  testWidgets('arrowing back up keeps the highlight on screen', (tester) async {
    await tester.pumpWidget(_longHarness(onPick: (_) {}));
    await tester.pumpAndSettle();

    for (var i = 0; i < 12; i++) {
      await _press(tester, LogicalKeyboardKey.arrowDown);
    }
    for (var press = 1; press <= 12; press++) {
      await _press(tester, LogicalKeyboardKey.arrowUp);
      expect(
        _highlightOnScreen(tester),
        isTrue,
        reason: 'the highlight vanished after $press press(es) of Up',
      );
    }
  });

  testWidgets('Down lands one full row on, not some other tile', (tester) async {
    // A wrong column count moves by the wrong number of tiles, which is what
    // put the highlight on a row the grid had not scrolled to.
    await tester.pumpWidget(_longHarness(onPick: (_) {}));
    await tester.pumpAndSettle();

    final first = _highlightedAnywhere(tester);
    await _press(tester, LogicalKeyboardKey.arrowRight);
    final second = _highlightedAnywhere(tester);

    // One Right is one tile, so the gap between them is the step per column.
    final firstIndex = int.parse(first!.split(' ').last);
    final perTile = int.parse(second!.split(' ').last) - firstIndex;
    expect(perTile, 1);

    await _press(tester, LogicalKeyboardKey.arrowLeft);
    await _press(tester, LogicalKeyboardKey.arrowDown);
    final afterDown = int.parse(_highlightedAnywhere(tester)!.split(' ').last);

    // Down must be a whole row: the same column, one row lower.
    expect(afterDown, greaterThan(firstIndex));
    expect((afterDown - firstIndex) % 1, 0);
    // And landing back on the same column is what makes it a row move.
    await _press(tester, LogicalKeyboardKey.arrowUp);
    expect(int.parse(_highlightedAnywhere(tester)!.split(' ').last), firstIndex);
  });
}
