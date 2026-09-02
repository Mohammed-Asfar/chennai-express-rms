import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The span a report covers, as trading days.
///
/// Inclusive at both ends. The backend resolves these against `business_date`,
/// so a sale rung up at 1 AM belongs to the previous day's figures.
class ReportDateRange {
  const ReportDateRange({
    required this.from,
    required this.to,
    required this.label,
  });

  final DateTime from;
  final DateTime to;
  final String label;

  static DateTime _dayOf(DateTime value) =>
      DateTime(value.year, value.month, value.day);

  /// The default. The usual question is "how did we do today".
  factory ReportDateRange.today() {
    final today = _dayOf(DateTime.now());
    return ReportDateRange(from: today, to: today, label: 'Today');
  }

  factory ReportDateRange.yesterday() {
    final day = _dayOf(DateTime.now()).subtract(const Duration(days: 1));
    return ReportDateRange(from: day, to: day, label: 'Yesterday');
  }

  factory ReportDateRange.lastDays(int days, String label) {
    final today = _dayOf(DateTime.now());
    return ReportDateRange(
      from: today.subtract(Duration(days: days - 1)),
      to: today,
      label: label,
    );
  }

  factory ReportDateRange.custom(DateTimeRange range) => ReportDateRange(
    from: _dayOf(range.start),
    to: _dayOf(range.end),
    label: _sameDay(range.start, range.end)
        ? _pretty(range.start)
        : '${_pretty(range.start)} – ${_pretty(range.end)}',
  );

  bool get isSingleDay => _sameDay(from, to);

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  static const _months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];

  static String _pretty(DateTime d) => '${d.day} ${_months[d.month - 1]}';

  /// How the covered days read in prose, under the headline figures.
  String get spoken => isSingleDay
      ? '${_pretty(from)} ${from.year}'
      : '${_pretty(from)} – ${_pretty(to)} ${to.year}';

  /// The wire format the backend filters on.
  static String wire(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

final reportRangeProvider = StateProvider<ReportDateRange>(
  (ref) => ReportDateRange.today(),
);
