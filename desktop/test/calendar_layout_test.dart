import 'package:flutter_test/flutter_test.dart';

/// Mirrors the grid maths in date_range_dialog.dart. A wrong offset here puts
/// dates under the wrong weekday, which would have someone filter the wrong day.
({int leading, int daysInMonth, int rows}) layout(int year, int month) {
  final firstOfMonth = DateTime(year, month);
  final daysInMonth = DateTime(year, month + 1, 0).day;
  final leading = firstOfMonth.weekday % 7;
  final cells = leading + daysInMonth;
  final rows = (cells / 7).ceil();
  return (leading: leading, daysInMonth: daysInMonth, rows: rows);
}

void main() {
  group('month grid', () {
    test('days in month, including leap years', () {
      expect(layout(2026, 9).daysInMonth, 30, reason: 'September');
      expect(layout(2026, 2).daysInMonth, 28, reason: 'Feb 2026');
      expect(layout(2028, 2).daysInMonth, 29, reason: 'Feb 2028 is a leap year');
      expect(layout(2026, 12).daysInMonth, 31, reason: 'December');
    });

    test('the first day lands under the right weekday', () {
      // 1 Sep 2026 is a Tuesday: Sun=0, Mon=1, Tue=2.
      expect(DateTime(2026, 9, 1).weekday, DateTime.tuesday);
      expect(layout(2026, 9).leading, 2);

      // 1 Nov 2026 is a Sunday — no leading blanks.
      expect(DateTime(2026, 11, 1).weekday, DateTime.sunday);
      expect(layout(2026, 11).leading, 0);
    });

    test('rows fit the month, so no empty week is drawn', () {
      // September 2026: 2 blanks + 30 days = 32 cells = 5 rows.
      expect(layout(2026, 9).rows, 5);
      // February 2026 starts on a Sunday with 28 days: exactly 4 rows.
      expect(layout(2026, 2).rows, 4);
    });

    test('every month is covered, none overflows', () {
      for (var year = 2020; year <= 2030; year++) {
        for (var month = 1; month <= 12; month++) {
          final l = layout(year, month);
          expect(l.leading + l.daysInMonth <= l.rows * 7, isTrue,
              reason: '$year-$month overflows its rows');
          expect(l.rows <= 6, isTrue, reason: '$year-$month needs too many rows');
        }
      }
    });
  });
}
