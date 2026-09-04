import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';

/// A horizontal strip that a mouse wheel can actually move.
///
/// Flutter maps a vertical wheel to vertical scrolling only, so a horizontal
/// list on a desktop PC looks scrollable and is not: the categories past the
/// edge of the screen simply cannot be reached. There is no touch screen and no
/// horizontal wheel on the counter's mouse, and dragging a list with the left
/// button is not a gesture Flutter offers by default either.
///
/// This translates a vertical wheel into horizontal movement, shows a scrollbar
/// so the overflow is visible at all, and enables drag-to-scroll so a
/// touchscreen till behaves the same way.
class HorizontalScroller extends StatefulWidget {
  const HorizontalScroller({super.key, required this.child, this.padding});

  /// The scrollable content — typically a [Row] of chips.
  final Widget child;
  final EdgeInsetsGeometry? padding;

  @override
  State<HorizontalScroller> createState() => _HorizontalScrollerState();
}

class _HorizontalScrollerState extends State<HorizontalScroller> {
  final _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Turns a vertical wheel notch into horizontal movement.
  ///
  /// Jumps rather than animates: a wheel produces a rapid burst of events, and
  /// animating each one fights the next and feels sluggish under a fast hand.
  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    if (!_controller.hasClients) return;

    // Only a purely vertical wheel is translated. A trackpad already sends a
    // horizontal delta that the scroll view applies itself, and adding this on
    // top moved the strip exactly twice as far as the fingers did.
    if (event.scrollDelta.dx != 0) return;

    final position = _controller.position;
    _controller.jumpTo(
      (position.pixels + event.scrollDelta.dy).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerSignal: _onPointerSignal,
      child: Scrollbar(
        controller: _controller,
        // Always visible: a strip that silently hides half the menu is the bug
        // this widget exists to fix. Staff need to see there is more.
        thumbVisibility: true,
        // Mouse included, so the strip can also be dragged directly.
        child: ScrollConfiguration(
          behavior: const _DragScrollBehavior(),
          child: SingleChildScrollView(
            controller: _controller,
            scrollDirection: Axis.horizontal,
            padding: widget.padding,
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

/// Lets a mouse drag the strip, which Flutter does not allow by default.
class _DragScrollBehavior extends MaterialScrollBehavior {
  const _DragScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => const {
    PointerDeviceKind.touch,
    PointerDeviceKind.mouse,
    PointerDeviceKind.trackpad,
    PointerDeviceKind.stylus,
  };
}
