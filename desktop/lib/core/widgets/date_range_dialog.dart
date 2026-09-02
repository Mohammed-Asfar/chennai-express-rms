import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';

/// Picks a range of trading days.
///
/// Written rather than using `showDateRangePicker`, which in calendar mode sets
/// its own size from `MediaQuery.sizeOf` and takes the whole screen — on a
/// desktop till that covers the floor and reads as having navigated away.
/// This sizes to the month it is showing, so there is no dead space under a
/// short one.
class DateRangeDialog extends StatefulWidget {
  const DateRangeDialog({
    super.key,
    required this.initialStart,
    required this.initialEnd,
    required this.firstDate,
    required this.lastDate,
  });

  final DateTime initialStart;
  final DateTime initialEnd;
  final DateTime firstDate;
  final DateTime lastDate;

  static Future<DateTimeRange?> show(
    BuildContext context, {
    required DateTime initialStart,
    required DateTime initialEnd,
    required DateTime firstDate,
    required DateTime lastDate,
  }) {
    return showDialog<DateTimeRange>(
      context: context,
      builder: (_) => DateRangeDialog(
        initialStart: initialStart,
        initialEnd: initialEnd,
        firstDate: firstDate,
        lastDate: lastDate,
      ),
    );
  }

  @override
  State<DateRangeDialog> createState() => _DateRangeDialogState();
}

class _DateRangeDialogState extends State<DateRangeDialog> {
  late DateTime _month;
  late DateTime _start;
  DateTime? _end;

  @override
  void initState() {
    super.initState();
    _start = _dayOf(widget.initialStart);
    _end = _dayOf(widget.initialEnd);
    _month = DateTime(_start.year, _start.month);
  }

  static DateTime _dayOf(DateTime d) => DateTime(d.year, d.month, d.day);

  static const _monthNames = [
    'January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November', 'December',
  ];

  static const _weekdays = ['S', 'M', 'T', 'W', 'T', 'F', 'S'];

  bool get _canGoBack =>
      _month.isAfter(DateTime(widget.firstDate.year, widget.firstDate.month));

  bool get _canGoForward =>
      _month.isBefore(DateTime(widget.lastDate.year, widget.lastDate.month));

  void _shiftMonth(int by) =>
      setState(() => _month = DateTime(_month.year, _month.month + by));

  /// Tapping sets the start, then the end. A third tap starts again — the
  /// alternative is a mode toggle nobody would find.
  void _tap(DateTime day) {
    setState(() {
      if (_end != null) {
        _start = day;
        _end = null;
      } else if (day.isBefore(_start)) {
        // Picked backwards: treat it as the new start rather than refusing.
        _end = _start;
        _start = day;
      } else {
        _end = day;
      }
    });
  }

  bool _inRange(DateTime day) {
    final end = _end;
    if (end == null) return false;
    return !day.isBefore(_start) && !day.isAfter(end);
  }

