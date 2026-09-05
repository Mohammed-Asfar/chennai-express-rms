import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_exception.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/utils/money.dart';
import '../../../core/widgets/app_loading.dart';
import '../../../core/widgets/error_banner.dart';
import '../../printers/data/printer_repository.dart';
import '../data/bill_models.dart';
import '../data/bill_repository.dart';
import '../../auth/presentation/auth_controller.dart';
import '../../order/presentation/order_screen.dart';
import 'bills_screen.dart';
import 'edit_bill_dialog.dart';
import 'reason_dialog.dart';
import 'take_payment_dialog.dart';

final _billDetailProvider = FutureProvider.family<Bill, String>((ref, billId) {
  return ref.watch(billRepositoryProvider).fetch(billId);
});

/// Marks one bill's cached copy, and the list it appears in, as out of date.
///
/// Both together, always. The detail is a family provider keyed on the bill id
/// and caches until invalidated, so refreshing only the list left a bill whose
/// row read PART PAID ₹405 opening as PAID ₹125 — the figures from before it
/// was amended. Exported so anything that changes a bill from elsewhere, like
/// the order screen's "Update bill", cannot refresh half of it.
void invalidateBill(WidgetRef ref, String billId) {
  ref.invalidate(_billDetailProvider(billId));
  ref.invalidate(billListProvider);
}

/// Everything on one issued bill: what was sold, the tax, and how it was paid.
///
/// The figures are the ones recorded at the time, not recomputed — this is a
/// record of what the customer was charged, and it must not drift.
class BillDetailDialog extends ConsumerWidget {
  const BillDetailDialog({super.key, required this.billId});

  final String billId;

  static Future<void> show(BuildContext context, String billId) {
    return showDialog<void>(
      context: context,
      builder: (_) => BillDetailDialog(billId: billId),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(_billDetailProvider(billId));
    final maxHeight = MediaQuery.sizeOf(context).height * 0.82;

    return Dialog(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 520, maxHeight: maxHeight),
        child: detail.when(
          loading: () => const SizedBox(
            height: 220,
            child: AppLoading(message: 'Loading bill'),
          ),
          error: (error, _) => Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: ErrorBanner(message: userMessage(error)),
          ),
          data: (bill) => _Content(bill: bill),
        ),
      ),
    );
  }
}

class _Content extends ConsumerWidget {
  const _Content({required this.bill});

