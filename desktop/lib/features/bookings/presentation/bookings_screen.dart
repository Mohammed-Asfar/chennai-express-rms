import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/widgets/app_loading.dart';
import '../../../core/widgets/error_banner.dart';
import '../../billing/presentation/reason_dialog.dart';
import '../../floor/data/floor_repository.dart';
import '../../order/presentation/order_screen.dart';
import '../data/booking_models.dart';
import '../data/booking_repository.dart';
import 'booking_editor_dialog.dart';
import 'booking_row.dart';

/// The day's bookings.
///
/// Ordered by time rather than by when they were taken: the question this
/// screen answers is "who is due next", not "who phoned first". Overdue
/// bookings are pulled out at the top, because they are the ones needing a
/// phone call before the table is given away.
class BookingsScreen extends ConsumerStatefulWidget {
  const BookingsScreen({super.key});

  @override
  ConsumerState<BookingsScreen> createState() => _BookingsScreenState();
}

class _BookingsScreenState extends ConsumerState<BookingsScreen> {
  @override
  void initState() {
    super.initState();
    // Bookings are taken over the phone while another screen is open, so what
    // was cached earlier in the shift is stale by the time this is reopened.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.invalidate(bookingsProvider);
    });
  }

  @override
  Widget build(BuildContext context) {
    final day = ref.watch(bookingsProvider);
    final date = ref.watch(bookingDateProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _DayBar(
          date: date,
          summary: day.valueOrNull?.summary,
          onShift: (days) {
            ref.read(bookingDateProvider.notifier).state = DateTime(
              date.year,
              date.month,
              date.day + days,
            );
          },
          onToday: () {
            final now = DateTime.now();
            ref.read(bookingDateProvider.notifier).state = DateTime(
              now.year,
              now.month,
              now.day,
            );
          },
          onNew: () => _book(context),
        ),
        Expanded(
          child: day.when(
            loading: () => const AppLoading(),
            error: (error, _) => Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: ErrorBanner(message: '$error'),
            ),
            data: (loaded) => loaded.bookings.isEmpty
                ? _Empty(onNew: () => _book(context))
                : _BookingList(
                    bookings: loaded.bookings,
                    onSeat: (booking) => _seat(context, booking),
                    onEdit: (booking) => _book(context, existing: booking),
                    onNoShow: (booking) => _close(context, booking, noShow: true),
                    onCancel: (booking) => _close(context, booking, noShow: false),
                  ),
          ),
        ),
      ],
    );
  }

  Future<void> _book(BuildContext context, {Booking? existing}) async {
    final warnings = await BookingEditorDialog.show(
      context,
      existing: existing,
      date: ref.read(bookingDateProvider),
    );
    if (warnings == null) return;

    ref.invalidate(bookingsProvider);
    if (!context.mounted || warnings.isEmpty) return;

    // The booking is already saved. A clash is worth saying out loud, but it is
    // the floor's call to make, not the app's.
    _tell(context, warnings.join('\n'));
  }

  Future<void> _seat(BuildContext context, Booking booking) async {
    // Which table they actually took. One order however many were held — v1 has
    // no table merge, and the party is one bill.
    final tableId = booking.tables.length > 1
        ? await _pickTable(context, booking)
        : booking.tables.firstOrNull?.id;

    if (booking.tables.length > 1 && tableId == null) return;
    if (!context.mounted) return;

    try {
      final orderId = await ref
          .read(bookingRepositoryProvider)
          .seat(booking.id, tableId: tableId);

      ref.invalidate(bookingsProvider);
      ref.invalidate(floorProvider);
      if (!context.mounted) return;

      // Straight into the order: the party is at the table waiting to order,
      // and making staff find it on the floor screen is a step for nothing.
      await Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => OrderScreen(orderId: orderId)),
      );
      ref.invalidate(floorProvider);
      ref.invalidate(bookingsProvider);
    } catch (error) {
      if (context.mounted) _tell(context, '$error');
    }
  }

  Future<String?> _pickTable(BuildContext context, Booking booking) {
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: Text('Where did ${booking.customerName} sit?'),
        children: [
          for (final table in booking.tables)
            SimpleDialogOption(
              onPressed: () => Navigator.of(dialogContext).pop(table.id),
              child: Text('${table.name} · ${table.seats} seats'),
            ),
        ],
      ),
    );
  }

  Future<void> _close(
    BuildContext context,
    Booking booking, {
    required bool noShow,
  }) async {
    final reason = await ReasonDialog.show(
      context,
      title: noShow ? 'Mark as no-show' : 'Cancel booking',
      message: noShow
          ? '${booking.customerName} did not arrive. Their table is released.'
          : "${booking.customerName}'s booking is cancelled and their table released.",
      confirmLabel: noShow ? 'No-show' : 'Cancel booking',
      hint: noShow ? 'Did not arrive' : 'Called to cancel',
    );
    if (reason == null || !context.mounted) return;

    try {
      final repository = ref.read(bookingRepositoryProvider);
      if (noShow) {
        await repository.markNoShow(booking.id, reason: reason);
      } else {
        await repository.cancel(booking.id, reason: reason);
      }
      ref.invalidate(bookingsProvider);
      ref.invalidate(floorProvider);
    } catch (error) {
      if (context.mounted) _tell(context, '$error');
    }
  }

  void _tell(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }
}

