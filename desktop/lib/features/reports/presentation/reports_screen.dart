import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_exception.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/utils/money.dart';
import '../../../core/widgets/app_loading.dart';
import '../../../core/widgets/date_range_dialog.dart';
import '../../../core/widgets/error_banner.dart';
import '../../billing/data/bill_models.dart' show PaymentStatus;
import '../data/report_models.dart';
import '../data/report_repository.dart';
import 'report_charts.dart';
import 'export_dialog.dart';
import 'report_range.dart';
import 'report_section.dart';

final reportSummaryProvider = FutureProvider<ReportSummary>((ref) {
  final range = ref.watch(reportRangeProvider);
  return ref
      .watch(reportRepositoryProvider)
      .summary(
        from: ReportDateRange.wire(range.from),
        to: ReportDateRange.wire(range.to),
      );
});

final reportItemsProvider = FutureProvider<ItemSalesReport>((ref) {
  final range = ref.watch(reportRangeProvider);
  return ref
      .watch(reportRepositoryProvider)
      .items(
        from: ReportDateRange.wire(range.from),
        to: ReportDateRange.wire(range.to),
      );
});

final reportDailyProvider = FutureProvider<DailySalesReport>((ref) {
  final range = ref.watch(reportRangeProvider);
  return ref
      .watch(reportRepositoryProvider)
      .daily(
        from: ReportDateRange.wire(range.from),
        to: ReportDateRange.wire(range.to),
      );
});

/// Outstanding is not watched against the range: it is everything still owed,
/// whenever it was billed.
final reportOutstandingProvider = FutureProvider<OutstandingReport>((ref) {
  return ref.watch(reportRepositoryProvider).outstanding();
});

/// What the owner reads at the end of a day or a month.
///
/// Every figure here is computed by the backend. Nothing on this screen adds up
/// a column itself — a total that disagreed with the bills would be worse than
/// no report at all.
/// Refetches every part of the report.
///
/// One function so the refresh button and the screen's own reload cannot fall
/// out of step and leave one panel showing older figures than another.
void refreshReports(WidgetRef ref) {
  ref.invalidate(reportSummaryProvider);
  ref.invalidate(reportItemsProvider);
  ref.invalidate(reportDailyProvider);
  ref.invalidate(reportOutstandingProvider);
}

class ReportsScreen extends ConsumerStatefulWidget {
  const ReportsScreen({super.key});

  @override
  ConsumerState<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends ConsumerState<ReportsScreen> {
  @override
  void initState() {
    super.initState();
    // Rebuilt every time the screen is opened. These providers cache, and a
    // day's takings shown from an earlier fetch is a figure someone might act
    // on — worse than a moment's loading.
    //
    // After the first frame, because invalidating a provider during a build
    // that is already reading it is not allowed.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) refreshReports(ref);
    });
  }

  @override
  Widget build(BuildContext context) {
    final range = ref.watch(reportRangeProvider);
    final summary = ref.watch(reportSummaryProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _RangeBar(
          range: range,
          onPick: (next) => ref.read(reportRangeProvider.notifier).state = next,
          onCustom: () => _pickCustom(context, ref),
        ),

        Expanded(
          child: summary.when(
            loading: () => const AppLoading(message: 'Building the report'),
            error: (error, _) => _ReportError(error: error),
            data: (data) => _ReportBody(range: range, summary: data),
          ),
        ),
      ],
    );
  }

  Future<void> _pickCustom(BuildContext context, WidgetRef ref) async {
    final current = ref.read(reportRangeProvider);
    final picked = await DateRangeDialog.show(
      context,
      initialStart: current.from,
      initialEnd: current.to,
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
    );
    if (picked == null) return;
    ref.read(reportRangeProvider.notifier).state = ReportDateRange.custom(
      picked,
    );
  }
}

/// A failed load. A cashier reaching this screen gets an explanation rather
/// than a raw 403, which tells them nothing they can act on.
class _ReportError extends StatelessWidget {
  const _ReportError({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isForbidden = error is ApiException && (error as ApiException).statusCode == 403;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: isForbidden
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.lock_outline,
                      size: AppSpacing.xxl,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    Text('Reports are admin only', style: theme.textTheme.titleLarge),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      'Ask an administrator to sign in to see sales figures.',
                      style: theme.textTheme.bodySmall,
                      textAlign: TextAlign.center,
                    ),
                  ],
                )
              : ErrorBanner(message: userMessage(error)),
        ),
      ),
    );
  }
}