  final Bill bill;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: AppColors.border)),
          ),
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.md,
            AppSpacing.sm,
            AppSpacing.md,
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(bill.billNumber, style: theme.textTheme.titleLarge),
                    const SizedBox(height: 2),
                    Text(_subtitle(), style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
              _StatusPill(status: bill.paymentStatus),
              IconButton(
                icon: const Icon(Icons.close, size: 20),
                tooltip: 'Close',
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),

        // The order is open for editing, so the lines below and the total have
        // drifted apart. Saying so is the whole point — a figure that looks
        // settled is one somebody will collect against.
        if (bill.orderReopened)
          Container(
            width: double.infinity,
            color: AppColors.warningTint,
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.lg,
              vertical: AppSpacing.md,
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.edit_note_outlined,
                  size: 18,
                  color: AppColors.warning,
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    'The order is open for editing. This total is out of date '
                    'until you update it.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: AppColors.warning,
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                FilledButton(
                  onPressed: () => _recalculate(context, ref),
                  child: const Text('Update total'),
                ),
              ],
            ),
          ),

        Flexible(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(AppSpacing.lg),
            children: [
              _Section(
                title: 'Items',
                child: Column(
                  children: [
                    for (final item in bill.items) _ItemRow(item: item),
                    if (bill.items.isEmpty)
                      Text(
                        'No items recorded.',
                        style: theme.textTheme.bodySmall,
                      ),
                  ],
                ),
              ),

              const SizedBox(height: AppSpacing.md),

              _Section(
                title: 'Total',
                child: Column(
                  children: [
                    _row(theme, 'Subtotal', bill.subtotal),
                    if (bill.discountAmount > 0)
                      _row(theme, 'Discount', -bill.discountAmount),
                    // Nothing when no tax was charged. Keyed on the bill's own
                    // figures, not the current setting: this one recorded what
                    // the customer paid and must keep showing it.
                    if (bill.cgst + bill.sgst > 0) ...[
                      // A bill mixing 5% and 18% items shows each rate on its own
                      // line, so the GST can be checked group by group. With a
                      // single rate that would just repeat the totals below, so
                      // only the summed split is shown.
                      if (bill.taxBreakdown.length > 1)
                        for (final group in bill.taxBreakdown)
                          _row(
                            theme,
                            'GST ${Money.formatRate(group.rate)}% on '
                            '${Money.formatWithSymbol(group.base)}',
                            group.cgst + group.sgst,
                          ),
                      _row(theme, 'CGST', bill.cgst),
                      _row(theme, 'SGST', bill.sgst),
                    ],
                    if (bill.roundOff != 0)
                      _row(theme, 'Round off', bill.roundOff),
                    const Divider(height: AppSpacing.lg),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('Total', style: theme.textTheme.titleLarge),
                        Text(
                          Money.formatWithSymbol(bill.total),
                          style: theme.textTheme.titleLarge,
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              const SizedBox(height: AppSpacing.md),

              _Section(
                title: 'Payment',
                child: Column(
                  children: [
                    for (final payment in bill.payments)
                      _PaymentRow(
                        payment: payment,
                        // Reversing is pointless once the bill is void — it
                        // cannot be voided while a payment stands, so by then
                        // they are already reversed.
                        onReverse: payment.isReversed
                            ? null
                            : () => _reverse(context, ref, payment),
                      ),
                    if (bill.payments.isEmpty)
                      Text(
                        'Nothing has been paid on this bill.',
                        style: theme.textTheme.bodySmall,
                      ),
                    if (bill.outstanding > 0) ...[
                      const Divider(height: AppSpacing.lg),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'Still due',
                            style: theme.textTheme.titleMedium?.copyWith(
                              color: theme.colorScheme.error,
                            ),
                          ),
                          Text(
                            Money.formatWithSymbol(bill.outstanding),
                            style: theme.textTheme.titleMedium?.copyWith(
                              color: theme.colorScheme.error,
                            ),
                          ),
                        ],
                      ),
                    ],

                    // Negative outstanding means more was collected than the
                    // bill now asks for — an amendment that reduced the total
                    // below what was already taken. Staff owe the difference
                    // back, so it is stated rather than clamped to zero.
                    if (bill.outstanding < 0) ...[
                      const Divider(height: AppSpacing.lg),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('Change owed', style: theme.textTheme.titleMedium),
                          Text(
                            Money.formatWithSymbol(-bill.outstanding),
                            style: theme.textTheme.titleMedium,
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),

              // Only for a bill that has been changed, which is the minority.
              // A history section on every bill would be noise on all of them.
              if (bill.wasAmended) ...[
                const SizedBox(height: AppSpacing.md),
                _AmendmentHistory(billId: bill.id, count: bill.amendmentCount),
              ],
            ],
          ),
        ),

        Container(
          decoration: const BoxDecoration(
            color: AppColors.surfaceSunken,
            border: Border(top: BorderSide(color: AppColors.border)),
          ),
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: AppSpacing.minTapTarget,
                  child: OutlinedButton.icon(
                    onPressed: () => _print(context, ref),
                    icon: const Icon(Icons.print_outlined, size: 18),
                    // A bill printed here has printed before, so the paper
                    // says duplicate. One never printed is still an original,
                    // which the backend decides from the print history.
                    label: const Text('Print'),
                  ),
                ),
              ),

              // Amending is admin-only, like voiding. Unlike voiding it stays
              // available once money has been taken — a wrong total is worth
              // correcting whether or not it has been paid, and the payment is
              // re-derived rather than rewritten.
              //
              // The button goes straight to the order, because "edit this
              // bill" almost always means an item is wrong. Discount and
              // customer are the rarer cases and sit behind the arrow rather
              // than adding a step to the common one.
              if (ref.watch(authControllerProvider).user?.isAdmin == true) ...[
                const SizedBox(width: AppSpacing.sm),
                SizedBox(
                  height: AppSpacing.minTapTarget,
                  child: OutlinedButton(
                    onPressed: () => _edit(context, ref),
                    child: const Text('Edit'),
                  ),
                ),
                // Narrow on purpose: this row already holds Print, Void and
                // Take payment, and a wider control here overflowed the dialog
                // by twelve pixels rather than wrapping.
                SizedBox(
                  height: AppSpacing.minTapTarget,
                  width: 32,
                  child: PopupMenuButton<String>(
                    tooltip: 'Other changes',
                    padding: EdgeInsets.zero,
                    onSelected: (value) {
                      if (value == 'details') _editDetails(context, ref);
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(
                        value: 'details',
                        child: Text('Discount and customer…'),
                      ),
                    ],
                    child: const Icon(Icons.arrow_drop_down, size: 20),
                  ),
                ),
              ],

              // Voiding is admin-only and refused while money stands against
              // the bill, so it is offered only when it can actually be done.
              // Showing it otherwise would be a button that only ever errors.
              if (ref.watch(authControllerProvider).user?.isAdmin == true &&
                  bill.livePayments.isEmpty) ...[
                const SizedBox(width: AppSpacing.sm),
                SizedBox(
                  height: AppSpacing.minTapTarget,
                  child: TextButton(
                    onPressed: () => _void(context, ref),
                    style: TextButton.styleFrom(
                      foregroundColor: theme.colorScheme.error,
                    ),
                    child: const Text('Void'),
                  ),
                ),
              ],

              // Settling later is the point of being able to print a bill
              // before it is paid: by then the billing dialog is long closed.
              // Held back while the order is reopened: the total on screen is
              // stale, and taking payment against it would collect the wrong
              // amount.
              if (bill.outstanding > 0 && !bill.orderReopened) ...[
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  flex: 2,
                  child: SizedBox(
                    height: AppSpacing.minTapTarget,
                    child: ElevatedButton.icon(
                      onPressed: () => _takePayment(context, ref),
                      icon: const Icon(Icons.payments_outlined, size: 18),
                      label: Text(
                        'Take payment '
                        '${Money.formatWithSymbol(bill.outstanding)}',
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  String _subtitle() {
    final at = bill.createdAt;
    final time = at == null
        ? ''
        : '${at.hour > 12 ? at.hour - 12 : (at.hour == 0 ? 12 : at.hour)}'
              ':${at.minute.toString().padLeft(2, '0')} '
              '${at.hour >= 12 ? 'pm' : 'am'}';
    final order = bill.orderNo == null ? '' : 'Order #${bill.orderNo}';
    return [
      bill.businessDate,
      time,
      bill.placeLabel,
      order,
    ].where((s) => s.isNotEmpty).join('  ·  ');
  }

  Widget _row(ThemeData theme, String label, int paise) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: theme.textTheme.bodyMedium),
        Text(Money.formatWithSymbol(paise), style: theme.textTheme.bodyMedium),
      ],
    ),
  );

  /// Reverses a payment recorded in error.
  ///
  /// The row is kept and marked, never deleted — a cashier who recorded cash
  /// when it was card leaves both rows, and the bill's paid amount follows.
  Future<void> _reverse(
    BuildContext context,
    WidgetRef ref,
    BillPayment payment,
  ) async {
    final reason = await ReasonDialog.show(
      context,
      title: 'Reverse this payment?',
      message:
          '${payment.mode.label} ${Money.formatWithSymbol(payment.amount)} '
          'will stop counting towards this bill. The record of it stays.',
      confirmLabel: 'Reverse it',
      hint: 'Recorded as cash, was card',
    );
    if (reason == null || !context.mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(billRepositoryProvider)
          .reversePayment(bill.id, payment.id, reason);
      _refresh(ref);
      messenger.showSnackBar(const SnackBar(content: Text('Payment reversed')));
    } on ApiException catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(error.message)));
    }
  }

  /// Voids a bill raised in error, reopening its order to be corrected.
  Future<void> _void(BuildContext context, WidgetRef ref) async {
    final reason = await ReasonDialog.show(
      context,
      title: 'Void ${bill.billNumber}?',
      message:
          'It stops counting as a sale and its order reopens so it can be '
          'corrected and billed again. The bill number stays used.',
      confirmLabel: 'Void it',
      hint: 'Billed to the wrong table',
    );
    if (reason == null || !context.mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      await ref.read(billRepositoryProvider).voidBill(bill.id, reason);
      // The detail too, not only the list: the cached copy still says the bill
      // is live, and it is keyed on an id that can be reached again from a
      // wider date range.
      _refresh(ref);
      navigator.pop();
      messenger.showSnackBar(
        SnackBar(content: Text('${bill.billNumber} voided')),
      );
    } on ApiException catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(error.message)));
    }
  }

  /// The discount and the customer, which need no trip to the order screen.
  Future<void> _editDetails(BuildContext context, WidgetRef ref) async {
    final changed = await EditBillDialog.show(context, bill);
    if (changed != true) return;
    _refresh(ref);
  }

  /// Opens the order this bill was made from, so its items can be changed.
  ///
  /// Straight to the order screen, with the lines already on it — that is what
  /// "edit this bill" means to whoever pressed it, and the order screen is
  /// where adding and removing items already lives. Going through a dialog
  /// first put a step between the button and the thing it does.
  ///
  /// The bill keeps its number: the customer is not handed a second slip for
  /// the same meal. On the way back the total is brought in step and the order
  /// closes again, so nobody has to know that reopening was involved.
  ///
  /// Discount and customer details are edited from the order screen's own
  /// billing flow, which is where they were set in the first place.
  Future<void> _edit(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final repository = ref.read(billRepositoryProvider);

    String orderId;
    try {
      orderId = await repository.reopenOrder(bill.id);
    } on ApiException catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(error.message)));
      return;
    }

    if (!context.mounted) return;
    // The dialog closes behind the order screen: coming back to a bill showing
    // figures from before the edit would be worse than not showing it at all.
    navigator.pop();

    await navigator.push(
      MaterialPageRoute<void>(builder: (_) => OrderScreen(orderId: orderId)),
    );

    // Back from the order screen. Whatever the lines say now is what the bill
    // should say, and the order closes with it.
    try {
      await repository.amend(bill.id, recalculate: true);
      messenger.showSnackBar(
        SnackBar(content: Text('${bill.billNumber} updated')),
      );
    } on ApiException catch (error) {
      // The order is left open on purpose: the bill and its lines disagree,
      // and the banner on the bill is how someone finds that out.
      messenger.showSnackBar(SnackBar(content: Text(error.message)));
    }

    // Both, not just the list. The detail is a family provider keyed on the
    // bill id and caches until invalidated, so refreshing only the list left
    // the next open showing the figures from before the edit — a bill whose
    // row said PART PAID 405 opening as PAID 125.
    _refresh(ref);
  }

  /// Brings the bill back in step with an order whose lines have changed.
  Future<void> _recalculate(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(billRepositoryProvider).amend(bill.id, recalculate: true);
      _refresh(ref);
      messenger.showSnackBar(
        SnackBar(content: Text('${bill.billNumber} updated')),
      );
    } on ApiException catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(error.message)));
    }
  }

  /// Both the detail and the list behind it go stale together.
  void _refresh(WidgetRef ref) => invalidateBill(ref, bill.id);

  /// Takes a payment, then reloads so the status and balance follow.
  Future<void> _takePayment(BuildContext context, WidgetRef ref) async {
    final paid = await TakePaymentDialog.show(context, bill);
    if (paid != true) return;

    _refresh(ref);
  }

  Future<void> _print(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final result = await ref
          .read(printerRepositoryProvider)
          .printBill(bill.id);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            result.printed
                ? 'Bill printed'
                : result.error ?? 'The printer did not respond',
          ),
        ),
      );
    } on ApiException catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(error.message)));
    }
  }
}