  bool _isSelectable(DateTime day) =>
      !day.isBefore(_dayOf(widget.firstDate)) &&
      !day.isAfter(_dayOf(widget.lastDate));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Dialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppSpacing.radiusLg),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _header(theme),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.md,
                AppSpacing.sm,
                AppSpacing.md,
                AppSpacing.md,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _monthBar(theme),
                  const SizedBox(height: AppSpacing.sm),
                  _weekdayRow(theme),
                  const SizedBox(height: AppSpacing.xs),
                  _grid(theme),
                ],
              ),
            ),
            const Divider(height: 1),
            _actions(theme),
          ],
        ),
      ),
    );
  }

  Widget _header(ThemeData theme) {
    final end = _end;
    final label = end == null
        ? '${_pretty(_start)} – select an end date'
        : _sameDay(_start, end)
            ? _pretty(_start)
            : '${_pretty(_start)} – ${_pretty(end)}';

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.md,
        AppSpacing.lg,
        AppSpacing.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('SELECT RANGE', style: theme.textTheme.labelSmall),
          const SizedBox(height: 2),
          Text(label, style: theme.textTheme.titleLarge),
        ],
      ),
    );
  }

  Widget _monthBar(ThemeData theme) => Row(
        children: [
          IconButton(
            icon: const Icon(Icons.chevron_left, size: 20),
            tooltip: 'Previous month',
            onPressed: _canGoBack ? () => _shiftMonth(-1) : null,
          ),
          Expanded(
            child: Text(
              '${_monthNames[_month.month - 1]} ${_month.year}',
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right, size: 20),
            tooltip: 'Next month',
            onPressed: _canGoForward ? () => _shiftMonth(1) : null,
          ),
        ],
      );

  Widget _weekdayRow(ThemeData theme) => Row(
        children: [
          for (final day in _weekdays)
            Expanded(
              child: Text(
                day,
                style: theme.textTheme.labelSmall,
                textAlign: TextAlign.center,
              ),
            ),
        ],
      );

  /// The month's days, laid out in weeks. Only as many rows as the month needs,
  /// which is what keeps the dialog from growing empty space.
  Widget _grid(ThemeData theme) {
    final firstOfMonth = DateTime(_month.year, _month.month);
    final daysInMonth = DateTime(_month.year, _month.month + 1, 0).day;
    // DateTime.weekday is 1=Mon..7=Sun; the grid starts on Sunday.
    final leading = firstOfMonth.weekday % 7;

    final cells = <Widget>[
      for (var i = 0; i < leading; i++) const _EmptyCell(),
      for (var day = 1; day <= daysInMonth; day++)
        _DayCell(
          day: day,
          date: DateTime(_month.year, _month.month, day),
          selectedStart: _start,
          selectedEnd: _end,
          inRange: _inRange(DateTime(_month.year, _month.month, day)),
          enabled: _isSelectable(DateTime(_month.year, _month.month, day)),
          onTap: _tap,
        ),
    ];
    while (cells.length % 7 != 0) {
      cells.add(const _EmptyCell());
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var row = 0; row < cells.length ~/ 7; row++)
          Row(
            children: [
              for (var col = 0; col < 7; col++)
                Expanded(child: cells[row * 7 + col]),
            ],
          ),
      ],
    );
  }

  Widget _actions(ThemeData theme) => Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            const SizedBox(width: AppSpacing.sm),
            ElevatedButton(
              // Without an end date there is no range to apply yet.
              onPressed: _end == null
                  ? null
                  : () => Navigator.of(context)
                      .pop(DateTimeRange(start: _start, end: _end!)),
              child: const Text('Apply'),
            ),
          ],
        ),
      );

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  static const _shortMonths = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  static String _pretty(DateTime d) =>
      '${d.day} ${_shortMonths[d.month - 1]} ${d.year}';
}

class _EmptyCell extends StatelessWidget {
  const _EmptyCell();

  @override
  Widget build(BuildContext context) => const SizedBox(height: 40);
}

class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.day,
    required this.date,
    required this.selectedStart,
    required this.selectedEnd,
    required this.inRange,
    required this.enabled,
    required this.onTap,
  });

  final int day;
  final DateTime date;
  final DateTime selectedStart;
  final DateTime? selectedEnd;
  final bool inRange;
  final bool enabled;
  final ValueChanged<DateTime> onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isStart = _same(date, selectedStart);
    final isEnd = selectedEnd != null && _same(date, selectedEnd!);
    final isEndpoint = isStart || isEnd;

    return SizedBox(
      height: 40,
      child: Padding(
        padding: const EdgeInsets.all(2),
        child: Material(
          // Endpoints carry the accent; the days between get a wash, so the
          // span is readable at a glance.
          color: isEndpoint
              ? AppColors.accent
              : inRange
                  ? AppColors.accentTint
                  : Colors.transparent,
          borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
          child: InkWell(
            onTap: enabled ? () => onTap(date) : null,
            borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
            child: Center(
              child: Text(
                '$day',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: !enabled
                      ? AppColors.inkFaint
                      : isEndpoint
                          ? AppColors.onAccent
                          : AppColors.ink,
                  fontWeight: isEndpoint ? FontWeight.w600 : null,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  static bool _same(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}