/// The quick ranges, plus a date picker for anything else.
class _RangeBar extends StatelessWidget {
  const _RangeBar({
    required this.range,
    required this.onPick,
    required this.onCustom,
  });

  final ReportDateRange range;
  final ValueChanged<ReportDateRange> onPick;
  final VoidCallback onCustom;

  @override
  Widget build(BuildContext context) {
    final presets = [
      ReportDateRange.today(),
      ReportDateRange.yesterday(),
      ReportDateRange.lastDays(7, 'Last 7 days'),
      ReportDateRange.lastDays(30, 'Last 30 days'),
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

          _RangeChip(
            label: isPreset ? 'Pick dates' : range.label,
            selected: !isPreset,
            icon: Icons.calendar_today_outlined,
            onTap: onCustom,
          ),

          const Spacer(),

          // Beside the range it exports, rather than in a menu: what gets
          // written is exactly the period on screen, and putting the two
          // together is what makes that obvious.
          OutlinedButton.icon(
            onPressed: () => showDialog<bool>(
              context: context,
              builder: (_) => ExportDialog(range: range),
            ),
            icon: const Icon(Icons.download_outlined, size: 18),
            label: const Text('Export'),
          ),
        ],
      ),
    );
  }
}

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

/// The scrolling body. Long by nature, so it is broken into bounded cards.
class _ReportBody extends StatelessWidget {
  const _ReportBody({required this.range, required this.summary});

  final ReportDateRange range;
  final ReportSummary summary;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.md,
        AppSpacing.lg,
        AppSpacing.xxl,
      ),
      children: [
        _Headline(range: range, summary: summary),

        if (summary.isEmpty)
          const _NothingInRange()
        else ...[
          const _TrendSection(),
          const _TopDishesSection(),
          _CollectionsSection(summary: summary),
          _OrderTypeSection(rows: summary.byOrderType),
          _SectionSalesSection(rows: summary.bySection),
          const _ItemSalesSection(),
          _DiscountsSection(discounts: summary.discounts),
          _TaxSection(sales: summary.sales),
          const _OutstandingSection(),
          _VoidedSection(voided: summary.voided, cancelled: summary.cancelled),
        ],
      ],
    );
  }
}

/// The three figures the owner looks at first, and the days they cover.
class _Headline extends StatelessWidget {
  const _Headline({required this.range, required this.summary});

  final ReportDateRange range;
  final ReportSummary summary;

  @override
  Widget build(BuildContext context) {
    final sales = summary.sales;

    return ReportSection(
      title: range.isSingleDay ? 'Sales for the day' : 'Sales for the period',
      // FR-R12: stated on the screen, not just implied, because the difference
      // between a trading day and a calendar day is exactly what makes a
      // late-night figure look wrong to someone reading it the next morning.
      subtitle:
          'Business days ${range.spoken}. A trading day runs past midnight, so '
          'late-night sales count against the day the kitchen opened.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: ReportStat(
                  label: 'Total sales',
                  value: Money.formatWithSymbol(sales.totalSales),
                ),
              ),
              Expanded(
                child: ReportStat(
                  label: sales.billCount == 1 ? 'Bill' : 'Bills',
                  value: '${sales.billCount}',
                ),
              ),
              Expanded(
                child: ReportStat(
                  label: 'Average bill',
                  value: Money.formatWithSymbol(sales.averageBillValue),
                ),
              ),
            ],
          ),

          if (sales.outstanding > 0) ...[
            const SizedBox(height: AppSpacing.md),
            const ReportDivider(),
            ReportRow(
              label: 'Still owed on bills dated in this range',
              amount: Money.formatWithSymbol(sales.outstanding),
              emphasis: true,
            ),
          ],
        ],
      ),
    );
  }
}

/// Money in, and the two totals that are easy to mistake for each other.
class _CollectionsSection extends StatelessWidget {
  const _CollectionsSection({required this.summary});

  final ReportSummary summary;