/// One payment on the bill, with a way to undo it.
///
/// Reversed payments stay listed but struck through: they are the audit trail,
/// and hiding them makes a corrected bill look like it was always right.
class _PaymentRow extends StatelessWidget {
  const _PaymentRow({required this.payment, required this.onReverse});

  final BillPayment payment;

  /// Null once it has been reversed — there is nothing left to undo.
  final VoidCallback? onReverse;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final off = payment.isReversed;

    final style = theme.textTheme.bodyMedium?.copyWith(
      color: off ? theme.colorScheme.onSurfaceVariant : null,
      decoration: off ? TextDecoration.lineThrough : null,
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              off ? '${payment.mode.label} (reversed)' : payment.mode.label,
              style: style,
            ),
          ),
          Text(Money.formatWithSymbol(payment.amount), style: style),
          SizedBox(
            width: 40,
            child: onReverse == null
                ? null
                : IconButton(
                    icon: const Icon(Icons.undo, size: 16),
                    tooltip: 'Reverse this payment',
                    visualDensity: VisualDensity.compact,
                    onPressed: onReverse,
                  ),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: AppSpacing.sm),
            child,
          ],
        ),
      ),
    );
  }
}

class _ItemRow extends StatelessWidget {
  const _ItemRow({required this.item});

  final BillItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 32,
            child: Text('${item.qty}x', style: theme.textTheme.bodyMedium),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.displayName, style: theme.textTheme.bodyMedium),
                // The unit price only earns its place when it is not obvious
                // from the line total.
                // "GST 0%" says nothing. With tax off the line is either the
                // unit price or, at a quantity of one, nothing at all.
                if (item.qty > 1)
                  Text(
                    '${Money.formatWithSymbol(item.unitPrice)} each'
                    '${item.taxRate > 0 ? '  ·  GST ${Money.formatRate(item.taxRate)}%' : ''}',
                    style: theme.textTheme.bodySmall,
                  )
                else if (item.taxRate > 0)
                  Text(
                    'GST ${Money.formatRate(item.taxRate)}%',
                    style: theme.textTheme.bodySmall,
                  ),
              ],
            ),
          ),
          Text(
            Money.formatWithSymbol(item.lineTotal),
            style: theme.textTheme.bodyMedium,
          ),
        ],
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

