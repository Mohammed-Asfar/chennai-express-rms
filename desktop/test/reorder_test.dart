import 'package:flutter_test/flutter_test.dart';

/// Mirrors the onReorder handler in menu_admin_screen.dart.
///
/// Flutter's ReorderableListView reports the destination index *before* the
/// dragged row is removed, so anything moved downwards arrives one place too
/// far unless it is corrected.
List<String> afterDrag(List<String> ids, int from, int to) {
  final next = [...ids];
  final target = to > from ? to - 1 : to;
  next.insert(target, next.removeAt(from));
  return next;
}

/// Mirrors _moveSection in floor_screen.dart: a step up or down, clamped.
List<String> afterStep(List<String> ids, String id, int direction) {
  final next = [...ids];
  final from = next.indexOf(id);
  final to = from + direction;
  if (from < 0 || to < 0 || to >= next.length) return next;
  next.insert(to, next.removeAt(from));
  return next;
}

void main() {
  group('dragging a category', () {
    final menu = ['biryani', 'starters', 'tiffin', 'drinks'];

    test('moves one down without overshooting', () {
      // The correction this exists for: without it, dragging Biryani to slot 1
      // lands it at slot 2 and the list quietly disagrees with the drag.
      expect(afterDrag(menu, 0, 2), [
        'starters',
        'biryani',
        'tiffin',
        'drinks',
      ]);
    });

    test('moves one up', () {
      expect(afterDrag(menu, 3, 0), [
        'drinks',
        'biryani',
        'starters',
        'tiffin',
      ]);
    });

    test('drops to the very end', () {
      expect(afterDrag(menu, 0, 4), [
        'starters',
        'tiffin',
        'drinks',
        'biryani',
      ]);
    });

    test('a drag that changes nothing leaves the list alone', () {
      expect(afterDrag(menu, 1, 1), menu);
      expect(afterDrag(menu, 1, 2), menu);
    });

    test('keeps every category, exactly once', () {
      // Losing one here would remove it from the till.
      final moved = afterDrag(menu, 2, 0);
      expect(moved.toSet(), menu.toSet());
      expect(moved.length, menu.length);
    });
  });

  group('stepping a section', () {
    final floor = ['ac', 'non-ac', 'terrace'];

    test('moves up a place', () {
      expect(afterStep(floor, 'terrace', -1), ['ac', 'terrace', 'non-ac']);
    });

    test('moves down a place', () {
      expect(afterStep(floor, 'ac', 1), ['non-ac', 'ac', 'terrace']);
    });

    test('the first cannot move up', () {
      // The menu hides the option, but the arithmetic must not wrap around to
      // the end if it is ever reached another way.
      expect(afterStep(floor, 'ac', -1), floor);
    });

    test('the last cannot move down', () {
      expect(afterStep(floor, 'terrace', 1), floor);
    });

    test('keeps every section', () {
      final moved = afterStep(floor, 'non-ac', 1);
      expect(moved.toSet(), floor.toSet());
      expect(moved.length, floor.length);
    });
  });
}
