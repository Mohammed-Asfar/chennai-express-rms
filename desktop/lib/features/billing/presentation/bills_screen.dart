import 'package:flutter/material.dart';
import '../../../core/api/api_exception.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/utils/money.dart';
import '../../../core/widgets/app_loading.dart';
import '../../../core/widgets/error_banner.dart';
import '../../../core/widgets/search_field.dart';
import '../data/bill_models.dart';
import '../data/bill_repository.dart';
import 'bill_detail_dialog.dart';
import '../../../core/widgets/date_range_dialog.dart';

/// The range being listed. Business dates, inclusive at both ends.
class BillRange {
  const BillRange({required this.from, required this.to, required this.label});

  final DateTime from;
  final DateTime to;
  final String label;

  static DateTime _dayOf(DateTime value) =>
      DateTime(value.year, value.month, value.day);

  /// The default. Most of the time the question is "what has been billed today".
  factory BillRange.today() {
    final today = _dayOf(DateTime.now());
    return BillRange(from: today, to: today, label: 'Today');
  }

  factory BillRange.yesterday() {
    final day = _dayOf(DateTime.now()).subtract(const Duration(days: 1));
    return BillRange(from: day, to: day, label: 'Yesterday');
  }

  factory BillRange.lastDays(int days, String label) {
    final today = _dayOf(DateTime.now());
    return BillRange(
      from: today.subtract(Duration(days: days - 1)),
      to: today,
      label: label,
    );
  }