/// What this bill said before it was changed.
///
/// A bill is overwritten in place, so it carries only its latest figures. This
/// is where the earlier ones live, and it is what someone reads when a total
/// does not reconcile against a printed copy or a day's takings.
///
/// Loaded on demand rather than with the bill: most bills are never amended,
/// and a second query on every open would be paid by all of them.
class _AmendmentHistory extends ConsumerWidget {
  const _AmendmentHistory({required this.billId, required this.count});

  final String billId;
  final int count;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    return _Section(
      title: 'Changed $count ${count == 1 ? 'time' : 'times'}',
      child: ref
          .watch(_amendmentsProvider(billId))
          .when(
            loading: () => Text(
              'Loading history…',
              style: theme.textTheme.bodySmall,
            ),
            error: (error, _) => Text(
              'The history could not be loaded.',
              style: theme.textTheme.bodySmall,
            ),
            data: (amendments) => Column(
              children: [
                for (final a in amendments) _AmendmentRow(amendment: a),
              ],
            ),
          ),
    );
  }
}

final _amendmentsProvider =
    FutureProvider.family<List<BillAmendment>, String>((ref, billId) {
  return ref.watch(billRepositoryProvider).amendments(billId);
});

class _AmendmentRow extends StatelessWidget {
  const _AmendmentRow({required this.amendment});