/// Overdue first, then everything else in time order.
class _BookingList extends StatelessWidget {
  const _BookingList({
    required this.bookings,
    required this.onSeat,
    required this.onEdit,
    required this.onNoShow,
    required this.onCancel,
  });

  final List<Booking> bookings;
  final ValueChanged<Booking> onSeat;
  final ValueChanged<Booking> onEdit;
  final ValueChanged<Booking> onNoShow;
  final ValueChanged<Booking> onCancel;

  @override
  Widget build(BuildContext context) {
    final overdue = bookings.where((b) => b.isOverdue).toList();
    final rest = bookings.where((b) => !b.isOverdue).toList();

    return ListView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: [
        if (overdue.isNotEmpty) ...[
          const _GroupHeading(
            label: 'Running late',
            detail: 'Past their time and not seated',
            tone: AppColors.warning,
          ),
          for (final booking in overdue) _row(booking),
          const SizedBox(height: AppSpacing.md),
          const _GroupHeading(label: 'The rest of the day', detail: null, tone: null),
        ],
        for (final booking in rest) _row(booking),
      ],
    );
  }

  Widget _row(Booking booking) => Padding(
    padding: const EdgeInsets.only(bottom: AppSpacing.sm),
    child: BookingRow(
      booking: booking,
      onSeat: () => onSeat(booking),
      onEdit: () => onEdit(booking),
      onNoShow: () => onNoShow(booking),
      onCancel: () => onCancel(booking),
    ),
  );
}

class _GroupHeading extends StatelessWidget {
  const _GroupHeading({required this.label, required this.detail, required this.tone});

  final String label;
  final String? detail;
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Row(
        children: [
          Text(
            label,
            style: theme.textTheme.titleSmall?.copyWith(color: tone ?? AppColors.ink),
          ),
          if (detail != null) ...[
            const SizedBox(width: AppSpacing.sm),
            Text(detail!, style: theme.textTheme.bodySmall),
          ],
        ],
      ),
    );
  }
}

/// The date being shown, how the day looks, and the way to add to it.
class _DayBar extends StatelessWidget {
  const _DayBar({
    required this.date,
    required this.summary,
    required this.onShift,
    required this.onToday,
    required this.onNew,
  });

  final DateTime date;
  final BookingSummary? summary;
  final ValueChanged<int> onShift;
  final VoidCallback onToday;
  final VoidCallback onNew;

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  static const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  bool get _isToday {
    final now = DateTime.now();
    return date.year == now.year && date.month == now.month && date.day == now.day;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = _isToday
        ? 'Today'
        : '${_weekdays[date.weekday - 1]} ${date.day} ${_months[date.month - 1]}';

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.md,
      ),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: [
          IconButton(
            onPressed: () => onShift(-1),
            icon: const Icon(Icons.chevron_left),
            tooltip: 'Previous day',
          ),
          SizedBox(
            width: 120,
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium,
            ),
          ),
          IconButton(
            onPressed: () => onShift(1),
            icon: const Icon(Icons.chevron_right),
            tooltip: 'Next day',
          ),
          if (!_isToday) ...[
            const SizedBox(width: AppSpacing.sm),
            TextButton(onPressed: onToday, child: const Text('Today')),
          ],

          const Spacer(),

          if (summary != null) ...[
            _Stat(label: 'Booked', value: '${summary!.booked}'),
            _Stat(label: 'Covers', value: '${summary!.covers}'),
            _Stat(label: 'Seated', value: '${summary!.seated}'),
            if (summary!.overdue > 0)
              _Stat(
                label: 'Late',
                value: '${summary!.overdue}',
                tone: AppColors.warning,
              ),
            const SizedBox(width: AppSpacing.md),
          ],

          FilledButton.icon(
            onPressed: onNew,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('New booking'),
          ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value, this.tone});

  final String label;
  final String value;
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(right: AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            value,
            style: theme.textTheme.titleMedium?.copyWith(color: tone),
          ),
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(color: tone),
          ),
        ],
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.onNew});

  final VoidCallback onNew;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.event_seat_outlined, size: 40, color: AppColors.inkFaint),
          const SizedBox(height: AppSpacing.md),
          Text('No bookings for this day', style: theme.textTheme.titleMedium),
          const SizedBox(height: AppSpacing.xs),
          Text(
            'Take one when the phone rings.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: AppSpacing.lg),
          FilledButton.icon(
            onPressed: onNew,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('New booking'),
          ),
        ],
      ),
    );
  }
}