  factory BillRange.custom(DateTimeRange range) => BillRange(
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

  /// The wire format the backend filters on.
  static String wire(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

/// Which kinds of order to list. Null is all of them.
///
/// Kept beside the range rather than sent to the backend: the day is already
/// fetched, and the summary has to stay the range's real takings, so filtering
/// here means a type can be picked and dropped without a round trip.
enum BillType {
  dineIn('dine_in', 'Dine-in'),
  takeaway('takeaway', 'Takeaway'),
  delivery('delivery', 'Delivery');

  const BillType(this.wire, this.label);

  /// The value `orders.type` holds.
  final String wire;
  final String label;
}

final billRangeProvider = StateProvider<BillRange>((ref) => BillRange.today());

final billTypeProvider = StateProvider<BillType?>((ref) => null);

final billListProvider = FutureProvider<BillList>((ref) {
  final range = ref.watch(billRangeProvider);
  return ref
      .watch(billRepositoryProvider)
      .list(from: BillRange.wire(range.from), to: BillRange.wire(range.to));
});

/// Bills for a day or a range of days, with what was taken.
class BillsScreen extends ConsumerStatefulWidget {
  const BillsScreen({super.key});

  @override
  ConsumerState<BillsScreen> createState() => _BillsScreenState();
}

class _BillsScreenState extends ConsumerState<BillsScreen> {
  String _search = '';

  @override
  void initState() {
    super.initState();
    // Refetched every time the screen is opened. The provider caches, so
    // without this a bill taken since the last visit — the takeaway that was
    // just settled on the floor — is missing from a list that looks complete.
    //
    // After the first frame, because invalidating a provider during a build
    // that is already reading it is not allowed.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.invalidate(billListProvider);
      // The filter is cleared with it. It outlives the screen, so returning to
      // Bills tomorrow would otherwise open on the kind someone picked once,
      // showing a partial day that looks like the whole of it.
      ref.read(billTypeProvider.notifier).state = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final range = ref.watch(billRangeProvider);
    final type = ref.watch(billTypeProvider);
    final result = ref.watch(billListProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _RangeBar(
          range: range,
          onPick: (next) => ref.read(billRangeProvider.notifier).state = next,
          onCustom: () => _pickCustom(context, ref),
        ),

        _TypeBar(
          selected: type,
          onPick: (next) => ref.read(billTypeProvider.notifier).state = next,
        ),

        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.md,
            AppSpacing.lg,
            0,
          ),
          child: SearchField(
            hintText: 'Search by bill number, order number, or customer',
            onChanged: (value) => setState(() => _search = value),
          ),
        ),

        Expanded(
          child: result.when(
            loading: () => const AppLoading(message: 'Loading bills'),
            error: (error, _) => Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.xl),
                  child: ErrorBanner(message: userMessage(error)),
                ),
              ),
            ),
            data: (list) {
              if (list.bills.isEmpty) return _NoBills(range: range);

              // Two filters that mean different things to the summary. Picking
              // a type narrows what is being counted, so the totals must follow
              // it — "Delivery" over the whole day's ₹5577 would be read as
              // deliveries having taken it. Searching is a way to find one
              // bill, so it leaves the takings alone.
              final ofType = type == null
                  ? list.bills
                  : list.bills.where((b) => b.orderType == type.wire).toList();

              final shown = ofType
                  .where((bill) => bill.matches(_search))
                  .toList();

              return Column(
                children: [
                  _SummaryBar(
                    summary: type == null
                        ? list.summary
                        : BillSummary.of(ofType),
                  ),
                  Expanded(
                    child: ofType.isEmpty
                        ? _NoBillsOfType(type: type!, range: range)
                        : shown.isEmpty
                        ? NoSearchResults(query: _search, noun: 'bills')
                        : ListView.builder(
                            padding: const EdgeInsets.fromLTRB(
                              AppSpacing.lg,
                              AppSpacing.md,
                              AppSpacing.lg,
                              AppSpacing.xxl,
                            ),
                            itemCount: shown.length,
                            itemBuilder: (context, index) => _BillRow(
                              bill: shown[index],
                              // Only worth showing the date when the range
                              // spans more than one day.
                              showDate: !range.isSingleDay,
                              onTap: () => BillDetailDialog.show(
                                context,
                                shown[index].id,
                              ),
                            ),
                          ),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Future<void> _pickCustom(BuildContext context, WidgetRef ref) async {
    final current = ref.read(billRangeProvider);
    final picked = await DateRangeDialog.show(
      context,
      initialStart: current.from,
      initialEnd: current.to,
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
    );
    if (picked == null) return;
    ref.read(billRangeProvider.notifier).state = BillRange.custom(picked);
  }
}

/// The quick ranges, plus a date picker for anything else.
class _RangeBar extends StatelessWidget {
  const _RangeBar({
    required this.range,
    required this.onPick,
    required this.onCustom,
  });

  final BillRange range;
  final ValueChanged<BillRange> onPick;
  final VoidCallback onCustom;

  @override
  Widget build(BuildContext context) {
    final presets = [
      BillRange.today(),
      BillRange.yesterday(),
      BillRange.lastDays(7, 'Last 7 days'),
      BillRange.lastDays(30, 'Last 30 days'),
    ];
    final isPreset = presets.any((p) => p.label == range.label);

    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.md,
      ),
      child: Row(
        children: [
          for (final preset in presets) ...[
            _RangeChip(
              label: preset.label,
              selected: preset.label == range.label,
              onTap: () => onPick(preset),
            ),
            const SizedBox(width: AppSpacing.sm),
          ],

          // A custom range keeps its own dates as the label once chosen, so it
          // is obvious what is being shown.
          _RangeChip(
            label: isPreset ? 'Pick dates' : range.label,
            selected: !isPreset,
            icon: Icons.calendar_today_outlined,
            onTap: onCustom,
          ),
        ],
      ),
    );
  }
}

/// Dine-in, takeaway or delivery — or all of them.
///
/// Sits under the dates because it narrows what they returned, and reads in the
/// same chips so the two rows are plainly one filter, not two ideas. Each kind
/// carries the icon the rows use, which is where that icon gets named.
class _TypeBar extends StatelessWidget {
  const _TypeBar({required this.selected, required this.onPick});

  final BillType? selected;
  final ValueChanged<BillType?> onPick;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.md,
      ),
      child: Row(
        children: [
          _RangeChip(
            label: 'All orders',
            selected: selected == null,
            onTap: () => onPick(null),
          ),
          const SizedBox(width: AppSpacing.sm),

          for (final type in BillType.values) ...[
            _RangeChip(
              label: type.label,
              icon: iconFor(type.wire),
              selected: selected == type,
              // Tapping the kind already showing goes back to all of them,
              // so clearing the filter is the same button that set it.
              onTap: () => onPick(selected == type ? null : type),
            ),
            const SizedBox(width: AppSpacing.sm),
          ],
        ],
      ),
    );
  }
}