  @override
  Widget build(BuildContext context) {
    final sales = summary.sales;
    final collections = summary.collections;

    return ReportSection(
      title: 'Payments',
      // These two figures differ whenever a bill is settled on a later day, and
      // both are correct. Saying so here stops the report being read as broken.
      subtitle:
          'A bill can be settled on a later day, so these two totals differ. '
          'Neither is wrong.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: ReportStat(
                  label: 'Collected on this range’s bills',
                  value: Money.formatWithSymbol(sales.collected),
                  note: 'Paid against bills dated in this range, whenever the '
                      'money came in.',
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: ReportStat(
                  label: 'Cash taken in this range',
                  value: Money.formatWithSymbol(collections.total),
                  note: 'Money received during these days, whatever day the '
                      'bill was dated.',
                ),
              ),
            ],
          ),

          const SizedBox(height: AppSpacing.lg),
          const ReportDivider(),
          const SizedBox(height: AppSpacing.md),

          PaymentModeDonut(
            byMode: collections.byMode,
            total: collections.total,
          ),
        ],
      ),
    );
  }
}

class _OrderTypeSection extends StatelessWidget {
  const _OrderTypeSection({required this.rows});

  final List<OrderTypeSales> rows;

  @override
  Widget build(BuildContext context) {
    return ReportSection(
      title: 'Dine-in and takeaway',
      child: rows.isEmpty
          ? const ReportEmpty(message: 'No bills in this range.')
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final row in rows) ...[
                  ReportRow(
                    label: row.type.label,
                    detail:
                        '${row.billCount} ${row.billCount == 1 ? 'bill' : 'bills'}',
                    amount: Money.formatWithSymbol(row.totalSales),
                  ),
                  if (row != rows.last) const ReportDivider(),
                ],
              ],
            ),
    );
  }
}

class _SectionSalesSection extends StatelessWidget {
  const _SectionSalesSection({required this.rows});

  final List<SectionSales> rows;

  @override
  Widget build(BuildContext context) {
    return ReportSection(
      title: 'Sales by section',
      subtitle: 'Takeaway is served from no section, so it is listed on its own.',
      child: rows.isEmpty
          ? const ReportEmpty(message: 'No bills in this range.')
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final row in rows) ...[
                  ReportRow(
                    label: row.displayName,
                    detail:
                        '${row.billCount} ${row.billCount == 1 ? 'bill' : 'bills'}',
                    amount: Money.formatWithSymbol(row.totalSales),
                  ),
                  if (row != rows.last) const ReportDivider(),
                ],
              ],
            ),
    );
  }
}

/// Sales across the days in the range.
class _TrendSection extends ConsumerWidget {
  const _TrendSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final result = ref.watch(reportDailyProvider);

    return ReportSection(
      title: 'Sales over time',
      subtitle: 'One point per trading day. A day the kitchen was shut shows as '
          'zero, not as a gap.',
      child: result.when(
        loading: () => const Padding(
          padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
          child: AppLoading(),
        ),
        error: (error, _) => ErrorBanner(message: userMessage(error)),
        data: (report) => SalesTrendChart(days: report.days),
      ),
    );
  }
}

/// The best sellers, given the prominence they earn.
///
/// The full item-wise table still follows further down: this is the headline,
/// not a replacement for the complete breakdown FR-R3 requires.
class _TopDishesSection extends ConsumerWidget {
  const _TopDishesSection();

  /// Enough to show a clear leader without becoming the full table again.
  static const _topN = 6;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final result = ref.watch(reportItemsProvider);

    return ReportSection(
      title: 'Top dishes',
      subtitle: 'By revenue before tax. The full list is below.',
      trailing: result.maybeWhen(
        data: (report) => report.items.length <= _topN
            ? null
            : Text(
                'of ${report.items.length} dishes',
                style: theme.textTheme.bodySmall,
              ),
        orElse: () => null,
      ),
      child: result.when(
        loading: () => const Padding(
          padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
          child: AppLoading(),
        ),
        error: (error, _) => ErrorBanner(message: userMessage(error)),
        data: (report) =>
            TopDishesChart(items: report.items.take(_topN).toList()),
      ),
    );
  }
}

/// Item-wise sales, loaded separately so a slow aggregate never holds up the
/// headline figures.
class _ItemSalesSection extends ConsumerWidget {
  const _ItemSalesSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final result = ref.watch(reportItemsProvider);