  final BillAmendment amendment;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final at = amendment.createdAt;

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(amendment.label, style: theme.textTheme.bodyMedium),
              ),
              // The figures either side, which is the reason this record
              // exists. Absent for a customer-detail edit, which moved nothing.
              if (amendment.movedMoney)
                Text(
                  '${Money.formatWithSymbol(amendment.totalBefore!)}'
                  '  →  '
                  '${Money.formatWithSymbol(amendment.totalAfter!)}',
                  style: theme.textTheme.bodyMedium,
                ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            [
              if (amendment.amendedBy != null) amendment.amendedBy!,
              if (at != null)
                '${at.day}/${at.month} '
                    '${at.hour > 12 ? at.hour - 12 : (at.hour == 0 ? 12 : at.hour)}'
                    ':${at.minute.toString().padLeft(2, '0')} '
                    '${at.hour >= 12 ? 'pm' : 'am'}',
              // The detail that matters at reconciliation: whether a document
              // already existed when the figures moved.
              if (amendment.wasPrinted) 'after printing',
              if (amendment.wasPaid) 'after payment',
              if (amendment.reason != null && amendment.reason!.isNotEmpty)
                amendment.reason!,
            ].join(' · '),
            style: theme.textTheme.bodySmall?.copyWith(color: AppColors.inkMuted),
          ),
        ],
      ),
    );
  }
}