/// The mark for an order type, used on the filter and on every row.
IconData iconFor(String? orderType) => switch (orderType) {
  'takeaway' => Icons.shopping_bag_outlined,
  'delivery' => Icons.delivery_dining_outlined,
  null => Icons.help_outline,
  _ => Icons.restaurant,
};

class _RangeChip extends StatelessWidget {
  const _RangeChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Material(
      color: selected ? AppColors.accent : AppColors.surfaceSunken,
      borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.sm,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(
                  icon,
                  size: 14,
                  color: selected ? AppColors.onAccent : AppColors.inkMuted,
                ),
                const SizedBox(width: AppSpacing.xs),
              ],
              Text(
                label,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: selected ? AppColors.onAccent : AppColors.ink,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// What the range adds up to.
class _SummaryBar extends StatelessWidget {
  const _SummaryBar({required this.summary});

  final BillSummary summary;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surfaceSunken,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.md,
      ),
      child: Row(
        children: [
          _Stat(
            label: summary.count == 1 ? 'Bill' : 'Bills',
            value: '${summary.count}',
          ),
          const SizedBox(width: AppSpacing.xl),
          _Stat(label: 'Billed', value: Money.formatWithSymbol(summary.total)),
          const SizedBox(width: AppSpacing.xl),
          _Stat(
            label: 'Collected',
            value: Money.formatWithSymbol(summary.collected),
          ),
          const Spacer(),
          // Only shown when something is actually owed — a zero here every day
          // would train people to stop reading it.
          if (summary.outstanding > 0)
            _Stat(
              label: 'Still due',
              value: Money.formatWithSymbol(summary.outstanding),
              emphasis: true,
            ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({
    required this.label,
    required this.value,
    this.emphasis = false,
  });

  final String label;
  final String value;
  final bool emphasis;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label.toUpperCase(), style: theme.textTheme.labelSmall),
        const SizedBox(height: 2),
        Text(
          value,
          style: theme.textTheme.titleMedium?.copyWith(
            color: emphasis ? theme.colorScheme.error : null,
          ),
        ),
      ],
    );
  }
}

class _BillRow extends StatefulWidget {
  const _BillRow({
    required this.bill,
    required this.showDate,
    required this.onTap,
  });

  final Bill bill;
  final bool showDate;
  final VoidCallback onTap;

  @override
  State<_BillRow> createState() => _BillRowState();
}

class _BillRowState extends State<_BillRow> {
  bool _hovered = false;