    return ReportSection(
      title: 'Item-wise sales',
      subtitle: 'Revenue is before tax and before any bill-level discount.',
      trailing: result.maybeWhen(
        data: (report) => Text(
          '${report.totals.qty} sold',
          style: theme.textTheme.bodySmall,
        ),
        orElse: () => null,
      ),
      child: result.when(
        loading: () => const Padding(
          padding: EdgeInsets.symmetric(vertical: AppSpacing.md),
          child: AppLoading(),
        ),
        error: (error, _) => ErrorBanner(message: userMessage(error)),
        data: (report) => report.items.isEmpty
            ? const ReportEmpty(message: 'Nothing was sold in this range.')
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final item in report.items) ...[
                    ReportRow(
                      label: item.displayName,
                      detail: '${item.qty} sold',
                      amount: Money.formatWithSymbol(item.revenue),
                      trailingDetail:
                          'with tax ${Money.formatWithSymbol(item.gross)}',
                    ),
                    const ReportDivider(),
                  ],
                  ReportRow(
                    label: 'Total',
                    detail: '${report.totals.qty} items',
                    amount: Money.formatWithSymbol(report.totals.revenue),
                    trailingDetail:
                        'with tax ${Money.formatWithSymbol(report.totals.gross)}',
                  ),
                ],
              ),
      ),
    );
  }
}

class _DiscountsSection extends StatelessWidget {
  const _DiscountsSection({required this.discounts});

  final Discounts discounts;

  @override
  Widget build(BuildContext context) {
    return ReportSection(
      title: 'Discounts given',
      subtitle: 'Who authorised money off, and how much.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ReportRow(
            label: 'Total discounted',
            amount: Money.formatWithSymbol(discounts.total),
          ),

          if (discounts.byUser.isNotEmpty) ...[
            const ReportDivider(),
            for (final user in discounts.byUser) ...[
              ReportRow(
                label: user.fullName.isEmpty ? user.username : user.fullName,
                detail:
                    '${user.billCount} ${user.billCount == 1 ? 'bill' : 'bills'}',
                amount: Money.formatWithSymbol(user.discountTotal),
              ),
              if (user != discounts.byUser.last) const ReportDivider(),
            ],
          ] else if (discounts.total == 0)
            const ReportEmpty(message: 'No discounts in this range.'),
        ],
      ),
    );
  }
}

/// The GST split, as it would be reconciled against a return.
class _TaxSection extends StatelessWidget {
  const _TaxSection({required this.sales});

  final SalesTotals sales;

  @override
  Widget build(BuildContext context) {
    return ReportSection(
      title: 'Tax and totals',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ReportRow(
            label: 'Subtotal',
            amount: Money.formatWithSymbol(sales.subtotal),
          ),
          const ReportDivider(),
          ReportRow(
            label: 'Discount',
            amount: Money.formatWithSymbol(sales.discountTotal),
          ),
          // Omitted when the range collected no tax, so a restaurant with GST
          // switched off is not asked to read two zero rows every day. A range
          // that does include taxed bills still shows them.
          if (sales.cgst + sales.sgst > 0) ...[
            const ReportDivider(),
            ReportRow(label: 'CGST', amount: Money.formatWithSymbol(sales.cgst)),
            const ReportDivider(),
            ReportRow(label: 'SGST', amount: Money.formatWithSymbol(sales.sgst)),
          ],
          const ReportDivider(),
          ReportRow(
            label: 'Round-off',
            amount: Money.formatWithSymbol(sales.roundOff),
          ),
          const ReportDivider(),
          ReportRow(
            label: 'Total sales',
            amount: Money.formatWithSymbol(sales.totalSales),
          ),
        ],
      ),
    );
  }
}

/// Everything still owed, at any age. Not filtered by the chosen range.
class _OutstandingSection extends ConsumerWidget {
  const _OutstandingSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final result = ref.watch(reportOutstandingProvider);

