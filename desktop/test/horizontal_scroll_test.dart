import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chennai_express_pos/core/widgets/horizontal_scroller.dart';

/// A strip wider than the window it is given, as the 16 category chips are.
Widget _harness({double width = 400, double content = 2000}) {
  return MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: width,
          height: 52,
          child: HorizontalScroller(
            child: Row(children: [SizedBox(width: content, height: 40)]),
          ),
        ),
      ),
    ),
  );
}

ScrollableState _scrollable(WidgetTester tester) {
  return tester.state<ScrollableState>(find.byType(Scrollable));
}

void main() {
  testWidgets('a mouse wheel moves the strip sideways', (tester) async {
    // The bug this widget exists to fix: Flutter maps a vertical wheel to
    // vertical scrolling only, so on a counter PC with no touch screen the
    // categories past the right edge could not be reached at all.
    await tester.pumpWidget(_harness());

    expect(_scrollable(tester).position.pixels, 0);

    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    pointer.hover(tester.getCenter(find.byType(HorizontalScroller)));
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 200)));
    await tester.pumpAndSettle();

    expect(
      _scrollable(tester).position.pixels,
      greaterThan(0),
      reason: 'a vertical wheel notch scrolled horizontally',
    );
  });

  testWidgets('the wheel stops at the end rather than overscrolling', (tester) async {
    // Clamped by hand, so a fast spin cannot leave the chips parked off-screen
    // in empty space.
    await tester.pumpWidget(_harness());

    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    pointer.hover(tester.getCenter(find.byType(HorizontalScroller)));
    for (var i = 0; i < 40; i++) {
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, 500)));
    }
    await tester.pumpAndSettle();

    final position = _scrollable(tester).position;
    expect(position.pixels, position.maxScrollExtent);
  });

  testWidgets('scrolling back stops at the start', (tester) async {
    await tester.pumpWidget(_harness());

    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    pointer.hover(tester.getCenter(find.byType(HorizontalScroller)));
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 300)));
    await tester.pumpAndSettle();
    for (var i = 0; i < 10; i++) {
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, -500)));
    }
    await tester.pumpAndSettle();

    expect(_scrollable(tester).position.pixels, 0);
  });

  testWidgets('a mouse can drag the strip', (tester) async {
    // Flutter excludes the mouse from drag devices by default, which leaves a
    // scrollbar the operator can see but a strip they cannot pull.
    await tester.pumpWidget(_harness());

    await tester.drag(
      find.byType(HorizontalScroller),
      const Offset(-200, 0),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();

    expect(_scrollable(tester).position.pixels, greaterThan(0));
  });

  testWidgets('the scrollbar is visible without hovering', (tester) async {
    // Staff have to be able to see that there is more menu off to the right.
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    final scrollbar = tester.widget<RawScrollbar>(find.byType(RawScrollbar));
    expect(scrollbar.thumbVisibility, isTrue);
  });

  testWidgets('the scrollbar is a hairline, not a bar', (tester) async {
    // At the default thickness it sits under the chips looking like another
    // control, competing with the categories it is only meant to hint at.
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    final scrollbar = tester.widget<RawScrollbar>(find.byType(RawScrollbar));
    expect(scrollbar.thickness, lessThanOrEqualTo(4));
  });

  testWidgets('a trackpad swipe is not doubled up', (tester) async {
    // A trackpad sends a real horizontal delta. Adding the vertical one on top
    // would move the strip twice as far as the fingers did.
    await tester.pumpWidget(_harness());

    final pointer = TestPointer(1, PointerDeviceKind.trackpad);
    pointer.hover(tester.getCenter(find.byType(HorizontalScroller)));
    await tester.sendEventToBinding(pointer.scroll(const Offset(120, 0)));
    await tester.pumpAndSettle();

    expect(_scrollable(tester).position.pixels, 120);
  });
}