  Bill get bill => widget.bill;
  bool get showDate => widget.showDate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            decoration: BoxDecoration(
              color: _hovered ? AppColors.surfaceHover : AppColors.surface,
              borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
              border: Border.all(
                color: _hovered ? AppColors.borderStrong : AppColors.border,
              ),
            ),
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Row(
              children: [
                _TypeIcon(orderType: bill.orderType),
                const SizedBox(width: AppSpacing.md),

                // Wide enough for a prefixed number as printed, e.g.
                // CE/2026-27/0016, not just the bare counter.
                SizedBox(
                  width: 190,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        bill.billNumber,
                        style: theme.textTheme.bodyLarge,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        // The order number is how the floor refers to a table's
                        // order, so it is the way back from a bill to a KOT.
                        bill.orderNo == null
                            ? _when()
                            : '${_when()}  ·  Order #${bill.orderNo}',
                        style: theme.textTheme.bodySmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),

                Expanded(
                  child: Wrap(
                    spacing: AppSpacing.xs,
                    runSpacing: AppSpacing.xs,
                    children: [
                      for (final payment in bill.livePayments)
                        _Chip(
                          label:
                              '${payment.mode.label} ${Money.formatWithSymbol(payment.amount)}',
                        ),
                      if (bill.livePayments.isEmpty)
                        const _Chip(label: "No payment yet"),
                    ],
                  ),
                ),

                _StatusPill(status: bill.paymentStatus),
                const SizedBox(width: AppSpacing.md),

                SizedBox(
                  width: 110,
                  child: Text(
                    Money.formatWithSymbol(bill.total),
                    style: theme.textTheme.titleMedium,
                    textAlign: TextAlign.right,
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Icon(
                  Icons.chevron_right,
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _when() {
    final at = bill.createdAt;
    final time = at == null
        ? ''
        : '${at.hour > 12 ? at.hour - 12 : (at.hour == 0 ? 12 : at.hour)}'
              ':${at.minute.toString().padLeft(2, '0')} '
              '${at.hour >= 12 ? 'pm' : 'am'}';
    if (!showDate) return time;
    return [bill.businessDate, time].where((s) => s.isNotEmpty).join('  ');
  }
}

/// Where the order was taken, as a mark at the head of the row.
///
/// It carries information rather than decorating: dine-in and takeaway are the
/// split most often eyeballed down a day's bills, and a shape is faster to scan
/// than reading the word on every line. Grey, not coloured — the status pill
/// and the amount are what the eye should land on first, and a third colour
/// competing with them would slow the whole row down.
class _TypeIcon extends StatelessWidget {
  const _TypeIcon({required this.orderType});

  /// dine_in, takeaway or delivery. Null for a bill whose order was purged.
  final String? orderType;

  @override
  Widget build(BuildContext context) {
    // A distinct icon per kind: delivery and takeaway are both counter sales
    // with no table, so the badge is the only thing telling them apart in a
    // list of a hundred bills. Shared with the filter chips, so the mark
    // someone tapped is the mark they then scan for.
    final icon = iconFor(orderType);
    final label = switch (orderType) {
      'takeaway' => 'Takeaway',
      'delivery' => 'Delivery',
      null => 'Order no longer on file',
      _ => 'Dine-in',
    };

    return Tooltip(
      // Named as well as drawn: an icon alone is a guess until someone is told
      // once what it means.
      message: label,
      child: Container(
        height: 36,
        width: 36,
        decoration: BoxDecoration(
          color: AppColors.surfaceSunken,
          borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
        ),
        alignment: Alignment.center,
        child: Icon(icon, size: 18, color: AppColors.inkMuted),
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.status});

  final PaymentStatus status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final (label, colour, tint) = switch (status) {
      PaymentStatus.paid => ('PAID', AppColors.success, AppColors.successTint),
      PaymentStatus.partial => (
        'PART PAID',
        AppColors.warning,
        AppColors.warningTint,
      ),
      PaymentStatus.unpaid => (
        'UNPAID',
        AppColors.danger,
        AppColors.dangerTint,
      ),
    };

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: 3,
      ),
      decoration: BoxDecoration(
        color: tint,
        borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(color: colour),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: 3,
      ),
      decoration: BoxDecoration(
        color: AppColors.surfaceSunken,
        borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
        border: Border.all(color: AppColors.border),
      ),
      child: Text(label, style: theme.textTheme.bodySmall),
    );
  }
}

/// The day had bills, just none of this kind.
///
/// Distinct from [_NoBills] because the two mean different things: nothing
/// billed at all is a quiet day, whereas no deliveries on a busy day is the
/// filter, and saying so stops it reading as lost data.
class _NoBillsOfType extends StatelessWidget {
  const _NoBillsOfType({required this.type, required this.range});

  final BillType type;
  final BillRange range;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 340),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              iconFor(type.wire),
              size: AppSpacing.xxl,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              'No ${type.label.toLowerCase()} bills',
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              range.label == 'Today'
                  ? 'Other kinds of order were billed today.'
                  : 'Other kinds of order were billed in this range.',
              style: theme.textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _NoBills extends StatelessWidget {
  const _NoBills({required this.range});

  final BillRange range;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 340),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.receipt_long_outlined,
              size: AppSpacing.xxl,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              range.label == 'Today' ? 'Nothing billed yet today' : 'No bills',
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              range.isSingleDay
                  ? 'Bills appear here as orders are settled.'
                  : 'Nothing was billed in this range.',
              style: theme.textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