    return ReportSection(
      title: 'Outstanding balances',
      // Range-independent on purpose: a debt from three weeks ago is still owed
      // today, and hiding it behind a date filter would lose it.
      subtitle: result.maybeWhen(
        data: (report) => 'Everything unpaid as of ${report.asOf}, whenever it '
            'was billed — not limited to the range above.',
        orElse: () => 'Everything unpaid, whenever it was billed.',
      ),
      trailing: result.maybeWhen(
        data: (report) => report.total == 0
            ? null
            : Text(
                Money.formatWithSymbol(report.total),
                style: theme.textTheme.titleMedium?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
        orElse: () => null,
      ),
      child: result.when(
        loading: () => const Padding(
          padding: EdgeInsets.symmetric(vertical: AppSpacing.md),
          child: AppLoading(),
        ),
        error: (error, _) => ErrorBanner(message: userMessage(error)),
        data: (report) => report.bills.isEmpty
            ? const ReportEmpty(message: 'Nothing is owed. Every bill is settled.')
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final bill in report.bills) ...[
                    ReportRow(
                      label: _label(bill),
                      detail: _detail(bill),
                      amount: Money.formatWithSymbol(bill.outstanding),
                      trailingDetail: bill.paymentStatus == PaymentStatus.partial
                          ? 'of ${Money.formatWithSymbol(bill.total)}'
                          : null,
                      emphasis: true,
                    ),
                    if (bill != report.bills.last) const ReportDivider(),
                  ],
                ],
              ),
      ),
    );
  }

  String _label(OutstandingBill bill) {
    final customer = bill.customerName;
    if (customer == null || customer.isEmpty) return bill.billNumber;
    return '${bill.billNumber}  ·  $customer';
  }

  String _detail(OutstandingBill bill) {
    final age = switch (bill.ageDays) {
      0 => 'today',
      1 => '1 day old',
      final days => '$days days old',
    };
    return '${bill.businessDate}  ·  $age';
  }
}

/// Voids and cancellations, kept together as the exceptions worth a second look.
class _VoidedSection extends StatelessWidget {
  const _VoidedSection({required this.voided, required this.cancelled});

  final VoidedSummary voided;
  final CancelledSummary cancelled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ReportSection(
      title: 'Voided and cancelled',
      subtitle: 'Excluded from every figure above.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Voided bills', style: theme.textTheme.titleMedium),
          const SizedBox(height: AppSpacing.xs),
          if (voided.bills.isEmpty)
            const ReportEmpty(message: 'No bills were voided in this range.')
          else ...[
            for (final bill in voided.bills) ...[
              ReportRow(
                label: bill.billNumber,
                detail: _voidDetail(bill),
                amount: Money.formatWithSymbol(bill.total),
              ),
              if (bill != voided.bills.last) const ReportDivider(),
            ],
            const ReportDivider(),
            ReportRow(
              label: '${voided.billCount} voided',
              amount: Money.formatWithSymbol(voided.total),
            ),
          ],

          const SizedBox(height: AppSpacing.lg),

          Text('Cancelled orders', style: theme.textTheme.titleMedium),
          const SizedBox(height: AppSpacing.xs),
          if (cancelled.orders.isEmpty)
            const ReportEmpty(message: 'No orders were cancelled in this range.')
          else ...[
            for (final order in cancelled.orders) ...[
              ReportRow(
                label: order.orderNo == null
                    ? order.type.label
                    : 'Order #${order.orderNo}  ·  ${order.type.label}',
                detail: _cancelDetail(order),
                amount: Money.formatWithSymbol(order.value),
              ),
              if (order != cancelled.orders.last) const ReportDivider(),
            ],
            const ReportDivider(),
            ReportRow(
              label: '${cancelled.orderCount} cancelled',
              amount: Money.formatWithSymbol(cancelled.total),
            ),
          ],
        ],
      ),
    );
  }

  String _voidDetail(VoidedBill bill) {
    final parts = [
      bill.businessDate,
      if (bill.voidedByName != null && bill.voidedByName!.isNotEmpty)
        bill.voidedByName!,
      if (bill.reason != null && bill.reason!.isNotEmpty) bill.reason!,
    ];
    return parts.join('  ·  ');
  }

  String _cancelDetail(CancelledOrder order) {
    final parts = [
      order.businessDate,
      if (order.reason != null && order.reason!.isNotEmpty) order.reason!,
    ];
    return parts.join('  ·  ');
  }
}

/// A range that produced no trading at all.
class _NothingInRange extends StatelessWidget {
  const _NothingInRange();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.xxl),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 340),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.insights_outlined,
                size: AppSpacing.xxl,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: AppSpacing.md),
              Text('Nothing to report', style: theme.textTheme.titleLarge),
              const SizedBox(height: AppSpacing.xs),
              Text(
                'No bills were raised on these trading days.',
                style: theme.textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
